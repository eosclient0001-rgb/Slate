//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/Shaders/ParticleSolver.wgsl — MLS-MPM Water Kernels (fixed-point lattice scatter, WGSL)
//============================================================================================================================================
//
//    One sub-step = five compute dispatches in this order:
//        ClearLattice → ScatterMass (P2G-1) → ScatterStress (P2G-2) → AdvanceLattice → GatherParticles (G2P)
//    A sixth entry point, ReduceProof, is recorded on demand and writes per-workgroup partial sums that the host adds up.
//
//    Method: moving-least-squares material point method (Hu et al. 2018) with APIC transfers and a quadratic B-spline
//    stencil (3×3×3 sites), weakly compressible water through a Tait-style equation of state p = κ((ρ/ρ₀)^γ − 1), density
//    re-estimated from the lattice every sub-step (no deformation gradient). Lattice mass and momentum are accumulated
//    with atomicAdd on i32 fixed-point quanta because WGSL only has integer atomics; per-contribution saturation is
//    counted in Tally[0] and speed clamps in Tally[1]; the host clears both whenever it reads a proof.
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
    Cohesion              : f32,        // [-]        tensile limit: p ≥ −Cohesion · κ (0 = no tension; keep ≪ hydrostatic head / κ)
    Reserved0             : f32,
    Reserved1             : f32,
};

struct Particle
{
    Position : vec3<f32>,     // [m]
    Velocity : vec3<f32>,     // [m/s]
    Affine   : mat3x3<f32>,   // [1/s]  APIC velocity gradient C
};

@group(0) @binding(0) var<uniform>             Constants       : SolverConstants;
@group(0) @binding(1) var<storage, read_write> Particles       : array<Particle>;
@group(0) @binding(2) var<storage, read_write> Lattice         : array<atomic<i32>>;   // 4 quanta per site: mass, momentum xyz
@group(0) @binding(3) var<storage, read_write> LatticeVelocity : array<vec4<f32>>;     // xyz [m/s], w = site mass [kg]
@group(0) @binding(4) var<storage, read_write> Tally           : array<atomic<u32>>;   // [0] saturations, [1] speed clamps
@group(0) @binding(5) var<storage, read_write> ProofPartials   : array<vec4<f32>>;     // per workgroup: count, Σ|v|², Σz, max|v|
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
    let identity = mat3x3<f32>(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(0.0, 0.0, 1.0));
    let stress   = -pressure * identity + Constants.Viscosity * strain;                                       // [Pa]
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

            // Separating slip wall: a site inside the margin may not carry velocity into the wall.
            if (site.x < Constants.WallMargin && velocity.x < 0.0) { velocity.x = 0.0; }
            if (site.y < Constants.WallMargin && velocity.y < 0.0) { velocity.y = 0.0; }
            if (site.z < Constants.WallMargin && velocity.z < 0.0) { velocity.z = 0.0; }
            if (site.x > high.x && velocity.x > 0.0) { velocity.x = 0.0; }
            if (site.y > high.y && velocity.y > 0.0) { velocity.y = 0.0; }
            if (site.z > high.z && velocity.z > 0.0) { velocity.z = 0.0; }
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
// Per workgroup: (particles within half a cell of the wall planes with finite velocity, Σ|v|², Σz, max|v|). A particle
// that reached the hard clamp lies a full cell outside the plane, so it counts as escaped: the clamp doubles as the
// tunnelling detector and "inside" coincides with the visible container of DamBreakStructure.

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

@compute @workgroup_size(256)
fn ReduceProof(@builtin(global_invocation_id) id: vec3<u32>,
               @builtin(local_invocation_id)  local: vec3<u32>,
               @builtin(workgroup_id)         group: vec3<u32>)
{
    var count  = 0.0;
    var energy = 0.0;
    var height = 0.0;
    var speed  = 0.0;
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
        }
    }
    SharedCount[local.x]  = count;
    SharedEnergy[local.x] = energy;
    SharedHeight[local.x] = height;
    SharedSpeed[local.x]  = speed;
    workgroupBarrier();
    for (var stride = 128u; stride > 0u; stride = stride >> 1u)
    {
        if (local.x < stride)
        {
            SharedCount[local.x]  += SharedCount[local.x + stride];
            SharedEnergy[local.x] += SharedEnergy[local.x + stride];
            SharedHeight[local.x] += SharedHeight[local.x + stride];
            SharedSpeed[local.x]   = max(SharedSpeed[local.x], SharedSpeed[local.x + stride]);
        }
        workgroupBarrier();
    }
    if (local.x == 0u)
    {
        ProofPartials[group.x] = vec4<f32>(SharedCount[0], SharedEnergy[0], SharedHeight[0], SharedSpeed[0]);
    }
}
