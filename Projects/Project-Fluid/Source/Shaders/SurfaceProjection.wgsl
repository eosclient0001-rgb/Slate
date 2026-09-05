//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/Shaders/SurfaceProjection.wgsl — Screen-Space Liquid Surface (sprites → narrow-range smooth → shade)
//============================================================================================================================================
//
//    Five raster dispatches per presentation, all in this file:
//        BackgroundRaster   procedural container (checker floor, faint inner walls, sky) → colour + eye distance
//        SpriteRaster       one camera-facing quad per particle, ray-cast sphere → eye distance, normal, speed, hardware depth
//        ThicknessRaster    same quads, additive chord length → water thickness [m]
//        SmoothRaster       narrow-range smoothing (Truong & Yuksel 2018): world-space Gaussian, range clamp, bias correction,
//                           dynamic range adjustment; separable 1-D forms + a 5×5 clean-up, ping-pong
//        ShadeRaster        normals from the smoothed distance, Fresnel, sky reflection, refracted background, Beer–Lambert
//
//    Distances are positive metres along the view axis; 1e9 marks "no surface". View space is right-handed with the camera
//    looking down −Z and +Y up; world space is right-handed with +Z up (the view matrix does the swap). The container's
//    inner corner is BoxOrigin in solver space; everything here works in box space (origin at that corner).
//
//    Group 0 is the view block for every entry point. Group 1 bindings are numbered uniquely across the whole module
//    (0 particles · 1 smooth input · 2–6 shade inputs · 7 smooth constants) so no two resources ever share a slot,
//    whichever WGSL compiler reads the module.

struct ViewConstants
{
    View           : mat4x4<f32>,
    Projection     : mat4x4<f32>,
    CameraPosition : vec4<f32>,   // xyz [m] box space   w = tan(fov/2)                 [-]
    CameraRight    : vec4<f32>,   // xyz [-]             w = aspect                     [-]
    CameraUp       : vec4<f32>,   // xyz [-]             w = sprite radius              [m]
    CameraForward  : vec4<f32>,   // xyz [-]             w = speed that maps to white   [m/s]
    BoxExtent      : vec4<f32>,   // xyz [m]             w = Δx                         [m]
    BoxOrigin      : vec4<f32>,   // xyz [m] solver-space position of the inner corner, w = offscreen scale [-]
    Smoothing      : vec4<f32>,   // x = σ [m], y = δ [m], z = μ [m], w = max kernel radius [px]
    Absorption     : vec4<f32>,   // xyz [1/m]           w = refraction strength        [-]
    SunDirection   : vec4<f32>,   // xyz [-]             w = unused
    Extent         : vec4<f32>,   // xy = offscreen target [px], zw = 1/xy
    Mode           : vec4<u32>,   // x = 0 water · 1 particles · 2 smoothed distance · 3 thickness, y = tick
};

@group(0) @binding(0) var<uniform> View : ViewConstants;

const NoSurface : f32 = 1.0e9;

//------------------------------------------------------------------------------------------------------------------------
//                                                    SHARED HELPERS
//------------------------------------------------------------------------------------------------------------------------

struct CoverVertex
{
    @builtin(position) Position : vec4<f32>,
};

// One triangle covering the whole target (vertex_index 0..2).
@vertex
fn CoverVertexMain(@builtin(vertex_index) index: u32) -> CoverVertex
{
    var output : CoverVertex;
    let x = f32(i32(index & 1u) * 4 - 1);
    let y = f32(i32(index >> 1u) * 4 - 1);
    output.Position = vec4<f32>(x, y, 0.0, 1.0);
    return output;
}

fn ViewRay(pixel: vec2<f32>) -> vec3<f32>
{
    // View-space direction through the pixel, z = −1 (unnormalised: multiply by eye distance to get the position).
    let ndc = vec2<f32>(pixel.x * View.Extent.z * 2.0 - 1.0, 1.0 - pixel.y * View.Extent.w * 2.0);
    return vec3<f32>(ndc.x * View.CameraPosition.w * View.CameraRight.w, ndc.y * View.CameraPosition.w, -1.0);
}

fn ToWorldDirection(v: vec3<f32>) -> vec3<f32>
{
    return v.x * View.CameraRight.xyz + v.y * View.CameraUp.xyz - v.z * View.CameraForward.xyz;
}

fn Sky(direction: vec3<f32>) -> vec3<f32>
{
    let up      = clamp(direction.z, -1.0, 1.0);
    let horizon = vec3<f32>(0.78, 0.86, 0.94);
    let zenith  = vec3<f32>(0.24, 0.42, 0.72);
    let ground  = vec3<f32>(0.32, 0.30, 0.28);
    var colour  = mix(horizon, zenith, pow(max(up, 0.0), 0.45));
    colour      = mix(colour, ground, smoothstep(0.0, -0.15, up));
    let sun     = pow(max(dot(direction, View.SunDirection.xyz), 0.0), 900.0) * 6.0;
    return colour + vec3<f32>(sun);
}

fn Srgb(linear: vec3<f32>) -> vec3<f32>
{
    return pow(max(linear, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
}

//------------------------------------------------------------------------------------------------------------------------
//                                                  BACKGROUND RASTER
//------------------------------------------------------------------------------------------------------------------------

struct BackgroundOutput
{
    @location(0) Colour   : vec4<f32>,
    @location(1) Distance : f32,
};

fn Checker(p: vec2<f32>, period: f32) -> f32
{
    let c = floor(p / period);
    return f32((i32(c.x) + i32(c.y)) & 1);
}

@fragment
fn BackgroundFragmentMain(input: CoverVertex) -> BackgroundOutput
{
    var output : BackgroundOutput;
    let rayView   = ViewRay(input.Position.xy);
    let direction = normalize(ToWorldDirection(rayView));
    let origin    = View.CameraPosition.xyz;
    let box       = View.BoxExtent.xyz;

    var best      = NoSurface;
    var colour    = Sky(direction);

    // Floor z = 0 inside the footprint.
    if (direction.z < 0.0)
    {
        let t = -origin.z / direction.z;
        let p = origin + direction * t;
        if (t > 0.0 && p.x >= 0.0 && p.x <= box.x && p.y >= 0.0 && p.y <= box.y)
        {
            best = t;
            let tile = mix(0.42, 0.55, Checker(p.xy, 0.25));
            colour   = vec3<f32>(tile, tile, tile) * mix(1.0, 0.6, smoothstep(2.0, 12.0, t));
        }
    }

    // Four vertical walls; only a face seen from inside the container is drawn, so the camera never looks at a wall's back.
    for (var face = 0u; face < 4u; face++)
    {
        let axisX      = face < 2u;
        let planeCoord = select(select(0.0, box.y, face == 3u), select(0.0, box.x, face == 1u), axisX);
        let inward     = select(-1.0, 1.0, face == 0u || face == 2u);     // +1 when the interior lies at larger coordinates
        let dirAxis    = select(direction.y, direction.x, axisX);
        let orgAxis    = select(origin.y, origin.x, axisX);
        if (abs(dirAxis) < 1.0e-5 || dirAxis * inward > 0.0)
        {
            continue;   // parallel, or travelling inward through this plane (its outer face)
        }
        let t = (planeCoord - orgAxis) / dirAxis;
        let p = origin + direction * t;
        let along  = select(p.x, p.y, axisX);
        let limit  = select(box.x, box.y, axisX);
        let inside = along >= 0.0 && along <= limit && p.z >= 0.0 && p.z <= box.z;
        if (t > 0.0 && t < best && inside)
        {
            best = t;
            let grid = max(step(fract(along / 0.25), 0.03), step(fract(p.z / 0.25), 0.03));
            colour   = mix(vec3<f32>(0.70, 0.74, 0.78), vec3<f32>(0.52, 0.56, 0.60), grid) * mix(1.0, 0.7, smoothstep(2.0, 12.0, t));
        }
    }

    // Eye distance along the view axis (not the ray length) so it compares directly with the sprite distances.
    let along = best * dot(direction, View.CameraForward.xyz);
    output.Colour   = vec4<f32>(colour, 1.0);
    output.Distance = select(NoSurface, along, best < NoSurface);
    return output;
}

//------------------------------------------------------------------------------------------------------------------------
//                                              SPRITE + THICKNESS RASTER
//------------------------------------------------------------------------------------------------------------------------

struct Particle   // identical to ParticleSolver.wgsl (80 B)
{
    Position : vec3<f32>,
    Volume   : f32,
    Velocity : vec3<f32>,
    Reserve  : f32,
    Affine   : mat3x3<f32>,
};

@group(1) @binding(0) var<storage, read> Particles : array<Particle>;

struct SpriteVertex
{
    @builtin(position)               Position : vec4<f32>,
    @location(0)                     Corner   : vec2<f32>,   // [-1, 1]²
    @location(1) @interpolate(flat)  Centre   : vec3<f32>,   // view space [m]
    @location(2) @interpolate(flat)  Speed    : f32,         // [m/s]
};

@vertex
fn SpriteVertexMain(@builtin(vertex_index) vertex: u32, @builtin(instance_index) instance: u32) -> SpriteVertex
{
    var output : SpriteVertex;
    let particle = Particles[instance];
    var corner = vec2<f32>(0.0);
    switch (vertex)
    {
        case 0u: { corner = vec2<f32>(-1.0, -1.0); }
        case 1u: { corner = vec2<f32>( 1.0, -1.0); }
        case 2u: { corner = vec2<f32>(-1.0,  1.0); }
        case 3u: { corner = vec2<f32>( 1.0,  1.0); }
        case 4u: { corner = vec2<f32>(-1.0,  1.0); }
        default: { corner = vec2<f32>( 1.0, -1.0); }
    }
    let radius   = View.CameraUp.w;
    let centre   = (View.View * vec4<f32>(particle.Position - View.BoxOrigin.xyz, 1.0)).xyz;
    let position = centre + vec3<f32>(corner * radius, 0.0);
    output.Position = View.Projection * vec4<f32>(position, 1.0);
    output.Corner   = corner;
    output.Centre   = centre;
    output.Speed    = length(particle.Velocity);
    return output;
}

struct SpriteOutput
{
    @location(0)          Distance : f32,
    @location(1)          Normal   : vec4<f32>,   // xyz view-space normal, w = speed [m/s]
    @builtin(frag_depth)  Depth    : f32,
};

@fragment
fn SpriteFragmentMain(input: SpriteVertex) -> SpriteOutput
{
    let r2 = dot(input.Corner, input.Corner);
    if (r2 > 1.0)
    {
        discard;
    }
    let normal = vec3<f32>(input.Corner, sqrt(1.0 - r2));
    let point  = input.Centre + normal * View.CameraUp.w;
    let clip   = View.Projection * vec4<f32>(point, 1.0);
    var output : SpriteOutput;
    output.Distance = -point.z;
    output.Normal   = vec4<f32>(normal, input.Speed);
    output.Depth    = clip.z / clip.w;
    return output;
}

@fragment
fn ThicknessFragmentMain(input: SpriteVertex) -> @location(0) f32
{
    let r2 = dot(input.Corner, input.Corner);
    if (r2 > 1.0)
    {
        discard;
    }
    return 2.0 * sqrt(1.0 - r2) * View.CameraUp.w;   // chord length through the sphere [m]
}

//------------------------------------------------------------------------------------------------------------------------
//                                          NARROW-RANGE SMOOTH (TRUONG & YUKSEL 2018)
//------------------------------------------------------------------------------------------------------------------------
// Positive-distance form of the paper (which stores negative eye-space z):
//     clamp      f(d_i, d_j) = d_j  if d_j ≤ d_i + δ_low   else  d_i + μ          (surfaces far behind pull the edge round)
//     weight     ω_ij = 0 if d_j < d_i − δ_high (much closer)                        (foreground must not bend the background)
//     bias       j and its mirror k are kept or dropped together                    (keeps the kernel symmetric)
//     dynamic    inside the range: δ_low ← max(δ_low, d_j − d_i + δ), δ_high ← max(δ_high, d_i − d_j + δ)
// Kernel radius in pixels follows Eq. 5: σ_px = H·σ / (2·d·tan(α/2)), radius = 3σ_px, capped by Smoothing.w. The paper's
// separable approximation is used: a horizontal and a vertical 1-D form per iteration, then one small 2-D clean-up form
// (5×5) that hides the axis-aligned streaks of the last 1-D form.

struct SmoothConstants
{
    Direction : vec2<i32>,   // [px]  step of the 1-D form; ignored by the clean-up form
    Form      : u32,         // [-]   0 = 1-D along Direction · 1 = 2-D 5×5 clean-up
    Reserved  : u32,
};

@group(1) @binding(1) var SmoothInput : texture_2d<f32>;
@group(1) @binding(7) var<uniform> Smooth : SmoothConstants;

fn LoadDistance(p: vec2<i32>) -> f32
{
    let extent = vec2<i32>(View.Extent.xy);
    if (p.x < 0 || p.y < 0 || p.x >= extent.x || p.y >= extent.y)
    {
        return NoSurface;
    }
    return textureLoad(SmoothInput, p, 0).r;
}

struct RangeSpan
{
    Low  : f32,   // [m] how far behind the centre a neighbour may lie and still be trusted
    High : f32,   // [m] how far in front
};

fn Accumulate(centre: f32, sample: f32, span: ptr<function, RangeSpan>) -> f32
{
    let delta = View.Smoothing.y;
    if (sample >= centre - (*span).High && sample <= centre + (*span).Low)
    {
        (*span).Low  = max((*span).Low,  sample - centre + delta);
        (*span).High = max((*span).High, centre - sample + delta);
    }
    return select(centre + View.Smoothing.z, sample, sample <= centre + (*span).Low);
}

fn Gather(pixel: vec2<i32>, offset: vec2<i32>, centre: f32, w: f32,
          span: ptr<function, RangeSpan>, sum: ptr<function, f32>, weight: ptr<function, f32>)
{
    let dj = LoadDistance(pixel + offset);
    let dk = LoadDistance(pixel - offset);
    if (dj < centre - (*span).High || dk < centre - (*span).High)
    {
        return;   // one of the pair is a foreground surface: drop both (bias correction)
    }
    *sum    += w * (Accumulate(centre, dj, span) + Accumulate(centre, dk, span));
    *weight += 2.0 * w;
}

@fragment
fn SmoothFragmentMain(input: CoverVertex) -> @location(0) f32
{
    let pixel  = vec2<i32>(input.Position.xy);
    let centre = LoadDistance(pixel);
    if (centre >= NoSurface * 0.5)
    {
        return NoSurface;
    }

    var span : RangeSpan;
    span.Low   = View.Smoothing.y;
    span.High  = View.Smoothing.y;
    var sum    = centre;
    var weight = 1.0;

    if (Smooth.Form == 1u)
    {
        let gain = -0.5;   // σ = 1 px
        for (var ring = 1; ring <= 2; ring++)
        {
            for (var edge = 0; edge < 2; edge++)
            {
                let start = select(-ring, -ring + 1, edge == 1);
                let stop  = select(ring, ring - 1, edge == 1);
                for (var t = start; t <= stop; t++)
                {
                    let offset = select(vec2<i32>(t, ring), vec2<i32>(ring, t), edge == 1);
                    Gather(pixel, offset, centre, exp(gain * f32(dot(offset, offset))), &span, &sum, &weight);
                }
            }
        }
        return sum / weight;
    }

    let sigmaPx = clamp(View.Extent.y * View.Smoothing.x / (2.0 * centre * View.CameraPosition.w), 0.75, View.Smoothing.w / 3.0);
    let radius  = i32(ceil(3.0 * sigmaPx));
    let gain    = -0.5 / (sigmaPx * sigmaPx);
    for (var t = 1; t <= radius; t++)
    {
        Gather(pixel, Smooth.Direction * t, centre, exp(gain * f32(t * t)), &span, &sum, &weight);
    }
    return sum / weight;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                    SHADE RASTER
//------------------------------------------------------------------------------------------------------------------------

@group(1) @binding(2) var SurfaceDistance    : texture_2d<f32>;   // smoothed (or raw in particle mode)
@group(1) @binding(3) var SurfaceNormal      : texture_2d<f32>;   // sprite normals + speed (particle mode)
@group(1) @binding(4) var Thickness          : texture_2d<f32>;
@group(1) @binding(5) var BackgroundColour   : texture_2d<f32>;
@group(1) @binding(6) var BackgroundDistance : texture_2d<f32>;

fn ViewPosition(pixel: vec2<i32>, distance: f32) -> vec3<f32>
{
    return ViewRay(vec2<f32>(pixel) + vec2<f32>(0.5)) * distance;
}

fn ClampPixel(p: vec2<i32>) -> vec2<i32>
{
    return clamp(p, vec2<i32>(0), vec2<i32>(View.Extent.xy) - 1);
}

fn SurfaceNormalFromDistance(pixel: vec2<i32>, centre: f32) -> vec3<f32>
{
    let p0 = ViewPosition(pixel, centre);
    let dr = textureLoad(SurfaceDistance, ClampPixel(pixel + vec2<i32>(1, 0)), 0).r;
    let dl = textureLoad(SurfaceDistance, ClampPixel(pixel - vec2<i32>(1, 0)), 0).r;
    let dd = textureLoad(SurfaceDistance, ClampPixel(pixel + vec2<i32>(0, 1)), 0).r;
    let du = textureLoad(SurfaceDistance, ClampPixel(pixel - vec2<i32>(0, 1)), 0).r;
    // One-sided differences towards the neighbour whose distance is closer to ours (keeps silhouettes crisp).
    var ddx = ViewPosition(pixel + vec2<i32>(1, 0), dr) - p0;
    if (abs(dl - centre) < abs(dr - centre)) { ddx = p0 - ViewPosition(pixel - vec2<i32>(1, 0), dl); }
    var ddy = ViewPosition(pixel + vec2<i32>(0, 1), dd) - p0;
    if (abs(du - centre) < abs(dd - centre)) { ddy = p0 - ViewPosition(pixel - vec2<i32>(0, 1), du); }
    var normal = normalize(cross(ddy, ddx));
    if (normal.z < 0.0) { normal = -normal; }
    return normal;
}

@fragment
fn ShadeFragmentMain(input: CoverVertex) -> @location(0) vec4<f32>
{
    let pixel      = ClampPixel(vec2<i32>(floor(input.Position.xy * View.BoxOrigin.w)));
    let background = textureLoad(BackgroundColour, pixel, 0).rgb;
    let backDist   = textureLoad(BackgroundDistance, pixel, 0).r;
    let distance   = textureLoad(SurfaceDistance, pixel, 0).r;
    let thickness  = textureLoad(Thickness, pixel, 0).r;
    let mode       = View.Mode.x;

    if (mode == 2u)
    {
        let shade = select(1.0 - fract(distance * 0.5), 0.0, distance >= NoSurface * 0.5);
        return vec4<f32>(Srgb(vec3<f32>(shade)), 1.0);
    }
    if (mode == 3u)
    {
        return vec4<f32>(Srgb(vec3<f32>(1.0 - exp(-thickness * 3.0))), 1.0);
    }
    if (distance >= NoSurface * 0.5 || distance > backDist)
    {
        return vec4<f32>(Srgb(background), 1.0);
    }

    let positionView = ViewPosition(pixel, distance);
    let toEye        = normalize(-positionView);

    if (mode == 1u)
    {
        let sample = textureLoad(SurfaceNormal, pixel, 0);
        let normal = sample.xyz;
        let speed  = clamp(sample.w / View.CameraForward.w, 0.0, 1.0);
        let base   = mix(vec3<f32>(0.10, 0.35, 0.85), vec3<f32>(1.0), speed);
        let light  = normalize(vec3<f32>(0.4, 0.6, 0.7));
        let shade  = 0.25 + 0.75 * max(dot(normal, light), 0.0);
        return vec4<f32>(Srgb(base * shade), 1.0);
    }

    let normal      = SurfaceNormalFromDistance(pixel, distance);
    let normalWorld = normalize(ToWorldDirection(normal));
    let eyeWorld    = normalize(ToWorldDirection(toEye));
    let cosine      = max(dot(normal, toEye), 0.0);
    let fresnel     = 0.02 + 0.98 * pow(1.0 - cosine, 5.0);
    let reflection  = Sky(reflect(-eyeWorld, normalWorld));

    // Refraction: offset the background lookup along the screen-space normal, more for thicker water.
    let bend        = View.Absorption.w * min(thickness, 0.5) * View.Extent.y;
    let refractAt   = ClampPixel(pixel + vec2<i32>(vec2<f32>(normal.x, -normal.y) * bend));
    var refracted   = textureLoad(BackgroundColour, refractAt, 0).rgb;
    if (textureLoad(BackgroundDistance, refractAt, 0).r < distance)
    {
        refracted = background;   // the offset landed on something in front of the water: keep the straight sample
    }
    let transmit    = exp(-View.Absorption.xyz * thickness);
    let scatter     = vec3<f32>(0.05, 0.30, 0.42) * (1.0 - transmit);
    let colour      = mix(refracted * transmit + scatter, reflection, fresnel);
    return vec4<f32>(Srgb(colour), 1.0);
}
