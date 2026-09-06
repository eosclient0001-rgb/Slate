//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/Shaders/HorizonProjection.wgsl — Ocean Surface Rendering (VS-generated grid, band fade, shading)
//============================================================================================================================================
//
//    One camera-centred grid of (G+1)² vertices, generated in the vertex shader from vertex_index (References §4 tier 0, after
//    Ryan 2026: a single big grid beats CPU-culled tiles). The grid square [−1, 1]² is warped by Chebyshev radius ρ = max(|tx|, |ty|)
//    → world radius ρ' = A (e^{αρ} − 1): cells are Cell metres wide at the camera and grow linearly with distance, so their
//    projected size stays roughly constant out to the horizon (α, A from HorizonProjection.js). The grid centre snaps to whole
//    cells so the near field does not swim when the camera moves.
//
//    Band fade (the aliasing cure): a band only displaces vertices where the local vertex spacing resolves its shortest wave
//    (≥ 4 vertices per λ_min, fading to 0 at 2), and only shades pixels whose footprint is finer than its texel; the slope
//    variance of a faded band is added to the micro-facet roughness instead (LEADR lineage), so the far sea keeps its glitter
//    without shimmering. Shading: Schlick Fresnel · analytic sky reflection, deep-water colour + crest scattering, GGX sun
//    glint, foam from FoamSolver's window, distance haze. Colours are linear, output is gamma-encoded.
//
//    Views (View.Screen.y): 0 shaded · 1 foam energy (R) and mask (G) · 2 Jacobian · 3 vertex band weights · 4 surface speed ·
//    5 shoal patch (depth, sand, bores, rim). Tier 2 (bindings 8–9): inside the patch window, wherever the water is shallow
//    enough for the patch to own the wave (Handover), the SWE free surface η = h + bed replaces the bands it can resolve and
//    its finite-difference slope joins the normal; the bands fade with depth where they would have broken; dry cells draw as sand.

const Pi = 3.14159265358979;

// struct Sea comes from SeaStructure.wgsl (prepended by HorizonProjection.js).

struct View
{
    ViewProjection: mat4x4f,
    Eye:            vec4f,    // xyz camera [m] · w sea level [m]
    Sun:            vec4f,    // xyz unit direction toward the sun · w intensity
    Grid:           vec4f,    // x G (cells per side) · y Cell [m] · z A [m] · w α
    Screen:         vec4f,    // x pixel angle [rad/px] · y view · z fade scale · w significant height Hs [m]
    Centre:         vec4f,    // xy snapped grid centre [m] · z haze distance [m] · w exposure
    Slope:          vec4f,    // mean-square slope per band [-] (Beckmann α² contribution)
    LambdaMin:      vec4f,    // shortest wavelength per band [m]
    Right:          vec4f,    // xyz camera right · w tan(horizontal fov / 2)
    Up:             vec4f,    // xyz camera up · w tan(vertical fov / 2)
    Forward:        vec4f,    // xyz camera forward
};

@group(0) @binding(0) var<uniform> U: Sea;
@group(0) @binding(1) var<uniform> V: View;
@group(0) @binding(2) var Displacement: texture_2d_array<f32>;
@group(0) @binding(3) var Derivative:   texture_2d_array<f32>;
@group(0) @binding(4) var Motion:       texture_2d_array<f32>;
@group(0) @binding(5) var Wrap:         sampler;
@group(0) @binding(6) var Foam:         texture_2d<f32>;
@group(0) @binding(7) var Clamp:        sampler;
@group(0) @binding(8) var<uniform> P:   Shoal;                   // tier 2 patch (scene 0 = absent)
@group(0) @binding(9) var Patch:        texture_2d<f32>;         // SWE state (h, u, v, bore)

struct Surface
{
    @builtin(position) Clip: vec4f,
    @location(0) World:   vec3f,     // displaced position [m]
    @location(1) Grid:    vec2f,     // undisplaced grid position [m] (band and foam lookups)
    @location(2) Weights: vec4f,     // per-band vertex weights (× depth fade)
    @location(3) Speed:   f32,       // |surface velocity| [m/s]
    @location(4) Shoal:   vec4f,     // x patch share (PatchWeight × Handover) · y water depth h [m] · z bed [m] · w bore
};

// Bilinear read of the patch state at world position p (h, u, v, bore); the bed is analytic so η = h + Bed.
fn PatchState(p: vec2f) -> vec4f
{
    let cell = (p - P.Patch.xy) / P.Patch.z - 0.5;
    let n = P.Patch.w - 1.0;
    let c = clamp(cell, vec2f(0.0), vec2f(n));
    let i0 = vec2u(floor(c));
    let i1 = min(i0 + vec2u(1u), vec2u(u32(n)));
    let f = fract(c);
    let s00 = textureLoad(Patch, i0, 0);
    let s10 = textureLoad(Patch, vec2u(i1.x, i0.y), 0);
    let s01 = textureLoad(Patch, vec2u(i0.x, i1.y), 0);
    let s11 = textureLoad(Patch, i1, 0);
    return mix(mix(s00, s10, f.x), mix(s01, s11, f.x), f.y);
}

//------------------------------------------------------------------------------------------------------------------------
//                                                        GRID
//------------------------------------------------------------------------------------------------------------------------

fn BandWeight(spacing: f32, band: u32) -> f32
{
    return clamp(V.LambdaMin[band] / spacing * 0.5 - 1.0, 0.0, 1.0);    // 1 at ≥ 4 vertices per λ_min, 0 at ≤ 2
}

@vertex
fn SurfaceVertex(@builtin(vertex_index) index: u32) -> Surface
{
    let g = u32(V.Grid.x);
    let columns = g + 1u;
    let ix = index % columns;
    let iy = index / columns;
    let t = (vec2f(f32(ix), f32(iy)) - 0.5 * V.Grid.x) / (0.5 * V.Grid.x);
    let rho = max(abs(t.x), abs(t.y));
    let radius = V.Grid.z * (exp(V.Grid.w * rho) - 1.0);
    let scale = select(radius / rho, V.Grid.z * V.Grid.w, rho < 1.0e-6);
    let grid = V.Centre.xy + t * scale;
    let spacing = (radius + V.Grid.z) * V.Grid.w * 2.0 / V.Grid.x;      // radial vertex spacing here [m]

    var displaced = vec3f(grid, V.Eye.w);
    var velocity = vec3f(0.0);
    var weights = vec4f(0.0);
    // Tier 2: inside the patch window the shallow-water surface owns the resolvable bands wherever the water is shallow
    // (Handover); the spectral bands keep the rest and fade with depth; the bed shapes both.
    let patchWeight = PatchWeight(P, grid);
    let bed = Bed(P, grid);
    let still = -bed;
    let share = patchWeight * Handover(P, still);
    var shoal = vec4f(share, 0.0, bed, 0.0);
    var spectral = vec3f(0.0);
    for (var b = 0u; b < U.Grid.z; b++)
    {
        let w = BandWeight(spacing, b) * DepthWeight(P, b, still) * SpectralShare(P, b, share);
        weights[b] = w;
        if (w > 0.0)
        {
            let uv = grid / U.Length[b];
            let d = textureSampleLevel(Displacement, Wrap, uv, b, 0.0);
            let m = textureSampleLevel(Motion, Wrap, uv, b, 0.0);
            spectral += w * vec3f(d.x, d.y, d.z);
            velocity += w * vec3f(m.z, m.w, m.y);
        }
    }
    displaced += spectral;
    if (patchWeight > 0.0)
    {
        let state = PatchState(grid);
        displaced.z += share * (state.x + bed);                                   // SWE free surface η = h + bed (= bed when dry)
        velocity += share * vec3f(state.y, state.z, 0.0);
        shoal = vec4f(share, state.x, bed, state.w);
    }
    // Land exists everywhere the bed rises above the sea (the analytic beach continues beyond the patch): the surface
    // never dips below the sand, and shoal.y carries the water depth so the fragment shader knows it stands on land.
    if (P.Wave.w > 1.5 && displaced.z < bed)
    {
        displaced.z = bed;
        shoal.y = 0.0;
    }
    else if (patchWeight <= 0.0 && P.Wave.w > 1.5)
    {
        shoal.y = displaced.z - bed;
    }
    var out: Surface;
    out.Clip = V.ViewProjection * vec4f(displaced, 1.0);
    out.World = displaced;
    out.Grid = grid;
    out.Weights = weights;
    out.Speed = length(velocity);
    out.Shoal = shoal;
    return out;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                       SHADING
//------------------------------------------------------------------------------------------------------------------------

fn Sky(direction: vec3f) -> vec3f
{
    let up = clamp(direction.z, 0.0, 1.0);
    let zenith = vec3f(0.11, 0.26, 0.58);
    let horizon = vec3f(0.62, 0.72, 0.82);
    var colour = mix(horizon, zenith, pow(up, 0.55));
    let toSun = max(dot(direction, V.Sun.xyz), 0.0);
    colour += vec3f(1.0, 0.85, 0.6) * (0.15 * pow(toSun, 8.0) + 25.0 * pow(toSun, 800.0)) * V.Sun.w;
    return colour;
}

fn Hash(p: vec2f) -> f32
{
    let q = fract(p * vec2f(0.1031, 0.1030) + vec2f(0.37, 0.11));
    let d = dot(q, q.yx + 33.33);
    return fract((q.x + d) * (q.y + d) * 13.7);
}

fn Tonemap(c: vec3f) -> vec3f
{
    let x = c * V.Centre.w;
    let mapped = (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);      // ACES fit (Narkowicz)
    return pow(clamp(mapped, vec3f(0.0), vec3f(1.0)), vec3f(1.0 / 2.2));
}

@fragment
fn SurfaceFragment(in: Surface) -> @location(0) vec4f
{
    let toEye = V.Eye.xyz - in.World;
    let range = length(toEye);
    let v = toEye / range;
    let footprint = range * V.Screen.x;                                  // world size of one pixel here [m]

    // Slopes and Jacobian from the resolved bands; the unresolved bands roughen the surface instead.
    var hx = 0.0;
    var hy = 0.0;
    var dxx = 0.0;
    var dyy = 0.0;
    var dxy = 0.0;
    var roughness2 = 0.0015;
    var height = 0.0;
    let still = -in.Shoal.z;
    for (var b = 0u; b < U.Grid.z; b++)
    {
        var pixelWeight = clamp(2.0 - footprint / (U.Spacing[b] * V.Screen.z), 0.0, 1.0);
        pixelWeight *= DepthWeight(P, b, still) * SpectralShare(P, b, in.Shoal.x);
        let uv = in.Grid / U.Length[b];
        let der = textureSampleLevel(Derivative, Wrap, uv, b, 0.0);
        let dis = textureSampleLevel(Displacement, Wrap, uv, b, 0.0);
        hx += pixelWeight * der.x;
        hy += pixelWeight * der.y;
        dxx += pixelWeight * der.z;
        dyy += pixelWeight * der.w;
        dxy += pixelWeight * dis.w;
        height += pixelWeight * dis.z;
        roughness2 += (1.0 - pixelWeight) * V.Slope[b] * DepthWeight(P, b, still);
    }
    // Tier 2: the patch's free-surface slope (finite differences of η = h + bed) blends in with the patch weight.
    if (in.Shoal.x > 0.0)
    {
        let e = P.Patch.z;
        let etaE = PatchState(in.Grid + vec2f(e, 0.0)).x + Bed(P, in.Grid + vec2f(e, 0.0));
        let etaW = PatchState(in.Grid - vec2f(e, 0.0)).x + Bed(P, in.Grid - vec2f(e, 0.0));
        let etaN = PatchState(in.Grid + vec2f(0.0, e)).x + Bed(P, in.Grid + vec2f(0.0, e));
        let etaS = PatchState(in.Grid - vec2f(0.0, e)).x + Bed(P, in.Grid - vec2f(0.0, e));
        hx += in.Shoal.x * (etaE - etaW) / (2.0 * e);
        hy += in.Shoal.x * (etaN - etaS) / (2.0 * e);
        height += in.Shoal.x * (in.Shoal.y + in.Shoal.z);
    }
    // The height field is h(x) at grid x; the surface sits at x + δ(x), so the slope there is J⁻ᵀ·∇h.
    let det = max((1.0 + dxx) * (1.0 + dyy) - dxy * dxy, 0.05);
    let sx = ((1.0 + dyy) * hx - dxy * hy) / det;
    let sy = (-dxy * hx + (1.0 + dxx) * hy) / det;
    let n = normalize(vec3f(-sx, -sy, 1.0));
    let jacobian = (1.0 + dxx) * (1.0 + dyy) - dxy * dxy;

    let foamUv = (in.Grid - U.Window.xy) / (U.Window.z * U.Window.w);
    let rim = clamp(min(min(foamUv.x, 1.0 - foamUv.x), min(foamUv.y, 1.0 - foamUv.y)) / 0.05, 0.0, 1.0);   // the window's soft edge
    let foam = textureSampleLevel(Foam, Clamp, foamUv, 0.0) * rim;
    let view = u32(V.Screen.y);
    if (view == 1u)
    {
        return vec4f(foam.x, foam.y * 0.6, 0.0, 1.0);
    }
    if (view == 2u)
    {
        let j = clamp(jacobian, 0.0, 2.0);
        return vec4f(clamp(1.0 - j, 0.0, 1.0), clamp(j - 1.0, 0.0, 1.0) * 0.5, select(0.0, 1.0, j < U.Foam.x), 1.0);
    }
    if (view == 3u)
    {
        return vec4f(in.Weights.x, in.Weights.y, in.Weights.z + 0.5 * in.Weights.w, 1.0);
    }
    if (view == 4u)
    {
        let s = clamp(in.Speed / 3.0, 0.0, 1.0);
        return vec4f(s, 0.35 * s, 1.0 - s, 1.0);
    }
    if (view == 5u)
    {
        // tier 2: depth (blue), dry sand (tan), bores (red), patch rim (green)
        let dryness = select(0.0, 1.0, in.Shoal.y <= P.Limits.x && P.Wave.w > 1.5);
        let depthShade = clamp(in.Shoal.y / 10.0, 0.0, 1.0);
        var c = mix(vec3f(0.1, 0.4, 0.9), vec3f(0.0, 0.05, 0.3), depthShade) * max(in.Shoal.x, 0.25);
        c = mix(c, vec3f(0.76, 0.66, 0.45), dryness);
        c = mix(c, vec3f(1.0, 0.1, 0.05), clamp(in.Shoal.w, 0.0, 1.0));
        c += vec3f(0.0, 0.5, 0.0) * step(0.02, in.Shoal.x) * step(in.Shoal.x, 0.98);
        return vec4f(c, 1.0);
    }
    // The hull: a flat deck disc where its pressure head exceeds 60 % (the water around it is physically depressed).
    if (P.Hull.w > 0.0 && HullHead(P, in.Grid) > 0.6 * P.Hull.w)
    {
        let deck = vec3f(0.32, 0.30, 0.27) * (0.4 + 0.6 * V.Sun.w);
        return vec4f(Tonemap(deck), 1.0);
    }
    // Dry sand inside the patch (and the beach above the sea outside it): a diffuse Lambert surface, wet near the water.
    let onLand = P.Wave.w > 1.5 && in.Shoal.y <= P.Limits.x;
    if (onLand)
    {
        let bedN = normalize(vec3f(-(Bed(P, in.Grid + vec2f(0.5, 0.0)) - Bed(P, in.Grid - vec2f(0.5, 0.0))),
                                   -(Bed(P, in.Grid + vec2f(0.0, 0.5)) - Bed(P, in.Grid - vec2f(0.0, 0.5))), 1.0));
        // wet where the swash reaches (foam memory) and just above the waterline; the sand is a dry Lambert surface with a
        // little grain so the beach is not a flat card
        let wetness = clamp(1.0 - (in.Shoal.z - V.Eye.w) / 0.8, 0.0, 1.0) * clamp(foam.x * 6.0 + 0.35, 0.0, 1.0);
        let grain = 0.92 + 0.16 * Hash(floor(in.Grid * 3.0));
        let sand = mix(vec3f(0.78, 0.68, 0.50), vec3f(0.36, 0.30, 0.21), wetness) * grain;
        // the same light budget as the foam (sky ambient + sun), so the beach and the whitecaps sit in one exposure
        let skyUp = Sky(vec3f(0.0, 0.0, 1.0));
        let lit = sand * (0.3 * skyUp + vec3f(1.0, 0.96, 0.88) * (0.25 + 0.75 * max(dot(bedN, V.Sun.xyz), 0.0)) * V.Sun.w);
        let landHaze = 1.0 - exp(-range / V.Centre.z);
        return vec4f(Tonemap(mix(lit, Sky(normalize(vec3f(-v.xy, 0.0))) * 0.98, landHaze)), 1.0);
    }

    let l = V.Sun.xyz;
    let nv = max(dot(n, v), 1.0e-3);
    let fresnel = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
    var r = reflect(-v, n);
    r.z = max(r.z, 0.02);                                                // no below-horizon reflections from steep normals
    let reflected = Sky(normalize(r));

    let deep = vec3f(0.003, 0.014, 0.040);
    let scatterColour = vec3f(0.02, 0.18, 0.22);
    let crest = clamp(height / max(V.Screen.w, 0.05) + 0.4, 0.0, 1.0);
    let backlight = pow(clamp(dot(-v, l) * 0.5 + 0.5, 0.0, 1.0), 3.0);
    let ambient = Sky(vec3f(0.0, 0.0, 1.0)) * 0.35;
    var water = deep * (ambient + vec3f(1.0, 0.95, 0.85) * max(dot(n, l), 0.0) * V.Sun.w * 0.4)
              + scatterColour * crest * (0.25 + 1.6 * backlight) * (0.3 + 0.7 * max(dot(n, l), 0.0)) * V.Sun.w * 0.5;

    let h = normalize(l + v);
    let nh = max(dot(n, h), 0.0);
    let alpha2 = roughness2;
    let denominator = nh * nh * (alpha2 - 1.0) + 1.0;
    let d = alpha2 / (Pi * denominator * denominator);
    let glint = vec3f(1.0, 0.92, 0.8) * V.Sun.w * 30.0 * d * max(dot(n, l), 0.0) * 0.25 / nv;

    var colour = mix(water, reflected, fresnel) + glint * (0.02 + 0.98 * pow(1.0 - max(dot(v, h), 0.0), 5.0));
    if (P.Wave.w > 1.5)
    {
        // shallow water over sand: the bed shows through with Beer–Lambert attenuation over the slant depth
        let slant = max(in.Shoal.y, 0.0) / max(nv, 0.2);
        let seen = exp(-slant * vec3f(0.9, 0.35, 0.25));
        let sandLit = vec3f(0.55, 0.47, 0.33) * (0.3 + 0.7 * max(dot(vec3f(0.0, 0.0, 1.0), l), 0.0)) * V.Sun.w * 0.7;
        colour = mix(colour, mix(water, sandLit, seen) * (1.0 - fresnel) + reflected * fresnel + glint * 0.5, (1.0 - fresnel) * 0.9 * max(max(seen.x, seen.y), seen.z));
    }

    let speckle = Hash(floor(in.Grid * 4.0));
    let cover = clamp(foam.x * 1.5 - 0.35 * speckle * (1.0 - foam.x), 0.0, 1.0);
    let foamColour = vec3f(0.9, 0.93, 0.95) * (0.35 + 0.65 * max(dot(n, l), 0.0) * V.Sun.w + 0.3 * ambient);
    colour = mix(colour, foamColour, cover);

    let haze = 1.0 - exp(-range / V.Centre.z);
    colour = mix(colour, Sky(normalize(vec3f(-v.xy, 0.0))) * 0.98, haze);
    return vec4f(Tonemap(colour), 1.0);
}

//------------------------------------------------------------------------------------------------------------------------
//                                                         SKY
//------------------------------------------------------------------------------------------------------------------------

struct Dome
{
    @builtin(position) Clip: vec4f,
    @location(0) Ndc: vec2f,
};

@vertex
fn SkyVertex(@builtin(vertex_index) index: u32) -> Dome
{
    var corners = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    var out: Dome;
    out.Clip = vec4f(corners[index], 0.0, 1.0);                           // reversed depth: 0 is the far plane
    out.Ndc = corners[index];
    return out;
}

@fragment
fn SkyFragment(in: Dome) -> @location(0) vec4f
{
    let direction = normalize(V.Forward.xyz + in.Ndc.x * V.Right.w * V.Right.xyz + in.Ndc.y * V.Up.w * V.Up.xyz);
    var colour = Sky(direction);
    if (direction.z < 0.0)
    {
        colour = Sky(vec3f(direction.xy, 0.0)) * 0.98;                    // below the grid's edge: haze colour
    }
    return vec4f(Tonemap(colour), 1.0);
}
