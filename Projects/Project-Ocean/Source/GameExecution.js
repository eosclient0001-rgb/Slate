//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/GameExecution.js — Project-Ocean Main Loop (Tick → SwellSolver.Advance → Present → proofs)
//============================================================================================================================================
//
//    🧩 Project-Ocean — the WebGPU large-body-of-water testbed (References/OceanPhaseO0-SurveyAndPlan.md, phase O1: tier 0
//    cascaded-FFT surface + tier 1 foam). One page, no build step; the loop is Project-Fluid's: a fixed-step accumulator turns
//    wall time into 1/60 s ticks, each tick advances the sea, presents, and every 30 ticks records a proof read back without
//    stalling. Fixed mode (proof mode) gates the next tick on the GPU finishing the previous one.
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
//                  &scene=sea|mode&wavelength=32&amplitude=0.4&gaussian=0&view=0&height=6&pitch=-6&yaw=…
//                  &seconds=6&proof=1&fixed=1&perkernel=1&offscreen=1
//    Exit status is written to #status and window.ProjectOceanExit (0 pass · 2 proof failed · 1 refusal — no WebGPU).

import { DescribeSea, DefaultSea, Tiers, Scenes, BandWindow, PeakWavelength } from "./OceanStructure.js";
import { SwellSolver } from "./SwellSolver.js";
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
    Sea: null, Solver: null, Horizon: null, Metrics: null,
    Settings: null,
    Accumulator: 0.0, LastStamp: 0.0, Dropped: 0, Ticks: 0, Recipe: "",
    Running: true, Finished: false, Proofs: [], Failures: [], TraceHash: null, LastProofTick: 0, Gate: false,
    ModeTrace: [], FoamFired: false, Keys: new Set(),
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
        Scene:      q.get("scene") === "mode" ? Scenes.Mode : Scenes.Sea,
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
                      "swell", "choppiness", "foam", "restart", "pause", "csv", "view"])
    {
        E[id] = document.getElementById(id);
    }
    Host.Settings = ReadSettings();
    const s = Host.Settings;
    E.tier.value = s.Tier; E.scene.value = s.Scene; E.wind.value = s.Wind; E.fetch.value = s.Fetch; E.depth.value = s.Depth;
    E.swell.value = s.Swell; E.choppiness.value = s.Choppiness; E.foam.checked = s.Foam; E.view.value = s.View;
    const Labels = () =>
    {
        E.windLabel.textContent  = `${parseFloat(E.wind.value).toFixed(1)} m/s (Beaufort ${Beaufort(parseFloat(E.wind.value))})`;
        E.fetchLabel.textContent = `${E.fetch.value} km`;
        E.depthLabel.textContent = `${E.depth.value} m`;
    };
    for (const id of ["wind", "fetch", "depth"]) { E[id].addEventListener("input", Labels); }
    Labels();
    E.restart.addEventListener("click", () => Restart());
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
    Status(`adapter: ${info.vendor ?? "?"} ${info.architecture ?? ""} ${info.description ?? ""} · timestamps ${wantTimestamps ? "on" : "off"} · maxStorage ${(adapter.limits.maxStorageBufferBindingSize / 1048576).toFixed(0)} MiB`);

    Host.Horizon = await HorizonProjection.Create(device, E.canvas, Host.Format);
    Host.Horizon.View = Host.Settings.View;
    await Restart();
    requestAnimationFrame(Pulse);
}

async function Restart()
{
    const E = Host.Elements, s = Host.Settings;
    s.Tier = E.tier.value; s.Scene = E.scene.value; s.Wind = parseFloat(E.wind.value); s.Fetch = parseFloat(E.fetch.value);
    s.Depth = parseFloat(E.depth.value); s.Swell = parseFloat(E.swell.value); s.Choppiness = parseFloat(E.choppiness.value); s.Foam = E.foam.checked;
    Host.Solver?.Destroy();
    const tier = Tiers[s.Tier];
    Host.Sea = DescribeSea({
        Tier: s.Tier, Bands: s.Bands ?? undefined, Size: s.Size ?? undefined,
        Wind: s.Wind, Fetch: s.Fetch, Depth: s.Depth, Swell: s.Swell, Choppiness: s.Choppiness, Angle: s.Angle, Seed: s.Seed,
        Foam: s.Foam, JThreshold: s.JThreshold, AzGamma: s.AzGamma, FoamDecay: s.FoamDecay, FoamRate: s.FoamRate,
        Scene: s.Scene, Wavelength: s.Wavelength, Amplitude: s.Amplitude,
        Height: s.Height, Pitch: s.Pitch, Yaw: s.Yaw,
    });
    Host.Solver = await SwellSolver.Create(Host.Device, Host.Sea, { Gaussian: s.Gaussian, FoamSize: tier.FoamSize, FoamSpacing: tier.FoamSpacing });
    Host.Horizon.AttachSea(Host.Sea, Host.Solver, tier.Grid, tier.Cell);
    Host.Metrics.Reset();
    Host.Accumulator = 0.0;
    Host.LastStamp   = performance.now();
    Host.Ticks = 0; Host.Dropped = 0; Host.Proofs = []; Host.Failures = []; Host.Finished = false; Host.TraceHash = null; Host.LastProofTick = 0; Host.Gate = false;
    Host.ModeTrace = [];
    Host.FoamFired = false;
    Host.Running = true;
    E.pause.textContent = "Pause";
    E.proofs.textContent = "";
    const sea = Host.Sea, spectrum = Host.Solver.Spectrum;
    const bands = sea.Bands.map((b, i) => { const [lo, hi] = BandWindow(sea, i); return `${b.Length.toFixed(0)} m @ ${b.Spacing} m → λ ${lo.toFixed(2)}–${hi.toFixed(0)} m`; });
    const hs = 4.0 * Math.sqrt(spectrum.Total);
    Host.Recipe = `${sea.BandCount} × ${sea.Size}² · ${sea.Foam ? `foam ${tier.FoamSize}² @ ${tier.FoamSpacing} m` : "no foam"} · grid ${tier.Grid}² @ ${tier.Cell} m`;
    E.sea.textContent = sea.Scene === Scenes.Mode
        ? `single wave λ ${sea.Mode.Wavelength.toFixed(2)} m · A ${sea.Mode.Amplitude} m · ak ${sea.Mode.Steepness.toFixed(3)} · ω ${sea.Mode.Omega.toFixed(4)} rad/s · c ${sea.Mode.PhaseSpeed.toFixed(3)} m/s\n${bands.join("\n")}`
        : `Hs ${hs.toFixed(2)} m (prescribed) · peak λ ${PeakWavelength(sea).toFixed(0)} m · Tp ${(2 * Math.PI / sea.PeakOmega).toFixed(1)} s · ${(sea.WindAngle * 180 / Math.PI).toFixed(0)}° · ${Host.Recipe}\n${bands.join("\n")}`;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                    MAIN LOOP
//------------------------------------------------------------------------------------------------------------------------

function Pulse(stamp)
{
    if (Host.Finished)
    {
        return;
    }
    requestAnimationFrame(Pulse);
    if (!Host.Running)
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
    if (finishing && Host.Solver.StagingBusy)
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
        Host.Solver.Advance(encoder, TickSeconds, metrics);
        Host.Ticks++;
        const lastTick = Host.Settings.Seconds > 0 && Host.Ticks * TickSeconds >= Host.Settings.Seconds;
        const proofDue = Host.Settings.Proof && Host.Ticks - Host.LastProofTick >= ProofInterval;
        if (!proofRecorded && (proofDue || lastTick))
        {
            proofRecorded = Host.Solver.RecordProof(encoder, metrics);
            if (proofRecorded)
            {
                Host.LastProofTick = Host.Ticks;
            }
        }
        if (lastTick)
        {
            break;
        }
    }
    const lastTick = Host.Settings.Seconds > 0 && Host.Ticks * TickSeconds >= Host.Settings.Seconds;
    Host.Horizon.Present(encoder, Host.Context, metrics);
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
        Host.Solver.ReadProof().then(record =>
        {
            if (record)
            {
                Judge(record, lastTick);
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

function Judge(record, final)
{
    const sea = Host.Sea;
    const rows = [];
    const Check = (name, ok, detail) => { rows.push(`${ok ? "✅" : "❌"} ${name}: ${detail}`); if (!ok) { Host.Failures.push(`t=${record.Time.toFixed(2)} ${name}: ${detail}`); } };
    const N = sea.Size;

    // Spectrum: the seeded energy per band vs the CPU quadrature, and the total. Prescribed 0 (a band with no waves in its
    // window, or the mode scene's finer bands) must be seeded 0.
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
            const key = `ProjectOcean.Foam.${sea.Tier}.${sea.Size}.${sea.BandCount}.${sea.FetchMetres}.${sea.Depth}.${sea.Seed}.${Host.Settings.Seconds}`;
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
    Host.Proofs.push({ ...record, Rows: rows });
    const bands = record.Bands.map((b, i) => `b${i} σ ${(Math.sqrt(b.Variance) * 100).toFixed(1)} cm`).join(" · ");
    const summary = `Hs ${record.SignificantHeight.toFixed(2)} m · ${bands}` + (record.Foam ? ` · foam ${(record.Foam.Coverage * 100).toFixed(1)} %` : "");
    Host.Elements.proofs.textContent = `t = ${record.Time.toFixed(2)} s · tick ${record.Tick}\n` + rows.join("\n") + "\n" + summary;
    console.log(`[Project-Ocean] proof t=${record.Time.toFixed(2)} ${rows.every(r => r.startsWith("✅") || r.startsWith("ℹ️")) ? "ok" : "FAIL"} · ${summary}`);
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
