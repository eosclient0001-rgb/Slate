//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/ShoalSolver.js — Shoal Patch Host (SWE state textures, sub-stepping, window shift, proofs)
//============================================================================================================================================
//
//    Owns tier 2: two rgba32float state textures (h, u, v, bore) that ping-pong through ShoalVelocity → ShoalDepth every
//    sub-step, the Shoal uniform (bed, patch window, wave, limits), and the proof readback. The patch is Size² cells of
//    Cell metres, fixed to the world; in the shore and open-sea scenes it re-centres on the camera in whole cells (ShoalShift),
//    in the run-up scene it stays put so the benchmark is exact.
//
//    Sub-steps: Δτ ≤ Courant · Δx / (√(g d_max) + ¼ u_cap) with Courant 0.5, so the GTX profile (256² at 1 m, 20 m deep) takes
//    1 sub-step per 1/60 s tick and the RTX profile (512² at 0.5 m) 2.
//
//    Hull: a moving surface pressure (a Gaussian of `HullHead` metres of head, radius `HullRadius`) that the host places
//    ahead of the camera in the open and shore scenes — the water stands lower under it and its motion sheds the
//    shallow-water wake (non-dispersive: the Kelvin pattern needs the Airy extension, RTX-only, O4+).
//
//    Proofs (RecordProof / ReadProof):
//        volume     Σ h Δx² of the closed basin (run-up scene, sponge 0) drifts less than 1e-4 relative over the run; in the
//                   open scenes the sponge exchanges water by design, so only finiteness and the caps are checked
//        run-up     run-up scene: the highest wet free surface R over the run vs Synolakis' R/d = 2.831 √cot β (H/d)^{5/4}
//                   (H/d = 0.0185 on his 1:19.85 beach → R/d = 0.0861). The scheme under-predicts by ≈ 0.45 Δx/d
//                   (1-D mirror of this kernel: −12 % at Δx/d = 0.25, −5.3 % at 0.125, −1.7 % at 0.0625 — the GPU run at
//                   Δx/d = 0.25 gave −17 % before the centred/upwind switch), so the tolerance is 5 % + 0.5 Δx/d and the
//                   log prints the error so the convergence can be read across the tiers
//        finite     no NaN/Inf, |u| below the cap, η below 3 H + Hs
//        bores      shore scene at wind ≥ 12 m/s: the bore detector fires somewhere in the surf zone (drives the foam)

import { Scenes, PeakWavelength } from "./OceanStructure.js";

const Tile        = 16;
const ShoalBytes  = 176;
const KernelNames = ["ShoalInit", "ShoalVelocity", "ShoalDepth", "ShoalShift", "ShoalMeasure"];

export class ShoalSolver
{
    static async Create(device, sea, swell, options = {})
    {
        const [shared, code] = await Promise.all(["SeaStructure", "ShoalSolver"].map(async name =>
        {
            const source = await fetch(new URL(`./Shaders/${name}.wgsl`, import.meta.url));
            if (!source.ok)
            {
                throw new Error(`ShoalSolver: cannot load ${name}.wgsl (${source.status})`);
            }
            return source.text();
        }));
        return new ShoalSolver(device, sea, swell, options, shared + "\n" + code);
    }

    constructor(device, sea, swell, options, code)
    {
        this.Device  = device;
        this.Sea     = sea;
        this.Swell   = swell;
        this.Options = { Size: 256, Cell: 1.0, Courant: 0.5, ...options };
        this.Size    = this.Options.Size;
        this.Cell    = this.Options.Cell;
        this.Shoal   = sea.Shoal;
        this.Time    = 0.0;
        this.Origin  = [0.0, 0.0];        // [m] south-west corner
        this.Focus   = [0.0, 0.0];
        this.Index   = 0;                 // texture holding the current state
        this.MaxRunUp = -1.0e9;         // highest wet bed seen [m] (quantised by the cell: Δx · slope)
        this.MaxSurface = -1.0e9;       // highest wet free surface seen [m] — the run-up R of the benchmark
        this.InitialVolume = null;

        const module = device.createShaderModule({ label: "ShoalSolver", code });
        const C = GPUShaderStage.COMPUTE;
        this.Layout = device.createBindGroupLayout({
            label: "ShoalLayout",
            entries: [
                { binding: 0, visibility: C, buffer: { type: "uniform" } },
                { binding: 1, visibility: C, buffer: { type: "uniform" } },
                { binding: 2, visibility: C, texture: { sampleType: "unfilterable-float" } },
                { binding: 3, visibility: C, storageTexture: { access: "write-only", format: "rgba32float" } },
                { binding: 4, visibility: C, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 5, visibility: C, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 6, visibility: C, sampler: { type: "filtering" } },
                { binding: 7, visibility: C, buffer: { type: "storage" } },
            ],
        });
        const layout = device.createPipelineLayout({ bindGroupLayouts: [this.Layout] });
        this.Kernels = {};
        for (const name of KernelNames)
        {
            this.Kernels[name] = device.createComputePipeline({ label: name, layout, compute: { module, entryPoint: name } });
        }
        const S = GPUBufferUsage, T = GPUTextureUsage;
        this.Constants = device.createBuffer({ label: "ShoalConstants", size: ShoalBytes, usage: S.UNIFORM | S.COPY_DST });
        this.Partials  = device.createBuffer({ label: "ShoalPartials", size: this.Size * 32, usage: S.STORAGE | S.COPY_SRC });
        this.Staging   = device.createBuffer({ label: "ShoalStaging", size: this.Size * 32, usage: S.MAP_READ | S.COPY_DST });
        this.StagingBusy = false;
        this.Destroyed   = false;
        this.ProofRecorded = false;
        this.Textures = [0, 1].map(i => device.createTexture({ label: `ShoalState${i}`, size: [this.Size, this.Size], format: "rgba32float",
                                                                usage: T.STORAGE_BINDING | T.TEXTURE_BINDING }));
        this.Views = this.Textures.map(t => t.createView());
        this.Groups = [0, 1].map(i => device.createBindGroup({
            label: `ShoalGroup${i}`, layout: this.Layout,
            entries: [
                { binding: 0, resource: { buffer: swell.Constants } },
                { binding: 1, resource: { buffer: this.Constants } },
                { binding: 2, resource: this.Views[i] },
                { binding: 3, resource: this.Views[1 - i] },
                { binding: 4, resource: swell.DisplacementView },
                { binding: 5, resource: swell.MotionView },
                { binding: 6, resource: swell.Wrap },
                { binding: 7, resource: { buffer: this.Partials } },
            ],
        }));

        // Sub-step plan from the deepest water and the speed cap.
        const depthMax = this.Shoal.Depth + this.Shoal.WaveHeight;
        const speed = Math.sqrt(sea.Gravity * depthMax) + this.Shoal.SpeedCap * 0.25;
        const tick = 1.0 / 60.0;
        this.SubSteps = Math.max(1, Math.ceil(tick / (this.Options.Courant * this.Cell / speed)));
        this.SubStepSeconds = tick / this.SubSteps;

        // Initial window: the run-up basin spans x ∈ [−½, ½] · size (its shoreline is at 0.38 · size, 12 % from the landward
        // wall — see DescribeSea); the other scenes centre on the focus.
        const shoal = this.Shoal;
        const half = 0.5 * this.Size * this.Cell;
        this.Origin = [Math.round(-half / this.Cell) * this.Cell, Math.round(-half / this.Cell) * this.Cell];
        this.WriteShoal([0, 0]);
        const encoder = device.createCommandEncoder({ label: "ShoalInit" });
        const pass = encoder.beginComputePass({ label: "ShoalInit" });
        pass.setPipeline(this.Kernels.ShoalInit);
        pass.setBindGroup(0, this.Groups[1]);          // writes texture 0
        const groups = Math.ceil(this.Size / Tile);
        pass.dispatchWorkgroups(groups, groups, 1);
        pass.end();
        device.queue.submit([encoder.finish()]);
        this.Index = 0;
    }

    get View()
    {
        return this.Views[this.Index];
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                     CONSTANTS
    //--------------------------------------------------------------------------------------------------------------------

    WriteShoal(shift)
    {
        const s = this.Shoal, sea = this.Sea, spectrum = this.Swell.Spectrum;
        const words = new ArrayBuffer(ShoalBytes);
        const f = new Float32Array(words), i = new Int32Array(words);
        const sceneCode = { [Scenes.Sea]: 0.0, [Scenes.Mode]: 0.0, [Scenes.Open]: 1.0, [Scenes.Shore]: 2.0, [Scenes.RunUp]: 3.0 }[s.Scene] ?? 0.0;
        f.set([this.Origin[0], this.Origin[1], this.Cell, this.Size], 0);
        f.set([s.Shore[0], s.Shore[1], s.Normal[0], s.Normal[1]], 4);
        f.set([s.Slope, s.Depth, s.Berm, s.BarHeight], 8);
        f.set([s.BarDistance, s.BarWidth, s.CuspAmplitude, s.CuspWavelength], 12);
        f.set([s.WaveHeight, s.WaveDepth, s.CrestDistance, sceneCode], 16);
        f.set([this.SubStepSeconds, s.Manning, s.Sponge, s.Relaxation], 20);
        const handover = sea.Spectral ? PeakWavelength(sea) / s.ShallowRatio : 0.0;      // [m]
        f.set([s.Dry, s.SpeedCap, handover, s.ForcingCap], 24);
        f.set(this.Hull ?? [0.0, 0.0, 0.0, 0.0], 28);
        for (let b = 0; b < 4; b++)
        {
            const band = sea.Bands[Math.min(b, sea.BandCount - 1)];
            const lo = 2.0 * Math.PI / band.MaxK, hi = band.MinK > 0.0 ? 2.0 * Math.PI / band.MinK : band.Length;
            f[32 + b] = b < sea.BandCount ? Math.sqrt(lo * hi) : 1.0;
            f[36 + b] = b < sea.BandCount ? Math.sqrt(spectrum.Bands[b]) : 0.0;
        }
        i.set([shift[0], shift[1], 0, 0], 40);
        this.Device.queue.writeBuffer(this.Constants, 0, words);
    }

    // Same scene and patch, new wind / fetch / depth: the handover depth and the band amplitudes are re-read from the new
    // description at the next WriteShoal; the water in the patch carries on and relaxes toward the re-seeded bands.
    Reseed(sea)
    {
        this.Sea   = sea;
        this.Shoal = sea.Shoal;
        if (!sea.Shoal.Hull)
        {
            this.Hull = null;                                 // the hull checkbox went off: lift the pressure patch
        }
    }

    SetFocus(x, y)
    {
        this.Focus = [x, y];
    }

    SetHull(x, y, radius, head)
    {
        this.Hull = [x, y, radius, head];
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                      ADVANCE
    //--------------------------------------------------------------------------------------------------------------------

    Advance(encoder, dt, metrics)
    {
        this.Time += dt;
        const groups = Math.ceil(this.Size / Tile);
        const Dispatch = (name, label) =>
        {
            const pass = encoder.beginComputePass({ label: name, timestampWrites: metrics.Slot(label) });
            pass.setPipeline(this.Kernels[name]);
            pass.setBindGroup(0, this.Groups[this.Index]);
            pass.dispatchWorkgroups(groups, groups, 1);
            pass.end();
            this.Index = 1 - this.Index;
        };
        // Follow the camera in whole cells (not in the run-up scene: the benchmark stays put).
        if (this.Shoal.Scene !== Scenes.RunUp)
        {
            const half = 0.5 * this.Size * this.Cell;
            const wanted = [Math.round((this.Focus[0] - half) / this.Cell) * this.Cell, Math.round((this.Focus[1] - half) / this.Cell) * this.Cell];
            const shift = [Math.round((wanted[0] - this.Origin[0]) / this.Cell), Math.round((wanted[1] - this.Origin[1]) / this.Cell)];
            if (shift[0] !== 0 || shift[1] !== 0)
            {
                this.WriteShoal(shift);
                this.Origin = wanted;
                Dispatch("ShoalShift", "Shoal");
            }
        }
        this.WriteShoal([0, 0]);
        const label = metrics.PerKernel ? null : "Shoal";
        for (let s = 0; s < this.SubSteps; s++)
        {
            Dispatch("ShoalVelocity", label ?? "ShoalVelocity");
            Dispatch("ShoalDepth", label ?? "ShoalDepth");
        }
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                       PROOFS
    //--------------------------------------------------------------------------------------------------------------------

    RecordProof(encoder, metrics)
    {
        if (this.StagingBusy)
        {
            return false;
        }
        const pass = encoder.beginComputePass({ label: "ShoalMeasure", timestampWrites: metrics.Slot("Proof") });
        pass.setPipeline(this.Kernels.ShoalMeasure);
        pass.setBindGroup(0, this.Groups[this.Index]);
        pass.dispatchWorkgroups(this.Size, 1, 1);
        pass.end();
        encoder.copyBufferToBuffer(this.Partials, 0, this.Staging, 0, this.Size * 32);
        this.StagingBusy = true;
        this.ProofRecorded = true;
        return true;
    }

    async ReadProof()
    {
        if (!this.ProofRecorded)
        {
            return null;
        }
        this.ProofRecorded = false;
        try
        {
            await this.Staging.mapAsync(GPUMapMode.READ);
        }
        catch (error)
        {
            this.StagingBusy = false;
            if (this.Destroyed)
            {
                this.Staging.destroy();
            }
            return null;
        }
        const words = new Float32Array(this.Staging.getMappedRange().slice(0));
        this.Staging.unmap();
        this.StagingBusy = false;
        if (this.Destroyed)
        {
            this.Staging.destroy();
        }
        let depth = 0.0, maxEta = -1.0e9, wet = 0, bad = 0, runUp = -1.0e9, kinetic = 0.0, bores = 0.0, maxSpeed = 0.0;
        for (let row = 0; row < this.Size; row++)
        {
            const i = row * 8;
            depth += words[i]; maxEta = Math.max(maxEta, words[i + 1]); wet += words[i + 2]; bad += words[i + 3];
            runUp = Math.max(runUp, words[i + 4]); kinetic += words[i + 5]; bores += words[i + 6]; maxSpeed = Math.max(maxSpeed, words[i + 7]);
        }
        const volume = depth * this.Cell * this.Cell;
        if (this.InitialVolume === null)
        {
            this.InitialVolume = volume;
        }
        this.MaxRunUp = Math.max(this.MaxRunUp, runUp);
        this.MaxSurface = Math.max(this.MaxSurface, maxEta);
        return {
            Volume: volume, InitialVolume: this.InitialVolume, MaxEta: maxEta, MaxSurface: this.MaxSurface, Wet: wet, NonFinite: bad,
            RunUp: runUp, MaxRunUp: this.MaxRunUp, Kinetic: 0.5 * kinetic * this.Cell * this.Cell, Bores: bores, MaxSpeed: maxSpeed,
            Cells: this.Size * this.Size,
        };
    }

    // A proof readback still mapping keeps its staging buffer until it unmaps (destroying under mapAsync is a GPU error).
    Destroy()
    {
        this.Destroyed = true;
        for (const b of [this.Constants, this.Partials]) { b.destroy(); }
        for (const t of this.Textures) { t.destroy(); }
        if (!this.StagingBusy)
        {
            this.Staging.destroy();
        }
    }
}

// Synolakis (1987) non-breaking run-up law for a solitary wave of height H in depth d on a plane beach of slope tan β:
// R / d = 2.831 √(cot β) (H / d)^{5/4}. Breaking limit: H / d > 0.818 (cot β)^{−10/9}.
export function SynolakisRunUp(waveHeight, depth, slope)
{
    const ratio = waveHeight / depth;
    return { RunUp: depth * 2.831 * Math.sqrt(1.0 / slope) * Math.pow(ratio, 1.25), Breaking: ratio > 0.818 * Math.pow(1.0 / slope, -10.0 / 9.0) };
}
