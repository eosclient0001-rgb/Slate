//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/SurfaceProjection.js — Screen-Space Liquid Renderer (targets, pipelines, orbit view)
//============================================================================================================================================
//
//    Hosts the five raster stages of Shaders/SurfaceProjection.wgsl. Everything except the final shade runs at an
//    offscreen scale (0.5 → quarter the pixels — the GTX setting from the survey); the shade stage reads the offscreen
//    targets at the canvas resolution. Distances are eye-space metres; "no surface" is 1e9.
//
//    Targets (offscreen size):
//        BackgroundColour rgba16float · BackgroundDistance r32float          procedural container + sky
//        SpriteDistance   r32float    · SpriteNormal rgba16float · Depth     depth32float, sphere impostors
//        Thickness        r16float    additive chord length
//        SmoothA / SmoothB r32float   narrow-range ping-pong (H → V → … → 5×5 clean-up)
//
//    Camera: orbit around the container (yaw, pitch, distance), right-handed +Z up world; view space looks down −Z.

const ViewFloats  = 76;   // 304 B
const SmoothBytes = 16;

export class SurfaceProjection
{
    static async Create(device, canvas, format)
    {
        const source = await fetch(new URL("./Shaders/SurfaceProjection.wgsl", import.meta.url));
        if (!source.ok)
        {
            throw new Error(`SurfaceProjection: cannot load SurfaceProjection.wgsl (${source.status})`);
        }
        return new SurfaceProjection(device, canvas, format, await source.text());
    }

    constructor(device, canvas, format, code)
    {
        this.Device = device;
        this.Canvas = canvas;
        this.Format = format;
        this.Scale  = 0.5;              // [-] offscreen / canvas
        this.Mode   = 0;                // 0 water · 1 particles · 2 smoothed distance · 3 thickness
        this.SmoothIterations = 3;      // [-] H+V pairs before the clean-up
        this.Orbit  = { Yaw: -0.65, Pitch: 0.38, Distance: 3.2 };    // [rad], [rad], [m]
        this.Tuning = {
            SigmaCells: 1.0,            // [Δx] world-space filter size σ
            DeltaCells: 1.0,            // [Δx] narrow range δ
            MuFraction: 0.5,            // [-]  μ = MuFraction · δ
            MaxKernelPixels: 24,        // [px]
            Absorption: [2.5, 0.8, 0.4],// [1/m]
            Refraction: 0.08,           // [-]
            SpriteRadiusCells: 0.42,    // [Δx] particles sit Δx/2 apart at rest, so 0.42 Δx spheres overlap into a closed sheet
            WhiteSpeed: 4.0,            // [m/s] particle-mode colour ramp
            Sun: [0.35, -0.55, 0.76],   // [-]
        };

        const module = device.createShaderModule({ label: "SurfaceProjection", code });
        const V = GPUShaderStage.VERTEX, F = GPUShaderStage.FRAGMENT;
        const tex = { sampleType: "unfilterable-float" };

        this.ViewLayout   = device.createBindGroupLayout({ label: "ViewLayout",   entries: [{ binding: 0, visibility: V | F, buffer: { type: "uniform" } }] });
        this.SpriteLayout = device.createBindGroupLayout({ label: "SpriteLayout", entries: [{ binding: 0, visibility: V, buffer: { type: "read-only-storage" } }] });
        this.SmoothLayout = device.createBindGroupLayout({ label: "SmoothLayout", entries: [
            { binding: 1, visibility: F, texture: tex },
            { binding: 7, visibility: F, buffer: { type: "uniform" } },
        ] });
        this.ShadeLayout  = device.createBindGroupLayout({ label: "ShadeLayout", entries: [2, 3, 4, 5, 6].map(binding => ({ binding, visibility: F, texture: tex })) });

        const Layout = (second) => device.createPipelineLayout({ bindGroupLayouts: second ? [this.ViewLayout, second] : [this.ViewLayout] });
        const cover  = { module, entryPoint: "CoverVertexMain" };
        const sprite = { module, entryPoint: "SpriteVertexMain" };

        this.Background = device.createRenderPipeline({
            label: "BackgroundRaster", layout: Layout(null), vertex: cover,
            fragment: { module, entryPoint: "BackgroundFragmentMain", targets: [{ format: "rgba16float" }, { format: "r32float" }] },
            primitive: { topology: "triangle-list" },
        });
        this.Sprite = device.createRenderPipeline({
            label: "SpriteRaster", layout: Layout(this.SpriteLayout), vertex: sprite,
            fragment: { module, entryPoint: "SpriteFragmentMain", targets: [{ format: "r32float" }, { format: "rgba16float" }] },
            primitive: { topology: "triangle-list" },
            depthStencil: { format: "depth32float", depthWriteEnabled: true, depthCompare: "less" },
        });
        this.Thickness = device.createRenderPipeline({
            label: "ThicknessRaster", layout: Layout(this.SpriteLayout), vertex: sprite,
            fragment: { module, entryPoint: "ThicknessFragmentMain", targets: [{
                format: "r16float",
                blend: { color: { srcFactor: "one", dstFactor: "one", operation: "add" }, alpha: { srcFactor: "one", dstFactor: "one", operation: "add" } },
            }] },
            primitive: { topology: "triangle-list" },
        });
        this.Smooth = device.createRenderPipeline({
            label: "SmoothRaster", layout: Layout(this.SmoothLayout), vertex: cover,
            fragment: { module, entryPoint: "SmoothFragmentMain", targets: [{ format: "r32float" }] },
            primitive: { topology: "triangle-list" },
        });
        this.Shade = device.createRenderPipeline({
            label: "ShadeRaster", layout: Layout(this.ShadeLayout), vertex: cover,
            fragment: { module, entryPoint: "ShadeFragmentMain", targets: [{ format }] },
            primitive: { topology: "triangle-list" },
        });

        this.ViewConstants = device.createBuffer({ label: "ViewConstants", size: ViewFloats * 4, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
        this.ViewGroup     = device.createBindGroup({ layout: this.ViewLayout, entries: [{ binding: 0, resource: { buffer: this.ViewConstants } }] });

        // Three smoothing forms: horizontal, vertical, clean-up.
        this.SmoothConstants = {};
        for (const [name, direction, kind] of [["H", [1, 0], 0], ["V", [0, 1], 0], ["C", [0, 0], 1]])
        {
            const buffer = device.createBuffer({ label: `Smooth${name}`, size: SmoothBytes, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
            const words  = new Int32Array([direction[0], direction[1], kind, 0]);
            device.queue.writeBuffer(buffer, 0, words);
            this.SmoothConstants[name] = buffer;
        }

        this.Targets = null;
        this.ParticleGroup = null;
        this.Scene = null;
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                 SCENE + TARGETS
    //--------------------------------------------------------------------------------------------------------------------

    AttachScene(scene, records)
    {
        this.Scene = scene;
        this.ParticleGroup = this.Device.createBindGroup({ layout: this.SpriteLayout, entries: [{ binding: 0, resource: { buffer: records } }] });
        const centre = scene.BoxExtent.map(e => e * 0.5);
        this.Target  = [centre[0], centre[1], scene.BoxExtent[2] * 0.25];
    }

    EnsureTargets()
    {
        const width  = Math.max(8, Math.floor(this.Canvas.width * this.Scale));
        const height = Math.max(8, Math.floor(this.Canvas.height * this.Scale));
        if (this.Targets && this.Targets.Width === width && this.Targets.Height === height)
        {
            return;
        }
        this.DestroyTargets();
        const device = this.Device;
        const Make = (label, format) => device.createTexture({ label, size: [width, height], format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING });
        const T = {
            Width: width, Height: height,
            BackgroundColour:   Make("BackgroundColour", "rgba16float"),
            BackgroundDistance: Make("BackgroundDistance", "r32float"),
            SpriteDistance:     Make("SpriteDistance", "r32float"),
            SpriteNormal:       Make("SpriteNormal", "rgba16float"),
            Depth:              device.createTexture({ label: "SpriteDepth", size: [width, height], format: "depth32float", usage: GPUTextureUsage.RENDER_ATTACHMENT }),
            Thickness:          Make("Thickness", "r16float"),
            SmoothA:            Make("SmoothA", "r32float"),
            SmoothB:            Make("SmoothB", "r32float"),
        };
        for (const key of Object.keys(T))
        {
            if (T[key] instanceof GPUTexture)
            {
                T[key + "View"] = T[key].createView();
            }
        }
        const SmoothGroup = (input, form) => device.createBindGroup({ layout: this.SmoothLayout, entries: [
            { binding: 1, resource: input },
            { binding: 7, resource: { buffer: this.SmoothConstants[form] } },
        ] });
        T.SmoothRawH = SmoothGroup(T.SpriteDistanceView, "H");
        T.SmoothBH   = SmoothGroup(T.SmoothBView, "H");
        T.SmoothAV   = SmoothGroup(T.SmoothAView, "V");
        T.SmoothBC   = SmoothGroup(T.SmoothBView, "C");
        const ShadeGroup = (surface) => device.createBindGroup({ layout: this.ShadeLayout, entries: [
            { binding: 2, resource: surface },
            { binding: 3, resource: T.SpriteNormalView },
            { binding: 4, resource: T.ThicknessView },
            { binding: 5, resource: T.BackgroundColourView },
            { binding: 6, resource: T.BackgroundDistanceView },
        ] });
        T.ShadeRaw = ShadeGroup(T.SpriteDistanceView);
        T.ShadeA   = ShadeGroup(T.SmoothAView);
        T.ShadeB   = ShadeGroup(T.SmoothBView);
        this.Targets = T;
    }

    DestroyTargets()
    {
        if (!this.Targets)
        {
            return;
        }
        for (const resource of Object.values(this.Targets))
        {
            if (resource instanceof GPUTexture)
            {
                resource.destroy();
            }
        }
        this.Targets = null;
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                      VIEW
    //--------------------------------------------------------------------------------------------------------------------

    CameraPosition()
    {
        const o = this.Orbit;
        return [
            this.Target[0] + o.Distance * Math.cos(o.Pitch) * Math.cos(o.Yaw),
            this.Target[1] + o.Distance * Math.cos(o.Pitch) * Math.sin(o.Yaw),
            this.Target[2] + o.Distance * Math.sin(o.Pitch),
        ];
    }

    WriteView(tick)
    {
        const T = this.Targets;
        const s = this.Scene;
        const eye = this.CameraPosition();
        const Sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
        const Dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
        const Cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
        const Normalise = (a) => { const l = Math.hypot(a[0], a[1], a[2]) || 1.0; return [a[0] / l, a[1] / l, a[2] / l]; };
        const forward = Normalise(Sub(this.Target, eye));
        const right   = Normalise(Cross(forward, [0, 0, 1]));
        const up      = Cross(right, forward);

        const fovY   = 45.0 * Math.PI / 180.0;
        const tanHalf = Math.tan(fovY * 0.5);
        const aspect = T.Width / T.Height;
        const near = 0.05, far = 60.0;
        const f = new Float32Array(ViewFloats);
        const u = new Uint32Array(f.buffer);

        // View (column-major): rows are right, up, −forward.
        f.set([right[0], up[0], -forward[0], 0,
               right[1], up[1], -forward[1], 0,
               right[2], up[2], -forward[2], 0,
               -Dot(right, eye), -Dot(up, eye), Dot(forward, eye), 1], 0);
        // Projection, clip z ∈ [0, 1].
        const A = far / (near - far), B = near * far / (near - far);
        f.set([1 / (tanHalf * aspect), 0, 0, 0,
               0, 1 / tanHalf, 0, 0,
               0, 0, A, -1,
               0, 0, B, 0], 16);
        f.set([eye[0], eye[1], eye[2], tanHalf], 32);
        f.set([right[0], right[1], right[2], aspect], 36);
        f.set([up[0], up[1], up[2], this.Tuning.SpriteRadiusCells * s.CellSize], 40);
        f.set([forward[0], forward[1], forward[2], this.Tuning.WhiteSpeed], 44);
        f.set([s.BoxExtent[0], s.BoxExtent[1], s.BoxExtent[2], s.CellSize], 48);
        f.set([s.BoxOrigin[0], s.BoxOrigin[1], s.BoxOrigin[2], this.Scale], 52);
        const delta = this.Tuning.DeltaCells * s.CellSize;
        f.set([this.Tuning.SigmaCells * s.CellSize, delta, this.Tuning.MuFraction * delta, this.Tuning.MaxKernelPixels], 56);
        f.set([...this.Tuning.Absorption, this.Tuning.Refraction], 60);
        const sun = Normalise(this.Tuning.Sun);
        f.set([sun[0], sun[1], sun[2], 0], 64);
        f.set([T.Width, T.Height, 1 / T.Width, 1 / T.Height], 68);
        u.set([this.Mode, tick >>> 0, 0, 0], 72);
        this.Device.queue.writeBuffer(this.ViewConstants, 0, f);
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                     PRESENT
    //--------------------------------------------------------------------------------------------------------------------

    // `context` is a GPUCanvasContext, or any object with getCurrentTexture() (an offscreen texture in the harness).
    Present(encoder, context, tick, metrics)
    {
        this.EnsureTargets();
        this.WriteView(tick);
        const T = this.Targets;
        const N = this.Scene.ParticleCount;

        {
            const raster = encoder.beginRenderPass({
                label: "BackgroundRaster", timestampWrites: metrics?.Slot("Background"),
                colorAttachments: [
                    { view: T.BackgroundColourView,   loadOp: "clear", storeOp: "store", clearValue: { r: 0, g: 0, b: 0, a: 1 } },
                    { view: T.BackgroundDistanceView, loadOp: "clear", storeOp: "store", clearValue: { r: 1.0e9, g: 0, b: 0, a: 0 } },
                ],
            });
            raster.setPipeline(this.Background);
            raster.setBindGroup(0, this.ViewGroup);
            raster.draw(3);
            raster.end();
        }
        {
            const raster = encoder.beginRenderPass({
                label: "SpriteRaster", timestampWrites: metrics?.Slot("Sprites"),
                colorAttachments: [
                    { view: T.SpriteDistanceView, loadOp: "clear", storeOp: "store", clearValue: { r: 1.0e9, g: 0, b: 0, a: 0 } },
                    { view: T.SpriteNormalView,   loadOp: "clear", storeOp: "store", clearValue: { r: 0, g: 0, b: 1, a: 0 } },
                ],
                depthStencilAttachment: { view: T.DepthView, depthClearValue: 1.0, depthLoadOp: "clear", depthStoreOp: "store" },
            });
            raster.setPipeline(this.Sprite);
            raster.setBindGroup(0, this.ViewGroup);
            raster.setBindGroup(1, this.ParticleGroup);
            raster.draw(6, N);
            raster.end();
        }
        {
            const raster = encoder.beginRenderPass({
                label: "ThicknessRaster", timestampWrites: metrics?.Slot("Thickness"),
                colorAttachments: [{ view: T.ThicknessView, loadOp: "clear", storeOp: "store", clearValue: { r: 0, g: 0, b: 0, a: 0 } }],
            });
            raster.setPipeline(this.Thickness);
            raster.setBindGroup(0, this.ViewGroup);
            raster.setBindGroup(1, this.ParticleGroup);
            raster.draw(6, N);
            raster.end();
        }

        let shadeGroup = T.ShadeRaw;
        const iterations = (this.Mode === 1) ? 0 : this.SmoothIterations;
        if (iterations > 0)
        {
            const Form = (label, group, target) =>
            {
                const raster = encoder.beginRenderPass({
                    label, timestampWrites: metrics?.Slot("Smooth"),
                    colorAttachments: [{ view: target, loadOp: "clear", storeOp: "store", clearValue: { r: 1.0e9, g: 0, b: 0, a: 0 } }],
                });
                raster.setPipeline(this.Smooth);
                raster.setBindGroup(0, this.ViewGroup);
                raster.setBindGroup(1, group);
                raster.draw(3);
                raster.end();
            };
            for (let i = 0; i < iterations; i++)
            {
                Form("SmoothH", i === 0 ? T.SmoothRawH : T.SmoothBH, T.SmoothAView);
                Form("SmoothV", T.SmoothAV, T.SmoothBView);
            }
            Form("SmoothC", T.SmoothBC, T.SmoothAView);
            shadeGroup = T.ShadeA;
        }

        {
            const raster = encoder.beginRenderPass({
                label: "ShadeRaster", timestampWrites: metrics?.Slot("Shade"),
                colorAttachments: [{ view: context.getCurrentTexture().createView(), loadOp: "clear", storeOp: "store", clearValue: { r: 0, g: 0, b: 0, a: 1 } }],
            });
            raster.setPipeline(this.Shade);
            raster.setBindGroup(0, this.ViewGroup);
            raster.setBindGroup(1, shadeGroup);
            raster.draw(3);
            raster.end();
        }
    }

    Destroy()
    {
        this.DestroyTargets();
        this.ViewConstants.destroy();
        for (const b of Object.values(this.SmoothConstants))
        {
            b.destroy();
        }
    }
}
