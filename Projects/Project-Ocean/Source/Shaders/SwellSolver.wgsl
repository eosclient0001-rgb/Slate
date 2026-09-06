//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/Shaders/SwellSolver.wgsl — Spectral Ocean Kernels (JONSWAP/TMA init, evolution, FFT, compose, proofs)
//============================================================================================================================================
//
//    Multi-band spectral ocean (References/OceanPhaseO0-SurveyAndPlan.md §4, tier 0). Band b is an N×N periodic patch of length
//    L_b = N s_b [m]; texel (x, y) of the spectral buffers holds the wavenumber k = ((x, y) − N/2) · 2π/L_b [rad/m] and the band
//    only carries |k| ∈ [MinK_b, MaxK_b) with MaxK_b = 2π/(ψ s_b) — Donatini's ψ rule: a wave with fewer than ψ texels per
//    wavelength is never synthesised (it would alias), the next finer band owns it.
//
//    Kernels (SwellSolver.js dispatches them in this order):
//        SpectrumInit    once per sea state: h̃0(k) = ξ · √(S(k) Δk² / 2) with ⟨|ξ|²⟩ = 1, so Σ_k ⟨|ĥ(k,t)|²⟩ = Σ_k S(k) Δk² = ⟨h²⟩
//        Evolve          ĥ(k,t) = h̃0(k) e^{−iωt} + h̃0*(−k) e^{+iωt} (waves travel along +k̂), ω² = g k tanh(k h), then the derived
//                        spectra are packed two real fields per complex FFT into three vec4 layers per band
//        FftRows / FftColumns   inverse DFT — in-place radix-2 decimation in time in workgroup memory, one line per workgroup
//                        (workgroup y = slab = layer · Bands + band); the column pass applies (−1)^(x+y) (the N/2 wavenumber
//                        shift). No 1/N²: h̃0 already carries Δk, so h(x) = Σ_k ĥ(k) e^{ik·x} exactly.
//        Compose         spatial layers → rgba16float band textures (Displacement, Derivative, Motion), choppiness ξ applied
//        Measure / MeasureMode   proof reductions, one workgroup per texture row: (Σh², max|h|, non-finite count, Σ|ĥ(k,t)|²),
//                        Σ(|h̃0(k)|² + |h̃0(−k)|²) and (Σa_z², Σv_z²) per band, and the Fourier coefficient of the seeded mode.
//                        Bindings 0–6 form the simulation group, 0, 1, 7, 8, 9 the measure group (no texture is bound for
//                        writing and reading in the same group).
//
//    Layers per band (real fields a + i b → one complex FFT each):
//        0: (δx + iδy | h + i ∂δx/∂y)     1: (∂h/∂x + i ∂h/∂y | ∂δx/∂x + i ∂δy/∂y)     2: (a_z + i v_z | u_x + i u_y)
//    with δ̂ = i k̂ ĥ (Gerstner sharpening: the displacement points up the height gradient, toward the crest), ∂δx/∂x = −(kx²/k) ĥ,
//    a_z = −ω² ĥ, v_z = ∂h/∂t and u = ∂δ/∂t. Units: metres, seconds, radians; +Z up. FFT_THREADS and LINE_LENGTH are substituted by SwellSolver.js (min(N/2, 256) and N),
//    which also prepends SeaStructure.wgsl (the `Sea` uniform).

const Pi     = 3.14159265358979;
const Layers = 3u;
const Tile   = 16u;

// struct Sea comes from SeaStructure.wgsl (prepended by SwellSolver.js).

@group(0) @binding(0) var<uniform> U: Sea;
@group(0) @binding(1) var<storage, read_write> Initial:  array<vec4f>;   // Bands × N²: h̃0(k) re im, h̃0(−k) re im
@group(0) @binding(2) var<storage, read_write> Spectral: array<vec4f>;   // Layers × Bands × N²: spectra in, spatial fields out
@group(0) @binding(3) var<storage, read_write> Pong:     array<vec4f>;   // row-transformed intermediate
@group(0) @binding(4) var Displacement: texture_storage_2d_array<rgba16float, write>;   // (ξδx, ξδy, h, ξ∂δx/∂y)
@group(0) @binding(5) var Derivative:   texture_storage_2d_array<rgba16float, write>;   // (∂h/∂x, ∂h/∂y, ξ∂δx/∂x, ξ∂δy/∂y)
@group(0) @binding(6) var Motion:       texture_storage_2d_array<rgba16float, write>;   // (a_z, v_z, ξu_x, ξu_y)
@group(0) @binding(7) var<storage, read_write> Partials: array<vec4f>;   // proof rows
@group(0) @binding(8) var Heights: texture_2d_array<f32>;                // Displacement, read side (Measure group)
@group(0) @binding(9) var Motions: texture_2d_array<f32>;                // Motion, read side (Measure group)

//------------------------------------------------------------------------------------------------------------------------
//                                                     SPECTRUM
//------------------------------------------------------------------------------------------------------------------------

fn Mul(p: vec2f, q: vec2f) -> vec2f
{
    return vec2f(p.x * q.x - p.y * q.y, p.x * q.y + p.y * q.x);
}

// tanh for x ≥ 0 that saturates instead of overflowing: k·h reaches 10³ in deep water and sinh/cosh blow up past e⁸⁸ in f32.
fn Tanh(x: f32) -> f32
{
    let e = exp(-2.0 * min(x, 20.0));
    return (1.0 - e) / (1.0 + e);
}

fn Omega(kk: f32) -> f32     // dispersion ω = √(g k tanh k h) [rad/s]
{
    return sqrt(U.Wave.x * kk * Tanh(kk * U.Wave.y));
}

fn RotPos(z: vec2f) -> vec2f     // i·z
{
    return vec2f(-z.y, z.x);
}

fn RotNeg(z: vec2f) -> vec2f     // −i·z
{
    return vec2f(z.y, -z.x);
}

fn Pack(a: vec2f, b: vec2f) -> vec2f     // a + i·b for complex a, b
{
    return vec2f(a.x - b.y, a.y + b.x);
}

// 2D variance density S(kx, ky) [m² per (rad/m)²] of the sea state inside band `band`'s window — the exact formula
// OceanStructure.js repeats on the CPU for the energy proof (JONSWAP · TMA · Donelan–Banner spreading, swell narrowing).
fn Density(k: vec2f, band: u32) -> f32
{
    let kk = length(k);
    if (kk < 1.0e-6 || kk < U.MinK[band] || kk >= U.MaxK[band])
    {
        return 0.0;
    }
    let g = U.Wave.x;
    let depth = U.Wave.y;
    let wind = U.Wave.z;
    let reach = U.Wave.w;
    let th = Tanh(kk * depth);
    let w = sqrt(g * kk * th);
    let dwdk = (g * th + g * kk * depth * (1.0 - th * th)) / (2.0 * w);
    let wp = 22.0 * pow(g * g / (wind * reach), 1.0 / 3.0);
    let alpha = 0.076 * pow(wind * wind / (reach * g), 0.22);
    let sigma = select(0.09, 0.07, w <= wp);
    let r = exp(-(w - wp) * (w - wp) / (2.0 * sigma * sigma * wp * wp));
    var s = alpha * g * g / pow(w, 5.0) * exp(-1.25 * pow(wp / w, 4.0)) * pow(U.Shape.x, r);
    let wh = w * sqrt(depth / g);                                        // TMA finite-depth attenuation
    s *= select(select(1.0, 1.0 - 0.5 * (2.0 - wh) * (2.0 - wh), wh < 2.0), 0.5 * wh * wh, wh < 1.0);
    // Angle from the wind via acos (the spreading function is even in θ): atan2 differs between GPUs for y = −0.
    let theta = acos(clamp(dot(k / kk, vec2f(cos(U.Shape.z), sin(U.Shape.z))), -1.0, 1.0));
    let x = w / wp;
    var beta: f32;
    if (x < 0.56)
    {
        beta = 2.61 * pow(0.56, 1.3);                                     // Donelan–Banner is undefined below 0.56 ωp: hold the edge value
    }
    else if (x < 0.95)
    {
        beta = 2.61 * pow(x, 1.3);
    }
    else if (x < 1.6)
    {
        beta = 2.28 * pow(x, -1.3);
    }
    else
    {
        beta = pow(10.0, -0.4 + 0.8393 * exp(-0.567 * log(x * x)));
    }
    beta *= 1.0 + 4.0 * U.Shape.y * exp(-x * x);                          // swell parameter: the long waves become long-crested
    let sech = 1.0 / cosh(beta * theta);
    let d = beta / (2.0 * Tanh(beta * Pi)) * sech * sech;
    return s * d * dwdk / kk;
}

fn Hash3(v0: vec3u) -> vec3u      // pcg3d (Jarzynski & Olano 2020)
{
    var v = v0 * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> vec3u(16u);
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    return v;
}

// One complex draw with ⟨|ξ|²⟩ = 1, deterministic in (texel, band, seed): a unit phasor e^{iφ} by default (every mode carries
// exactly its spectral energy, so the spectrum proof is exact), or (ξr + iξi)/√2 Gaussian when Sea.Previous.w = 1 — Tessendorf's
// Rayleigh amplitudes, which add wave-group variety at the price of ±1/√M energy scatter.
fn Draw(cell: vec3u) -> vec2f
{
    let h = Hash3(cell + vec3u(U.Grid.w * 7919u, U.Grid.w * 104729u, U.Grid.w * 31u + 17u));
    let u1 = (f32(h.x >> 8u) + 1.0) / 16777217.0;
    let u2 = f32(h.y >> 8u) / 16777216.0;
    let phasor = vec2f(cos(2.0 * Pi * u2), sin(2.0 * Pi * u2));
    let radius = select(1.0, sqrt(-log(u1)), U.Previous.w > 0.5);
    return radius * phasor;
}

fn Wavenumber(texel: vec2u, band: u32) -> vec2f
{
    let n = U.Grid.x;
    let dk = 2.0 * Pi / U.Length[band];
    return vec2f(f32(i32(texel.x) - i32(n / 2u)), f32(i32(texel.y) - i32(n / 2u))) * dk;
}

@compute @workgroup_size(Tile, Tile)
fn SpectrumInit(@builtin(global_invocation_id) id: vec3u)
{
    let n = U.Grid.x;
    if (id.x >= n || id.y >= n)
    {
        return;
    }
    let band = id.z;
    var a = vec2f(0.0);
    var b = vec2f(0.0);
    if (U.Clock.w > 0.5)
    {
        // Mode scene: one deterministic wave of amplitude A along +x in band 0 (h̃0 = A/2 at +k only).
        if (band == 0u && id.y == n / 2u)
        {
            let m = i32(id.x) - i32(n / 2u);
            if (m == i32(U.Mode.x))
            {
                a = vec2f(0.5 * U.Mode.y, 0.0);
            }
            if (m == -i32(U.Mode.x))
            {
                b = vec2f(0.5 * U.Mode.y, 0.0);
            }
        }
    }
    else
    {
        let k = Wavenumber(id.xy, band);
        let dk = 2.0 * Pi / U.Length[band];
        let mirror = vec2u((n - id.x) % n, (n - id.y) % n);       // the texel holding −k
        a = Draw(vec3u(id.xy, band)) * sqrt(Density(k, band) * dk * dk * 0.5);
        b = Draw(vec3u(mirror, band)) * sqrt(Density(-k, band) * dk * dk * 0.5);
    }
    Initial[(band * n + id.y) * n + id.x] = vec4f(a, b);
}

//------------------------------------------------------------------------------------------------------------------------
//                                                     EVOLUTION
//------------------------------------------------------------------------------------------------------------------------

struct Phasor
{
    H:     vec2f,    // ĥ(k, t)
    V:     vec2f,    // ∂ĥ/∂t
    Omega: f32,
};

// ĥ(k,t) = h̃0(k) e^{−iωt} + h̃0*(−k) e^{+iωt} — the crest of mode k moves along +k̂ (Tessendorf's convention with e^{+ik·x}).
fn Coefficient(texel: u32, kk: f32) -> Phasor
{
    let h0 = Initial[texel];
    let w = Omega(kk);
    let phase = w * U.Clock.x;
    let c = cos(phase);
    let s = sin(phase);
    let forward = Mul(h0.xy, vec2f(c, -s));                   // h̃0(k) e^{−iωt}
    let backward = Mul(vec2f(h0.z, -h0.w), vec2f(c, s));      // h̃0*(−k) e^{+iωt}
    var wave: Phasor;
    wave.H = forward + backward;
    wave.V = w * (RotNeg(forward) + RotPos(backward));
    wave.Omega = w;
    return wave;
}

@compute @workgroup_size(Tile, Tile)
fn Evolve(@builtin(global_invocation_id) id: vec3u)
{
    let n = U.Grid.x;
    if (id.x >= n || id.y >= n)
    {
        return;
    }
    let band = id.z;
    let bands = U.Grid.z;
    let texel = (band * n + id.y) * n + id.x;
    let stride = bands * n * n;
    let k = Wavenumber(id.xy, band);
    let kk = length(k);
    var layer0 = vec4f(0.0);
    var layer1 = vec4f(0.0);
    var layer2 = vec4f(0.0);
    let seeded = Initial[texel];
    if (kk > 1.0e-6 && dot(seeded, seeded) > 0.0)                  // ¾ of a band's cells lie outside its window: skip them
    {
        let wave = Coefficient(texel, kk);
        let h = wave.H;
        let v = wave.V;
        let w = wave.Omega;
        let kn = k / kk;
        let dx = kn.x * RotPos(h);
        let dy = kn.y * RotPos(h);
        let hx = k.x * RotPos(h);
        let hy = k.y * RotPos(h);
        let dxx = -(k.x * k.x / kk) * h;
        let dyy = -(k.y * k.y / kk) * h;
        let dxy = -(k.x * k.y / kk) * h;
        let az = -(w * w) * h;
        let ux = kn.x * RotPos(v);
        let uy = kn.y * RotPos(v);
        layer0 = vec4f(Pack(dx, dy), Pack(h, dxy));
        layer1 = vec4f(Pack(hx, hy), Pack(dxx, dyy));
        layer2 = vec4f(Pack(az, v), Pack(ux, uy));
    }
    Spectral[texel] = layer0;
    Spectral[stride + texel] = layer1;
    Spectral[2u * stride + texel] = layer2;
}

//------------------------------------------------------------------------------------------------------------------------
//                                                        FFT
//------------------------------------------------------------------------------------------------------------------------

var<workgroup> Line: array<vec4f, LINE_LENGTH>;

// One inverse DFT of length N over `line` of slab `slab` (slab = layer · Bands + band; a row when vertical is false, a column
// otherwise). Radix-2 decimation in time: bit-reversed load, log2 N in-place butterfly stages with e^{+iπ·pos/half} twiddles.
// Both packed complex fields (xy and zw) ride the same butterflies.
fn Transform(line: u32, slab: u32, vertical: bool, thread: u32)
{
    let n = U.Grid.x;
    let logN = U.Grid.y;
    let base = slab * n * n;
    for (var i = thread; i < n; i += FFT_THREADS)
    {
        let source = reverseBits(i) >> (32u - logN);
        if (vertical)
        {
            Line[i] = Pong[base + source * n + line];
        }
        else
        {
            Line[i] = Spectral[base + line * n + source];
        }
    }
    workgroupBarrier();
    for (var half = 1u; half < n; half = half << 1u)
    {
        for (var j = thread; j < n / 2u; j += FFT_THREADS)
        {
            let group = j / half;
            let pos = j - group * half;
            let i0 = group * half * 2u + pos;
            let i1 = i0 + half;
            let angle = Pi * f32(pos) / f32(half);
            let twiddle = vec2f(cos(angle), sin(angle));
            let odd = Line[i1];
            let t = vec4f(Mul(odd.xy, twiddle), Mul(odd.zw, twiddle));
            let even = Line[i0];
            Line[i0] = even + t;
            Line[i1] = even - t;
        }
        workgroupBarrier();
    }
    for (var i = thread; i < n; i += FFT_THREADS)
    {
        if (vertical)
        {
            let sign = select(1.0, -1.0, ((i + line) & 1u) == 1u);   // (−1)^(x+y): the k-origin sits at texel N/2
            Spectral[base + i * n + line] = Line[i] * sign;
        }
        else
        {
            Pong[base + line * n + i] = Line[i];
        }
    }
}

@compute @workgroup_size(FFT_THREADS)
fn FftRows(@builtin(workgroup_id) group: vec3u, @builtin(local_invocation_id) local: vec3u)
{
    Transform(group.x, group.y, false, local.x);
}

@compute @workgroup_size(FFT_THREADS)
fn FftColumns(@builtin(workgroup_id) group: vec3u, @builtin(local_invocation_id) local: vec3u)
{
    Transform(group.x, group.y, true, local.x);
}

//------------------------------------------------------------------------------------------------------------------------
//                                                       COMPOSE
//------------------------------------------------------------------------------------------------------------------------

@compute @workgroup_size(Tile, Tile)
fn Compose(@builtin(global_invocation_id) id: vec3u)
{
    let n = U.Grid.x;
    if (id.x >= n || id.y >= n)
    {
        return;
    }
    let band = id.z;
    let texel = (band * n + id.y) * n + id.x;
    let stride = U.Grid.z * n * n;
    let chop = U.Shape.w;
    let l0 = Spectral[texel];
    let l1 = Spectral[stride + texel];
    let l2 = Spectral[2u * stride + texel];
    textureStore(Displacement, id.xy, band, vec4f(chop * l0.x, chop * l0.y, l0.z, chop * l0.w));
    textureStore(Derivative,   id.xy, band, vec4f(l1.x, l1.y, chop * l1.z, chop * l1.w));
    textureStore(Motion,       id.xy, band, vec4f(l2.x, l2.y, chop * l2.z, chop * l2.w));
}

//------------------------------------------------------------------------------------------------------------------------
//                                                       PROOFS
//------------------------------------------------------------------------------------------------------------------------

var<workgroup> Sum: array<vec4f, FFT_THREADS>;
var<workgroup> Energy: array<f32, FFT_THREADS>;
var<workgroup> Kinetic: array<vec2f, FFT_THREADS>;

fn NonFinite(x: f32) -> bool
{
    return (bitcast<u32>(x) & 0x7f800000u) == 0x7f800000u;
}

// Partials[3 (band · N + row)]     = (Σ h², max |h|, non-finite texels, Σ_k |ĥ(k, t)|²)      over one row of one band
// Partials[3 (band · N + row) + 1] = (Σ_k |h̃0(k)|² + |h̃0(−k)|², 0, 0, 0)                      — the time-averaged energy
// Partials[3 (band · N + row) + 2] = (Σ a_z², Σ v_z², 0, 0)                                    — from the Motion texture
// Parseval for the unnormalised inverse DFT: mean_x h² = Σ_k |ĥ(k)|², so lane w of row 0 must equal lane x / N².
@compute @workgroup_size(FFT_THREADS)
fn Measure(@builtin(workgroup_id) group: vec3u, @builtin(local_invocation_id) local: vec3u)
{
    let n = U.Grid.x;
    let row = group.x;
    let band = group.y;
    var acc = vec4f(0.0);
    var energy = 0.0;
    var kinetic = vec2f(0.0);
    for (var x = local.x; x < n; x += FFT_THREADS)
    {
        let d = textureLoad(Heights, vec2u(x, row), band, 0);
        let m = textureLoad(Motions, vec2u(x, row), band, 0);
        let bad = NonFinite(d.x) || NonFinite(d.y) || NonFinite(d.z) || NonFinite(d.w) || NonFinite(m.x) || NonFinite(m.y) || NonFinite(m.z) || NonFinite(m.w);
        let h = d.z;
        acc.x += h * h;
        acc.y = max(acc.y, abs(h));
        acc.z += select(0.0, 1.0, bad);
        let texel = (band * n + row) * n + x;
        let kk = length(Wavenumber(vec2u(x, row), band));
        if (kk > 1.0e-6)
        {
            let wave = Coefficient(texel, kk);
            acc.w += dot(wave.H, wave.H);
        }
        let s = Initial[texel];
        energy += dot(s, s);
        kinetic += m.xy * m.xy;
    }
    Sum[local.x] = acc;
    Energy[local.x] = energy;
    Kinetic[local.x] = kinetic;
    workgroupBarrier();
    for (var stride = FFT_THREADS / 2u; stride > 0u; stride = stride >> 1u)
    {
        if (local.x < stride)
        {
            let other = Sum[local.x + stride];
            let mine = Sum[local.x];
            Sum[local.x] = vec4f(mine.x + other.x, max(mine.y, other.y), mine.z + other.z, mine.w + other.w);
            Energy[local.x] += Energy[local.x + stride];
            Kinetic[local.x] += Kinetic[local.x + stride];
        }
        workgroupBarrier();
    }
    if (local.x == 0u)
    {
        Partials[3u * (band * n + row)] = Sum[0];
        Partials[3u * (band * n + row) + 1u] = vec4f(Energy[0], 0.0, 0.0, 0.0);
        Partials[3u * (band * n + row) + 2u] = vec4f(Kinetic[0], 0.0, 0.0);
    }
}

// Partials[3 · Bands · N] = complex Fourier coefficient (1/N) Σ_x h(x, row 0) e^{−i k x} of band 0 at the seeded mode: for
// h = A cos(k x − ω t) this is (A/2) e^{−iωt}, so its phase advances at exactly −ω and its modulus is A/2.
@compute @workgroup_size(FFT_THREADS)
fn MeasureMode(@builtin(local_invocation_id) local: vec3u)
{
    let n = U.Grid.x;
    var acc = vec2f(0.0);
    for (var x = local.x; x < n; x += FFT_THREADS)
    {
        let h = textureLoad(Heights, vec2u(x, 0u), 0u, 0).z;
        let angle = 2.0 * Pi * U.Mode.x * f32(x) / f32(n);
        acc += h * vec2f(cos(angle), -sin(angle));
    }
    Sum[local.x] = vec4f(acc, 0.0, 0.0);
    workgroupBarrier();
    for (var stride = FFT_THREADS / 2u; stride > 0u; stride = stride >> 1u)
    {
        if (local.x < stride)
        {
            Sum[local.x] += Sum[local.x + stride];
        }
        workgroupBarrier();
    }
    if (local.x == 0u)
    {
        Partials[3u * U.Grid.z * n] = vec4f(Sum[0].xy / f32(n), 0.0, 0.0);
    }
}
