//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/LiquidSolver.js — MPM Water on WebGPU (explicit MLS-MPM · position-based MPM)
//============================================================================================================================================
//
//    Owns the GPU side of one dam-break: the particle records, the fixed-point lattice, the seven compute kernels of
//    Shaders/ParticleSolver.wgsl and the staging storage that brings proof sums back to the host. The host drives it with
//    Advance(encoder, subSteps, Δt) once per Tick — the same contract as RigidBodySolver::Advance(Δτ) in Project-Physics —
//    and reads proofs asynchronously so the main loop never stalls on the GPU.
//
//    Two methods, chosen by Tuning.Method (see the shader header for the recipes):
//        "explicit"        MLS-MPM with a Tait equation of state — sub-step bound by the sound speed c₀ (≈ 8 m/s)
//        "positionbased"   PB-MPM (EA SEED 2024) — Iterations Jacobi passes per sub-step, sub-step bound by advection only
//    The constants buffer holds one 256-byte slice per iteration (dynamic uniform offset): slice 0 carries gravity, the
//    last slice carries Integrate = 1; the explicit method is the single-slice case.
//
//    Storage (all in solver space, +Z up, metres):
//        Records          ParticleCount × 80 B     position, volume ratio J, velocity, APIC matrix
//        Lattice          sites × 4 × i32          fixed-point mass + momentum accumulators (atomics)
//        LatticeVelocity  sites × vec4<f32>        velocity after gravity + walls, w = site mass
//        Tally            4 × u32                  [0] saturated fixed-point contributions, [1] speed clamps
//        ProofPartials    ⌈N/256⌉ × 2 vec4<f32>    per-workgroup (count, Σ|v|², Σz, max|v|), (ΣJ, min J, max J, Σ(J−1)²)
//        MassPartials     ⌈sites/256⌉ × f32        per-workgroup Σ site mass

import { ParticleStride } from "./DamBreakStructure.js";

const ParticleWorkgroup = 64;
const SiteWorkgroup     = 256;
const SliceBytes        = 256;                // one SolverConstants (116 B) per iteration; 256 satisfies every minUniformBufferOffsetAlignment
const MaxIterations     = 8;
const ExplicitKernels   = ["ClearLattice", "ScatterMass", "ScatterStress", "AdvanceLattice", "GatherParticles"];
const PositionKernels   = ["ProjectVolume", "ClearLattice", "ScatterMass", "AdvanceLattice", "GatherParticles"];
const KernelNames       = ["ClearLattice", "ScatterMass", "ScatterStress", "ProjectVolume", "AdvanceLattice", "GatherParticles", "ReduceProof"];
const SiteKernels       = new Set(["ClearLattice", "AdvanceLattice"]);

export const Methods = Object.freeze({ Explicit: "explicit", PositionBased: "positionbased" });

export const DefaultTuning = Object.freeze({
    Method:           Methods.PositionBased,
    Iterations:       2,         // [-]      position-based: Jacobi passes per sub-step (EA default 2)
    Stiffness:        10000.0,   // [Pa]     explicit: κ — sound speed c₀ = √(γκ/ρ₀) ≈ 8.4 m/s at γ = 7, ρ₀ = 1000; ≈ 7 % compression under 0.6 m of water
    EosExponent:      7.0,       // [-]      explicit: γ
    Viscosity:        0.002,     // [Pa·s]   explicit: μ
    Cohesion:         0.005,     // [-]      explicit: tensile limit as a fraction of κ: −50 Pa of surface cohesion vs a 1.4 kPa hydrostatic head
    VolumeRelaxation: 2.0,       // [-]      position-based: ω of the volume projection (EA liquidRelaxation 2)
    ShearRelaxation:  0.01,      // [-]      position-based: strain removed per iteration (EA liquidViscosity 0.01)
    VolumeBlend:      0.1,       // [-]      position-based: pull of J toward the lattice volume ratio when compressed (EA 0.1)
    Tension:          0.25,      // [-]      position-based: contraction strain cap per iteration — engages only past J ≈ 4 (spray)
    Gravity:          9.81,      // [m/s²]
    MaxSpeed:         20.0,      // [m/s]    safety clamp (≈ 4 × the free-fall speed over the box height)
    Courant:          0.6,       // [-]      explicit (c₀ + v_ref) · Δt / Δx · position-based v_ref · Δt / Δx — picks the sub-step count
});

export class LiquidSolver
{
    static async Create(device, scene, tuning = {})
    {
        const source = await fetch(new URL("./Shaders/ParticleSolver.wgsl", import.meta.url));
        if (!source.ok)
        {
            throw new Error(`LiquidSolver: cannot load ParticleSolver.wgsl (${source.status})`);
        }
        return new LiquidSolver(device, scene, tuning, await source.text());
    }

    constructor(device, scene, tuning, code)
    {
        this.Device   = device;
        this.Scene    = scene;
        this.Tuning   = { ...DefaultTuning, ...tuning };
        this.Tick     = 0;        // [-]  Advance calls so far
        this.Time     = 0.0;      // [s]  simulated seconds
        this.SubSteps = 0;        // [-]  total sub-steps so far

        const module = device.createShaderModule({ label: "ParticleSolver", code });
        const layout = device.createBindGroupLayout({
            label: "LiquidSolverLayout",
            entries: [
                { binding: 0, visibility: GPUShaderStage.COMPUTE, buffer: { type: "uniform", hasDynamicOffset: true } },
                { binding: 1, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } },
                { binding: 2, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } },
                { binding: 3, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } },
                { binding: 4, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } },
                { binding: 5, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } },
                { binding: 6, visibility: GPUShaderStage.COMPUTE, buffer: { type: "storage" } },
            ],
        });
        const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [layout] });

        this.Kernels = {};
        for (const name of KernelNames)
        {
            this.Kernels[name] = device.createComputePipeline({
                label: name, layout: pipelineLayout, compute: { module, entryPoint: name },
            });
        }

        const N     = scene.ParticleCount;
        const sites = scene.NodeCount;
        this.ParticleGroups = Math.ceil(N / ParticleWorkgroup);
        this.SiteGroups     = Math.ceil(sites / SiteWorkgroup);
        this.ProofGroups    = Math.ceil(N / SiteWorkgroup);

        const Make = (label, size, usage) => device.createBuffer({ label, size, usage });
        const S = GPUBufferUsage;
        this.Records         = Make("Records",         N * ParticleStride,         S.STORAGE | S.COPY_DST | S.COPY_SRC);
        this.Lattice         = Make("Lattice",         sites * 16,                 S.STORAGE | S.COPY_DST);
        this.LatticeVelocity = Make("LatticeVelocity", sites * 16,                 S.STORAGE | S.COPY_SRC);
        this.Tally           = Make("Tally",           16,                         S.STORAGE | S.COPY_SRC | S.COPY_DST);
        this.ProofPartials   = Make("ProofPartials",   this.ProofGroups * 32,      S.STORAGE | S.COPY_SRC);
        this.MassPartials    = Make("MassPartials",    this.SiteGroups * 4,        S.STORAGE | S.COPY_SRC);
        this.Constants       = Make("SolverConstants", SliceBytes * MaxIterations, S.UNIFORM | S.COPY_DST);

        // One staging block: [ProofPartials | MassPartials | Tally], every section 4-byte aligned by construction.
        this.ProofOffset   = 0;
        this.MassOffset    = this.ProofGroups * 32;
        this.TallyOffset   = this.MassOffset + this.SiteGroups * 4;
        this.StagingBytes  = this.TallyOffset + 16;
        this.Staging       = Make("ProofStaging", this.StagingBytes, S.MAP_READ | S.COPY_DST);
        this.StagingBusy   = false;
        this.ProofRecorded = false;
        this.TraceStaging  = null;

        device.queue.writeBuffer(this.Records, 0, scene.Records);
        device.queue.writeBuffer(this.Tally, 0, new Uint32Array(4));

        this.Group = device.createBindGroup({
            label: "LiquidSolverGroup", layout,
            entries: [
                { binding: 0, resource: { buffer: this.Constants, offset: 0, size: SliceBytes } },
                { binding: 1, resource: { buffer: this.Records } },
                { binding: 2, resource: { buffer: this.Lattice } },
                { binding: 3, resource: { buffer: this.LatticeVelocity } },
                { binding: 4, resource: { buffer: this.Tally } },
                { binding: 5, resource: { buffer: this.ProofPartials } },
                { binding: 6, resource: { buffer: this.MassPartials } },
            ],
        });

        this.TimeStep = 0.0;
        this.SetTuning(this.Tuning);
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                    TUNING
    //--------------------------------------------------------------------------------------------------------------------

    SetTuning(tuning)
    {
        this.Tuning = { ...this.Tuning, ...tuning };
        this.Tuning.Iterations = Math.min(MaxIterations, Math.max(1, Math.round(this.Tuning.Iterations)));
        this.WriteConstants(this.TimeStep);
    }

    get PositionBased()
    {
        return this.Tuning.Method === Methods.PositionBased;
    }

    // Iterations of the lattice transfer per sub-step: 1 for the explicit method, Tuning.Iterations for position-based.
    get Iterations()
    {
        return this.PositionBased ? this.Tuning.Iterations : 1;
    }

    // Kernel names of one iteration, in dispatch order.
    get Recipe()
    {
        return this.PositionBased ? PositionKernels : ExplicitKernels;
    }

    // Sound speed of the equation of state at rest density, the reference flow speed (free fall over the box height)
    // and the sub-step count that keeps the Courant number under the bound for a tick of tickSeconds:
    // (c₀ + v_ref) · Δt / Δx for the explicit method (acoustic), v_ref · Δt / Δx for the position-based one (advective).
    Describe(tickSeconds)
    {
        const t     = this.Tuning;
        const s     = this.Scene;
        const c0    = Math.sqrt(t.EosExponent * t.Stiffness / s.RestDensity);
        const vRef  = Math.sqrt(2.0 * t.Gravity * s.CellCount[2] * s.CellSize);
        const dtMax = t.Courant * s.CellSize / (this.PositionBased ? vRef : c0 + vRef);
        const steps = Math.max(1, Math.ceil(tickSeconds / dtMax));
        return { Method: t.Method, Iterations: this.Iterations, SoundSpeed: this.PositionBased ? Infinity : c0, ReferenceSpeed: vRef,
                 MaxSubStep: dtMax, SubSteps: steps, SubStep: tickSeconds / steps, Transfers: steps * this.Iterations };
    }

    // One 256-byte slice per iteration. Slice 0 carries gravity (added once per sub-step, on the lattice), the last slice
    // carries Integrate = 1; everything else is identical between slices.
    WriteConstants(timeStep)
    {
        const s = this.Scene;
        const t = this.Tuning;
        const massQuantum     = s.ParticleMass * 2 ** -20;   // [kg]      2¹¹ particle masses of range per site, 1e-6 resolution
        const momentumQuantum = s.ParticleMass * 2 ** -17;   // [kg·m/s]  2¹⁴ m/s × particle mass of range per site, 8e-6 resolution
        const iterations = this.Iterations;
        const block = new Float32Array(SliceBytes / 4 * iterations);
        const words = new Uint32Array(block.buffer);
        for (let i = 0; i < iterations; i++)
        {
            const f = block.subarray(i * SliceBytes / 4, (i + 1) * SliceBytes / 4);
            const u = words.subarray(i * SliceBytes / 4, (i + 1) * SliceBytes / 4);
            u[0]  = s.CellCount[0];  u[1] = s.CellCount[1];  u[2] = s.CellCount[2];  u[3] = s.ParticleCount;
            f[4]  = s.CellSize;
            f[5]  = 1.0 / s.CellSize;
            f[6]  = timeStep;
            f[7]  = s.ParticleMass;
            f[8]  = s.RestDensity;
            f[9]  = t.Stiffness;
            f[10] = t.EosExponent;
            f[11] = t.Viscosity;
            f[12] = 0.0;  f[13] = 0.0;  f[14] = i === 0 ? -t.Gravity : 0.0;
            f[15] = massQuantum;
            f[16] = momentumQuantum;
            f[17] = s.WallMargin;
            f[18] = 1.0 / massQuantum;
            f[19] = 1.0 / momentumQuantum;
            f[20] = t.MaxSpeed;
            f[21] = t.Cohesion;
            f[22] = t.VolumeRelaxation;
            f[23] = t.ShearRelaxation;
            f[24] = t.VolumeBlend;
            u[25] = i === iterations - 1 ? 1 : 0;
            u[26] = this.PositionBased ? 1 : 0;
            u[27] = i;
            f[28] = t.Tension;
        }
        this.Device.queue.writeBuffer(this.Constants, 0, block);
        this.TimeStep = timeStep;
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                    ADVANCE
    //--------------------------------------------------------------------------------------------------------------------
    // Records subSteps × Iterations × (5 dispatches). With metrics.PerKernel each dispatch gets its own pass and
    // timestamp pair, otherwise one pass per sub-step (fewer, coarser timestamps — Chrome quantises them to 100 µs).

    Advance(encoder, subSteps, subStepSeconds, metrics)
    {
        if (subStepSeconds !== this.TimeStep)
        {
            this.WriteConstants(subStepSeconds);
        }
        const perKernel  = metrics && metrics.PerKernel;
        const recipe     = this.Recipe;
        const iterations = this.Iterations;
        for (let step = 0; step < subSteps; step++)
        {
            let dispatch = perKernel ? null : encoder.beginComputePass({ label: "SubStep", timestampWrites: metrics?.Slot("Simulation") });
            for (let iteration = 0; iteration < iterations; iteration++)
            {
                const offsets = [iteration * SliceBytes];
                for (const name of recipe)
                {
                    if (perKernel)
                    {
                        dispatch = encoder.beginComputePass({ label: name, timestampWrites: metrics.Slot(name) });
                    }
                    dispatch.setPipeline(this.Kernels[name]);
                    dispatch.setBindGroup(0, this.Group, offsets);
                    dispatch.dispatchWorkgroups(SiteKernels.has(name) ? this.SiteGroups : this.ParticleGroups);
                    if (perKernel)
                    {
                        dispatch.end();
                    }
                }
            }
            if (!perKernel)
            {
                dispatch.end();
            }
            this.SubSteps++;
            this.Time += subStepSeconds;
        }
        this.Tick++;
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                     PROOFS
    //--------------------------------------------------------------------------------------------------------------------

    // Appends the proof reduction and the copies into staging. Returns false when the previous proof is still mapped.
    RecordProof(encoder, metrics)
    {
        if (this.StagingBusy)
        {
            return false;
        }
        const dispatch = encoder.beginComputePass({ label: "ReduceProof", timestampWrites: metrics?.Slot("Proof") });
        dispatch.setPipeline(this.Kernels.ReduceProof);
        dispatch.setBindGroup(0, this.Group, [0]);
        dispatch.dispatchWorkgroups(this.ProofGroups);
        dispatch.end();
        encoder.copyBufferToBuffer(this.ProofPartials, 0, this.Staging, this.ProofOffset, this.ProofGroups * 32);
        encoder.copyBufferToBuffer(this.MassPartials,  0, this.Staging, this.MassOffset,  this.SiteGroups * 4);
        encoder.copyBufferToBuffer(this.Tally,         0, this.Staging, this.TallyOffset, 16);
        this.StagingBusy   = true;
        this.ProofRecorded = true;
        this.ProofTick     = this.Tick;   // stamped now: the read may resolve several ticks later on a slow GPU
        this.ProofTime     = this.Time;
        return true;
    }

    // Call after the submit that carried RecordProof. Resolves to the proof record; clears the tally counters.
    async ReadProof()
    {
        if (!this.ProofRecorded)
        {
            return null;
        }
        this.ProofRecorded = false;
        await this.Staging.mapAsync(GPUMapMode.READ);
        const bytes   = this.Staging.getMappedRange();
        const proof   = new Float32Array(bytes, this.ProofOffset, this.ProofGroups * 8);
        const mass    = new Float32Array(bytes, this.MassOffset, this.SiteGroups);
        const tally   = new Uint32Array(bytes, this.TallyOffset, 4);

        let count = 0.0, energy = 0.0, height = 0.0, maxSpeed = 0.0;
        let volumeSum = 0.0, volumeMin = Infinity, volumeMax = -Infinity, volumeSquare = 0.0;
        for (let g = 0; g < this.ProofGroups; g++)
        {
            count        += proof[g * 8 + 0];
            energy       += proof[g * 8 + 1];
            height       += proof[g * 8 + 2];
            maxSpeed      = Math.max(maxSpeed, proof[g * 8 + 3]);
            volumeSum    += proof[g * 8 + 4];
            volumeMin     = Math.min(volumeMin, proof[g * 8 + 5]);
            volumeMax     = Math.max(volumeMax, proof[g * 8 + 6]);
            volumeSquare += proof[g * 8 + 7];
        }
        let latticeMass = 0.0;
        for (let g = 0; g < this.SiteGroups; g++)
        {
            latticeMass += mass[g];
        }
        const record = {
            Tick: this.ProofTick, Time: this.ProofTime,
            Inside: count, Expected: this.Scene.ParticleCount,
            LatticeMass: latticeMass, ExpectedMass: this.Scene.ParticleCount * this.Scene.ParticleMass,
            MeanSpeed: count > 0 ? Math.sqrt(energy / count) : NaN,    // [m/s] RMS speed
            MeanHeight: count > 0 ? height / count : NaN,               // [m]   solver space
            MaxSpeed: maxSpeed,
            MeanVolume: count > 0 ? volumeSum / count : NaN,                // [-]   mean J (1 = rest volume)
            MinVolume: volumeMin, MaxVolume: volumeMax,
            VolumeSpread: count > 0 ? Math.sqrt(volumeSquare / count) : NaN,  // [-]   RMS of J − 1
            Saturations: tally[0], SpeedClamps: tally[1],
        };
        this.Staging.unmap();
        this.StagingBusy = false;
        this.Device.queue.writeBuffer(this.Tally, 0, new Uint32Array(4));
        return record;
    }

    // Copies the particle records for a determinism trace; resolve with ReadTrace after the submit.
    RecordTrace(encoder)
    {
        const bytes = this.Scene.ParticleCount * ParticleStride;
        if (!this.TraceStaging)
        {
            this.TraceStaging = this.Device.createBuffer({ label: "TraceStaging", size: bytes, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
        }
        encoder.copyBufferToBuffer(this.Records, 0, this.TraceStaging, 0, bytes);
    }

    // FNV-1a over the position lanes of every record — identical on two runs of the same build on the same GPU.
    async ReadTrace()
    {
        await this.TraceStaging.mapAsync(GPUMapMode.READ);
        const words = new Uint32Array(this.TraceStaging.getMappedRange());
        let hash = 0x811C9DC5;
        for (let p = 0; p < this.Scene.ParticleCount; p++)
        {
            for (let lane = 0; lane < 3; lane++)
            {
                hash ^= words[p * (ParticleStride / 4) + lane];
                hash  = Math.imul(hash, 0x01000193) >>> 0;
            }
        }
        this.TraceStaging.unmap();
        return hash >>> 0;
    }

    Destroy()
    {
        for (const b of [this.Records, this.Lattice, this.LatticeVelocity, this.Tally, this.ProofPartials, this.MassPartials, this.Constants, this.Staging, this.TraceStaging])
        {
            b?.destroy();
        }
    }
}
