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
