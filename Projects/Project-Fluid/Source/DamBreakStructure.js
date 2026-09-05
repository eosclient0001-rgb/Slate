//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/DamBreakStructure.js — Dam-Break Initial Condition (lattice extents + particle records)
//============================================================================================================================================
//
//    Describes the classic dam-break test: a rectangular column of water released against one wall of a closed box of
//    fixed physical size (2 m × 1 m × 1.25 m). The lattice, the wall margin and the particle records are produced here so
//    that the solver, the renderer and the proofs share one definition of "the box". Resolution is the number of lattice
//    cells along x; everything else follows from it (Δx = 2 m / Resolution, eight particles per cell at Δx/2 spacing, so
//    particle count grows with Resolution³ — 32 → ~7 k, 64 → ~74 k, 96 → ~280 k, 128 → ~700 k).
//
//    Records match the WGSL Particle struct: Position vec3 + Volume (16 B), Velocity vec3 + reserve (16 B), Affine mat3x3
//    (48 B) → 80 bytes.
//    A deterministic jitter of ±5 % of the spacing breaks the lattice symmetry the same way on every machine.
//
//    Units: metres, kilograms; right-handed, +Z up. Node (i, j, k) sits at (i, j, k) · Δx; the fluid may occupy nodes
//    [WallMargin, CellCount − 1 − WallMargin] on each axis; the visible container walls sit half a cell outside that.

export const ParticleStride = 80;     // [B]   bytes per particle record
export const ParticleFloats = 20;     // [-]   f32 lanes per record
export const DomainSize     = [2.0, 1.0, 1.25];   // [m]  physical box including the wall margin

// Mulberry32 — tiny deterministic generator so the jitter is reproducible across browsers.
function SeededSequence(seed)
{
    let s = seed >>> 0;
    return () =>
    {
        s = (s + 0x6D2B79F5) >>> 0;
        let t = s;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

export function DescribeDamBreak(options = {})
{
    const Resolution  = Math.max(16, Math.floor(options.Resolution ?? 64));   // [cells] along x
    const CellSize    = DomainSize[0] / Resolution;                            // [m]     Δx
    const CellCount   = DomainSize.map(extent => Math.round(extent / CellSize));
    const WallMargin  = options.WallMargin  ?? 2;                              // [cells]
    const RestDensity = options.RestDensity ?? 1000.0;                         // [kg/m³]
    const DamLength   = options.DamLengthFraction ?? 0.25;                     // [-] of the free length
    const DamHeight   = options.DamHeightFraction ?? 0.625;                    // [-] of the free height

    const Span = CellCount.map(n => n - 1 - 2 * WallMargin);                   // [cells] free span per axis
    if (Span.some(s => s < 4))
    {
        throw new Error(`DamBreakStructure: lattice ${CellCount.join("×")} is too small for a wall margin of ${WallMargin}`);
    }

    const ColumnX = Math.max(1, Math.round(Span[0] * DamLength));
    const ColumnY = Span[1];
    const ColumnZ = Math.max(2, Math.round(Span[2] * DamHeight));
    const ParticleCount = 8 * ColumnX * ColumnY * ColumnZ;

    const Records = new Float32Array(ParticleCount * ParticleFloats);
    const Next    = SeededSequence(options.Seed ?? 0x5EED);
    const Spacing = CellSize * 0.5;
    const Jitter  = Spacing * 0.05;
    let cursor = 0;
    for (let k = 0; k < ColumnZ * 2; k++)
    {
        for (let j = 0; j < ColumnY * 2; j++)
        {
            for (let i = 0; i < ColumnX * 2; i++)
            {
                const lane = cursor * ParticleFloats;
                Records[lane + 0] = (WallMargin + 0.25) * CellSize + i * Spacing + (Next() - 0.5) * 2.0 * Jitter;
                Records[lane + 1] = (WallMargin + 0.25) * CellSize + j * Spacing + (Next() - 0.5) * 2.0 * Jitter;
                Records[lane + 2] = (WallMargin + 0.25) * CellSize + k * Spacing + (Next() - 0.5) * 2.0 * Jitter;
                Records[lane + 3] = 1.0;   // Volume J = det F: rest volume
                // Velocity (4..6) and Affine (8..19) start at zero; lane 7 is the reserve lane.
                cursor++;
            }
        }
    }

    const ParticleMass  = RestDensity * CellSize * CellSize * CellSize / 8.0;                    // [kg]
    const FluidVolume   = ParticleCount * CellSize * CellSize * CellSize / 8.0;                   // [m³] at rest density
    const FloorHeight   = WallMargin * CellSize;                                                  // [m]  wall plane the particles rest on
    const SettledHeight = FluidVolume / (Span[0] * Span[1] * CellSize * CellSize);                // [m]  column height at rest, above FloorHeight
    const BoxOrigin     = CellCount.map(() => (WallMargin - 0.5) * CellSize);                     // [m]  visible inner corner (half a cell outside the plane)
    const BoxExtent     = CellCount.map(n => (n - 2 * WallMargin) * CellSize);                    // [m]  visible inner size

    return {
        Resolution, CellSize, CellCount, WallMargin, RestDensity, ParticleCount, ParticleMass, Records,
        BoxOrigin, BoxExtent, FloorHeight, SettledHeight, FluidVolume,
        Column: { Cells: [ColumnX, ColumnY, ColumnZ], Length: ColumnX * CellSize, Height: ColumnZ * CellSize },
        NodeCount: CellCount[0] * CellCount[1] * CellCount[2],
    };
}

// Particle count for a resolution without building the records (for the UI).
export function PredictParticleCount(Resolution, options = {})
{
    const CellSize   = DomainSize[0] / Math.max(16, Math.floor(Resolution));
    const CellCount  = DomainSize.map(extent => Math.round(extent / CellSize));
    const WallMargin = options.WallMargin ?? 2;
    const Span       = CellCount.map(n => n - 1 - 2 * WallMargin);
    const ColumnX    = Math.max(1, Math.round(Span[0] * (options.DamLengthFraction ?? 0.25)));
    const ColumnZ    = Math.max(2, Math.round(Span[2] * (options.DamHeightFraction ?? 0.625)));
    return 8 * ColumnX * Span[1] * ColumnZ;
}
