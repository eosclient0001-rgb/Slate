//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/Shaders/ParticleSolver.wgsl — MPM Water Kernels (PB-MPM · explicit MLS-MPM, fixed-point P2G)
//============================================================================================================================================
//
//    Two methods share one kernel set and one particle record; Constants.Method selects the sub-step recipe:
//
//      0  explicit MLS-MPM (Hu et al. 2018) — one dispatch chain per sub-step:
//             ClearLattice → ScatterMass (P2G-1) → ScatterStress (P2G-2) → AdvanceLattice → GatherParticles (G2P)
//         Weakly compressible water through a Tait-style equation of state p = κ((ρ/ρ₀)^γ − 1), density re-estimated from
//         the lattice every sub-step (no deformation gradient). The sub-step is bounded by the acoustic Courant number.
//
//      1  position-based MPM (Lewin, EA SEED, SIGGRAPH 2024) — k iterations per sub-step, no stiffness, no sound speed:
//             [ ProjectVolume → ClearLattice → ScatterMass → AdvanceLattice → GatherParticles ] × k
//         Each iteration projects the particle's displacement gradient D = C·Δτ toward volume preservation
//         (1 + tr(D + αI))·J = 1, then the lattice transfer averages the proposals mass-weighted (a Jacobi solve on the
//         lattice). Gravity enters on iteration 0 only; the last iteration integrates J and advects. J (the volume
//         ratio det F) lives in Particle.Volume and is blended toward the lattice-measured ratio when compressed, which
//         is what stops it drifting (EA's "grid volume for liquid"). Bounded by the advection Courant number only.
//
//    Both use APIC transfers and a quadratic B-spline stencil (3×3×3 sites). Lattice mass and momentum are accumulated
//    with atomicAdd on i32 fixed-point quanta because WGSL only has integer atomics; per-contribution saturation is
//    counted in Tally[0] and speed clamps in Tally[1]; the host clears both whenever it reads a proof. ReduceProof is
//    recorded on demand and writes per-workgroup partial sums that the host adds up.
//
//    Constants arrive as one 256-byte slice per iteration (dynamic uniform offset), so the same bind group serves every
//    dispatch; only Gravity, Integrate and Iteration differ between slices.
//
//    Units: metres, seconds, kilograms; right-handed, +Z up (gravity is (0, 0, −9.81)). Lattice site (x, y, z) sits at
//    position (x, y, z) · Δx; the domain spans [0, CellCount · Δx] and the fluid lives inside the WallMargin slab.
//
//    Vocabulary: "lattice" = the background Eulerian point set, "site" = one lattice point, "stencil" = the 27 sites a
//    particle touches, "quantum" = the fixed-point unit of a lattice accumulator.

struct SolverConstants
{
    CellCount             : vec3<u32>,  // [-]        lattice sites per axis
    ParticleCount         : u32,        // [-]
    CellSize              : f32,        // [m]        Δx
    InverseCellSize       : f32,        // [1/m]
    TimeStep              : f32,        // [s]        Δτ of one sub-step
    ParticleMass          : f32,        // [kg]
    RestDensity           : f32,        // [kg/m³]    ρ₀
    Stiffness             : f32,        // [Pa]       κ
    EosExponent           : f32,        // [-]        γ
    Viscosity             : f32,        // [Pa·s]     μ (dynamic)
    Gravity               : vec3<f32>,  // [m/s²]
    MassQuantum           : f32,        // [kg]       fixed-point unit of lattice mass
    MomentumQuantum       : f32,        // [kg·m/s]   fixed-point unit of lattice momentum
    WallMargin            : f32,        // [cells]    sites on every face that act as a slip wall
    InverseMassQuantum    : f32,        // [1/kg]
    InverseMomentumQuantum: f32,        // [s/(kg·m)]
    MaxSpeed              : f32,        // [m/s]      safety clamp applied in G2P (counted in Tally[1])
    Cohesion              : f32,        // [-]        explicit: tensile limit p ≥ −Cohesion · κ (0 = no tension; keep ≪ hydrostatic head / κ)
    VolumeRelaxation      : f32,        // [-]        position-based: ω of the volume projection (1 = exact Jacobi step, 2 = over-relaxed)
    ShearRelaxation       : f32,        // [-]        position-based: fraction of the strain part removed per iteration (viscosity)
    VolumeBlend           : f32,        // [-]        position-based: J ← mix(J, J_lattice, VolumeBlend) when compressed
    Integrate             : u32,        // [-]        1 = this dispatch advects, updates J and enforces walls (last iteration)
    Method                : u32,        // [-]        0 = explicit MLS-MPM · 1 = position-based MPM
    Iteration             : u32,        // [-]        index within the sub-step (informational)
    Tension               : f32,        // [-]        position-based: largest contraction strain one iteration may propose (α ≥ −Tension)
};

struct Particle
{
    Position : vec3<f32>,     // [m]
    Volume   : f32,           // [-]    J = det F, volume ratio (position-based method; 1 at rest)
    Velocity : vec3<f32>,     // [m/s]
    Reserve  : f32,           // [-]    unused lane (keeps the 80-byte stride explicit)
    Affine   : mat3x3<f32>,   // [1/s]  APIC velocity gradient C
};

const Identity : mat3x3<f32> = mat3x3<f32>(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 0.0, 1.0));

fn Trace(m: mat3x3<f32>) -> f32
{
    return m[0][0] + m[1][1] + m[2][2];
}

@group(0) @binding(0) var<uniform>             Constants       : SolverConstants;
@group(0) @binding(1) var<storage, read_write> Particles       : array<Particle>;
@group(0) @binding(2) var<storage, read_write> Lattice         : array<atomic<i32>>;   // 4 quanta per site: mass, momentum xyz
@group(0) @binding(3) var<storage, read_write> LatticeVelocity : array<vec4<f32>>;     // xyz [m/s], w = site mass [kg]
@group(0) @binding(4) var<storage, read_write> Tally           : array<atomic<u32>>;   // [0] saturations, [1] speed clamps
@group(0) @binding(5) var<storage, read_write> ProofPartials   : array<vec4<f32>>;     // 2 per workgroup: see ReduceProof
@group(0) @binding(6) var<storage, read_write> MassPartials    : array<f32>;           // per workgroup: Σ site mass [kg]

//------------------------------------------------------------------------------------------------------------------------
//                                                  STENCIL HELPERS
//------------------------------------------------------------------------------------------------------------------------

struct Stencil
{
    Anchor  : vec3<i32>,            // [cells] lowest site of the 3×3×3 footprint
    Offset  : vec3<f32>,            // [cells] particle position relative to the anchor, ∈ [0.5, 1.5)
    Weights : array<vec3<f32>, 3>,  // [-]     quadratic B-spline weights per axis
};

fn BuildStencil(position: vec3<f32>) -> Stencil
{
    var stencil : Stencil;
    let scaled = position * Constants.InverseCellSize;
    stencil.Anchor = vec3<i32>(floor(scaled - vec3<f32>(0.5)));
    stencil.Offset = scaled - vec3<f32>(stencil.Anchor);
    let f = stencil.Offset;
    stencil.Weights[0] = 0.5 * (1.5 - f) * (1.5 - f);
    stencil.Weights[1] = 0.75 - (f - 1.0) * (f - 1.0);
    stencil.Weights[2] = 0.5 * (f - 0.5) * (f - 0.5);
    return stencil;
}

fn SiteIndex(site: vec3<i32>) -> u32
{
    let s = vec3<u32>(site);
    return (s.z * Constants.CellCount.y + s.y) * Constants.CellCount.x + s.x;
}

fn Quantise(amount: f32, inverseQuantum: f32) -> i32
{
    let quanta  = amount * inverseQuantum;
    let clamped = clamp(quanta, -536870912.0, 536870912.0);   // ±2²⁹ leaves headroom for 4 saturated adds before wrap
    if (clamped != quanta)
    {
        atomicAdd(&Tally[0], 1u);
    }
    return i32(round(clamped));
}

//------------------------------------------------------------------------------------------------------------------------
//                                                    CLEAR LATTICE
//------------------------------------------------------------------------------------------------------------------------

@compute @workgroup_size(256)
fn ClearLattice(@builtin(global_invocation_id) id: vec3<u32>)
{
    let siteCount = Constants.CellCount.x * Constants.CellCount.y * Constants.CellCount.z;
    if (id.x >= siteCount)
    {
        return;
    }
    atomicStore(&Lattice[id.x * 4u + 0u], 0);
    atomicStore(&Lattice[id.x * 4u + 1u], 0);
    atomicStore(&Lattice[id.x * 4u + 2u], 0);
    atomicStore(&Lattice[id.x * 4u + 3u], 0);
}

//------------------------------------------------------------------------------------------------------------------------
//                                              P2G-1 — SCATTER MASS + MOMENTUM
//------------------------------------------------------------------------------------------------------------------------

@compute @workgroup_size(64)
fn ScatterMass(@builtin(global_invocation_id) id: vec3<u32>)
{
    if (id.x >= Constants.ParticleCount)
    {
        return;
    }
    let particle = Particles[id.x];
    let stencil  = BuildStencil(particle.Position);

    for (var i = 0u; i < 3u; i++)
    {
        for (var j = 0u; j < 3u; j++)
        {
            for (var k = 0u; k < 3u; k++)
            {
                let weight   = stencil.Weights[i].x * stencil.Weights[j].y * stencil.Weights[k].z;
                let site     = stencil.Anchor + vec3<i32>(i32(i), i32(j), i32(k));
                let delta    = (vec3<f32>(f32(i), f32(j), f32(k)) - stencil.Offset) * Constants.CellSize;   // [m] site − particle
                let mass     = weight * Constants.ParticleMass;                                              // [kg]
                let momentum = mass * (particle.Velocity + particle.Affine * delta);                         // [kg·m/s]
                let slot     = SiteIndex(site) * 4u;
                atomicAdd(&Lattice[slot + 0u], Quantise(mass,       Constants.InverseMassQuantum));
                atomicAdd(&Lattice[slot + 1u], Quantise(momentum.x, Constants.InverseMomentumQuantum));
                atomicAdd(&Lattice[slot + 2u], Quantise(momentum.y, Constants.InverseMomentumQuantum));
                atomicAdd(&Lattice[slot + 3u], Quantise(momentum.z, Constants.InverseMomentumQuantum));
            }
        }
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                          P2G-2 — DENSITY, PRESSURE, STRESS SCATTER
//------------------------------------------------------------------------------------------------------------------------
// Density at the particle is the lattice mass interpolated back through the same stencil, divided by the cell volume.
// Sites on the far side of a wall plane hold almost no mass, so a particle resting on the floor would read ≈ 0.6 ρ₀ and
// the equation of state would pull it into the wall (boundary deficiency). For the density estimate only, the wall is a
// mirror: a site beyond the plane borrows the mass of its reflection and the plane site counts twice — exact for fluid
// at rest against the wall, harmless for fluid that is not touching it.
// The momentum increment is −Δτ · V_p · σ · D⁻¹ · (x_i − x_p) · w_ip with D⁻¹ = 4/Δx² for quadratic B-splines.

fn MirroredSiteMass(site: vec3<i32>) -> f32
{
    let margin = i32(Constants.WallMargin);
    let high   = vec3<i32>(Constants.CellCount) - 1 - margin;
    var mirror = site;
    var factor = 1.0;
    for (var axis = 0; axis < 3; axis++)
    {
        if (site[axis] < margin)          { mirror[axis] = 2 * margin - site[axis]; }
        else if (site[axis] == margin)    { factor *= 2.0; }
        else if (site[axis] > high[axis]) { mirror[axis] = 2 * high[axis] - site[axis]; }
        else if (site[axis] == high[axis]){ factor *= 2.0; }
    }
    return f32(atomicLoad(&Lattice[SiteIndex(mirror) * 4u])) * Constants.MassQuantum * factor;
}

@compute @workgroup_size(64)
fn ScatterStress(@builtin(global_invocation_id) id: vec3<u32>)
{
    if (id.x >= Constants.ParticleCount)
    {
        return;
    }
    let particle   = Particles[id.x];
    let stencil    = BuildStencil(particle.Position);
    let cellVolume = Constants.CellSize * Constants.CellSize * Constants.CellSize;   // [m³]

    var density = 0.0;                                                               // [kg/m³]
    for (var i = 0u; i < 3u; i++)
    {
        for (var j = 0u; j < 3u; j++)
        {
            for (var k = 0u; k < 3u; k++)
            {
                let weight = stencil.Weights[i].x * stencil.Weights[j].y * stencil.Weights[k].z;
                let site   = stencil.Anchor + vec3<i32>(i32(i), i32(j), i32(k));
                density   += weight * MirroredSiteMass(site) / cellVolume;
            }
        }
    }
    density = max(density, 1.0e-6);

    let volume   = Constants.ParticleMass / density;                                                          // [m³]
    let ratio    = density / Constants.RestDensity;                                                           // [-]
    let pressure = max(-Constants.Cohesion * Constants.Stiffness,
                       Constants.Stiffness * (pow(ratio, Constants.EosExponent) - 1.0));                             // [Pa]
    let strain   = particle.Affine + transpose(particle.Affine);                                              // [1/s]
    let stress   = -pressure * Identity + Constants.Viscosity * strain;                                       // [Pa]
    let scale    = -volume * 4.0 * Constants.InverseCellSize * Constants.InverseCellSize * Constants.TimeStep;  // [m·s]  → term·Δ·w is kg·m/s
    let term     = stress * scale;

    for (var i = 0u; i < 3u; i++)
    {
        for (var j = 0u; j < 3u; j++)
        {
            for (var k = 0u; k < 3u; k++)
            {
                let weight   = stencil.Weights[i].x * stencil.Weights[j].y * stencil.Weights[k].z;
                let site     = stencil.Anchor + vec3<i32>(i32(i), i32(j), i32(k));
                let delta    = (vec3<f32>(f32(i), f32(j), f32(k)) - stencil.Offset) * Constants.CellSize;   // [m]
                let momentum = (term * delta) * weight;                                                      // [kg·m/s]
                let slot     = SiteIndex(site) * 4u;
                atomicAdd(&Lattice[slot + 1u], Quantise(momentum.x, Constants.InverseMomentumQuantum));
                atomicAdd(&Lattice[slot + 2u], Quantise(momentum.y, Constants.InverseMomentumQuantum));
                atomicAdd(&Lattice[slot + 3u], Quantise(momentum.z, Constants.InverseMomentumQuantum));
            }
        }
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                  POSITION-BASED PROJECTION (EA SEED PB-MPM, LIQUID BRANCH)
//------------------------------------------------------------------------------------------------------------------------
// Works on D = C·Δτ, the dimensionless displacement gradient of this sub-step (EA's deformationDisplacement).
//     shear    D ← D − ShearRelaxation · sym(D)                     removes strain, keeps rotation → viscosity
//     volume   α = (1/J − 1 − tr D) / 3 ;  D ← D + ω·α·I            so that (1 + tr(D + αI))·J → 1 (3 = trace of I in 3-D)
// α < 0 contracts an over-expanded particle — that pull is the cohesion that holds sheets and drops together. It is
// floored at −Tension only as a safety net: a particle that has been stretched far past J = 1/(1 − 3·Tension) must not
// slam its neighbours with a one-iteration collapse.

@compute @workgroup_size(64)
fn ProjectVolume(@builtin(global_invocation_id) id: vec3<u32>)
{
    if (id.x >= Constants.ParticleCount)
    {
        return;
    }
    var particle = Particles[id.x];
    let dt       = Constants.TimeStep;
    var D        = particle.Affine * dt;                                                        // [-]
    D            = D - Constants.ShearRelaxation * 0.5 * (D + transpose(D));
    let alpha    = max((1.0 / max(particle.Volume, 0.1) - 1.0 - Trace(D)) / 3.0, -Constants.Tension);
    D            = D + Constants.VolumeRelaxation * alpha * Identity;
    particle.Affine = D * (1.0 / dt);
    Particles[id.x] = particle;
}

//------------------------------------------------------------------------------------------------------------------------
//                                        LATTICE ADVANCE — GRAVITY, SLIP WALLS, MASS SUM
//------------------------------------------------------------------------------------------------------------------------

var<workgroup> SharedMass : array<f32, 256>;

@compute @workgroup_size(256)
fn AdvanceLattice(@builtin(global_invocation_id) id: vec3<u32>,
                  @builtin(local_invocation_id)  local: vec3<u32>,
                  @builtin(workgroup_id)         group: vec3<u32>)
{
    let siteCount = Constants.CellCount.x * Constants.CellCount.y * Constants.CellCount.z;
    var mass      = 0.0;
    var velocity  = vec3<f32>(0.0);

    if (id.x < siteCount)
    {
        mass = f32(atomicLoad(&Lattice[id.x * 4u])) * Constants.MassQuantum;
        if (mass > 0.0)
        {
            let momentum = vec3<f32>(f32(atomicLoad(&Lattice[id.x * 4u + 1u])),
                                     f32(atomicLoad(&Lattice[id.x * 4u + 2u])),
                                     f32(atomicLoad(&Lattice[id.x * 4u + 3u]))) * Constants.MomentumQuantum;
            velocity = momentum / mass + Constants.Gravity * Constants.TimeStep;

            let x    = id.x % Constants.CellCount.x;
            let y    = (id.x / Constants.CellCount.x) % Constants.CellCount.y;
            let z    = id.x / (Constants.CellCount.x * Constants.CellCount.y);
            let site = vec3<f32>(f32(x), f32(y), f32(z));
            let high = vec3<f32>(Constants.CellCount) - 1.0 - Constants.WallMargin;

            // Separating slip wall: a site on or beyond a wall plane may not carry velocity into the wall. The plane site
            // itself must be included — a particle resting on the plane draws 87.5 % of its velocity from the plane site
            // and the one behind it; leaving the plane site free makes the wall soft by half a cell and lets impact
            // pressure drive particles through it (seen as containment misses and wall-bounce jitter).
            if (site.x <= Constants.WallMargin && velocity.x < 0.0) { velocity.x = 0.0; }
            if (site.y <= Constants.WallMargin && velocity.y < 0.0) { velocity.y = 0.0; }
            if (site.z <= Constants.WallMargin && velocity.z < 0.0) { velocity.z = 0.0; }
            if (site.x >= high.x && velocity.x > 0.0) { velocity.x = 0.0; }
            if (site.y >= high.y && velocity.y > 0.0) { velocity.y = 0.0; }
            if (site.z >= high.z && velocity.z > 0.0) { velocity.z = 0.0; }
        }
        LatticeVelocity[id.x] = vec4<f32>(velocity, mass);
    }

    SharedMass[local.x] = mass;
    workgroupBarrier();
    for (var stride = 128u; stride > 0u; stride = stride >> 1u)
    {
        if (local.x < stride)
        {
            SharedMass[local.x] += SharedMass[local.x + stride];
        }
        workgroupBarrier();
    }
    if (local.x == 0u)
    {
        MassPartials[group.x] = SharedMass[0];
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                          G2P — GATHER VELOCITY, APIC MATRIX, ADVECT
//------------------------------------------------------------------------------------------------------------------------

@compute @workgroup_size(64)
fn GatherParticles(@builtin(global_invocation_id) id: vec3<u32>)
{
    if (id.x >= Constants.ParticleCount)
    {
        return;
    }
    var particle = Particles[id.x];
    let stencil  = BuildStencil(particle.Position);

    var velocity = vec3<f32>(0.0);
    var affine   = mat3x3<f32>(vec3<f32>(0.0), vec3<f32>(0.0), vec3<f32>(0.0));   // [m²/s] before the D⁻¹ scale
    for (var i = 0u; i < 3u; i++)
    {
        for (var j = 0u; j < 3u; j++)
        {
            for (var k = 0u; k < 3u; k++)
            {
                let weight = stencil.Weights[i].x * stencil.Weights[j].y * stencil.Weights[k].z;
                let site   = stencil.Anchor + vec3<i32>(i32(i), i32(j), i32(k));
                let delta  = (vec3<f32>(f32(i), f32(j), f32(k)) - stencil.Offset) * Constants.CellSize;   // [m]
                let sample = LatticeVelocity[SiteIndex(site)].xyz;                                           // [m/s]
                velocity  += weight * sample;
                affine    += mat3x3<f32>(sample * delta.x, sample * delta.y, sample * delta.z) * weight;
            }
        }
    }

    // Safety clamp: never lets one bad sub-step turn into NaNs across the whole lattice. Counted so the proof sees it.
    let speed = length(velocity);
    if (speed > Constants.MaxSpeed)
    {
        velocity = velocity * (Constants.MaxSpeed / speed);
        atomicAdd(&Tally[1], 1u);
    }

    particle.Affine   = affine * (4.0 * Constants.InverseCellSize * Constants.InverseCellSize);
    particle.Velocity = velocity;

    if (Constants.Integrate == 0u)
    {
        Particles[id.x] = particle;   // intermediate position-based iteration: proposals only, no motion yet
        return;
    }

    if (Constants.Method == 1u)
    {
        // Volume ratio measured on the lattice (mirrored at the walls): J_lattice = ρ₀ / ρ_lattice. Pull J toward it only
        // when compressed — in tension the lattice and the integrated volume disagree by design (EA's rule) — then
        // integrate J with the divergence of this sub-step: det(I + D) ≈ 1 + tr D.
        let cellVolume = Constants.CellSize * Constants.CellSize * Constants.CellSize;
        var density = 0.0;
        for (var i = 0u; i < 3u; i++)
        {
            for (var j = 0u; j < 3u; j++)
            {
                for (var k = 0u; k < 3u; k++)
                {
                    let weight = stencil.Weights[i].x * stencil.Weights[j].y * stencil.Weights[k].z;
                    let site   = stencil.Anchor + vec3<i32>(i32(i), i32(j), i32(k));
                    density   += weight * MirroredSiteMass(site) / cellVolume;
                }
            }
        }
        let latticeVolume = Constants.RestDensity / max(density, 1.0e-6);
        if (latticeVolume < 1.0)
        {
            particle.Volume = mix(particle.Volume, latticeVolume, Constants.VolumeBlend);
        }
        particle.Volume = clamp(particle.Volume * (1.0 + Trace(particle.Affine) * Constants.TimeStep), 0.1, 10.0);
    }

    particle.Position = particle.Position + velocity * Constants.TimeStep;

    // Look three sub-steps ahead; a particle about to cross a wall plane has its normal velocity reduced so it arrives
    // exactly at the plane instead. Cheap insurance against the slip wall letting fast particles tunnel into the margin.
    let low   = vec3<f32>(Constants.WallMargin * Constants.CellSize);
    let high  = (vec3<f32>(Constants.CellCount) - 1.0 - Constants.WallMargin) * Constants.CellSize;
    let ahead = particle.Position + particle.Velocity * (3.0 * Constants.TimeStep);
    let push  = (max(low - ahead, vec3<f32>(0.0)) - max(ahead - high, vec3<f32>(0.0))) / (3.0 * Constants.TimeStep);
    particle.Velocity = particle.Velocity + push;

    // Hard clamp keeps the 3×3×3 stencil inside the lattice: anchor ∈ [0, CellCount − 3].
    let clampLow  = vec3<f32>(1.001 * Constants.CellSize);
    let clampHigh = (vec3<f32>(Constants.CellCount) - 2.001) * Constants.CellSize;
    particle.Position = clamp(particle.Position, clampLow, clampHigh);

    Particles[id.x] = particle;
}

//------------------------------------------------------------------------------------------------------------------------
//                                              PROOF REDUCTION (ON DEMAND)
//------------------------------------------------------------------------------------------------------------------------
// Two vec4 per workgroup: (particles within half a cell of the wall planes with finite velocity, Σ|v|², Σz, max|v|) and
// (ΣJ, min J, max J, Σ(J − 1)²) over the same particles — the volume statistics judge the position-based method. A
// particle that reached the hard clamp lies a full cell outside the plane, so it counts as escaped: the clamp doubles as
// the tunnelling detector and "inside" coincides with the visible container of DamBreakStructure.

// Exponent bits all set = Inf or NaN. Done on the bit pattern because WGSL float comparisons with NaN are unspecified.
fn Finite(v: vec3<f32>) -> bool
{
    let bits = bitcast<vec3<u32>>(v) & vec3<u32>(0x7F800000u);
    return all(bits != vec3<u32>(0x7F800000u));
}

var<workgroup> SharedCount  : array<f32, 256>;
var<workgroup> SharedEnergy : array<f32, 256>;
var<workgroup> SharedHeight : array<f32, 256>;
var<workgroup> SharedSpeed  : array<f32, 256>;
var<workgroup> SharedVolume : array<vec4<f32>, 256>;   // ΣJ, min J, max J, Σ(J − 1)²

@compute @workgroup_size(256)
fn ReduceProof(@builtin(global_invocation_id) id: vec3<u32>,
               @builtin(local_invocation_id)  local: vec3<u32>,
               @builtin(workgroup_id)         group: vec3<u32>)
{
    var count  = 0.0;
    var energy = 0.0;
    var height = 0.0;
    var speed  = 0.0;
    var volume = vec4<f32>(0.0, 1.0e9, -1.0e9, 0.0);
    if (id.x < Constants.ParticleCount)
    {
        let particle = Particles[id.x];
        let low      = vec3<f32>((Constants.WallMargin - 0.5) * Constants.CellSize);
        let high     = (vec3<f32>(Constants.CellCount) - 0.5 - Constants.WallMargin) * Constants.CellSize;
        let inside   = all(particle.Position > low) && all(particle.Position < high);
        let finite   = Finite(particle.Position) && Finite(particle.Velocity);
        if (inside && finite)
        {
            count  = 1.0;
            energy = dot(particle.Velocity, particle.Velocity);
            height = particle.Position.z;
            speed  = length(particle.Velocity);
            volume = vec4<f32>(particle.Volume, particle.Volume, particle.Volume, (particle.Volume - 1.0) * (particle.Volume - 1.0));
        }
    }
    SharedCount[local.x]  = count;
    SharedEnergy[local.x] = energy;
    SharedHeight[local.x] = height;
    SharedSpeed[local.x]  = speed;
    SharedVolume[local.x] = volume;
    workgroupBarrier();
    for (var stride = 128u; stride > 0u; stride = stride >> 1u)
    {
        if (local.x < stride)
        {
            SharedCount[local.x]  += SharedCount[local.x + stride];
            SharedEnergy[local.x] += SharedEnergy[local.x + stride];
            SharedHeight[local.x] += SharedHeight[local.x + stride];
            SharedSpeed[local.x]   = max(SharedSpeed[local.x], SharedSpeed[local.x + stride]);
            let other = SharedVolume[local.x + stride];
            SharedVolume[local.x] = vec4<f32>(SharedVolume[local.x].x + other.x, min(SharedVolume[local.x].y, other.y),
                                              max(SharedVolume[local.x].z, other.z), SharedVolume[local.x].w + other.w);
        }
        workgroupBarrier();
    }
    if (local.x == 0u)
    {
        ProofPartials[group.x * 2u]      = vec4<f32>(SharedCount[0], SharedEnergy[0], SharedHeight[0], SharedSpeed[0]);
        ProofPartials[group.x * 2u + 1u] = SharedVolume[0];
    }
}
