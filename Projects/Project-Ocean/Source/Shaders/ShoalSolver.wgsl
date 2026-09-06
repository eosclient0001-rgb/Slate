//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/Shaders/ShoalSolver.wgsl — Shallow-Water Shoal Patch (staggered FV, wetting/drying, bores)
//============================================================================================================================================
//
//    Tier 2 of References/OceanPhaseO0-SurveyAndPlan.md §4: the exactly-conserving half of Jeschke & Wojtan 2023 — the
//    non-linear shallow-water equations on a staggered (Arakawa-C) grid after Stelling & Duinmeijer 2003:
//        ∂h/∂t + ∇·(h u) = 0                                              (Water: cell centres, h = water depth ≥ 0)
//        ∂u/∂t + (u·∇)u = −g ∇η − g n² |u| u / h^{4/3}                     (Flux: faces, η = h + bed, Manning friction)
//    The face velocities are advected with a first-order upwind form that conserves momentum at hydraulic jumps, so
//    bores (the tier-4 breakers in their shallow form) travel at the right speed and lose the right energy. Wetting and
//    drying are handled by the upwind face depth: a face takes the depth of its upwind cell, so a dry cell can only be
//    filled, never drained below zero. Explicit, so Δτ ≤ 0.6 Δx / √(g d_max): the host sub-steps.
//
//    Kernels (one sub-step = ShoalVelocity → ShoalDepth, the forward–backward staggered scheme; ShoalShift when the window moves):
//        ShoalInit      still water over the bed (h = max(0, −bed)); the run-up scene adds a solitary wave
//        ShoalVelocity  u ← u − Δτ (advection + g ∇ηⁿ + friction) with the flux-form advection of Stelling & Duinmeijer
//                       2003 (eq. 22: fluxes averaged to the cell centres, centred face depth; upwind velocities where the
//                       flow converges — momentum-conserving at bores — centred elsewhere), Manning friction (implicit),
//                       speed cap; handover: where the spectral bands own the wave (deep) the patch is relaxed toward
//                       them (height + depth-averaged velocity), where it owns the wave (shallow) it runs free; the rim
//                       relaxes fully — how tier-0 waves enter the patch and how patch waves leave it without reflecting
//        ShoalDepth     h ← h − Δτ ∇·(h_face uⁿ⁺¹) with h_face the upwind depth (mass exactly conserved, nothing drains dry);
//                       bore field from the rise rate ∂η/∂t ≥ 0.25…0.65 √(g h) (Kennedy et al. 2000), decaying over 0.35 s
//        ShoalMeasure   proof rows: Σ h (volume), max η over wet cells, Σ [h > dry], non-finite, max wet bed, Σ h |u|², Σ bore, max |u|
//
//    Storage: State texture rgba32float (h, u_east, v_north, bore) — u lives on the east face of the cell, v on the north.
//    Units: metres, seconds; +Z up. Two textures ping-pong (read Previous, write Next). WG = 16 × 16.

const Tile = 16u;
const WG   = 256u;
const Gravity = 9.81;

// struct Sea and struct Shoal come from SeaStructure.wgsl (prepended by ShoalSolver.js).

@group(0) @binding(0) var<uniform> U: Sea;
@group(0) @binding(1) var<uniform> P: Shoal;
@group(0) @binding(2) var Previous: texture_2d<f32>;                              // (h, u, v, bore) in
@group(0) @binding(3) var Next: texture_storage_2d<rgba32float, write>;           // (h, u, v, bore) out
@group(0) @binding(4) var Displacement: texture_2d_array<f32>;                    // spectral bands (forcing in the sponge)
@group(0) @binding(5) var Motion:       texture_2d_array<f32>;
@group(0) @binding(6) var Wrap: sampler;
@group(0) @binding(7) var<storage, read_write> Partials: array<vec4f>;            // ShoalMeasure rows

fn Cell(i: vec2i) -> vec4f      // clamped read: the rim repeats its neighbour (wall for the closed basin)
{
    let n = i32(P.Patch.w);
    return textureLoad(Previous, vec2u(clamp(i, vec2i(0), vec2i(n - 1))), 0);
}

fn Centre(i: vec2i) -> vec2f    // world position of a cell centre [m]
{
    return P.Patch.xy + (vec2f(i) + 0.5) * P.Patch.z;
}

fn BedAt(i: vec2i) -> f32
{
    let n = i32(P.Patch.w);
    return Bed(P, Centre(clamp(i, vec2i(0), vec2i(n - 1))));
}

// Spectral sea at a world position, as the patch must carry it: every band it can resolve, faded by depth like the
// renderer fades them, as free-surface height and depth-averaged velocity — the nudging target where the bands own the
// wave, the forcing at the rim.
struct Forcing
{
    Height:   f32,
    Velocity: vec2f,
};

fn SpectralSea(p: vec2f, still: f32) -> Forcing
{
    var f: Forcing;
    f.Height = 0.0;
    f.Velocity = vec2f(0.0);
    for (var b = 0u; b < U.Grid.z; b++)
    {
        let w = Resolve(P, b) * DepthWeight(P, b, still);
        if (w > 0.0)
        {
            let uv = p / U.Length[b];
            f.Height += w * textureSampleLevel(Displacement, Wrap, uv, b, 0.0).z;
            // the bands carry the deep-water surface velocity a √(gk); the depth-averaged velocity of the same wave in
            // depth d is a ω / (kd) with ω² = gk tanh(kd), i.e. the texture value × √tanh(kd) / (kd) — capped where the
            // band is far longer than the depth allows
            let kd = 6.28318530718 / P.Lambda[b] * max(still, 0.05);
            let column = min(sqrt(tanh(kd)) / kd, P.Limits.w);
            f.Velocity += w * column * textureSampleLevel(Motion, Wrap, uv, b, 0.0).zw;
        }
    }
    return f;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                        INIT
//------------------------------------------------------------------------------------------------------------------------

// Solitary wave (Boussinesq first order): η = H sech²(√(3H / 4d³) (s + X₁)), u = c η / (d + η), c = √(g (d + H)); it moves
// along the shore normal (s is the landward distance, the crest starts X₁ seaward). The run-up benchmark: Synolakis 1987,
// H/d = 0.0185 on a 1:19.85 beach → R/d = 0.0861 from his law 2.831 √cot β (H/d)^{5/4} (non-breaking waves).
fn Solitary(s: f32, d: f32) -> vec2f     // (η, u along the normal)
{
    let h = P.Wave.x;
    let k = sqrt(0.75 * h / (d * d * d));
    let arg = k * (s + P.Wave.z);
    let sech = 1.0 / cosh(clamp(arg, -30.0, 30.0));
    let eta = h * sech * sech;
    let c = sqrt(Gravity * (d + h));
    return vec2f(eta, c * eta / (d + eta));
}

@compute @workgroup_size(Tile, Tile)
fn ShoalInit(@builtin(global_invocation_id) id: vec3u)
{
    let n = u32(P.Patch.w);
    if (id.x >= n || id.y >= n)
    {
        return;
    }
    let i = vec2i(id.xy);
    let bed = BedAt(i);
    var h = max(0.0, -bed);
    var u = 0.0;
    var v = 0.0;
    if (P.Wave.w > 2.5 && P.Wave.x > 0.0)
    {
        let s = dot(Centre(i) - P.Shore.xy, P.Shore.zw);           // landward distance [m]
        let wave = Solitary(s, P.Wave.y);
        if (bed < 0.0)
        {
            h = max(0.0, wave.x - bed);
            // face velocities: east face at s + ½Δx·n_x, north face at s + ½Δx·n_y
            let ue = Solitary(s + 0.5 * P.Patch.z * P.Shore.z, P.Wave.y).y;
            let vn = Solitary(s + 0.5 * P.Patch.z * P.Shore.w, P.Wave.y).y;
            u = ue * P.Shore.z;
            v = vn * P.Shore.w;
        }
    }
    textureStore(Next, id.xy, vec4f(h, u, v, 0.0));
}

//------------------------------------------------------------------------------------------------------------------------
//                                                    CONTINUITY
//------------------------------------------------------------------------------------------------------------------------

// Depth on the east face of cell i: the upwind cell's depth (Stelling–Duinmeijer wetting/drying), but never more water
// than the *free-surface difference* allows when the neighbour's bed is higher (no flow "through" a dry bank). A face
// at rest takes the higher free surface as upwind — otherwise a wet cell next to dry sand could never start to flow.
fn FaceDepthEast(i: vec2i, u: f32) -> f32
{
    let here = Cell(i);
    let east = Cell(i + vec2i(1, 0));
    let bedHere = BedAt(i);
    let bedEast = BedAt(i + vec2i(1, 0));
    let etaHere = here.x + bedHere;
    let etaEast = east.x + bedEast;
    let toEast = select(etaHere >= etaEast, u > 0.0, u != 0.0);
    let upwind = select(east.x, here.x, toEast);
    let crest = max(bedHere, bedEast);
    let level = select(etaEast, etaHere, toEast);
    return max(0.0, min(upwind, level - crest));
}

fn FaceDepthNorth(i: vec2i, v: f32) -> f32
{
    let here = Cell(i);
    let north = Cell(i + vec2i(0, 1));
    let bedHere = BedAt(i);
    let bedNorth = BedAt(i + vec2i(0, 1));
    let etaHere = here.x + bedHere;
    let etaNorth = north.x + bedNorth;
    let toNorth = select(etaHere >= etaNorth, v > 0.0, v != 0.0);
    let upwind = select(north.x, here.x, toNorth);
    let crest = max(bedHere, bedNorth);
    let level = select(etaNorth, etaHere, toNorth);
    return max(0.0, min(upwind, level - crest));
}

@compute @workgroup_size(Tile, Tile)
fn ShoalDepth(@builtin(global_invocation_id) id: vec3u)
{
    let n = i32(P.Patch.w);
    if (i32(id.x) >= n || i32(id.y) >= n)
    {
        return;
    }
    let i = vec2i(id.xy);
    let here = Cell(i);
    let dx = P.Patch.z;
    let dt = P.Step.x;
    // Fluxes through the four faces (east/north are this cell's, west/south belong to the neighbours). Closed walls at
    // the patch rim: no flux through x = 0, x = n, y = 0, y = n.
    let uE = select(here.y, 0.0, i.x == n - 1);
    let uW = select(Cell(i - vec2i(1, 0)).y, 0.0, i.x == 0);
    let vN = select(here.z, 0.0, i.y == n - 1);
    let vS = select(Cell(i - vec2i(0, 1)).z, 0.0, i.y == 0);
    let qE = uE * FaceDepthEast(i, uE);
    let qW = uW * FaceDepthEast(i - vec2i(1, 0), uW);
    let qN = vN * FaceDepthNorth(i, vN);
    let qS = vS * FaceDepthNorth(i - vec2i(0, 1), vS);
    var h = here.x - dt / dx * (qE - qW + qN - qS);
    h = max(h, 0.0);
    // Bore detector (feeds the foam): the surface rises faster than a fraction of the shallow-water celerity — the
    // breaking criterion of Kennedy, Chen, Kirby & Dalrymple 2000 (initiation at ∂η/∂t ≥ 0.65 √(g h), sustained down to
    // 0.15 √(g h)); the value ramps from 0.25 to 0.65 and is smoothed in time so a bore's foam does not flicker.
    var bore = 0.0;
    if (h > P.Limits.x)
    {
        let rise = (h - here.x) / dt;
        bore = smoothstep(0.25, 0.65, rise / sqrt(Gravity * h));
    }
    bore = max(bore, here.w * exp(-dt / 0.35));
    textureStore(Next, id.xy, vec4f(h, here.y, here.z, bore));
}

//------------------------------------------------------------------------------------------------------------------------
//                                                      MOMENTUM
//------------------------------------------------------------------------------------------------------------------------

// Face fluxes q = u · h_face [m²/s]; zero through the four outer walls.
fn FluxEast(i: vec2i) -> f32
{
    let n = i32(P.Patch.w);
    if (i.x < 0 || i.x >= n - 1 || i.y < 0 || i.y >= n)
    {
        return 0.0;
    }
    let u = Cell(i).y;
    return u * FaceDepthEast(i, u);
}

fn FluxNorth(i: vec2i) -> f32
{
    let n = i32(P.Patch.w);
    if (i.x < 0 || i.x >= n || i.y < 0 || i.y >= n - 1)
    {
        return 0.0;
    }
    let v = Cell(i).z;
    return v * FaceDepthNorth(i, v);
}

// Advection of a face velocity `u` with neighbours uUp (behind, −normal) and uDown (ahead, +normal) along the normal and
// uSide− / uSide+ across it, in the conservative flux form of Stelling & Duinmeijer 2003 (eq. 22): with q̄ the fluxes
// averaged to the two cell centres either side of the face (along) and to the two corners (across), and ū the velocity
// carried through each,
//     advection = [ Σ (q̄₊ ū₊ − q̄₋ ū₋) − u Σ (q̄₊ − q̄₋) ] / (Δx h̄)
// which is ∂(q u)/∂x − u ∂q/∂x in discrete form. Their switch decides how ū is taken: where the flow *converges* along
// the normal (a bore forming — the velocity ahead is lower than behind) ū is upwind, which is the momentum-conserving
// choice that gives bores the right speed and dissipation; elsewhere ū is centred (energy-conserving), which keeps the
// scheme second order on smooth run-up — the 1-D mirror gains ≈ 4 points of Synolakis run-up at Δx/d = 0.25 and halves
// the error at 0.125. h̄ is the centred face depth.
fn Advect(u: f32, uUp: f32, uDown: f32, uSideMinus: f32, uSidePlus: f32,
          qMinus: f32, qPlus: f32, qSideMinus: f32, qSidePlus: f32, hBar: f32) -> f32
{
    let dx = P.Patch.z;
    let converging = select((u > uDown), (u < uUp), (u > 0.0));
    var uMinus = 0.5 * (uUp + u);
    var uPlus = 0.5 * (u + uDown);
    if (converging)
    {
        uMinus = select(u, uUp, qMinus > 0.0);
        uPlus = select(uDown, u, qPlus > 0.0);
    }
    let uSideLow = select(u, uSideMinus, qSideMinus > 0.0);
    let uSideHigh = select(uSidePlus, u, qSidePlus > 0.0);
    let along = qPlus * uPlus - qMinus * uMinus - u * (qPlus - qMinus);
    let across = qSidePlus * uSideHigh - qSideMinus * uSideLow - u * (qSidePlus - qSideMinus);
    return (along + across) / (dx * hBar);
}

@compute @workgroup_size(Tile, Tile)
fn ShoalVelocity(@builtin(global_invocation_id) id: vec3u)
{
    let n = i32(P.Patch.w);
    if (i32(id.x) >= n || i32(id.y) >= n)
    {
        return;
    }
    let i = vec2i(id.xy);
    let here = Cell(i);
    let dx = P.Patch.z;
    let dt = P.Step.x;
    let bedHere = BedAt(i);
    let eta = here.x + bedHere;
    let dry = P.Limits.x;
    // the hull is a moving surface pressure (metres of head): the water stands lower under it and flows around it
    let hullHere = HullHead(P, Centre(i));
    let hullEast = HullHead(P, Centre(i + vec2i(1, 0)));
    let hullNorth = HullHead(P, Centre(i + vec2i(0, 1)));

    // ---- east face: u (normal +x; the transverse direction is y)
    var u = 0.0;
    if (i.x < n - 1)
    {
        let east = Cell(i + vec2i(1, 0));
        let bedEast = BedAt(i + vec2i(1, 0));
        let etaEast = east.x + bedEast;
        let hFace = FaceDepthEast(i, here.y);
        let hBar = 0.5 * (here.x + east.x);
        if (hFace > dry && hBar > dry)
        {
            let qW = FluxEast(i - vec2i(1, 0));
            let qE = FluxEast(i);
            let qEE = FluxEast(i + vec2i(1, 0));
            let qCornerN = 0.5 * (FluxNorth(i) + FluxNorth(i + vec2i(1, 0)));
            let qCornerS = 0.5 * (FluxNorth(i - vec2i(0, 1)) + FluxNorth(i + vec2i(1, -1)));
            let advect = Advect(here.y, Cell(i - vec2i(1, 0)).y, east.y, Cell(i - vec2i(0, 1)).y, Cell(i + vec2i(0, 1)).y,
                                0.5 * (qW + qE), 0.5 * (qE + qEE), qCornerS, qCornerN, hBar);
            let slope = Gravity * (etaEast + hullEast - eta - hullHere) / dx;
            let vFace = 0.25 * (here.z + east.z + Cell(i - vec2i(0, 1)).z + Cell(i + vec2i(1, -1)).z);
            let speed = length(vec2f(here.y, vFace));
            let friction = Gravity * P.Step.y * P.Step.y * speed / pow(max(hFace, dry), 4.0 / 3.0);
            u = (here.y - dt * (advect + slope)) / (1.0 + dt * friction);
            // no flow uphill into a dry cell whose bed stands above the water
            if (east.x <= dry && bedEast > eta && u > 0.0) { u = 0.0; }
            if (here.x <= dry && bedHere > etaEast && u < 0.0) { u = 0.0; }
        }
        else if (hFace > dry)
        {
            // thin film (one side nearly dry): pressure only — the run-up tongue
            u = here.y - dt * Gravity * (etaEast + hullEast - eta - hullHere) / dx;
            if (east.x <= dry && bedEast > eta && u > 0.0) { u = 0.0; }
            if (here.x <= dry && bedHere > etaEast && u < 0.0) { u = 0.0; }
        }
    }
    // ---- north face: v (normal +y; the transverse direction is x)
    var v = 0.0;
    if (i.y < n - 1)
    {
        let north = Cell(i + vec2i(0, 1));
        let bedNorth = BedAt(i + vec2i(0, 1));
        let etaNorth = north.x + bedNorth;
        let hFace = FaceDepthNorth(i, here.z);
        let hBar = 0.5 * (here.x + north.x);
        if (hFace > dry && hBar > dry)
        {
            let qS = FluxNorth(i - vec2i(0, 1));
            let qN = FluxNorth(i);
            let qNN = FluxNorth(i + vec2i(0, 1));
            let qCornerE = 0.5 * (FluxEast(i) + FluxEast(i + vec2i(0, 1)));
            let qCornerW = 0.5 * (FluxEast(i - vec2i(1, 0)) + FluxEast(i + vec2i(-1, 1)));
            let advect = Advect(here.z, Cell(i - vec2i(0, 1)).z, north.z, Cell(i - vec2i(1, 0)).z, Cell(i + vec2i(1, 0)).z,
                                0.5 * (qS + qN), 0.5 * (qN + qNN), qCornerW, qCornerE, hBar);
            let slope = Gravity * (etaNorth + hullNorth - eta - hullHere) / dx;
            let uFace = 0.25 * (here.y + north.y + Cell(i - vec2i(1, 0)).y + Cell(i + vec2i(-1, 1)).y);
            let speed = length(vec2f(uFace, here.z));
            let friction = Gravity * P.Step.y * P.Step.y * speed / pow(max(hFace, dry), 4.0 / 3.0);
            v = (here.z - dt * (advect + slope)) / (1.0 + dt * friction);
            if (north.x <= dry && bedNorth > eta && v > 0.0) { v = 0.0; }
            if (here.x <= dry && bedHere > etaNorth && v < 0.0) { v = 0.0; }
        }
        else if (hFace > dry)
        {
            v = here.z - dt * Gravity * (etaNorth + hullNorth - eta - hullHere) / dx;
            if (north.x <= dry && bedNorth > eta && v > 0.0) { v = 0.0; }
            if (here.x <= dry && bedHere > etaNorth && v < 0.0) { v = 0.0; }
        }
    }
    let cap = P.Limits.y;
    u = clamp(u, -cap, cap);
    v = clamp(v, -cap, cap);

    // ---- handover and rim: where the spectral bands own the wave (deep) the patch is nudged to follow them, so that the
    // wave arrives in the surf zone with its full height and the right phase; at the rim the relaxation is total, which
    // is how tier-0 waves enter and how the patch's own waves leave without reflecting. Rate 0 = a free basin (run-up).
    var h = here.x;
    let p = Centre(i);
    let weight = PatchWeight(P, p);
    let still = -bedHere;
    let rate = P.Step.w * ((1.0 - Handover(P, still)) + select(0.0, 1.0 - weight, P.Step.z > 0.0));
    if (rate > 0.0)
    {
        let sea = SpectralSea(p, still);
        let goal = max(0.0, sea.Height - bedHere);
        let blend = 1.0 - exp(-rate * dt);
        h = mix(h, goal, blend);
        u = mix(u, sea.Velocity.x, blend);
        v = mix(v, sea.Velocity.y, blend);
    }

    textureStore(Next, id.xy, vec4f(h, u, v, here.w));
}

//------------------------------------------------------------------------------------------------------------------------
//                                                        SHIFT
//------------------------------------------------------------------------------------------------------------------------

// The patch follows the camera in whole cells: copy the old state shifted by P.Shift; cells that enter take still water
// (the sponge fills them with the spectral sea within a few ticks).
@compute @workgroup_size(Tile, Tile)
fn ShoalShift(@builtin(global_invocation_id) id: vec3u)
{
    let n = i32(P.Patch.w);
    if (i32(id.x) >= n || i32(id.y) >= n)
    {
        return;
    }
    let i = vec2i(id.xy);
    let source = i + P.Shift.xy;
    if (all(source >= vec2i(0)) && all(source < vec2i(n)))
    {
        textureStore(Next, id.xy, textureLoad(Previous, vec2u(source), 0));
    }
    else
    {
        let bed = Bed(P, Centre(i));
        textureStore(Next, id.xy, vec4f(max(0.0, -bed), 0.0, 0.0, 0.0));
    }
}

//------------------------------------------------------------------------------------------------------------------------
//                                                        PROOF
//------------------------------------------------------------------------------------------------------------------------

var<workgroup> Sum: array<vec4f, WG>;
var<workgroup> Extra: array<vec4f, WG>;

fn NonFinite(x: f32) -> bool
{
    return (bitcast<u32>(x) & 0x7f800000u) == 0x7f800000u;
}

// Partials[2 row]     = (Σ h, max η over wet cells, Σ [h > dry], non-finite)
// Partials[2 row + 1] = (max wet bed — the run-up, Σ h |u|², Σ bore, max |u|)
@compute @workgroup_size(WG)
fn ShoalMeasure(@builtin(workgroup_id) group: vec3u, @builtin(local_invocation_id) local: vec3u)
{
    let n = u32(P.Patch.w);
    var acc = vec4f(0.0, -1.0e9, 0.0, 0.0);
    var extra = vec4f(-1.0e9, 0.0, 0.0, 0.0);
    for (var x = local.x; x < n; x += WG)
    {
        let i = vec2i(i32(x), i32(group.x));
        let c = textureLoad(Previous, vec2u(i), 0);
        let bed = Bed(P, Centre(i));
        acc.x += c.x;
        let wet = c.x > P.Limits.x;
        if (wet)
        {
            acc.y = max(acc.y, c.x + bed);
            acc.z += 1.0;
            extra.x = max(extra.x, bed);
        }
        acc.w += select(0.0, 1.0, NonFinite(c.x) || NonFinite(c.y) || NonFinite(c.z));
        extra.y += c.x * (c.y * c.y + c.z * c.z);
        extra.z += c.w;
        extra.w = max(extra.w, max(abs(c.y), abs(c.z)));
    }
    Sum[local.x] = acc;
    Extra[local.x] = extra;
    workgroupBarrier();
    for (var stride = WG / 2u; stride > 0u; stride = stride >> 1u)
    {
        if (local.x < stride)
        {
            let a = Sum[local.x];
            let b = Sum[local.x + stride];
            Sum[local.x] = vec4f(a.x + b.x, max(a.y, b.y), a.z + b.z, a.w + b.w);
            let c = Extra[local.x];
            let d = Extra[local.x + stride];
            Extra[local.x] = vec4f(max(c.x, d.x), c.y + d.y, c.z + d.z, max(c.w, d.w));
        }
        workgroupBarrier();
    }
    if (local.x == 0u)
    {
        Partials[2u * group.x] = Sum[0];
        Partials[2u * group.x + 1u] = Extra[0];
    }
}
