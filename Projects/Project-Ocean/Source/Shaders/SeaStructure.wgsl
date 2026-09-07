//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/Shaders/SeaStructure.wgsl — Shared Sea-State Uniform (prepended to every ocean shader)
//============================================================================================================================================
//
//    One uniform block, written by SwellSolver.js (WriteSea) and read by SwellSolver.wgsl, FoamSolver.wgsl and
//    HorizonProjection.wgsl. 192 bytes, std140-friendly (vec4 only). Per-band lanes index x, y, z, w = band 0…3.

struct Sea
{
    Grid:     vec4u,    // x Size N · y log2 N · z Bands · w Seed
    Wave:     vec4f,    // x Gravity [m/s²] · y Depth [m] · z Wind U₁₀ [m/s] · w Fetch [m]
    Shape:    vec4f,    // x Gamma · y Swell · z WindAngle [rad] · w Choppiness ξ
    Clock:    vec4f,    // x Time [s] · y Δτ [s] · z Psi · w Scene (0 sea · 1 single mode)
    Mode:     vec4f,    // x Index · y Amplitude [m] · z K [rad/m] · w Omega [rad/s]
    Spacing:  vec4f,    // texel spacing per band [m]
    Length:   vec4f,    // patch length per band [m]
    MinK:     vec4f,    // band window lower bound [rad/m] (inclusive)
    MaxK:     vec4f,    // band window upper bound [rad/m] (exclusive)
    Foam:     vec4f,    // x J threshold · y a_z gamma [g] · z decay [s] · w injection rate [1/s]
    Window:   vec4f,    // x, y foam window origin [m] · z texel spacing [m] · w size [texels]
    Previous: vec4f,    // x, y previous foam window origin [m] · z blur [0…1] · w unused
};

// Tier 2 — the shoal patch (ShoalSolver.wgsl): a square SWE grid fixed in the world over an analytic bed. Written by
// ShoalSolver.js (WriteShoal); read by ShoalSolver.wgsl, FoamSolver.wgsl and HorizonProjection.wgsl. 176 bytes.
struct Shoal
{
    Patch:  vec4f,    // x, y origin (south-west corner) [m] · z cell [m] · w size [cells]
    Shore:  vec4f,    // x, y a point on the still-water shoreline [m] · z, w unit normal pointing landward (= wave direction)
    Bed:    vec4f,    // x beach slope [-] · y offshore depth [m] · z berm height [m] · w bar height [m]
    Bar:    vec4f,    // x bar distance seaward of the shoreline [m] · y bar width [m] · z cusp amplitude [m] · w cusp wavelength [m]
    Wave:   vec4f,    // x solitary wave height H [m] · y still depth d [m] · z crest distance seaward X₁ [m] · w scene (0 off · 1 open sea · 2 shore · 3 run-up)
    Step:   vec4f,    // x Δτ [s] · y Manning n [s/m^⅓] · z sponge width [cells] (0 = closed basin) · w relaxation rate [1/s] (0 = free)
    Limits: vec4f,    // x dry threshold [m] · y speed cap [m/s] · z handover depth [m] (peak λ / ShallowRatio) · w forcing velocity cap
    Hull:   vec4f,    // x, y hull position [m] · z hull radius σ [m] · w pressure head [m] (0 = no hull)
    Lambda: vec4f,    // representative wavelength per band [m] (geometric mean of the band window — the band's kinematics)
    Sigma:  vec4f,    // height standard deviation per band [m] (from the prescribed spectrum)
    Shift:  vec4i,    // x, y cell shift for ShoalShift · z, w unused
};

// Bed elevation [m] (+Z up, 0 = still water) at world position p — the one terrain the solver, the foam and the renderer see.
// Scene 1 (open sea) is a flat floor at the offshore depth; scenes 2 and 3 are a plane beach through the shoreline, clamped to
// the offshore plain and the berm; scene 2 adds a longshore bar and beach cusps.
fn Bed(P: Shoal, p: vec2f) -> f32
{
    if (P.Wave.w < 1.5)
    {
        return -P.Bed.y;
    }
    let r = p - P.Shore.xy;
    let s = dot(r, P.Shore.zw);                                   // landward distance from the shoreline [m]
    var b = s * P.Bed.x;
    if (P.Wave.w < 2.5)
    {
        let across = dot(r, vec2f(-P.Shore.w, P.Shore.z));
        let bar = (s + P.Bar.x) / P.Bar.y;
        b += P.Bed.w * exp(-bar * bar);
        // beach cusps: horns and bays at two incommensurate spacings (λ and 1.618 λ) so the shoreline is not a saw blade
        let cusp = (s - 15.0) / 45.0;
        let phase = 6.28318530718 * across / P.Bar.w;
        b += P.Bar.z * (0.65 * sin(phase) + 0.35 * sin(phase * 0.618 + 1.3)) * exp(-cusp * cusp);
    }
    return clamp(b, -P.Bed.y, P.Bed.z);
}

// Blend weight of the patch at world position p: 0 outside, rising across the sponge rim to 1 in the interior (a closed
// basin — sponge 0 — is 1 everywhere inside).
fn PatchWeight(P: Shoal, p: vec2f) -> f32
{
    if (P.Wave.w < 0.5)
    {
        return 0.0;
    }
    let local = (p - P.Patch.xy) / P.Patch.z;                     // [cells]
    let edge = min(min(local.x, local.y), min(P.Patch.w - local.x, P.Patch.w - local.y));
    if (edge <= 0.0)
    {
        return 0.0;
    }
    return select(smoothstep(0.0, P.Step.z, edge), 1.0, P.Step.z <= 0.0);
}

// Hull pressure head [m] at world position p: a Gaussian of the head over the hull radius (0 without a hull).
fn HullHead(P: Shoal, p: vec2f) -> f32
{
    if (P.Hull.w <= 0.0)
    {
        return 0.0;
    }
    let r = (p - P.Hull.xy) / P.Hull.z;
    return P.Hull.w * exp(-dot(r, r));
}

// Who owns the long waves at still-water depth `still`: 0 = the spectral bands (deep — the patch is nudged to follow them),
// 1 = the shallow-water patch (shallow — it shoals, breaks and runs up on its own). The handover is centred on the
// handover depth (peak λ / ShallowRatio) and spans ½ … 1½ of it; land is always the patch's.
fn Handover(P: Shoal, still: f32) -> f32
{
    if (P.Limits.z <= 0.0)
    {
        return 1.0;                                                   // no spectral sea: the patch owns everything
    }
    return 1.0 - smoothstep(0.5 * P.Limits.z, 1.5 * P.Limits.z, still);
}

// Which bands the patch can carry at all: a band whose representative wave spans fewer than ≈ 6 cells stays spectral
// everywhere (its shorter members are smeared by the first-order scheme — they are the ripples, not the surf).
fn Resolve(P: Shoal, b: u32) -> f32
{
    return smoothstep(4.0 * P.Patch.z, 8.0 * P.Patch.z, P.Lambda[b]);
}

// How much of band b is drawn spectrally at a point where the patch owns `share` (= Handover × PatchWeight) of the surface…
fn SpectralShare(P: Shoal, b: u32, share: f32) -> f32
{
    return 1.0 - share * Resolve(P, b);
}

// …and how much of it survives the depth at all: a band whose waves would break here (depth below ≈ 2 Hs) fades out, and
// nothing spectral is drawn on land. Outside any patch the bed is still analytic, so the fade applies everywhere.
fn DepthWeight(P: Shoal, b: u32, still: f32) -> f32
{
    if (P.Wave.w < 0.5)
    {
        return 1.0;
    }
    return smoothstep(2.0 * P.Sigma[b], 8.0 * P.Sigma[b], still);
}
