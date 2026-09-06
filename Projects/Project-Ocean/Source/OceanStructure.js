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
//    Fetch: a wind sea stops growing once the dimensionless fetch gF/U² passes ≈ 2×10⁴ (the Pierson–Moskowitz limit;
//    Hasselmann's 1973 peak-frequency law ω̃p = 22 X̃^(−⅓) meets the fully developed ω̃p ≈ 0.85 there — Holthuijsen 2007
//    §6.3). Beyond it JONSWAP would keep lowering the peak and raising the energy without bound, so the effective fetch is
//    capped: a 2 m/s breeze over 200 km gives Hs 0.1 m, not 0.8 m. (γ = 3.3 still overshoots PM's energy by ≈ 40 % at the
//    cap; a mature-sea γ → 1 would close that and is left for later.)
//
//    Units: metres, seconds, radians; +Z up; wind angle measured from +X toward +Y; waves travel WITH the wind.

export const Tiers = Object.freeze({
    //      spectral bands                                foam window (persistent)      vertex grid              SWE patch
    gtx: { Bands: 3, Size: 256, Spacing: 0.5,   Ratio: 4, FoamSize: 512,  FoamSpacing: 1.0, Grid: 512,  Cell: 0.5,  ShoalSize: 256, ShoalCell: 1.0 },   // 8 / 2 / 0.5 m
    rtx: { Bands: 4, Size: 512, Spacing: 0.125, Ratio: 4, FoamSize: 1024, FoamSpacing: 0.5, Grid: 1024, Cell: 0.25, ShoalSize: 512, ShoalCell: 0.5 },   // 8 / 2 / 0.5 / 0.125 m
});

// sea: open water, spectral only · mode: one deterministic wave (dispersion proof) · open: sea + SWE patch over a flat floor
// (wakes, tier-0/2 blend) · shore: sea + beach (shoaling, bores, run-up, drain-back) · runup: closed basin, solitary wave
// on a plane beach (Synolakis benchmark; no spectral sea)
export const Scenes = Object.freeze({ Sea: "sea", Mode: "mode", Open: "open", Shore: "shore", RunUp: "runup" });

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
    // ---- tier 2: shoal patch (shore / open / runup scenes)
    ShoalSize:   null,      // [-]    cells per side (null → tier: GTX 256, RTX 512)
    ShoalCell:   null,      // [m]    cell size (null → tier: GTX 1 m, RTX 0.5 m)
    Slope:       0.05,      // [-]    beach slope tan β (1:20)
    ShoalDepth:  20.0,      // [m]    offshore plain depth (the patch never sees deeper water)
    Berm:        3.0,       // [m]    beach crest height
    BarHeight:   1.5,       // [m]    longshore bar height (shore scene)
    BarDistance: 80.0,      // [m]    bar crest seaward of the shoreline
    BarWidth:    25.0,      // [m]    bar Gaussian width
    CuspAmplitude: 0.4,     // [m]    beach cusps
    CuspWavelength: 35.0,   // [m]
    ShoreDistance: 120.0,   // [m]    still-water shoreline ahead of the origin, along the wind (waves run onto the beach)
    RunUpDepth:  4.0,       // [m]    run-up scene: still depth d (the benchmark scales with Δx / d: GTX 0.25, RTX 0.125)
    Manning:     0.02,      // [s/m^⅓] bed friction (sand)
    Sponge:      12.0,      // [-]    relaxation rim width in cells (0 = closed basin)
    Relaxation:  6.0,       // [1/s]  peak relaxation rate at the patch edge
    Dry:         0.005,     // [m]    wet/dry threshold
    SpeedCap:    15.0,      // [m/s]
    ShallowRatio: 8.0,      // [-]    handover depth = peak λ / this: shallower water belongs to the patch, deeper to the bands
    ForcingCap:  3.0,       // [-]    cap on the depth-averaged velocity factor √tanh(kd) / (kd) of the forcing
    Hull:        true,      // [-]    open/shore scenes: a hull (moving surface pressure) ahead of the camera
    HullRadius:  4.0,       // [m]    hull Gaussian radius
    HullHead:    1.2,       // [m]    hull pressure head (metres of water displaced under it)
    HullLead:    18.0,      // [m]    hull distance ahead of the camera
    WaveRatio:   0.0185,    // [-]    run-up scene: H / d (Synolakis' laboratory case; breaking limit 0.818 cot β^{−10/9} = 0.030)
    CrestRatio:  35.0,      // [-]    run-up scene: initial crest distance seaward of the shoreline, in depths (toe is at 19.85 d)
    RunUpSlope:  1.0 / 19.85, // [-]  run-up scene: Synolakis' beach
    Fade:        1.0,       // [-]    a band fades out where its texel subtends Fade pixels
    MaxHeight:   30.0,      // [m]    vertical extent used for node culling
    Height:      6.0,       // [m]    camera height above the mean surface
    Pitch:       -6.0,      // [deg]  camera pitch (negative looks down)
    Yaw:         null,      // [deg]  camera yaw (null → look upwind)
    SunElevation: 22.0,     // [deg]
    SunAzimuth:  145.0,     // [deg]  relative to the wind direction — ahead of the default upwind camera, glitter path in view
});

// Fetch [m] at which the sea driven by `wind` is fully developed (Pierson–Moskowitz limit gF/U² ≈ 2×10⁴).
export function FullyDevelopedFetch(wind, gravity = DefaultSea.Gravity)
{
    const u = Math.max(wind, 0.5);
    return 2.0e4 * u * u / gravity;
}

export function DescribeSea(overrides = {})
{
    const p    = { ...DefaultSea, ...overrides };
    const tier = Tiers[p.Tier] ?? Tiers.gtx;
    const fetchRequested = p.Fetch * 1000.0;                                  // [m]
    const fetchMetres    = Math.min(fetchRequested, FullyDevelopedFetch(p.Wind, p.Gravity));
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
    const runUp = p.Scene === Scenes.RunUp;
    const shoalScene = [Scenes.Open, Scenes.Shore, Scenes.RunUp].includes(p.Scene) ? p.Scene : null;
    // Waves travel with the wind, onto the beach. The run-up benchmark runs along +x so the basin's side walls are parallel
    // to the wave (a 1-D problem in 2-D: any transverse flow is an error) and its shoreline sits 12 % from the landward
    // wall of the patch: 88 % of the patch is sea, so the crest starts ≈ 21 depths from the seaward wall (tail 2.5 % of H).
    const normal = runUp ? [1.0, 0.0] : [Math.cos(windAngle), Math.sin(windAngle)];
    const shoalSize = PowerOfTwo(p.ShoalSize ?? tier.ShoalSize, 64, 1024), shoalCell = p.ShoalCell ?? tier.ShoalCell;
    const shoalDepth = runUp ? p.RunUpDepth : p.ShoalDepth;
    const shoreDistance = runUp ? 0.38 * shoalSize * shoalCell : p.ShoreDistance;
    const shoal = Object.freeze({
        Scene: shoalScene ?? Scenes.Sea,
        Size: shoalSize, Cell: shoalCell,
        Shore: [normal[0] * shoreDistance, normal[1] * shoreDistance], Normal: normal,
        Slope: runUp ? p.RunUpSlope : p.Slope, Depth: shoalDepth, Berm: p.Berm,
        BarHeight: p.BarHeight, BarDistance: p.BarDistance, BarWidth: p.BarWidth, CuspAmplitude: p.CuspAmplitude, CuspWavelength: p.CuspWavelength,
        WaveHeight: runUp ? p.WaveRatio * shoalDepth : 0.0, WaveDepth: shoalDepth, CrestDistance: p.CrestRatio * shoalDepth,
        Manning: runUp ? 0.0 : p.Manning, Sponge: runUp ? 0.0 : p.Sponge, Relaxation: runUp ? 0.0 : p.Relaxation,
        Dry: p.Dry, SpeedCap: p.SpeedCap, ShallowRatio: p.ShallowRatio, ForcingCap: p.ForcingCap,
        Hull: p.Hull && !runUp, HullRadius: p.HullRadius, HullHead: p.HullHead, HullLead: p.HullLead,
    });
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
        Wind: p.Wind, FetchMetres: fetchMetres, FetchRequested: fetchRequested, Depth: p.Depth, Swell: Clamp(p.Swell, 0.0, 1.0),
        WindAngle: windAngle, Choppiness: p.Choppiness, Gamma: p.Gamma, Gravity: p.Gravity, Seed: p.Seed,
        Foam: !!p.Foam, JThreshold: p.JThreshold, AzGamma: p.AzGamma, FoamDecay: p.FoamDecay, FoamRate: p.FoamRate,
        Scene: mode ? Scenes.Mode : (shoalScene ?? Scenes.Sea),
        Shoal: shoal,
        Spectral: !runUp,                                                        // the run-up basin has no spectral sea
        Mode: Object.freeze({ Index: modeIndex, Wavelength: modeWavelength, K: modeK, Omega: modeOmega, Amplitude: p.Amplitude,
                              PhaseSpeed: modeOmega / modeK, Steepness: modeK * p.Amplitude }),
        Fade: p.Fade, MaxHeight: p.MaxHeight,
        NodeCells: p.NodeCells ?? tier.NodeCells, LodRatio: p.LodRatio ?? tier.LodRatio, LeafCell: p.LeafCell ?? tier.LeafCell,
        Camera: Object.freeze({ Height: Math.max(1.5, p.Height), Pitch: p.Pitch * Math.PI / 180.0,
                                Yaw: (p.Yaw === null || p.Yaw === undefined ? p.Angle + 180.0 : p.Yaw) * Math.PI / 180.0 }),
        Sun: Object.freeze({ Elevation: p.SunElevation * Math.PI / 180.0, Azimuth: windAngle + p.SunAzimuth * Math.PI / 180.0 }),
        // JONSWAP peak for the display and the sanity bounds (fetch-limited Hasselmann 1973, fetch capped at full development)
        PeakOmega: 22.0 * Math.pow(p.Gravity * p.Gravity / (Math.max(p.Wind, 0.5) * fetchMetres), 1.0 / 3.0),
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
