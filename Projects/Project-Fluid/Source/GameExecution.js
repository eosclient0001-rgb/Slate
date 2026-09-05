//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/GameExecution.js — Project-Fluid Main Loop (Tick → LiquidSolver.Advance → Present → proofs)
//============================================================================================================================================
//
//    🧩 Project-Fluid — the WebGPU fluid testbed. One page, no build step: the browser is the platform (Chrome/Edge 113+,
//    Firefox 141+, Safari 26). The loop mirrors Project-Physics: a fixed-step accumulator turns wall time into ticks,
//    each tick advances the solver by N sub-steps, presents, and every 30 ticks records a proof that the host reads back
//    without stalling. The exit report is the same shape as Project-Physics' `--fixed --seconds` run.
//
//    Proofs (dam-break in a closed box, 2 m × 1 m × 1.25 m, +Z up):
//        containment   every particle stays inside the visible container (the G2P hard clamp is the tunnelling detector)
//        mass          Σ lattice mass == N · m_p within 0.1 % (fixed-point scatter loses nothing but rounding)
//        finite        no NaN/Inf in any record; the fixed-point saturation counter stays at zero (speed clamps are reported)
//        settle        after the run the free surface is level: mean particle height → SettledHeight / 2 within 15 %,
//                      RMS speed < 0.2 m/s
//        volume        position-based only: mean volume ratio J within 5 % of 1 at every proof
//        determinism   two runs with the same settings give the same FNV-1a hash of the positions (same GPU/browser)
//
//    Query string: ?resolution=64&seconds=8&proof=1&fixed=1&mode=0&scale=0.5&solver=positionbased&iterations=2&substeps=auto
//    (solver=explicit selects the MLS-MPM baseline with stiffness=κ; fixed=1 makes each tick wait for the GPU so the proof
//    series is complete; proof=0 keeps the invariants — containment, mass, finite — on the final tick but skips the
//    settle judgement, for short timing runs; seconds=0 runs until the tab closes.)
//    Exit status is written to #status and window.ProjectFluidExit (0 pass · 2 proof failed · 1 refusal — no WebGPU).

import { DescribeDamBreak, PredictParticleCount, DomainSize } from "./DamBreakStructure.js";
import { LiquidSolver, DefaultTuning, Methods } from "./LiquidSolver.js";
import { SurfaceProjection } from "./SurfaceProjection.js";
import { TimingMetrics } from "./TimingMetrics.js";

const TickSeconds   = 1.0 / 60.0;    // [s]   fixed tick, like Project-Physics
const MaxCatchUp    = 4;             // [-]   ticks per animation frame after a stall (rest is dropped, counted)
const ProofInterval = 30;            // [-]   ticks between proofs

//------------------------------------------------------------------------------------------------------------------------
//                                                    HOST STATE
//------------------------------------------------------------------------------------------------------------------------

const Host = {
    Device: null, Context: null, Format: null,
    Scene: null, Solver: null, Surface: null, Metrics: null,
    Settings: null,
    Accumulator: 0.0, LastStamp: 0.0, Dropped: 0, Ticks: 0, SubStepsPerTick: 1, SubStepSeconds: TickSeconds, Recipe: "",
    Running: true, Finished: false, Proofs: [], Failures: [], TraceHash: null, LastProofTick: 0, Gate: false,
    Elements: {},
};

function ReadSettings()
{
    const q = new URLSearchParams(location.search);
    const Number_ = (key, fallback) => { const v = parseFloat(q.get(key)); return Number.isFinite(v) ? v : fallback; };
    return {
        Resolution:  Math.round(Number_("resolution", 64)),
        Seconds:     Number_("seconds", 0),                      // 0 = run until stopped
        Proof:       q.get("proof") !== "0",
        Mode:        Math.round(Number_("mode", 0)),
        Scale:       Number_("scale", 0.5),
        Solver:      q.get("solver") === "explicit" ? Methods.Explicit : Methods.PositionBased,
        Iterations:  Math.round(Number_("iterations", DefaultTuning.Iterations)),
        Stiffness:   Number_("stiffness", DefaultTuning.Stiffness),
        Viscosity:   Number_("viscosity", DefaultTuning.Viscosity),
        Relaxation:  Number_("relaxation", DefaultTuning.VolumeRelaxation),
        Shear:       Number_("shear", DefaultTuning.ShearRelaxation),
        SubSteps:    q.get("substeps") ?? "auto",
        PerKernel:   q.get("perkernel") === "1",
        Fixed:       q.get("fixed") === "1",                     // one tick per animation frame, GPU-synchronous, no wall-clock accumulator
        Offscreen:   q.get("offscreen") === "1",                 // harness: shade into a texture, expose window.ProjectFluidCapture()
    };
}

//------------------------------------------------------------------------------------------------------------------------
//                                                     START-UP
//------------------------------------------------------------------------------------------------------------------------

async function Start()
{
    const E = Host.Elements;
    for (const id of ["canvas", "status", "telemetry", "proofs", "resolution", "resolutionLabel", "mode", "scale", "solver", "iterations", "stiffness", "substeps", "restart", "pause", "csv", "particles"])
    {
        E[id] = document.getElementById(id);
    }
    Host.Settings = ReadSettings();
    E.resolution.value = Host.Settings.Resolution;
    E.mode.value       = Host.Settings.Mode;
    E.scale.value      = Host.Settings.Scale;
    E.solver.value     = Host.Settings.Solver;
    E.iterations.value = String(Host.Settings.Iterations);
    E.stiffness.value  = Host.Settings.Stiffness;
    E.substeps.value   = Host.Settings.SubSteps;
    E.resolutionLabel.textContent = `${Host.Settings.Resolution} cells → ${PredictParticleCount(Host.Settings.Resolution).toLocaleString()} particles`;
    E.resolution.addEventListener("input", () => { E.resolutionLabel.textContent = `${E.resolution.value} cells → ${PredictParticleCount(E.resolution.value).toLocaleString()} particles`; });
    E.restart.addEventListener("click", () => Restart());
    E.pause.addEventListener("click", () => { Host.Running = !Host.Running; E.pause.textContent = Host.Running ? "Pause" : "Resume"; Host.LastStamp = performance.now(); });
    E.csv.addEventListener("click", () => Download("ProjectFluid_Telemetry.csv", Host.Metrics.Csv()));
    E.mode.addEventListener("change", () => { if (Host.Surface) { Host.Surface.Mode = parseInt(E.mode.value, 10); } });
    E.scale.addEventListener("change", () => { if (Host.Surface) { Host.Surface.Scale = parseFloat(E.scale.value); } });
    E.stiffness.addEventListener("change", () => { if (Host.Solver) { Host.Solver.SetTuning({ Stiffness: parseFloat(E.stiffness.value) }); PlanSubSteps(); } });
    E.iterations.addEventListener("change", () => { if (Host.Solver) { Host.Solver.SetTuning({ Iterations: parseInt(E.iterations.value, 10) }); PlanSubSteps(); } });
    E.solver.addEventListener("change", () => { if (Host.Solver) { Host.Solver.SetTuning({ Method: E.solver.value }); PlanSubSteps(); } });
    E.substeps.addEventListener("change", () => PlanSubSteps());
    InstallOrbit(E.canvas);

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
    Host.Device  = device;
    Host.Format  = navigator.gpu.getPreferredCanvasFormat();
    if (Host.Settings.Offscreen)
    {
        // Harness mode: no swapchain (headless SwiftShader cannot present); shade into a readable texture instead.
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

    Host.Surface = await SurfaceProjection.Create(device, E.canvas, Host.Format);
    Host.Surface.Mode  = Host.Settings.Mode;
    Host.Surface.Scale = Host.Settings.Scale;
    await Restart();
    requestAnimationFrame(Pulse);
}

async function Restart()
{
    const E = Host.Elements;
    Host.Settings.Resolution = Math.round(parseFloat(E.resolution.value));
    Host.Settings.Solver     = E.solver.value;
    Host.Settings.Iterations = parseInt(E.iterations.value, 10);
    Host.Settings.Stiffness  = parseFloat(E.stiffness.value);
    Host.Settings.SubSteps   = E.substeps.value;
    Host.Solver?.Destroy();
    Host.Scene  = DescribeDamBreak({ Resolution: Host.Settings.Resolution });
    Host.Solver = await LiquidSolver.Create(Host.Device, Host.Scene, {
        Method: Host.Settings.Solver, Iterations: Host.Settings.Iterations,
        Stiffness: Host.Settings.Stiffness, Viscosity: Host.Settings.Viscosity,
        VolumeRelaxation: Host.Settings.Relaxation, ShearRelaxation: Host.Settings.Shear,
    });
    Host.Surface.AttachScene(Host.Scene, Host.Solver.Records);
    Host.Metrics.Reset();
    Host.Accumulator = 0.0;
    Host.LastStamp   = performance.now();
    Host.Ticks = 0; Host.Dropped = 0; Host.Proofs = []; Host.Failures = []; Host.Finished = false; Host.TraceHash = null; Host.LastProofTick = 0; Host.Gate = false;
    Host.Running = true;
    E.pause.textContent = "Pause";
    E.proofs.textContent = "";
    PlanSubSteps();
    const s = Host.Scene;
    E.particles.textContent = `${s.ParticleCount.toLocaleString()} particles · lattice ${s.CellCount.join("×")} (${s.NodeCount.toLocaleString()} sites) · Δx ${(s.CellSize * 1000).toFixed(1)} mm · column ${s.Column.Length.toFixed(2)} × ${s.Column.Height.toFixed(2)} m · settles at ${(s.SettledHeight * 100).toFixed(1)} cm`;
}

function PlanSubSteps()
{
    const plan = Host.Solver.Describe(TickSeconds);
    const requested = Host.Elements.substeps.value;
    Host.SubStepsPerTick = requested === "auto" ? plan.SubSteps : Math.max(1, parseInt(requested, 10) || plan.SubSteps);
    Host.SubStepSeconds  = TickSeconds / Host.SubStepsPerTick;
    const explicit = plan.Method === Methods.Explicit;
    const courant  = ((explicit ? plan.SoundSpeed : 0.0) + plan.ReferenceSpeed) * Host.SubStepSeconds / Host.Scene.CellSize;
    Host.Elements.substeps.title = `${explicit ? `c₀ ${plan.SoundSpeed.toFixed(1)} m/s · ` : ""}v_ref ${plan.ReferenceSpeed.toFixed(1)} m/s · auto = ${plan.SubSteps} · Courant ${courant.toFixed(2)}`;
    Host.Elements.iterations.disabled = explicit;
    Host.Elements.stiffness.disabled  = !explicit;
    Host.Recipe = explicit ? `explicit MLS-MPM · ${Host.SubStepsPerTick} sub-steps` : `PB-MPM · ${Host.SubStepsPerTick} sub-steps × ${plan.Iterations} iterations = ${Host.SubStepsPerTick * plan.Iterations} transfers/tick`;
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
        // Fixed mode is the proof mode: the next tick is not encoded until the GPU has finished the previous one, so the
        // proof series (every 30 ticks) is complete on any GPU — without the gate a slow or emulated GPU falls hundreds
        // of ticks behind the encoder and every proof but the first and last is skipped as "readback still in flight".
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
    // The final tick must carry a proof: if the previous proof's readback is still in flight (slow GPU, throttled tab),
    // wait a frame rather than finishing without one. Ticks are not advanced while waiting.
    const finishing = Host.Settings.Seconds > 0 && (Host.Ticks + ticks) * TickSeconds >= Host.Settings.Seconds;
    if (finishing && Host.Solver.StagingBusy)
    {
        return;
    }

    const metrics = Host.Metrics;
    metrics.Begin();
    const encoder = Host.Device.createCommandEncoder({ label: "Tick" });
    let proofRecorded = false;
    for (let t = 0; t < ticks; t++)
    {
        Host.Solver.Advance(encoder, Host.SubStepsPerTick, Host.SubStepSeconds, metrics);
        Host.Ticks++;
        const lastTick = Host.Settings.Seconds > 0 && Host.Ticks * TickSeconds >= Host.Settings.Seconds;
        // A proof is due every ProofInterval ticks; when the previous readback is still in flight (slow GPU) it stays
        // due until RecordProof accepts it, so the time series has no holes — it just slips a few ticks.
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
            Host.Solver.RecordTrace(encoder);
            break;
        }
    }
    const lastTick = Host.Settings.Seconds > 0 && Host.Ticks * TickSeconds >= Host.Settings.Seconds;
    Host.Surface.Present(encoder, Host.Context, Host.Ticks, metrics);
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
        Host.Solver.ReadProof().then(record => { if (record) { Judge(record, lastTick); } });
    }
    if (lastTick)
    {
        Host.Finished = true;
        Host.Solver.ReadTrace().then(hash => { Host.TraceHash = hash; Conclude(); });
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                                      PROOFS
//------------------------------------------------------------------------------------------------------------------------

function Judge(record, final)
{
    const s = Host.Scene;
    const rows = [];
    const Check = (name, ok, detail) => { rows.push(`${ok ? "✅" : "❌"} ${name}: ${detail}`); if (!ok) { Host.Failures.push(`t=${record.Time.toFixed(2)} ${name}: ${detail}`); } };

    Check("containment", record.Inside === record.Expected, `${record.Inside} / ${record.Expected} inside`);
    const massError = Math.abs(record.LatticeMass - record.ExpectedMass) / record.ExpectedMass;
    Check("mass", massError < 1.0e-3, `${record.LatticeMass.toFixed(3)} kg vs ${record.ExpectedMass.toFixed(3)} kg (${(massError * 100).toFixed(3)} %)`);
    Check("finite", record.Saturations === 0 && Number.isFinite(record.MeanSpeed) && Number.isFinite(record.MeanHeight), `saturations ${record.Saturations}, max |v| ${record.MaxSpeed.toFixed(2)} m/s`);
    if (record.SpeedClamps > 0)
    {
        rows.push(`⚠️ speed clamp fired ${record.SpeedClamps}× since the last proof (splash spikes above ${Host.Solver.Tuning.MaxSpeed} m/s — not a failure, but watch the settle proof)`);
    }
    if (Host.Solver.PositionBased)
    {
        // Volume proof (position-based only): the particle-integrated volume ratio must stay near 1 on average. The
        // explicit method re-measures density every sub-step and never touches J, so it is exempt.
        const drift = Math.abs(record.MeanVolume - 1.0);
        Check("volume", drift < 0.05, `mean J ${record.MeanVolume.toFixed(4)} (RMS spread ${record.VolumeSpread.toFixed(3)}, min ${record.MinVolume.toFixed(2)}, max ${record.MaxVolume.toFixed(2)})`);
    }
    if (final && Host.Settings.Proof)
    {
        // The settle proof needs the sloshing to have died down: ≥ 6 s at 32–64 cells (energy halves every ~2 s).
        const meanAboveFloor = record.MeanHeight - s.FloorHeight;
        const expected = s.SettledHeight * 0.5;
        const heightError = Math.abs(meanAboveFloor - expected) / expected;
        Check("settle", heightError < 0.15 && record.MeanSpeed < 0.2, `mean height ${(meanAboveFloor * 100).toFixed(1)} cm vs ${(expected * 100).toFixed(1)} cm (${(heightError * 100).toFixed(1)} %), RMS speed ${record.MeanSpeed.toFixed(3)} m/s`);
    }
    Host.Proofs.push({ ...record, Rows: rows });
    const E = Host.Elements;
    const summary = `RMS speed ${record.MeanSpeed.toFixed(3)} m/s · mean height ${((record.MeanHeight - s.FloorHeight) * 100).toFixed(1)} cm` +
                    (Host.Solver.PositionBased ? ` · mean J ${record.MeanVolume.toFixed(4)}` : "");
    E.proofs.textContent = `t = ${record.Time.toFixed(2)} s · tick ${record.Tick}\n` + rows.join("\n") + "\n" + summary;
    console.log(`[Project-Fluid] proof t=${record.Time.toFixed(2)} ${rows.every(r => r.startsWith("✅") || r.startsWith("⚠️")) ? "ok" : "FAIL"} · ${summary}`);   // the time series for headless runs
}

function Conclude()
{
    const E = Host.Elements;
    const failed = Host.Failures.length > 0;
    const exit = failed ? 2 : 0;
    window.ProjectFluidExit = exit;
    const lines = [
        `${failed ? "❌ FAIL" : "✅ PASS"} — ${Host.Ticks} ticks in ${Host.Settings.Seconds} s simulated, ${Host.Dropped} dropped, ${Host.Recipe}`,
        `trace hash ${Host.TraceHash.toString(16).padStart(8, "0")} (run twice with the same URL: must match)`,
        ...Host.Failures,
    ];
    E.status.textContent = lines.join("\n");
    E.status.className = failed ? "fail" : "pass";
    console.log(`[Project-Fluid] exit ${exit}\n` + lines.join("\n") + "\n" + Host.Metrics.Csv());
}

//------------------------------------------------------------------------------------------------------------------------
//                                                 TELEMETRY + UI
//------------------------------------------------------------------------------------------------------------------------

function Telemetry()
{
    const m = Host.Metrics;
    const rows = m.Rows().map(r => `${r.Label.padEnd(16)} ${r.PerTick.toFixed(3).padStart(8)} ms/tick`);
    const gpuTotal = m.Rows().reduce((sum, r) => sum + r.PerTick, 0.0);
    Host.Elements.telemetry.textContent =
        `wall ${m.WallAverage.toFixed(2)} ms/frame (CPU encode) · GPU ${gpuTotal.toFixed(2)} ms/tick · ${Host.Ticks} ticks · ${Host.Dropped} dropped · ${Host.Recipe}\n` + rows.join("\n");
}

function Status(text)
{
    Host.Elements.status.textContent = text;
}

function Refuse(text)
{
    window.ProjectFluidExit = 1;
    Host.Elements.status.textContent = "⛔ " + text;
    Host.Elements.status.className = "fail";
    Host.Finished = true;
}

function Fail(text)
{
    Host.Failures.push(text);
    console.error("[Project-Fluid] " + text);
}

function Download(name, text)
{
    const link = document.createElement("a");
    link.href = URL.createObjectURL(new Blob([text], { type: "text/csv" }));
    link.download = name;
    link.click();
    URL.revokeObjectURL(link.href);
}

// A stand-in for GPUCanvasContext: one rgba8unorm texture sized like the canvas plus a PNG capture for the harness.
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
    window.ProjectFluidCapture = async () =>
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

function InstallOrbit(canvas)
{
    let dragging = false, lastX = 0, lastY = 0;
    canvas.addEventListener("pointerdown", e => { dragging = true; lastX = e.clientX; lastY = e.clientY; canvas.setPointerCapture(e.pointerId); });
    canvas.addEventListener("pointerup",   e => { dragging = false; canvas.releasePointerCapture(e.pointerId); });
    canvas.addEventListener("pointermove", e =>
    {
        if (!dragging || !Host.Surface) { return; }
        const o = Host.Surface.Orbit;
        o.Yaw   -= (e.clientX - lastX) * 0.005;
        o.Pitch  = Math.min(1.45, Math.max(-0.2, o.Pitch + (e.clientY - lastY) * 0.005));
        lastX = e.clientX; lastY = e.clientY;
    });
    canvas.addEventListener("wheel", e => { if (Host.Surface) { Host.Surface.Orbit.Distance = Math.min(12.0, Math.max(0.8, Host.Surface.Orbit.Distance * (1 + e.deltaY * 0.001))); e.preventDefault(); } }, { passive: false });
    const Resize = () =>
    {
        const ratio = Math.min(window.devicePixelRatio || 1, 2);
        canvas.width  = Math.floor(canvas.clientWidth * ratio);
        canvas.height = Math.floor(canvas.clientHeight * ratio);
    };
    new ResizeObserver(Resize).observe(canvas);
    Resize();
}

Start().catch(error => { console.error(error); Refuse(String(error?.message ?? error)); });
