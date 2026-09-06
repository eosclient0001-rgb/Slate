//============================================================================================================================================
// 📦 Frontier/Scratchpad/ShoalMirrorRun.mjs — 1-D CPU mirror of Shaders/ShoalSolver.wgsl (Synolakis run-up convergence, volume)
//============================================================================================================================================
//
//    node Scratchpad/ShoalMirrorRun.mjs
//
//    The same staggered scheme as the WGSL kernel, in one dimension: forward–backward stepping, upwind face depth with the
//    at-rest rule, Stelling–Duinmeijer flux-form advection with the converging-flow upwind switch, optional Manning friction.
//    Runs the solitary-wave run-up benchmark (Synolakis 1987: H/d = 0.0185 on a 1:19.85 beach → R/d = 0.0861) at three Δx/d
//    and prints the error, so a change to the kernel can be judged in seconds before a 60 s GPU proof. Findings recorded:
//        · without the at-rest rule (face upwind chosen by the sign of a zero velocity) the wet cell beside dry sand never
//          starts to flow and R ≈ 0 — the first GPU run showed exactly that
//        · pure upwind advection: −16 % / −11 % / −5.5 % at Δx/d 0.25 / 0.125 / 0.0625; with the converging switch
//          −12 % / −5.3 % / −1.7 % (the tolerance in GameExecution.js is 5 % + 0.5 Δx/d)
//        · volume drift is fp64 round-off (< 1e-14) — the flux form is exactly conservative

const g = 9.81;

function Run(N, dx, d, ratio, slope, seconds, options = {})
{
    const { courant = 0.5, crest = 35 * d, beach = 7 * d, dry = 0.001, manning = 0.0, upwindOnly = false } = options;
    const H = ratio * d;
    const shore = N - Math.round(beach / dx);
    const bed = new Float64Array(N), h = new Float64Array(N), u = new Float64Array(N);   // u on the east face of cell i
    for (let i = 0; i < N; i++)
    {
        const s = (i + 0.5 - shore) * dx;
        bed[i] = Math.max(-d, Math.min(s * slope, 5.0));
    }
    const k = Math.sqrt(0.75 * H / (d * d * d)), c = Math.sqrt(g * (d + H));
    const eta = s => H / Math.cosh(Math.max(-30, Math.min(30, k * (s + crest)))) ** 2;
    for (let i = 0; i < N; i++)
    {
        const s = (i + 0.5 - shore) * dx;
        if (bed[i] < 0)
        {
            h[i] = Math.max(0, eta(s) - bed[i]);
            const etaFace = eta(s + 0.5 * dx);
            u[i] = c * etaFace / (d + etaFace);
        }
    }
    const cap = 15.0;
    const dt = courant * dx / (Math.sqrt(g * (d + H)) + 0.25 * cap);
    const steps = Math.ceil(seconds / dt);
    const volume0 = h.reduce((a, b) => a + b, 0) * dx;
    const faceDepth = (i, uf) =>
    {
        if (i < 0 || i >= N - 1) { return 0; }
        const e0 = h[i] + bed[i], e1 = h[i + 1] + bed[i + 1];
        const toEast = uf !== 0 ? uf > 0 : e0 >= e1;
        const upwind = toEast ? h[i] : h[i + 1];
        const level = toEast ? e0 : e1;
        return Math.max(0, Math.min(upwind, level - Math.max(bed[i], bed[i + 1])));
    };
    const flux = i => (i < 0 || i >= N - 1) ? 0 : u[i] * faceDepth(i, u[i]);
    let maxSurface = -1e9, maxBed = -1e9;
    for (let n = 0; n < steps; n++)
    {
        const next = new Float64Array(N);
        for (let i = 0; i < N - 1; i++)
        {
            const hFace = faceDepth(i, u[i]), hBar = 0.5 * (h[i] + h[i + 1]);
            const eta0 = h[i] + bed[i], eta1 = h[i + 1] + bed[i + 1];
            let v = 0;
            if (hFace > dry && hBar > dry)
            {
                const qMinus = 0.5 * (flux(i - 1) + flux(i)), qPlus = 0.5 * (flux(i) + flux(i + 1));
                const uUp = i > 0 ? u[i - 1] : 0, uDown = u[i + 1] ?? 0;
                const converging = u[i] > 0 ? u[i] < uUp : u[i] > uDown;
                let uMinus = 0.5 * (uUp + u[i]), uPlus = 0.5 * (u[i] + uDown);
                if (converging || upwindOnly)
                {
                    uMinus = qMinus > 0 ? uUp : u[i];
                    uPlus = qPlus > 0 ? u[i] : uDown;
                }
                const advect = (qPlus * uPlus - qMinus * uMinus - u[i] * (qPlus - qMinus)) / (dx * hBar);
                v = u[i] - dt * (advect + g * (eta1 - eta0) / dx);
            }
            else if (hFace > dry)
            {
                v = u[i] - dt * g * (eta1 - eta0) / dx;
            }
            if (manning > 0 && hFace > dry)
            {
                v /= 1 + dt * g * manning * manning * Math.abs(u[i]) / Math.pow(Math.max(hFace, dry), 4 / 3);
            }
            if (h[i + 1] <= dry && bed[i + 1] > eta0 && v > 0) { v = 0; }
            if (h[i] <= dry && bed[i] > eta1 && v < 0) { v = 0; }
            next[i] = Math.max(-cap, Math.min(cap, v));
        }
        u.set(next);
        const depth = new Float64Array(N);
        for (let i = 0; i < N; i++)
        {
            depth[i] = Math.max(0, h[i] - dt / dx * (flux(i) - flux(i - 1)));
        }
        h.set(depth);
        if (n % 4 === 0)
        {
            for (let i = 0; i < N; i++)
            {
                if (h[i] > dry && bed[i] > -0.5 * d)
                {
                    maxSurface = Math.max(maxSurface, h[i] + bed[i]);
                    maxBed = Math.max(maxBed, bed[i]);
                }
            }
        }
    }
    const volume = h.reduce((a, b) => a + b, 0) * dx;
    const law = d * 2.831 * Math.sqrt(1 / slope) * ratio ** 1.25;
    return { RunUp: maxSurface, WetBed: maxBed, Law: law, Error: (maxSurface - law) / law, Drift: (volume - volume0) / volume0, Steps: steps };
}

console.log("Synolakis H/d = 0.0185, 1:19.85 beach, d = 4 m, 60 s — error of the highest wet surface vs the run-up law");
for (const upwindOnly of [false, true])
{
    const rows = [];
    for (const [N, dx] of [[256, 1.0], [512, 0.5], [1024, 0.25]])
    {
        const r = Run(N, dx, 4, 0.0185, 1 / 19.85, 60, { upwindOnly });
        rows.push(`Δx/d ${(dx / 4).toFixed(4)}: ${(r.Error * 100).toFixed(1)} % (R ${r.RunUp.toFixed(4)} m, law ${r.Law.toFixed(4)} m, drift ${r.Drift.toExponential(1)})`);
    }
    console.log(`${upwindOnly ? "upwind only        " : "converging switch  "} ${rows.join(" · ")}`);
}
