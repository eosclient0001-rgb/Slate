//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/OceanStructure.js — Sea-State Description (quality tiers, spectral bands, wind, camera)
//============================================================================================================================================
//
//    Turns the query string / UI into one immutable description of the sea that SwellSolver (simulation) and
//    HorizonProjection (rendering) both read. Nothing here touches the GPU.
//
//    Tiers (References/OceanPhaseO0-SurveyAndPlan.md §4): the GTX profile runs 3 bands × 256² at 8 / 2 / 0.5 m texels
//    (patches 2048 / 512 / 128 m), the RTX profile 4 × 512² at 8 / 2 / 0.5 / 0.125 m (4096 / 1024 / 256 / 64 m).
//    Bands are Donatini's multi-band synthesis: band b has texel spacing s_b = s₀ · r^(B−1−b) [m] and patch length
//    L_b = N · s_b [m]; it owns the wavelengths λ ∈ [ψ s_b, ψ s_(b−1)) — ψ = 4 is the "poorly resolved waves" rule
//    (fewer than ψ texels per wavelength are discarded, never aliased) and band 0 additionally owns everything up to L_0,
//    so the shortest synthesised wave is 2 m on GTX and 0.5 m on RTX.
//
//    Units: metres, seconds, radians; +Z up; wind angle measured from +X toward +Y; waves travel WITH the wind.

export const Tiers = Object.freeze({
    //      spectral bands                                foam window (persistent)      vertex grid
    gtx: { Bands: 3, Size: 256, Spacing: 0.5,   Ratio: 4, FoamSize: 512,  FoamSpacing: 1.0, Grid: 512,  Cell: 0.5  },   // 8 / 2 / 0.5 m
    rtx: { Bands: 4, Size: 512, Spacing: 0.125, Ratio: 4, FoamSize: 1024, FoamSpacing: 0.5, Grid: 1024, Cell: 0.25 },   // 8 / 2 / 0.5 / 0.125 m
});

export const Scenes = Object.freeze({ Sea: "sea", Mode: "mode" });    // mode = one deterministic wave for the dispersion proof

export const DefaultSea = Object.freeze({
    Tier:        "gtx",
    Wind:        10.0,      // [m/s]  U₁₀
    Fetch:       200.0,     // [km]   JONSWAP fetch
    Depth:       200.0,     // [m]    water depth (TMA + finite-depth dispersion)
    Swell:       0.3,       // [-]    Horvath's swell parameter 0…1 (elongates the long waves into parallel trains)
    Angle:       30.0,      // [deg]  wind direction
    Choppiness:  1.2,       // [-]    Tessendorf ξ — 1 is trochoidal; games run 1–2 so crests fold and foam (J proxy)
    Psi:         4.0,       // [-]    Donatini's minimum texels per wavelength
    Gamma:       3.3,       // [-]    JONSWAP peak enhancement
    Gravity:     9.81,      // [m/s²]
    Seed:        7,         // [-]    phase realisation
    Foam:        true,
    JThreshold:  0.6,       // [-]    foam when the Jacobian folds below this (War Thunder 0.3–0.5 at their ξ; see O1 notes)
    AzGamma:     0.39,      // [-]    …or the vertical acceleration passes −γ g (Chen et al. via Donatini 2024)
    FoamDecay:   4.0,       // [s]    e-folding time of the foam energy
    FoamRate:    2.5,       // [1/s]  injection rate while the breaking mask fires
    Scene:       Scenes.Sea,
    Wavelength:  32.0,      // [m]    mode scene: the single wavelength (snapped to band 0's grid)
    Amplitude:   0.4,       // [m]    mode scene: amplitude A (steepness ak = 2πA/λ ≈ 0.08 — no breaking)
    Fade:        1.0,       // [-]    a band fades out where its texel subtends Fade pixels
    MaxHeight:   30.0,      // [m]    vertical extent used for node culling
    Height:      6.0,       // [m]    camera height above the mean surface
    Pitch:       -6.0,      // [deg]  camera pitch (negative looks down)
    Yaw:         null,      // [deg]  camera yaw (null → look upwind)
    SunElevation: 22.0,     // [deg]
    SunAzimuth:  145.0,     // [deg]  relative to the wind direction — ahead of the default upwind camera, glitter path in view
});

export function DescribeSea(overrides = {})
{
    const p    = { ...DefaultSea, ...overrides };
    const tier = Tiers[p.Tier] ?? Tiers.gtx;
    const bandCount = Clamp(Math.round(p.Bands ?? tier.Bands), 1, 4);
    const size      = PowerOfTwo(p.Size ?? tier.Size, 64, 1024);
    const spacing   = p.Spacing ?? tier.Spacing;           // [m] finest texel
    const ratio     = p.Ratio ?? tier.Ratio;
    const psi       = Math.max(2.5, p.Psi);
    const bands = [];
    for (let b = 0; b < bandCount; b++)
    {
        const s = spacing * Math.pow(ratio, bandCount - 1 - b);   // band 0 coarsest
        const L = size * s;
        bands.push({ Index: b, Spacing: s, Length: L, DeltaK: 2.0 * Math.PI / L, MaxK: 2.0 * Math.PI / (psi * s), MinK: 0.0 });
    }
    for (let b = 1; b < bandCount; b++)
    {
        bands[b].MinK = bands[b - 1].MaxK;                        // contiguous windows in k, no wave lives in two bands
    }
    const windAngle = p.Angle * Math.PI / 180.0;
    const mode = p.Scene === Scenes.Mode;
    // Mode scene: the requested wavelength snaps to band 0's wavenumber grid so the analytic phase speed is exact.
    const modeIndex      = Math.max(1, Math.round(bands[0].Length / p.Wavelength));
    const modeWavelength = bands[0].Length / modeIndex;
    const modeK          = modeIndex * bands[0].DeltaK;
    const modeOmega      = Math.sqrt(p.Gravity * modeK * Math.tanh(modeK * p.Depth));
    return Object.freeze({
        Tier: tier === Tiers.rtx ? "rtx" : "gtx",
        Bands: Object.freeze(bands),
        BandCount: bandCount,
        Size: size,
        Psi: psi,
        Wind: p.Wind, FetchMetres: p.Fetch * 1000.0, Depth: p.Depth, Swell: Clamp(p.Swell, 0.0, 1.0),
        WindAngle: windAngle, Choppiness: p.Choppiness, Gamma: p.Gamma, Gravity: p.Gravity, Seed: p.Seed,
        Foam: !!p.Foam, JThreshold: p.JThreshold, AzGamma: p.AzGamma, FoamDecay: p.FoamDecay, FoamRate: p.FoamRate,
        Scene: mode ? Scenes.Mode : Scenes.Sea,
        Mode: Object.freeze({ Index: modeIndex, Wavelength: modeWavelength, K: modeK, Omega: modeOmega, Amplitude: p.Amplitude,
                              PhaseSpeed: modeOmega / modeK, Steepness: modeK * p.Amplitude }),
        Fade: p.Fade, MaxHeight: p.MaxHeight,
        NodeCells: p.NodeCells ?? tier.NodeCells, LodRatio: p.LodRatio ?? tier.LodRatio, LeafCell: p.LeafCell ?? tier.LeafCell,
        Camera: Object.freeze({ Height: Math.max(1.5, p.Height), Pitch: p.Pitch * Math.PI / 180.0,
                                Yaw: (p.Yaw === null || p.Yaw === undefined ? p.Angle + 180.0 : p.Yaw) * Math.PI / 180.0 }),
        Sun: Object.freeze({ Elevation: p.SunElevation * Math.PI / 180.0, Azimuth: windAngle + p.SunAzimuth * Math.PI / 180.0 }),
        // JONSWAP peak for the display and the sanity bounds (fetch-limited Hasselmann 1973)
        PeakOmega: 22.0 * Math.pow(p.Gravity * p.Gravity / (Math.max(p.Wind, 0.5) * p.Fetch * 1000.0), 1.0 / 3.0),
    });
}

// Wavelength window of a band, for the UI: [λmin, λmax] in metres.
export function BandWindow(sea, b)
{
    const band = sea.Bands[b];
    return [2.0 * Math.PI / band.MaxK, band.MinK > 0.0 ? 2.0 * Math.PI / band.MinK : band.Length];
}

// Longest wave the sea can carry with meaningful energy — a JONSWAP peak wavelength from the dispersion relation.
export function PeakWavelength(sea)
{
    const g = sea.Gravity, w = sea.PeakOmega;
    let k = w * w / g;                                          // deep-water start, two Newton steps for finite depth
    for (let i = 0; i < 4; i++)
    {
        const f = g * k * Math.tanh(k * sea.Depth) - w * w;
        const t = Math.tanh(k * sea.Depth);
        const df = g * t + g * k * sea.Depth * (1.0 - t * t);
        k -= f / df;
    }
    return 2.0 * Math.PI / k;
}

function Clamp(x, lo, hi)
{
    return Math.min(hi, Math.max(lo, x));
}

function PowerOfTwo(x, lo, hi)
{
    const n = Clamp(Math.round(x), lo, hi);
    return Math.pow(2, Math.round(Math.log2(n)));
}
