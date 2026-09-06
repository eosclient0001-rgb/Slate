//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/GameExecution.js — Project-Ocean Main Loop (Tick → SwellSolver.Advance → Present → proofs)
//============================================================================================================================================
//
//    🧩 Project-Ocean — the WebGPU large-body-of-water testbed (References/OceanPhaseO0-SurveyAndPlan.md, phase O1: tier 0
//    cascaded-FFT surface + tier 1 foam). One page, no build step; the loop is Project-Fluid's: a fixed-step accumulator turns
//    wall time into 1/60 s ticks, each tick advances the sea, presents, and every 30 ticks records a proof read back without
//    stalling. Fixed mode (proof mode) gates the next tick on the GPU finishing the previous one.
//
//    Controls apply live: wind, fetch, depth, swell and choppiness re-seed the running bands in place (Apply — same
//    lattice, phases continue, so the sea morphs); tier, scene and foam change the lattice and rebuild (Restart, camera
//    kept); the Restart button rebuilds from the UI with a fresh clock and camera. View changes are immediate.
//
//    Proofs (see SwellSolver.js):
//        spectrum      per band Σ_k |h̃0|² equals the CPU quadrature of ∫∫S(k)dk² within 5 % (and the total within 5 %)
//        parseval      mean_x h² equals Σ_k |ĥ(k,t)|² within 2 % (the FFT is an exact inverse DFT; fp16 storage is the error)
//        dispersion    scene=mode: the seeded wave's phase advances at √(g k tanh kh) within 1 %; its amplitude holds within 2 %
//        finite        no NaN/Inf anywhere; max |h| < 4 Hs (+ 1 m)
//        foam          scene=sea, foam on: foam energy exists only after the breaking mask has fired (never fired ⇒ exactly
//                      0); a mask on ≥ 0.01 % of the window injects energy; the mean foam energy must not fall when the wind
//                      rises (compared with the previous finished run stored in localStorage: run wind=6, then 10, then 18)
//        determinism   two runs with the same URL give the same FNV-1a hash of the final proof's row sums
//
//    Query string: ?tier=gtx|rtx&bands=3&size=256&wind=10&fetch=200&depth=200&swell=0.3&chop=1.2&angle=30&seed=7
//                  &foam=1&jthreshold=0.6&azgamma=0.39&foamdecay=4&foamrate=2.5
//                  &scene=sea|mode|open|shore|runup&wavelength=32&amplitude=0.4&gaussian=0
//                  &shoalsize=256&shoalcell=1&slope=0.05&shoaldepth=20&runupdepth=4&waveratio=0.0185&sponge=12&manning=0.02&bar=1.5
//                  &hull=1&head=1.2
//                  &view=0…5&height=6&pitch=-6&yaw=…&seconds=6&proof=1&fixed=1&perkernel=1&offscreen=1&present=0
//    Tier 2 (scene=open|shore|runup) adds the shallow-water patch (ShoalSolver.js) and its proofs:
//        volume        run-up basin: Σ h Δx² drifts < 1e-4 relative (closed, exactly conserving flux form)
//        run-up        run-up scene: max wet bed vs Synolakis R/d = 2.831 √cot β (H/d)^{5/4} within 15 %
//        shoal-finite  no NaN/Inf, |u| under the cap, η bounded
//        bores         shore scene at wind ≥ 12 m/s: the bore detector fires in the surf zone
//    Exit status is written to #status and window.ProjectOceanExit (0 pass · 2 proof failed · 1 refusal — no WebGPU).

import { DescribeSea, DefaultSea, Tiers, Scenes, BandWindow, PeakWavelength, FullyDevelopedFetch } from "./OceanStructure.js";
import { SwellSolver } from "./SwellSolver.js";
import { ShoalSolver, SynolakisRunUp } from "./ShoalSolver.js";
import { HorizonProjection } from "./HorizonProjection.js";
import { TimingMetrics } from "./TimingMetrics.js";

const TickSeconds   = 1.0 / 60.0;    // [s]   fixed tick
const MaxCatchUp    = 4;             // [-]   ticks per animation frame after a stall (rest is dropped, counted)
const ProofInterval = 30;            // [-]   ticks between proofs

//------------------------------------------------------------------------------------------------------------------------
//                                                    HOST STATE
//------------------------------------------------------------------------------------------------------------------------

const Host = {
    Device: null, Context: null, Format: null,
    Sea: null, Solver: null, Shoal: null, Horizon: null, Metrics: null,
    Settings: null,
    Accumulator: 0.0, LastStamp: 0.0, Dropped: 0, Ticks: 0, Recipe: "",
    Running: true, Finished: false, Proofs: [], Failures: [], TraceHash: null, LastProofTick: 0, Gate: false,
    Rebuilding: false, RestartPending: null, ApplyPending: false, LoopAlive: false, Generation: 0, AdapterLine: "",
    ModeTrace: [], FoamFired: false, BoresSeen: false, Keys: new Set(),
    Elements: {},
};

function ReadSettings()
{
    const q = new URLSearchParams(location.search);
    const Number_ = (key, fallback) => { const v = parseFloat(q.get(key)); return Number.isFinite(v) ? v : fallback; };
    const tier = q.get("tier") === "rtx" ? "rtx" : "gtx";
    return {
        Tier:       tier,
        Bands:      q.has("bands") ? Math.round(Number_("bands", Tiers[tier].Bands)) : null,
        Size:       q.has("size") ? Math.round(Number_("size", Tiers[tier].Size)) : null,
        Wind:       Number_("wind", DefaultSea.Wind),
        Fetch:      Number_("fetch", DefaultSea.Fetch),
        Depth:      Number_("depth", DefaultSea.Depth),
        Swell:      Number_("swell", DefaultSea.Swell),
        Choppiness: Number_("chop", DefaultSea.Choppiness),
        Angle:      Number_("angle", DefaultSea.Angle),
        Seed:       Math.round(Number_("seed", DefaultSea.Seed)),
        Foam:       q.get("foam") !== "0",
        JThreshold: Number_("jthreshold", DefaultSea.JThreshold),
        AzGamma:    Number_("azgamma", DefaultSea.AzGamma),
        FoamDecay:  Number_("foamdecay", DefaultSea.FoamDecay),
        FoamRate:   Number_("foamrate", DefaultSea.FoamRate),
        Scene:      Object.values(Scenes).includes(q.get("scene")) ? q.get("scene") : Scenes.Sea,
        ShoalSize:  q.has("shoalsize") ? Math.round(Number_("shoalsize", 256)) : null,
        ShoalCell:  q.has("shoalcell") ? Number_("shoalcell", 1.0) : null,
        Slope:      Number_("slope", DefaultSea.Slope),
        ShoalDepth: Number_("shoaldepth", DefaultSea.ShoalDepth),
        RunUpDepth: Number_("runupdepth", DefaultSea.RunUpDepth),
        WaveRatio:  Number_("waveratio", DefaultSea.WaveRatio),
        Present:    q.get("present") !== "0",                      // 0 = simulate only (proof timing without the draw)
        Sponge:     Number_("sponge", DefaultSea.Sponge),
        Manning:    Number_("manning", DefaultSea.Manning),
        BarHeight:  Number_("bar", DefaultSea.BarHeight),
        Hull:       q.get("hull") !== "0",
        HullHead: Number_("head", DefaultSea.HullHead),
        Wavelength: Number_("wavelength", DefaultSea.Wavelength),
        Amplitude:  Number_("amplitude", DefaultSea.Amplitude),
        Gaussian:   q.get("gaussian") === "1",
        View:       Math.round(Number_("view", 0)),
        Height:     Number_("height", DefaultSea.Height),
        Pitch:      Number_("pitch", DefaultSea.Pitch),
        Yaw:        q.has("yaw") ? Number_("yaw", 0.0) : null,
        Seconds:    Number_("seconds", 0),                        // 0 = run until stopped
        Proof:      q.get("proof") !== "0",
        PerKernel:  q.get("perkernel") === "1",
        Fixed:      q.get("fixed") === "1",                       // one tick per animation frame, GPU-synchronous
        Offscreen:  q.get("offscreen") === "1",                   // harness: shade into a texture, expose window.ProjectOceanCapture()
    };
}

//------------------------------------------------------------------------------------------------------------------------
//                                                     START-UP
//------------------------------------------------------------------------------------------------------------------------

async function Start()
{
    const E = Host.Elements;
    for (const id of ["canvas", "status", "telemetry", "proofs", "sea", "tier", "scene", "wind", "windLabel", "fetch", "fetchLabel", "depth", "depthLabel",
                      "swell", "choppiness", "foam", "restart", "pause", "csv", "view", "shoal"])
    {
        E[id] = document.getElementById(id);
    }
    Host.Settings = ReadSettings();
    const s = Host.Settings;
    E.tier.value = s.Tier; E.scene.value = s.Scene; E.wind.value = s.Wind; E.fetch.value = s.Fetch; E.depth.value = s.Depth;
    E.swell.value = s.Swell; E.choppiness.value = s.Choppiness; E.foam.checked = s.Foam; E.view.value = s.View;
    const Labels = () =>
    {
        const wind = parseFloat(E.wind.value), fetch = parseFloat(E.fetch.value), developed = FullyDevelopedFetch(wind) / 1000.0;
        E.windLabel.textContent  = `${wind.toFixed(1)} m/s (Beaufort ${Beaufort(wind)})`;
        E.fetchLabel.textContent = fetch > developed ? `${E.fetch.value} km → ${developed.toFixed(0)} km (sea fully developed at this wind)` : `${E.fetch.value} km`;
        E.depthLabel.textContent = `${E.depth.value} m`;
    };
    // Spectral parameters apply live: the bands are re-seeded in place a moment after the last edit (the phases carry on,
    // so the sea morphs instead of jumping). Tier, scene and foam change the lattice and rebuild; Restart resets the clock.
    const apply = Debounce(Apply, 150);
    for (const id of ["wind", "fetch", "depth"]) { E[id].addEventListener("input", () => { Labels(); apply(); }); }
    for (const id of ["swell", "choppiness"]) { E[id].addEventListener("input", apply); }
    E.tier.addEventListener("change", () => Restart(true));
    E.foam.addEventListener("change", () => Restart(true));
    E.scene.addEventListener("change", () => Restart(false));
    Labels();
    E.restart.addEventListener("click", () => Restart(false));
    E.pause.addEventListener("click", () => { Host.Running = !Host.Running; E.pause.textContent = Host.Running ? "Pause" : "Resume"; Host.LastStamp = performance.now(); });
    E.csv.addEventListener("click", () => Download("ProjectOcean_Telemetry.csv", Host.Metrics.Csv()));
    E.view.addEventListener("change", () => { if (Host.Horizon) { Host.Horizon.View = parseInt(E.view.value, 10); } });
    InstallCamera(E.canvas);

    if (!navigator.gpu)
    {
        return Refuse("This browser has no WebGPU (navigator.gpu is undefined). Use Chrome/Edge 113+, Firefox 141+ or Safari 26 — on Windows the GTX/RTX card runs it through D3D12.");
    }
    const adapter = await navigator.gpu.requestAdapter({ powerPreference: "high-performance" });
    if (!adapter)
    {
        return Refuse("WebGPU is present but no adapter was offered. On Windows check chrome://gpu → WebGPU, and that the discrete GPU is not blocklisted.");
    }
    const wantTimestamps = adapter.features.has("timestamp-query");
    const device = await adapter.requestDevice({ requiredFeatures: wantTimestamps ? ["timestamp-query"] : [] });
    device.lost.then(info => Refuse(`GPU device lost (${info.reason}): ${info.message}`));
    device.addEventListener("uncapturederror", e => Fail(`Uncaptured GPU error: ${e.error.message}`));
    Host.Device = device;
    Host.Format = navigator.gpu.getPreferredCanvasFormat();
    if (Host.Settings.Offscreen)
    {
        Host.Context = OffscreenContext(device, Host.Format, E.canvas);
    }
    else
    {
        Host.Context = E.canvas.getContext("webgpu");
        Host.Context.configure({ device, format: Host.Format, alphaMode: "opaque" });
    }
    Host.Metrics = new TimingMetrics(device, wantTimestamps);
    Host.Metrics.PerKernel = Host.Settings.PerKernel;

    const info = adapter.info ?? {};
    Host.AdapterLine = `adapter: ${info.vendor ?? "?"} ${info.architecture ?? ""} ${info.description ?? ""} · timestamps ${wantTimestamps ? "on" : "off"} · maxStorage ${(adapter.limits.maxStorageBufferBindingSize / 1048576).toFixed(0)} MiB`;
    Status(Host.AdapterLine);

    Host.Horizon = await HorizonProjection.Create(device, E.canvas, Host.Format);
    Host.Horizon.View = Host.Settings.View;
    await Restart(false);
}

function Debounce(action, milliseconds)
{
    let handle = 0;
    return () => { clearTimeout(handle); handle = setTimeout(action, milliseconds); };
}

// The UI → one immutable sea description (Host.Settings keeps the query-string parameters the UI does not expose).
function Describe()
{
    const E = Host.Elements, s = Host.Settings;
    s.Tier = E.tier.value; s.Scene = E.scene.value; s.Wind = parseFloat(E.wind.value); s.Fetch = parseFloat(E.fetch.value);
    s.Depth = parseFloat(E.depth.value); s.Swell = parseFloat(E.swell.value); s.Choppiness = parseFloat(E.choppiness.value); s.Foam = E.foam.checked;
    return DescribeSea({
        Tier: s.Tier, Bands: s.Bands ?? undefined, Size: s.Size ?? undefined,
        Wind: s.Wind, Fetch: s.Fetch, Depth: s.Depth, Swell: s.Swell, Choppiness: s.Choppiness, Angle: s.Angle, Seed: s.Seed,
        Foam: s.Foam, JThreshold: s.JThreshold, AzGamma: s.AzGamma, FoamDecay: s.FoamDecay, FoamRate: s.FoamRate,
        Scene: s.Scene, Wavelength: s.Wavelength, Amplitude: s.Amplitude,
        ShoalSize: s.ShoalSize, ShoalCell: s.ShoalCell, Slope: s.Slope, ShoalDepth: s.ShoalDepth, RunUpDepth: s.RunUpDepth, WaveRatio: s.WaveRatio,
        Sponge: s.Sponge, Manning: s.Manning, BarHeight: s.BarHeight, Hull: s.Hull, HullHead: s.HullHead,
        Height: s.Height, Pitch: s.Pitch, Yaw: s.Yaw,
    });
}

// True when two descriptions share every GPU resource: same textures, buffers and pipelines, only the spectrum differs.
function SameLattice(a, b)
{
    return !!a && !!b && a.Tier === b.Tier && a.Size === b.Size && a.BandCount === b.BandCount && a.Foam === b.Foam
        && a.Scene === b.Scene && a.Spectral === b.Spectral
        && a.Shoal.Scene === b.Shoal.Scene && a.Shoal.Size === b.Shoal.Size && a.Shoal.Cell === b.Shoal.Cell;
}

// Live edit: same lattice → re-seed the running sea in place (no stall, no reset); otherwise rebuild and keep the camera.
async function Apply()
{
    if (Host.Rebuilding || !Host.Solver)
    {
        Host.ApplyPending = true;                         // picked up when the rebuild in progress finishes
        return;
    }
    const sea = Describe();
    if (!SameLattice(sea, Host.Sea) || Host.Finished)
    {
        return Restart(true);                             // a finished proof run restarts so the edit is visible
    }
    Host.Sea = sea;
    Host.Generation++;                                    // a proof recorded under the old spectrum is not judged
    Host.Solver.Reseed(sea);
    Host.Shoal?.Reseed(sea);
    Host.Horizon.Sea = sea;
    Announce();
}

// Rebuilds the sea from the UI: new solver(s), new clock, proofs cleared. keepCamera leaves the camera where the user
// steered it (tier / foam toggles); a fresh scene or the Restart button resets it to the scene's default.
async function Restart(keepCamera = false)
{
    if (Host.Rebuilding)
    {
        Host.RestartPending = keepCamera;                 // coalesce: one more rebuild after this one, with the latest UI
        return;
    }
    Host.Rebuilding = true;
    const E = Host.Elements, s = Host.Settings;
    const tier = Tiers[E.tier.value];
    const sea = Describe();
    // Pulse does not encode while Rebuilding, so nothing new references the old buffers; the ticks already submitted keep
    // them alive inside the implementation until they finish (a proof readback still mapping unmaps first, see Destroy).
    Host.Solver?.Destroy();
    Host.Shoal?.Destroy();
    Host.Shoal = null;
    Host.Sea = sea;
    Host.Generation++;
    Host.Solver = await SwellSolver.Create(Host.Device, Host.Sea, { Gaussian: s.Gaussian, FoamSize: tier.FoamSize, FoamSpacing: tier.FoamSpacing });
    if (Host.Sea.Shoal.Scene !== Scenes.Sea)
    {
        Host.Shoal = await ShoalSolver.Create(Host.Device, Host.Sea, Host.Solver, { Size: Host.Sea.Shoal.Size, Cell: Host.Sea.Shoal.Cell });
        Host.Solver.AttachShoal(Host.Shoal);
    }
    Host.Horizon.AttachSea(Host.Sea, Host.Solver, tier.Grid, tier.Cell, Host.Shoal, keepCamera);
    if (Host.Shoal && Host.Sea.Scene === Scenes.RunUp && s.Yaw === null)
    {
        // Stand offshore, look along +x at the beach, high enough to see the run-up tongue.
        Host.Horizon.Camera.X = Host.Sea.Shoal.Shore[0] - 90.0;
        Host.Horizon.Camera.Y = 0.0;
        Host.Horizon.Camera.Yaw = 0.0;
        Host.Horizon.Camera.Height = Math.max(Host.Horizon.Camera.Height, 8.0);
        Host.Horizon.Camera.Pitch = -8.0 * Math.PI / 180.0;
    }
    Host.Metrics.Reset();
    Host.Accumulator = 0.0;
    Host.LastStamp   = performance.now();
    Host.Ticks = 0; Host.Dropped = 0; Host.Proofs = []; Host.Failures = []; Host.Finished = false; Host.TraceHash = null; Host.LastProofTick = 0; Host.Gate = false;
    Host.ModeTrace = [];
    Host.FoamFired = false;
    Host.BoresSeen = false;
    Host.Running = true;
    E.pause.textContent = "Pause";
    E.proofs.textContent = "";
    E.status.className = "";
    E.status.textContent = Host.AdapterLine;
    Host.Rebuilding = false;
    Announce();
    if (!Host.LoopAlive)
    {
        Host.LoopAlive = true;                            // first start, or a finished proof run whose loop had stopped
        requestAnimationFrame(Pulse);
    }
    if (Host.RestartPending !== null)
    {
        const again = Host.RestartPending;
        Host.RestartPending = null;
        return Restart(again);
    }
    if (Host.ApplyPending)
    {
        Host.ApplyPending = false;                        // edits made while rebuilding
        return Apply();
    }
}

// The sea-state panel: what the solver was given (prescribed Hs, peak, bands, patch).
function Announce()
{
    const E = Host.Elements, tier = Tiers[Host.Sea.Tier];
    const sea = Host.Sea, spectrum = Host.Solver.Spectrum;
    const bands = sea.Bands.map((b, i) => { const [lo, hi] = BandWindow(sea, i); return `${b.Length.toFixed(0)} m @ ${b.Spacing} m → λ ${lo.toFixed(2)}–${hi.toFixed(0)} m`; });
    const hs = 4.0 * Math.sqrt(spectrum.Total);
    const fetch = sea.FetchMetres < sea.FetchRequested ? ` · fetch ${(sea.FetchMetres / 1000).toFixed(0)} km (fully developed)` : "";
    const shoalText = Host.Shoal ? ` · shoal ${Host.Shoal.Size}² @ ${Host.Shoal.Cell} m × ${Host.Shoal.SubSteps} sub-steps` : "";
    Host.Recipe = `${sea.BandCount} × ${sea.Size}² · ${sea.Foam ? `foam ${tier.FoamSize}² @ ${tier.FoamSpacing} m` : "no foam"} · grid ${tier.Grid}² @ ${tier.Cell} m${shoalText}`;
    E.shoal.textContent = Host.Shoal
        ? (sea.Scene === Scenes.RunUp
            ? `run-up basin: solitary wave H ${sea.Shoal.WaveHeight} m in d ${sea.Shoal.Depth} m (H/d ${(sea.Shoal.WaveHeight / sea.Shoal.Depth).toFixed(4)}) on a 1:${(1 / sea.Shoal.Slope).toFixed(2)} beach → Synolakis R ${SynolakisRunUp(sea.Shoal.WaveHeight, sea.Shoal.Depth, sea.Shoal.Slope).RunUp.toFixed(3)} m`
            : `${sea.Scene === Scenes.Shore ? `beach 1:${(1 / sea.Shoal.Slope).toFixed(0)} with bar ${sea.Shoal.BarHeight} m and cusps` : "flat floor"} · depth ${sea.Shoal.Depth} m · sponge ${sea.Shoal.Sponge} cells · Manning ${sea.Shoal.Manning}`)
        : "off (scene=open | shore | runup)";
    E.sea.textContent = sea.Scene === Scenes.Mode
        ? `single wave λ ${sea.Mode.Wavelength.toFixed(2)} m · A ${sea.Mode.Amplitude} m · ak ${sea.Mode.Steepness.toFixed(3)} · ω ${sea.Mode.Omega.toFixed(4)} rad/s · c ${sea.Mode.PhaseSpeed.toFixed(3)} m/s\n${bands.join("\n")}`
        : `Hs ${hs.toFixed(2)} m (prescribed) · peak λ ${PeakWavelength(sea).toFixed(0)} m · Tp ${(2 * Math.PI / sea.PeakOmega).toFixed(1)} s · ${(sea.WindAngle * 180 / Math.PI).toFixed(0)}°${fetch} · ${Host.Recipe}\n${bands.join("\n")}`;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                    MAIN LOOP
//------------------------------------------------------------------------------------------------------------------------

function Pulse(stamp)
{
    if (Host.Finished)
    {
        Host.LoopAlive = false;                           // Restart revives it
        return;
    }
    requestAnimationFrame(Pulse);
    if (!Host.Running || Host.Rebuilding)
    {
        return;
    }
    const wallBegin = performance.now();
    let ticks = 0;
    if (Host.Settings.Fixed)
    {
        if (Host.Gate)
        {
            return;
        }
        ticks = 1;
    }
    else
    {
        Host.Accumulator += Math.min((stamp - Host.LastStamp) / 1000.0, 0.25);
        Host.LastStamp = stamp;
        ticks = Math.floor(Host.Accumulator / TickSeconds);
        if (ticks > MaxCatchUp)
        {
            Host.Dropped += ticks - MaxCatchUp;
            ticks = MaxCatchUp;
            Host.Accumulator = 0.0;
        }
        else
        {
            Host.Accumulator -= ticks * TickSeconds;
        }
    }
    if (ticks === 0)
    {
        return;
    }
    const finishing = Host.Settings.Seconds > 0 && (Host.Ticks + ticks) * TickSeconds >= Host.Settings.Seconds;
    if (finishing && (Host.Solver.StagingBusy || Host.Shoal?.StagingBusy))
    {
        return;
    }
    Steer(ticks * TickSeconds);

    const metrics = Host.Metrics;
    metrics.Begin();
    const encoder = Host.Device.createCommandEncoder({ label: "Tick" });
    let proofRecorded = false;
    for (let t = 0; t < ticks; t++)
    {
        Host.Solver.Focus(Host.Horizon.Camera.X, Host.Horizon.Camera.Y);
        if (Host.Shoal)
        {
            const c = Host.Horizon.Camera, shoal = Host.Sea.Shoal;
            Host.Shoal.SetFocus(c.X, c.Y);
            if (shoal.Hull)
            {
                Host.Shoal.SetHull(c.X + Math.cos(c.Yaw) * shoal.HullLead, c.Y + Math.sin(c.Yaw) * shoal.HullLead, shoal.HullRadius, shoal.HullHead);
            }
        }
        Host.Solver.Advance(encoder, TickSeconds, metrics, Host.Shoal);       // bands → [shoal] → foam
        Host.Ticks++;
        const lastTick = Host.Settings.Seconds > 0 && Host.Ticks * TickSeconds >= Host.Settings.Seconds;
        const proofDue = Host.Settings.Proof && Host.Ticks - Host.LastProofTick >= ProofInterval;
        if (!proofRecorded && (proofDue || lastTick))
        {
            proofRecorded = Host.Solver.RecordProof(encoder, metrics);
            if (proofRecorded)
            {
                Host.LastProofTick = Host.Ticks;
                Host.Shoal?.RecordProof(encoder, metrics);
            }
        }
        if (lastTick)
        {
            break;
        }
    }
    const lastTick = Host.Settings.Seconds > 0 && Host.Ticks * TickSeconds >= Host.Settings.Seconds;
    if (Host.Settings.Present || lastTick)
    {
        Host.Horizon.Present(encoder, Host.Context, metrics);
    }
    metrics.End(encoder);
    Host.Device.queue.submit([encoder.finish()]);
    metrics.RecordWall(performance.now() - wallBegin);
    if (Host.Settings.Fixed)
    {
        Host.Gate = true;
        Host.Device.queue.onSubmittedWorkDone().then(() => { Host.Gate = false; });
    }
    metrics.Collect().then(() => Telemetry());
    if (proofRecorded)
    {
        const solver = Host.Solver, generation = Host.Generation;
        Promise.all([solver.ReadProof(), Host.Shoal ? Host.Shoal.ReadProof() : null]).then(([record, shoal]) =>
        {
            if (solver !== Host.Solver)
            {
                return;                                   // the sea was rebuilt while this readback was in flight
            }
            if (record && generation === Host.Generation)  // a live edit re-seeded the sea under this proof: not judged
            {
                Judge(record, lastTick, shoal);
            }
            if (lastTick)
            {
                Host.TraceHash = record ? record.Hash : 0;
                Conclude();
            }
        });
    }
    else if (lastTick)
    {
        Host.TraceHash = Host.Solver.LastProof?.Hash ?? 0;
        Conclude();
    }
    if (lastTick)
    {
        Host.Finished = true;
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                                      PROOFS
//------------------------------------------------------------------------------------------------------------------------

function Judge(record, final, shoal = null)
{
    const sea = Host.Sea;
    const rows = [];
    const Check = (name, ok, detail) => { rows.push(`${ok ? "✅" : "❌"} ${name}: ${detail}`); if (!ok) { Host.Failures.push(`t=${record.Time.toFixed(2)} ${name}: ${detail}`); } };
    const N = sea.Size;

    if (sea.Spectral)
    {
        // Spectrum: the seeded energy per band vs the CPU quadrature, and the total. Prescribed 0 (a band with no waves in
        // its window, or the mode scene's finer bands) must be seeded 0.
        let worst = 0.0, detail = [];
        for (const [i, band] of record.Bands.entries())
        {
            const seeded = band.Energy;
            const error = band.Prescribed > 1.0e-12 ? Math.abs(seeded - band.Prescribed) / band.Prescribed : seeded;
            worst = Math.max(worst, error);
            detail.push(`b${i} ${(seeded * 1.0e4).toFixed(2)}/${(band.Prescribed * 1.0e4).toFixed(2)} cm²`);
        }
        const totalSeeded = record.Bands.reduce((s, b) => s + b.Energy, 0.0);
        const totalError = Math.abs(totalSeeded - record.Prescribed) / Math.max(record.Prescribed, 1.0e-12);
        Check("spectrum", worst < 0.05 && totalError < 0.05, `Σ|h̃0|² vs ∫S dk²: ${detail.join(" · ")} · total ${(totalError * 100).toFixed(2)} % off`);

        // Parseval: the spatial variance of the fp16 height texture vs the spectral sum this tick.
        let parsevalWorst = 0.0;
        const parseval = [];
        for (const [i, band] of record.Bands.entries())
        {
            if (band.Spectral > 1.0e-12)
            {
                const error = Math.abs(band.Variance - band.Spectral) / band.Spectral;
                parsevalWorst = Math.max(parsevalWorst, error);
                parseval.push(`b${i} ${(band.Variance * 1.0e4).toFixed(2)}/${(band.Spectral * 1.0e4).toFixed(2)} cm²`);
            }
        }
        Check("parseval", parsevalWorst < 0.02, `mean h² vs Σ|ĥ(k,t)|²: ${parseval.join(" · ")} · worst ${(parsevalWorst * 100).toFixed(2)} % · Hs now ${record.SignificantHeight.toFixed(2)} m (prescribed ${(4.0 * Math.sqrt(record.Prescribed)).toFixed(2)} m)`);

        const hsBound = 4.0 * Math.sqrt(Math.max(record.Prescribed, record.TotalVariance)) * 4.0 + 1.0;
        Check("finite", record.NonFinite === 0 && Number.isFinite(record.TotalVariance) && record.MaxHeight < hsBound, `non-finite ${record.NonFinite} · max |h| ${record.MaxHeight.toFixed(2)} m (bound ${hsBound.toFixed(1)} m)`);
    }

    if (sea.Scene === Scenes.Mode)
    {
        // Dispersion: the coefficient's phase must advance at −ω. Compare against the previous proof (unwrapped, since
        // ω·30 ticks can exceed π for short waves we use the analytic count of whole turns).
        const m = sea.Mode;
        const amplitude = 2.0 * Math.hypot(record.Mode.Re, record.Mode.Im);
        const phase = Math.atan2(record.Mode.Im, record.Mode.Re);
        Host.ModeTrace.push({ Time: record.Time, Phase: phase });
        const expectedPhase = -m.Omega * record.Time;
        let error = phase - expectedPhase;
        error -= 2.0 * Math.PI * Math.round(error / (2.0 * Math.PI));
        const omegaError = Math.abs(error) / (m.Omega * record.Time);
        const amplitudeError = Math.abs(amplitude - m.Amplitude) / m.Amplitude;
        Check("dispersion", omegaError < 0.01 && amplitudeError < 0.02,
              `phase ${phase.toFixed(4)} vs ${(expectedPhase - 2.0 * Math.PI * Math.round(expectedPhase / (2.0 * Math.PI))).toFixed(4)} rad → ω error ${(omegaError * 100).toFixed(3)} % (ω ${m.Omega.toFixed(4)} rad/s, c ${m.PhaseSpeed.toFixed(3)} m/s) · A ${amplitude.toFixed(4)} vs ${m.Amplitude} m`);
    }

    if (record.Foam)
    {
        // Foam is persistent, so the mask firing NOW is not required for foam to exist now; the causal statement is the
        // other way round: energy may exist only if the mask has fired at some proof of this run, and a mask that fires on
        // at least 0.01 % of the window this tick must have injected something.
        const f = record.Foam;
        const firing = f.MaskFraction > 0.0 || f.FoldedFraction > 0.0;
        Host.FoamFired = Host.FoamFired || firing;
        const causal = Host.FoamFired ? true : f.Mean === 0.0;
        const responsive = (f.MaskFraction + f.FoldedFraction) >= 1.0e-4 ? f.Mean > 0.0 : true;
        // Monahan & O'Muircheartaigh (1980) whitecap coverage W = 3.84e-6 U₁₀^3.41 is the field reference for the coverage.
        const monahan = 3.84e-6 * Math.pow(sea.Wind, 3.41);
        Check("foam", f.NonFinite === 0 && causal && responsive && f.Mean <= 1.0,
              `coverage ${(f.Coverage * 100).toFixed(2)} % (Monahan ${(monahan * 100).toFixed(2)} % at ${sea.Wind} m/s) · energy ${(f.Mean * 100).toFixed(4)} % · mask −a_z ≥ ${sea.AzGamma} g on ${(f.MaskFraction * 100).toFixed(3)} % · J < ${sea.JThreshold} on ${(f.FoldedFraction * 100).toFixed(3)} % · −a_z/g rms ${f.FallRms.toFixed(3)}${Host.FoamFired ? "" : " · nothing has broken yet"}`);
        if (final && sea.Scene === Scenes.Sea)
        {
            // Monotone in wind: the mean foam energy must not fall when the wind rises, compared with the last finished run
            // at the same tier / fetch / depth / seed (kept in localStorage, so run wind=6, then 10, then 18).
            const key = `ProjectOcean.Foam.${sea.Tier}.${sea.Size}.${sea.BandCount}.${sea.FetchRequested}.${sea.Depth}.${sea.Seed}.${Host.Settings.Seconds}`;
            let previous = null;
            try { previous = JSON.parse(localStorage.getItem(key) ?? "null"); } catch (error) { previous = null; }
            if (previous && Math.abs(previous.Wind - sea.Wind) > 0.1)
            {
                const rising = sea.Wind > previous.Wind;
                const monotone = rising ? f.Mean >= previous.Mean * 0.999 : f.Mean <= previous.Mean * 1.001 + 1.0e-12;
                Check("foam-monotone", monotone, `energy ${(f.Mean * 100).toFixed(4)} % at ${sea.Wind} m/s vs ${(previous.Mean * 100).toFixed(4)} % at ${previous.Wind} m/s`);
            }
            else
            {
                rows.push(`ℹ️ foam-monotone: first run at this sea state (${sea.Wind} m/s) — run again with another wind to compare`);
            }
            try { localStorage.setItem(key, JSON.stringify({ Wind: sea.Wind, Mean: f.Mean, Coverage: f.Coverage })); } catch (error) { /* private mode */ }
        }
    }
    if (shoal)
    {
        JudgeShoal(shoal, final, rows, Check);
    }
    Host.Proofs.push({ ...record, Shoal: shoal, Rows: rows });
    const bands = record.Bands.map((b, i) => `b${i} σ ${(Math.sqrt(b.Variance) * 100).toFixed(1)} cm`).join(" · ");
    const summary = `Hs ${record.SignificantHeight.toFixed(2)} m · ${bands}` + (record.Foam ? ` · foam ${(record.Foam.Coverage * 100).toFixed(1)} %` : "")
                  + (shoal ? ` · shoal η ${shoal.MaxEta.toFixed(2)} m |u| ${shoal.MaxSpeed.toFixed(2)} m/s wet ${(100 * shoal.Wet / shoal.Cells).toFixed(1)} % K ${shoal.Kinetic.toFixed(0)} bores ${shoal.Bores.toFixed(1)}` : "");
    Host.Elements.proofs.textContent = `t = ${record.Time.toFixed(2)} s · tick ${record.Tick}\n` + rows.join("\n") + "\n" + summary;
    console.log(`[Project-Ocean] proof t=${record.Time.toFixed(2)} ${rows.every(r => r.startsWith("✅") || r.startsWith("ℹ️")) ? "ok" : "FAIL"} · ${summary}`);
}

function JudgeShoal(p, final, rows, Check)
{
    const sea = Host.Sea, shoal = sea.Shoal;
    const closed = shoal.Sponge <= 0.0;
    if (closed)
    {
        const drift = Math.abs(p.Volume - p.InitialVolume) / p.InitialVolume;
        Check("volume", drift < 1.0e-4, `${p.Volume.toFixed(1)} m³ vs ${p.InitialVolume.toFixed(1)} m³ at start (drift ${(drift * 100).toExponential(2)} %)`);
    }
    const etaBound = 3.0 * shoal.WaveHeight + 4.0 * Math.sqrt(Host.Solver.Spectrum.Total) + shoal.Berm + 1.0;
    Check("shoal-finite", p.NonFinite === 0 && p.MaxSpeed <= shoal.SpeedCap + 1.0e-3 && p.MaxEta < etaBound,
          `non-finite ${p.NonFinite} · max |u| ${p.MaxSpeed.toFixed(2)} m/s (cap ${shoal.SpeedCap}) · max η ${p.MaxEta.toFixed(2)} m · wet ${(100 * p.Wet / p.Cells).toFixed(1)} % · kinetic ${p.Kinetic.toFixed(0)} m⁵/s²`);
    if (sea.Scene === Scenes.RunUp)
    {
        const law = SynolakisRunUp(shoal.WaveHeight, shoal.Depth, shoal.Slope);
        const resolution = shoal.Cell / shoal.Depth;
        const tolerance = 0.05 + 0.5 * resolution;
        const error = (p.MaxSurface - law.RunUp) / law.RunUp;
        const text = `max wet surface ${p.MaxSurface.toFixed(4)} m (wet bed ${p.MaxRunUp.toFixed(3)} m) vs Synolakis ${law.RunUp.toFixed(4)} m · R/d ${(p.MaxSurface / shoal.Depth).toFixed(4)} vs ${(law.RunUp / shoal.Depth).toFixed(4)} · ${(error * 100).toFixed(1)} % at Δx/d ${resolution.toFixed(3)} (tolerance ±${(tolerance * 100).toFixed(0)} %)${law.Breaking ? " · beyond the breaking limit — law invalid" : ""}`;
        if (final)
        {
            Check("run-up", Math.abs(error) < tolerance, text);
        }
        else
        {
            rows.push(`ℹ️ run-up so far: ${text} · now η ${p.MaxEta.toFixed(3)} m — judged at the end`);
        }
    }
    if (sea.Scene === Scenes.Shore)
    {
        Host.BoresSeen = Host.BoresSeen || p.Bores > 0.0;
        if (final && sea.Wind >= 12.0)
        {
            Check("bores", Host.BoresSeen, `bore detector fired ${Host.BoresSeen ? "yes" : "no"} (Σ bore now ${p.Bores.toFixed(1)} cell-units at ${sea.Wind} m/s)`);
        }
        else
        {
            rows.push(`ℹ️ bores: Σ ${p.Bores.toFixed(1)} cell-units${Host.BoresSeen ? " (seen)" : ""}`);
        }
    }
}

function Conclude()
{
    const E = Host.Elements;
    const failed = Host.Failures.length > 0;
    const exit = failed ? 2 : 0;
    window.ProjectOceanExit = exit;
    const lines = [
        `${failed ? "❌ FAIL" : "✅ PASS"} — ${Host.Ticks} ticks in ${Host.Settings.Seconds} s simulated, ${Host.Dropped} dropped, ${Host.Recipe}`,
        `trace hash ${(Host.TraceHash >>> 0).toString(16).padStart(8, "0")} (run twice with the same URL: must match)`,
        ...Host.Failures,
    ];
    E.status.textContent = lines.join("\n");
    E.status.className = failed ? "fail" : "pass";
    console.log(`[Project-Ocean] exit ${exit}\n` + lines.join("\n") + "\n" + Host.Metrics.Csv());
}

//------------------------------------------------------------------------------------------------------------------------
//                                                 TELEMETRY + UI
//------------------------------------------------------------------------------------------------------------------------

function Telemetry()
{
    const m = Host.Metrics;
    const rows = m.Rows().map(r => `${r.Label.padEnd(12)} ${r.PerTick.toFixed(3).padStart(8)} ms/tick`);
    const gpuTotal = m.Rows().reduce((sum, r) => sum + r.PerTick, 0.0);
    const c = Host.Horizon.Camera;
    Host.Elements.telemetry.textContent =
        `wall ${m.WallAverage.toFixed(2)} ms/frame (CPU encode) · GPU ${gpuTotal.toFixed(2)} ms/tick · ${Host.Ticks} ticks · ${Host.Dropped} dropped\n` +
        `camera (${c.X.toFixed(0)}, ${c.Y.toFixed(0)}) +${c.Height.toFixed(1)} m · yaw ${(c.Yaw * 180 / Math.PI).toFixed(0)}° · pitch ${(c.Pitch * 180 / Math.PI).toFixed(0)}°\n` + rows.join("\n");
}

function Beaufort(wind)
{
    const upper = [0.5, 1.5, 3.3, 5.5, 7.9, 10.7, 13.8, 17.1, 20.7, 24.4, 28.4, 32.6];
    return upper.findIndex(u => wind < u) === -1 ? 12 : upper.findIndex(u => wind < u);
}

function Status(text)
{
    Host.Elements.status.textContent = text;
}

function Refuse(text)
{
    window.ProjectOceanExit = 1;
    Host.Elements.status.textContent = "⛔ " + text;
    Host.Elements.status.className = "fail";
    Host.Finished = true;
}

function Fail(text)
{
    Host.Failures.push(text);
    console.error("[Project-Ocean] " + text);
}

function Download(name, text)
{
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([text], { type: "text/csv" }));
    link.download = name;
    link.click();
    URL.revokeObjectURL(link.href);
}

// A stand-in for GPUCanvasContext: one texture sized like the canvas plus a PNG capture for the harness.
function OffscreenContext(device, format, canvas)
{
    const stand = { Texture: null, Width: 0, Height: 0 };
    const Ensure = () =>
    {
        const width = Math.max(8, canvas.width), height = Math.max(8, canvas.height);
        if (!stand.Texture || stand.Width !== width || stand.Height !== height)
        {
            stand.Texture?.destroy();
            stand.Texture = device.createTexture({ label: "OffscreenPresent", size: [width, height], format,
                                                   usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC });
            stand.Width = width; stand.Height = height;
        }
        return stand.Texture;
    };
    window.ProjectOceanCapture = async () =>
    {
        const texture = Ensure();
        const rowBytes = Math.ceil(stand.Width * 4 / 256) * 256;
        const staging  = device.createBuffer({ size: rowBytes * stand.Height, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
        const encoder  = device.createCommandEncoder();
        encoder.copyTextureToBuffer({ texture }, { buffer: staging, bytesPerRow: rowBytes }, [stand.Width, stand.Height]);
        device.queue.submit([encoder.finish()]);
        await staging.mapAsync(GPUMapMode.READ);
        const bytes = new Uint8Array(staging.getMappedRange());
        const pixels = new Uint8ClampedArray(stand.Width * stand.Height * 4);
        const bgra = format.startsWith("bgra");
        for (let y = 0; y < stand.Height; y++)
        {
            for (let x = 0; x < stand.Width; x++)
            {
                const src = y * rowBytes + x * 4, dst = (y * stand.Width + x) * 4;
                pixels[dst + 0] = bytes[src + (bgra ? 2 : 0)];
                pixels[dst + 1] = bytes[src + 1];
                pixels[dst + 2] = bytes[src + (bgra ? 0 : 2)];
                pixels[dst + 3] = 255;
            }
        }
        staging.unmap();
        staging.destroy();
        const sink = document.createElement("canvas");
        sink.width = stand.Width; sink.height = stand.Height;
        sink.getContext("2d").putImageData(new ImageData(pixels, stand.Width, stand.Height), 0, 0);
        return sink.toDataURL("image/png");
    };
    return { getCurrentTexture: Ensure };
}

// Camera: drag to look, wheel for height, keys to sail (applied per tick in Steer).
function InstallCamera(canvas)
{
    let dragging = false, lastX = 0, lastY = 0;
    canvas.addEventListener("pointerdown", e => { dragging = true; lastX = e.clientX; lastY = e.clientY; canvas.setPointerCapture(e.pointerId); canvas.focus(); });
    canvas.addEventListener("pointerup",   e => { dragging = false; canvas.releasePointerCapture(e.pointerId); });
    canvas.addEventListener("pointermove", e =>
    {
        if (!dragging || !Host.Horizon) { return; }
        const c = Host.Horizon.Camera;
        c.Yaw   -= (e.clientX - lastX) * 0.004;
        c.Pitch  = Math.min(1.2, Math.max(-1.4, c.Pitch - (e.clientY - lastY) * 0.004));
        lastX = e.clientX; lastY = e.clientY;
    });
    canvas.addEventListener("wheel", e => { if (Host.Horizon) { const c = Host.Horizon.Camera; c.Height = Math.min(2000.0, Math.max(1.5, c.Height * (1 + e.deltaY * 0.001))); e.preventDefault(); } }, { passive: false });
    window.addEventListener("keydown", e => { if (e.target === document.body || e.target === canvas) { Host.Keys.add(e.key.toLowerCase()); } });
    window.addEventListener("keyup",   e => { Host.Keys.delete(e.key.toLowerCase()); });
    canvas.tabIndex = 0;
    const Resize = () =>
    {
        const ratio = Math.min(window.devicePixelRatio || 1, 2);
        canvas.width  = Math.floor(canvas.clientWidth * ratio);
        canvas.height = Math.floor(canvas.clientHeight * ratio);
    };
    new ResizeObserver(Resize).observe(canvas);
    Resize();
}

function Steer(dt)
{
    const k = Host.Keys;
    if (k.size === 0 || !Host.Horizon)
    {
        return;
    }
    const speed = (k.has("shift") ? 60.0 : 12.0) * Math.max(1.0, Host.Horizon.Camera.Height / 6.0);   // [m/s]
    const ahead = ((k.has("w") || k.has("arrowup")) ? 1 : 0) - ((k.has("s") || k.has("arrowdown")) ? 1 : 0);
    const side  = ((k.has("d") || k.has("arrowright")) ? 1 : 0) - ((k.has("a") || k.has("arrowleft")) ? 1 : 0);
    Host.Horizon.Sail(ahead * speed * dt, side * speed * dt);
}

Start().catch(error => { console.error(error); Refuse(String(error?.message ?? error)); });
