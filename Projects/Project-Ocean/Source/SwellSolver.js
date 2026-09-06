//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/SwellSolver.js — Spectral Ocean Host (band textures, FFT dispatch, foam window, proofs)
//============================================================================================================================================
//
//    Owns the GPU side of the sea: per band an N×N spectrum (h̃0), the spectral/spatial ping-pong storage, and three
//    rgba16float texture arrays the renderer samples (Displacement, Derivative, Motion). Advance(encoder, Δτ) records:
//        Evolve (all bands) → FftRows → FftColumns → Compose → [FoamAdvance]
//    — 5 dispatches per tick regardless of band count (bands are array layers / workgroup z). The FFT is decimation in time
//    in workgroup memory: one row (or column) of one slab per workgroup, N elements per line, 3 layers × Bands slabs.
//
//    Proofs (RecordProof / ReadProof, non-blocking readback like Project-Fluid):
//        spectrum      Σ_k(|h̃0(k)|² + |h̃0(−k)|²) per band = ∫∫ S(k) dk² over the band window (CPU quadrature) within 5 %:
//                      the GPU spectrum carries the variance the model prescribes (band windows, Δk², TMA, spreading all agree)
//        parseval      mean_x h² = Σ_k |ĥ(k,t)|² within 2 % — the FFT is an exact inverse DFT (fp16 storage is the error source)
//        dispersion    (mode scene) the seeded wave's Fourier coefficient advances its phase at ω = √(g k tanh kh) within 1 %
//                      and keeps |coefficient| = A/2 within 2 %
//        finite        no NaN/Inf in any band texture or the foam window; |h| below 4 Hs
//        foam          (sea scene) foam exists when the breaking mask fires and is zero when it never fires; the foam
//                      fraction is monotone in wind speed across proof runs (compared by the host across URLs)
//    Trace hash: FNV-1a over the row sums of the final proof.

import { Scenes } from "./OceanStructure.js";

const Tile        = 16;
const FftThreads  = 256;
const SeaBytes    = 192;
const KernelNames = ["SpectrumInit", "Evolve", "FftRows", "FftColumns", "Compose", "Measure", "MeasureMode"];
const Layers      = 3;

export class SwellSolver
{
    static async Create(device, sea, options = {})
    {
        const [shared, swell, foam] = await Promise.all(["SeaStructure", "SwellSolver", "FoamSolver"].map(async name =>
        {
            const source = await fetch(new URL(`./Shaders/${name}.wgsl`, import.meta.url));
            if (!source.ok)
            {
                throw new Error(`SwellSolver: cannot load ${name}.wgsl (${source.status})`);
            }
            return source.text();
        }));
        return new SwellSolver(device, sea, options, shared, swell, foam);
    }

    constructor(device, sea, options, shared, swellCode, foamCode)
    {
        this.Device  = device;
        this.Sea     = sea;
        this.Options = { Gaussian: false, FoamSize: 512, FoamSpacing: 1.0, Blur: 0.35, ...options };
        this.Time    = 0.0;      // [s] simulated seconds
        this.Tick    = 0;
        this.Shoal   = null;     // tier 2, attached later
        const N = sea.Size, B = sea.BandCount;
        this.Size = N; this.Bands = B;

        // Kernels. The FFT line length is N; each of the min(N / 2, 256) workgroup threads handles N / 512 butterflies per stage.
        const threads = Math.max(32, Math.min(FftThreads, N / 2));
        const code = shared + "\n" + swellCode.replaceAll("LINE_LENGTH", String(N)).replaceAll("FFT_THREADS", String(threads) + "u");
        const module = device.createShaderModule({ label: "SwellSolver", code });
        const C = GPUShaderStage.COMPUTE;
        // Two layouts over one binding space: the simulation kernels write the band textures (bindings 4–6), the measure
        // kernels read them (8–9); WebGPU forbids one bind group holding a texture as both, so each set gets its own group.
        const simulateLayout = device.createBindGroupLayout({
            label: "SwellSimulateLayout",
            entries: [
                { binding: 0, visibility: C, buffer: { type: "uniform" } },
                { binding: 1, visibility: C, buffer: { type: "storage" } },
                { binding: 2, visibility: C, buffer: { type: "storage" } },
                { binding: 3, visibility: C, buffer: { type: "storage" } },
                { binding: 4, visibility: C, storageTexture: { access: "write-only", format: "rgba16float", viewDimension: "2d-array" } },
                { binding: 5, visibility: C, storageTexture: { access: "write-only", format: "rgba16float", viewDimension: "2d-array" } },
                { binding: 6, visibility: C, storageTexture: { access: "write-only", format: "rgba16float", viewDimension: "2d-array" } },
            ],
        });
        const measureLayout = device.createBindGroupLayout({
            label: "SwellMeasureLayout",
            entries: [
                { binding: 0, visibility: C, buffer: { type: "uniform" } },
                { binding: 1, visibility: C, buffer: { type: "storage" } },
                { binding: 7, visibility: C, buffer: { type: "storage" } },
                { binding: 8, visibility: C, texture: { sampleType: "unfilterable-float", viewDimension: "2d-array" } },
                { binding: 9, visibility: C, texture: { sampleType: "unfilterable-float", viewDimension: "2d-array" } },
            ],
        });
        const simulatePipeline = device.createPipelineLayout({ bindGroupLayouts: [simulateLayout] });
        const measurePipeline  = device.createPipelineLayout({ bindGroupLayouts: [measureLayout] });
        this.Kernels = {};
        for (const name of KernelNames)
        {
            const measure = name.startsWith("Measure");
            this.Kernels[name] = device.createComputePipeline({ label: name, layout: measure ? measurePipeline : simulatePipeline, compute: { module, entryPoint: name } });
        }

        // Storage: spectra and fields.
        const S = GPUBufferUsage;
        const Make = (label, size, usage) => device.createBuffer({ label, size, usage });
        const cells = B * N * N;
        this.Constants = Make("SeaConstants", SeaBytes, S.UNIFORM | S.COPY_DST);
        this.Initial   = Make("InitialSpectrum", cells * 16, S.STORAGE | S.COPY_SRC);
        this.Spectral  = Make("Spectral", Layers * cells * 16, S.STORAGE | S.COPY_SRC);   // COPY_SRC: diagnostics
        this.Pong      = Make("Pong", Layers * cells * 16, S.STORAGE | S.COPY_SRC);
        this.PartialRows = 3 * B * N + 1;
        this.Partials  = Make("SwellPartials", this.PartialRows * 16, S.STORAGE | S.COPY_SRC);

        const T = GPUTextureUsage;
        const Texture = (label) => device.createTexture({ label, size: [N, N, B], format: "rgba16float", usage: T.STORAGE_BINDING | T.TEXTURE_BINDING | T.COPY_SRC });
        this.Displacement = Texture("Displacement");
        this.Derivative   = Texture("Derivative");
        this.Motion       = Texture("Motion");
        this.DisplacementView = this.Displacement.createView({ dimension: "2d-array" });
        this.DerivativeView   = this.Derivative.createView({ dimension: "2d-array" });
        this.MotionView       = this.Motion.createView({ dimension: "2d-array" });

        this.Group = device.createBindGroup({
            label: "SwellSimulateGroup", layout: simulateLayout,
            entries: [
                { binding: 0, resource: { buffer: this.Constants } },
                { binding: 1, resource: { buffer: this.Initial } },
                { binding: 2, resource: { buffer: this.Spectral } },
                { binding: 3, resource: { buffer: this.Pong } },
                { binding: 4, resource: this.DisplacementView },
                { binding: 5, resource: this.DerivativeView },
                { binding: 6, resource: this.MotionView },
            ],
        });
        this.MeasureGroup = device.createBindGroup({
            label: "SwellMeasureGroup", layout: measureLayout,
            entries: [
                { binding: 0, resource: { buffer: this.Constants } },
                { binding: 1, resource: { buffer: this.Initial } },
                { binding: 7, resource: { buffer: this.Partials } },
                { binding: 8, resource: this.DisplacementView },
                { binding: 9, resource: this.MotionView },
            ],
        });

        // Foam window (tier 1).
        this.FoamEnabled = sea.Foam;
        this.FoamSize    = this.Options.FoamSize;
        this.FoamSpacing = this.Options.FoamSpacing;
        this.FoamOrigin  = [0.0, 0.0];
        this.FoamPrevious = [0.0, 0.0];
        this.FoamFocus   = [0.0, 0.0];
        this.Wrap  = device.createSampler({ label: "Wrap",  addressModeU: "repeat", addressModeV: "repeat", magFilter: "linear", minFilter: "linear" });
        this.Clamp = device.createSampler({ label: "Clamp", addressModeU: "clamp-to-edge", addressModeV: "clamp-to-edge", magFilter: "linear", minFilter: "linear" });
        const FoamTexture = (label) => device.createTexture({ label, size: [this.FoamSize, this.FoamSize], format: "rgba16float",
                                                              usage: T.STORAGE_BINDING | T.TEXTURE_BINDING | T.RENDER_ATTACHMENT });
        this.FoamTextures = [FoamTexture("FoamA"), FoamTexture("FoamB")];
        this.FoamViews    = this.FoamTextures.map(t => t.createView());
        this.FoamIndex    = 0;      // the texture holding the current foam
        const foamShader = device.createShaderModule({ label: "FoamSolver", code: shared + "\n" + foamCode });
        this.FoamLayout = device.createBindGroupLayout({
            label: "FoamSolverLayout",
            entries: [
                { binding: 0, visibility: C, buffer: { type: "uniform" } },
                { binding: 1, visibility: C, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 2, visibility: C, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 3, visibility: C, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 4, visibility: C, sampler: { type: "filtering" } },
                { binding: 5, visibility: C, texture: { sampleType: "float" } },
                { binding: 6, visibility: C, sampler: { type: "filtering" } },
                { binding: 7, visibility: C, storageTexture: { access: "write-only", format: "rgba16float" } },
                { binding: 10, visibility: C, buffer: { type: "uniform" } },
                { binding: 11, visibility: C, texture: { sampleType: "unfilterable-float" } },
            ],
        });
        this.FoamMeasureLayout = device.createBindGroupLayout({
            label: "FoamMeasureLayout",
            entries: [
                { binding: 0, visibility: C, buffer: { type: "uniform" } },
                { binding: 8, visibility: C, texture: { sampleType: "unfilterable-float" } },
                { binding: 9, visibility: C, buffer: { type: "storage" } },
            ],
        });
        this.FoamAdvance = device.createComputePipeline({ label: "FoamAdvance", layout: device.createPipelineLayout({ bindGroupLayouts: [this.FoamLayout] }),
                                                          compute: { module: foamShader, entryPoint: "FoamAdvance" } });
        this.FoamMeasure = device.createComputePipeline({ label: "MeasureFoam", layout: device.createPipelineLayout({ bindGroupLayouts: [this.FoamMeasureLayout] }),
                                                          compute: { module: foamShader, entryPoint: "MeasureFoam" } });
        this.FoamPartials = Make("FoamPartials", this.FoamSize * 32, S.STORAGE | S.COPY_SRC);
        // Tier-2 stand-ins until AttachShoal: a Shoal uniform with scene 0 (every patch branch skips) and a 1×1 state texture.
        this.ShoalStandIn = { Constants: Make("ShoalAbsent", 176, S.UNIFORM | S.COPY_DST),
                              Texture: device.createTexture({ label: "ShoalAbsent", size: [1, 1], format: "rgba32float", usage: T.TEXTURE_BINDING }) };
        this.ShoalStandIn.View = this.ShoalStandIn.Texture.createView();
        this.ShoalConstants = this.ShoalStandIn.Constants;
        this.ShoalView = this.ShoalStandIn.View;
        this.BuildFoamGroups();
        this.FoamMeasureGroups = [0, 1].map(i => device.createBindGroup({
            label: `FoamMeasureGroup${i}`, layout: this.FoamMeasureLayout,
            entries: [
                { binding: 0, resource: { buffer: this.Constants } },
                { binding: 8, resource: this.FoamViews[i] },
                { binding: 9, resource: { buffer: this.FoamPartials } },
            ],
        }));

        // Proof staging: [swell partials | foam partials].
        this.FoamOffset   = this.PartialRows * 16;
        this.StagingBytes = this.FoamOffset + this.FoamSize * 32;
        this.Staging      = Make("ProofStaging", this.StagingBytes, S.MAP_READ | S.COPY_DST);
        this.StagingBusy  = false;
        this.ProofRecorded = false;
        this.LastProof    = null;

        this.Spectrum = sea.Spectral ? this.PrescribedVariance() : { Bands: new Array(B).fill(0.0), Total: 0.0, Slope: new Array(B).fill(0.0), LambdaMin: sea.Bands.map(b => 2.0 * Math.PI / b.MaxK) };
        this.WriteSea(0.0, 1.0 / 60.0);
        if (sea.Spectral)
        {
            const encoder = device.createCommandEncoder({ label: "SeaInit" });
            const pass = encoder.beginComputePass({ label: "SpectrumInit" });
            pass.setPipeline(this.Kernels.SpectrumInit);
            pass.setBindGroup(0, this.Group);
            pass.dispatchWorkgroups(Math.ceil(N / Tile), Math.ceil(N / Tile), B);
            pass.end();
            device.queue.submit([encoder.finish()]);
        }
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                     CONSTANTS
    //--------------------------------------------------------------------------------------------------------------------

    WriteSea(time, dt)
    {
        const sea = this.Sea;
        const words = new ArrayBuffer(SeaBytes);
        const u = new Uint32Array(words), f = new Float32Array(words);
        u[0] = sea.Size; u[1] = Math.round(Math.log2(sea.Size)); u[2] = sea.BandCount; u[3] = sea.Seed;
        f.set([sea.Gravity, sea.Depth, Math.max(sea.Wind, 0.5), sea.FetchMetres], 4);
        f.set([sea.Gamma, sea.Swell, sea.WindAngle, sea.Choppiness], 8);
        f.set([time, dt, sea.Psi, sea.Scene === Scenes.Mode ? 1.0 : 0.0], 12);
        f.set([sea.Mode.Index, sea.Mode.Amplitude, sea.Mode.K, sea.Mode.Omega], 16);
        for (let b = 0; b < 4; b++)
        {
            const band = sea.Bands[Math.min(b, sea.BandCount - 1)];
            f[20 + b] = band.Spacing; f[24 + b] = band.Length; f[28 + b] = band.MinK; f[32 + b] = band.MaxK;
        }
        f.set([sea.JThreshold, sea.AzGamma, sea.FoamDecay, sea.FoamRate], 36);
        f.set([this.FoamOrigin[0], this.FoamOrigin[1], this.FoamSpacing, this.FoamSize], 40);
        f.set([this.FoamPrevious[0], this.FoamPrevious[1], this.Options.Blur, this.Options.Gaussian ? 1.0 : 0.0], 44);
        this.Device.queue.writeBuffer(this.Constants, 0, words);
    }

    // The foam window follows a focus point (the camera's ground position), snapped to whole texels.
    Focus(x, y)
    {
        this.FoamFocus = [x, y];
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                      ADVANCE
    //--------------------------------------------------------------------------------------------------------------------

    // One tick: bands → (tier-2 shoal, if given) → foam. The shoal runs between the two because the foam reads its bores.
    Advance(encoder, dt, metrics, shoal = null)
    {
        const N = this.Size, B = this.Bands;
        this.Time += dt;
        this.Tick++;
        this.FoamPrevious = this.FoamOrigin;
        const half = 0.5 * this.FoamSize * this.FoamSpacing;
        this.FoamOrigin = [Math.round((this.FoamFocus[0] - half) / this.FoamSpacing) * this.FoamSpacing,
                           Math.round((this.FoamFocus[1] - half) / this.FoamSpacing) * this.FoamSpacing];
        this.WriteSea(this.Time, dt);
        if (!this.Sea.Spectral)
        {
            // No spectral sea in this scene (run-up basin): the band textures stay at their all-zero initial state.
            shoal?.Advance(encoder, dt, metrics);
            this.AdvanceFoam(encoder, metrics);
            return;
        }

        const perKernel = metrics.PerKernel;
        const Dispatch = (name, x, y, z, label) =>
        {
            const pass = encoder.beginComputePass({ label: name, timestampWrites: metrics.Slot(label ?? name) });
            pass.setPipeline(this.Kernels[name]);
            pass.setBindGroup(0, this.Group);
            pass.dispatchWorkgroups(x, y, z);
            pass.end();
        };
        const tiles = Math.ceil(N / Tile);
        Dispatch("Evolve", tiles, tiles, B, perKernel ? "Evolve" : "Spectrum");
        Dispatch("FftRows", N, Layers * B, 1, perKernel ? "FftRows" : "Fft");
        Dispatch("FftColumns", N, Layers * B, 1, perKernel ? "FftColumns" : "Fft");
        Dispatch("Compose", tiles, tiles, B, perKernel ? "Compose" : "Spectrum");
        shoal?.Advance(encoder, dt, metrics);
        this.AdvanceFoam(encoder, metrics);
    }

    AdvanceFoam(encoder, metrics)
    {
        if (!this.FoamEnabled)
        {
            return;
        }
        if (this.Shoal && this.ShoalView !== this.Shoal.View)
        {
            this.ShoalView = this.Shoal.View;
            this.BuildFoamGroups();
        }
        const pass = encoder.beginComputePass({ label: "FoamAdvance", timestampWrites: metrics.Slot("Foam") });
        pass.setPipeline(this.FoamAdvance);
        pass.setBindGroup(0, this.FoamGroups[this.FoamIndex]);
        const groups = Math.ceil(this.FoamSize / Tile);
        pass.dispatchWorkgroups(groups, groups, 1);
        pass.end();
        this.FoamIndex = 1 - this.FoamIndex;
    }

    get FoamView()
    {
        return this.FoamViews[this.FoamIndex];
    }

    BuildFoamGroups()
    {
        this.FoamGroups = [0, 1].map(i => this.Device.createBindGroup({
            label: `FoamGroup${i}`, layout: this.FoamLayout,
            entries: [
                { binding: 0, resource: { buffer: this.Constants } },
                { binding: 1, resource: this.DisplacementView },
                { binding: 2, resource: this.DerivativeView },
                { binding: 3, resource: this.MotionView },
                { binding: 4, resource: this.Wrap },
                { binding: 5, resource: this.FoamViews[i] },          // previous = i, next = 1 − i
                { binding: 6, resource: this.Clamp },
                { binding: 7, resource: this.FoamViews[1 - i] },
                { binding: 10, resource: { buffer: this.ShoalConstants } },
                { binding: 11, resource: this.ShoalView },
            ],
        }));
    }

    // Tier 2 present: the foam reads the patch's bores. Called once after ShoalSolver.Create (its state ping-pongs, so the
    // group is rebuilt per tick with the current view — cheap, two bind groups).
    AttachShoal(shoal)
    {
        this.Shoal = shoal;
        this.ShoalConstants = shoal.Constants;
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                       PROOFS
    //--------------------------------------------------------------------------------------------------------------------

    // Records the reductions and the staging copy; false when the previous readback is still mapped (caller retries).
    RecordProof(encoder, metrics)
    {
        if (this.StagingBusy)
        {
            return false;
        }
        const N = this.Size, B = this.Bands;
        const pass = encoder.beginComputePass({ label: "Measure", timestampWrites: metrics.Slot("Proof") });
        pass.setPipeline(this.Kernels.Measure);
        pass.setBindGroup(0, this.MeasureGroup);
        pass.dispatchWorkgroups(N, B, 1);
        if (this.Sea.Scene === Scenes.Mode)
        {
            pass.setPipeline(this.Kernels.MeasureMode);
            pass.dispatchWorkgroups(1, 1, 1);
        }
        if (this.FoamEnabled)
        {
            pass.setPipeline(this.FoamMeasure);
            pass.setBindGroup(0, this.FoamMeasureGroups[this.FoamIndex]);
            pass.dispatchWorkgroups(this.FoamSize, 1, 1);
        }
        pass.end();
        encoder.copyBufferToBuffer(this.Partials, 0, this.Staging, 0, this.PartialRows * 16);
        if (this.FoamEnabled)
        {
            encoder.copyBufferToBuffer(this.FoamPartials, 0, this.Staging, this.FoamOffset, this.FoamSize * 32);
        }
        this.StagingBusy = true;
        this.ProofRecorded = true;
        this.ProofTime = this.Time;
        this.ProofTick = this.Tick;
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
            return null;
        }
        const words = new Float32Array(this.Staging.getMappedRange().slice(0));
        this.Staging.unmap();
        this.StagingBusy = false;

        const N = this.Size, B = this.Bands, sea = this.Sea;
        const bands = [];
        let nonFinite = 0, maxHeight = 0.0, hash = 0x811c9dc5;
        for (let b = 0; b < B; b++)
        {
            let sumSquares = 0.0, spectral = 0.0, energy = 0.0, acceleration = 0.0, velocity = 0.0;
            for (let row = 0; row < N; row++)
            {
                const i = 3 * (b * N + row) * 4;
                sumSquares += words[i];
                maxHeight = Math.max(maxHeight, words[i + 1]);
                nonFinite += words[i + 2];
                spectral += words[i + 3];
                energy += words[i + 4];
                acceleration += words[i + 8];
                velocity += words[i + 9];
                hash = Fnv(hash, words[i]);
            }
            const texels = N * N;
            bands.push({ Variance: sumSquares / texels, Spectral: spectral, Prescribed: this.Spectrum.Bands[b], Energy: energy,
                         AccelerationRms: Math.sqrt(acceleration / texels), VelocityRms: Math.sqrt(velocity / texels) });
        }
        const modeIndex = 3 * B * N * 4;
        const mode = { Re: words[modeIndex], Im: words[modeIndex + 1] };
        let foam = null;
        if (this.FoamEnabled)
        {
            let sum = 0.0, mask = 0.0, folded = 0.0, covered = 0.0, bad = 0.0, fall = 0.0, fall2 = 0.0;
            for (let row = 0; row < this.FoamSize; row++)
            {
                const i = this.FoamOffset / 4 + row * 8;
                sum += words[i]; mask += words[i + 1]; folded += words[i + 2]; covered += words[i + 3];
                bad += words[i + 4]; fall += words[i + 5]; fall2 += words[i + 6];
            }
            const texels = this.FoamSize * this.FoamSize;
            foam = { Mean: sum / texels, MaskFraction: mask / texels, FoldedFraction: folded / texels, Coverage: covered / texels,
                     NonFinite: bad, FallMean: fall / texels, FallRms: Math.sqrt(fall2 / texels) };
            nonFinite += bad;
        }
        const totalVariance = bands.reduce((s, b) => s + b.Variance, 0.0);
        this.LastProof = {
            Time: this.ProofTime, Tick: this.ProofTick, Bands: bands, TotalVariance: totalVariance,
            SignificantHeight: 4.0 * Math.sqrt(totalVariance), Prescribed: this.Spectrum.Total,
            MaxHeight: maxHeight, NonFinite: nonFinite, Mode: mode, Foam: foam, Hash: hash >>> 0,
        };
        return this.LastProof;
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                  CPU SPECTRUM
    //--------------------------------------------------------------------------------------------------------------------

    // ∫∫ S(k) dk² over each band window by midpoint quadrature on the band's own wavenumber grid — the same texels the GPU
    // seeds, so the comparison isolates the GPU arithmetic (and the fp16 write of h) rather than quadrature differences.
    PrescribedVariance()
    {
        const sea = this.Sea;
        const N = sea.Size;
        const result = { Bands: [], Total: 0.0, Slope: [], LambdaMin: [] };
        for (let b = 0; b < sea.BandCount; b++)
        {
            const band = sea.Bands[b];
            let sum = 0.0, slope = 0.0;
            if (sea.Scene === Scenes.Mode)
            {
                if (b === 0)
                {
                    sum = 0.5 * sea.Mode.Amplitude * sea.Mode.Amplitude;
                    slope = sum * sea.Mode.K * sea.Mode.K;
                }
            }
            else
            {
                const dk = band.DeltaK;
                for (let y = 0; y < N; y++)
                {
                    const ky = (y - N / 2) * dk;
                    for (let x = 0; x < N; x++)
                    {
                        const kx = (x - N / 2) * dk;
                        const s = Density(sea, kx, ky, b) * dk * dk;
                        sum += s;
                        slope += s * (kx * kx + ky * ky);
                    }
                }
            }
            result.Bands.push(sum);
            result.Slope.push(slope);
            result.LambdaMin.push(2.0 * Math.PI / band.MaxK);
            result.Total += sum;
        }
        return result;
    }

    Destroy()
    {
        for (const b of [this.Constants, this.Initial, this.Spectral, this.Pong, this.Partials, this.FoamPartials, this.Staging]) { b.destroy(); }
        for (const t of [this.Displacement, this.Derivative, this.Motion, ...this.FoamTextures, this.ShoalStandIn.Texture]) { t.destroy(); }
        this.ShoalStandIn.Constants.destroy();
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                                   SPECTRUM (CPU)
//------------------------------------------------------------------------------------------------------------------------

// Mirror of Density() in SwellSolver.wgsl — keep the two in step.
export function Density(sea, kx, ky, b)
{
    const band = sea.Bands[b];
    const kk = Math.hypot(kx, ky);
    if (kk < 1.0e-6 || kk < band.MinK || kk >= band.MaxK)
    {
        return 0.0;
    }
    const g = sea.Gravity, depth = sea.Depth, wind = Math.max(sea.Wind, 0.5), reach = sea.FetchMetres;
    const th = Math.tanh(kk * depth);          // JS tanh saturates safely; the WGSL side uses its own Tanh for that
    const w = Math.sqrt(g * kk * th);
    const dwdk = (g * th + g * kk * depth * (1.0 - th * th)) / (2.0 * w);
    const wp = 22.0 * Math.pow(g * g / (wind * reach), 1.0 / 3.0);
    const alpha = 0.076 * Math.pow(wind * wind / (reach * g), 0.22);
    const sigma = w <= wp ? 0.07 : 0.09;
    const r = Math.exp(-(w - wp) * (w - wp) / (2.0 * sigma * sigma * wp * wp));
    let s = alpha * g * g / Math.pow(w, 5.0) * Math.exp(-1.25 * Math.pow(wp / w, 4.0)) * Math.pow(sea.Gamma, r);
    const wh = w * Math.sqrt(depth / g);
    s *= wh < 1.0 ? 0.5 * wh * wh : (wh < 2.0 ? 1.0 - 0.5 * (2.0 - wh) * (2.0 - wh) : 1.0);
    const theta = Math.acos(Math.min(1.0, Math.max(-1.0, (kx * Math.cos(sea.WindAngle) + ky * Math.sin(sea.WindAngle)) / kk)));
    const x = w / wp;
    let beta;
    if (x < 0.56)      { beta = 2.61 * Math.pow(0.56, 1.3); }
    else if (x < 0.95) { beta = 2.61 * Math.pow(x, 1.3); }
    else if (x < 1.6)  { beta = 2.28 * Math.pow(x, -1.3); }
    else               { beta = Math.pow(10.0, -0.4 + 0.8393 * Math.exp(-0.567 * Math.log(x * x))); }
    beta *= 1.0 + 4.0 * sea.Swell * Math.exp(-x * x);
    const sech = 1.0 / Math.cosh(beta * theta);
    const d = beta / (2.0 * Math.tanh(beta * Math.PI)) * sech * sech;
    return s * d * dwdk / kk;
}

function Fnv(hash, value)
{
    const bytes = new Uint8Array(new Float32Array([value]).buffer);
    for (const byte of bytes)
    {
        hash ^= byte;
        hash = Math.imul(hash, 0x01000193);
    }
    return hash >>> 0;
}
