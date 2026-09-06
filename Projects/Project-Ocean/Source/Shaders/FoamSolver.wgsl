//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/Shaders/FoamSolver.wgsl — Persistent Whitecap Foam (breaking mask → decaying, spreading energy)
//============================================================================================================================================
//
//    Tier 1 of References/OceanPhaseO0-SurveyAndPlan.md §4. A square window of FoamSize² texels rides with the camera (its origin
//    is snapped to whole texels, so nothing swims). Each tick every texel of the window:
//        1. sums the band derivatives at its grid position and forms the Jacobian J = (1 + ∂δx/∂x)(1 + ∂δy/∂y) − (∂δx/∂y)² of
//           the horizontal displacement (choppiness ξ already folded into the textures) and the vertical acceleration a_z;
//        2. fires the breaking mask when J < J_threshold (the surface folds — War Thunder / Tessendorf) OR a_z ≤ −γ g
//           (the crest falls faster than gravity can follow — Chen et al., γ = 0.39 via Donatini 2024);
//        3. re-samples last tick's foam at the same world position (the window may have shifted), spreads it with a tent
//           blur, lets it decay with time constant FoamDecay and injects FoamRate · Δτ · strength while the mask fires.
//    Foam lives in undisplaced (grid) space, exactly where HorizonProjection looks it up, so it rides the orbital motion of the
//    surface for free — no advection pass (inside the tier-2 patch the foam is carried by the SWE current instead).
//    Channels: R foam energy 0…1 · G acceleration mask (0/1) · B J · A −a_z / g.
//    Bindings 0–7, 10, 11 serve FoamAdvance, bindings 0, 8, 9 serve MeasureFoam (a different bind group, no read/write overlap).
//    Tier 2 (bores → foam) reads the shoal patch state; without a patch its scene code is 0 and the branch is skipped.

const Pi   = 3.14159265358979;
const Tile = 16u;
const WG   = 256u;

// struct Sea comes from SeaStructure.wgsl (prepended by SwellSolver.js).

@group(0) @binding(0) var<uniform> U: Sea;
@group(0) @binding(1) var Displacement: texture_2d_array<f32>;
@group(0) @binding(2) var Derivative:   texture_2d_array<f32>;
@group(0) @binding(3) var Motion:       texture_2d_array<f32>;
@group(0) @binding(4) var Wrap:         sampler;                 // linear, repeat (band textures tile)
@group(0) @binding(5) var Previous:     texture_2d<f32>;         // last tick's foam window
@group(0) @binding(6) var Clamp:        sampler;                 // linear, clamp (foam window)
@group(0) @binding(7) var Next:         texture_storage_2d<rgba16float, write>;
@group(0) @binding(8) var Current:      texture_2d<f32>;         // MeasureFoam input
@group(0) @binding(9) var<storage, read_write> Partials: array<vec4f>;
@group(0) @binding(10) var<uniform> P: Shoal;                    // tier 2 patch (scene 0 = absent)
@group(0) @binding(11) var Patch: texture_2d<f32>;               // SWE state (h, u, v, bore)

@compute @workgroup_size(Tile, Tile)
fn FoamAdvance(@builtin(global_invocation_id) id: vec3u)
{
    let size = u32(U.Window.w);
    if (id.x >= size || id.y >= size)
    {
        return;
    }
    let extent = U.Window.z * f32(size);
    let world = U.Window.xy + (vec2f(id.xy) + 0.5) * U.Window.z;
    var dxx = 0.0;
    var dyy = 0.0;
    var dxy = 0.0;
    var az = 0.0;
    for (var b = 0u; b < U.Grid.z; b++)
    {
        let uv = world / U.Length[b];
        let der = textureSampleLevel(Derivative, Wrap, uv, b, 0.0);
        let dis = textureSampleLevel(Displacement, Wrap, uv, b, 0.0);
        dxx += der.z;
        dyy += der.w;
        dxy += dis.w;
        az += textureSampleLevel(Motion, Wrap, uv, b, 0.0).x;
    }
    let j = (1.0 + dxx) * (1.0 + dyy) - dxy * dxy;
    let fall = -az / U.Wave.x;                                                    // [g] downward acceleration of the surface
    var strength = max(0.0, (U.Foam.x - j) / U.Foam.x) + max(0.0, (fall - U.Foam.y) / U.Foam.y);
    var mask = select(0.0, 1.0, fall >= U.Foam.y);
    // Tier 2: inside the shoal patch, bores (breaking in the shallow-water sense) inject foam; the spectral criteria fade
    // out where the bands themselves fade (shallow water, land), so the foam follows whichever tier owns the surface.
    let weight = PatchWeight(P, world);
    if (weight > 0.0)
    {
        let cell = (world - P.Patch.xy) / P.Patch.z;
        let state = textureLoad(Patch, vec2u(clamp(cell, vec2f(0.0), vec2f(P.Patch.w - 1.0))), 0);
        let still = -Bed(P, world);
        var spectral = 0.0;
        for (var b = 0u; b < U.Grid.z; b++)
        {
            spectral = max(spectral, DepthWeight(P, b, still));
        }
        strength = strength * mix(1.0, spectral, weight) + weight * 3.0 * state.w;
        mask = max(mask * mix(1.0, spectral, weight), select(0.0, 1.0, state.w > 0.1));
        if (state.x <= P.Limits.x)
        {
            strength = 0.0;                                                       // dry sand keeps no foam
        }
    }

    // Inside the patch the foam rides the shallow-water current (semi-Lagrangian: read where the water came from); in
    // the open sea the FFT surface is Eulerian and the foam stays with the texel as before.
    var origin = world;
    if (weight > 0.0)
    {
        let cell = (world - P.Patch.xy) / P.Patch.z;
        let state = textureLoad(Patch, vec2u(clamp(cell, vec2f(0.0), vec2f(P.Patch.w - 1.0))), 0);
        origin = world - weight * Handover(P, -Bed(P, world)) * vec2f(state.y, state.z) * U.Clock.y;
    }
    let previousUv = (origin - U.Previous.xy) / extent;
    let inside = select(0.0, 1.0, all(previousUv >= vec2f(0.0)) && all(previousUv <= vec2f(1.0)));
    let texel = 1.0 / f32(size);
    let centre = textureSampleLevel(Previous, Clamp, previousUv, 0.0).x;
    let spread = 0.25 * (textureSampleLevel(Previous, Clamp, previousUv + vec2f( texel,  texel), 0.0).x +
                         textureSampleLevel(Previous, Clamp, previousUv + vec2f(-texel,  texel), 0.0).x +
                         textureSampleLevel(Previous, Clamp, previousUv + vec2f( texel, -texel), 0.0).x +
                         textureSampleLevel(Previous, Clamp, previousUv + vec2f(-texel, -texel), 0.0).x);
    let carried = mix(centre, spread, U.Previous.z) * inside * exp(-U.Clock.y / U.Foam.z);
    let foam = min(1.0, carried + U.Foam.w * U.Clock.y * min(strength, 2.0));
    textureStore(Next, id.xy, vec4f(foam, mask, j, fall));
}

//------------------------------------------------------------------------------------------------------------------------
//                                                        PROOF
//------------------------------------------------------------------------------------------------------------------------

var<workgroup> Sum: array<vec4f, WG>;
var<workgroup> Extra: array<vec4f, WG>;

fn NonFinite(x: f32) -> bool
{
    return (bitcast<u32>(x) & 0x7f800000u) == 0x7f800000u;
}

// Partials[2 row]     = (Σ foam, Σ [−a_z ≥ γ g], Σ [J < J_threshold], Σ [foam > 0.02])   over one row of the window
// Partials[2 row + 1] = (non-finite texels, Σ −a_z/g, Σ (a_z/g)², 0)
@compute @workgroup_size(WG)
fn MeasureFoam(@builtin(workgroup_id) group: vec3u, @builtin(local_invocation_id) local: vec3u)
{
    let size = u32(U.Window.w);
    var acc = vec4f(0.0);
    var extra = vec4f(0.0);
    for (var x = local.x; x < size; x += WG)
    {
        let f = textureLoad(Current, vec2u(x, group.x), 0);
        acc.x += f.x;
        acc.y += f.y;
        acc.z += select(0.0, 1.0, f.z < U.Foam.x);
        acc.w += select(0.0, 1.0, f.x > 0.02);
        extra.x += select(0.0, 1.0, NonFinite(f.x) || NonFinite(f.z) || NonFinite(f.w));
        extra.y += f.w;
        extra.z += f.w * f.w;
    }
    Sum[local.x] = acc;
    Extra[local.x] = extra;
    workgroupBarrier();
    for (var stride = WG / 2u; stride > 0u; stride = stride >> 1u)
    {
        if (local.x < stride)
        {
            Sum[local.x] += Sum[local.x + stride];
            Extra[local.x] += Extra[local.x + stride];
        }
        workgroupBarrier();
    }
    if (local.x == 0u)
    {
        Partials[2u * group.x] = Sum[0];
        Partials[2u * group.x + 1u] = Extra[0];
    }
}
