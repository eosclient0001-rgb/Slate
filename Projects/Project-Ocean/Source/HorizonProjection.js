//============================================================================================================================================
// 📦 Frontier/Projects/Project-Ocean/Source/HorizonProjection.js — Ocean Renderer Host (camera, warped grid, sky, band-fade constants)
//============================================================================================================================================
//
//    Draws the sea SwellSolver simulates: a sky triangle first, then one camera-centred grid of (G+1)² vertices generated in
//    the vertex shader (see HorizonProjection.wgsl). The grid is warped exponentially so cells are Cell metres wide at the
//    camera and reach Range metres at the rim; α and A solve A·α = Cell·G/2 and A·(e^α − 1) = Range each frame.
//
//    Camera: first person at (X, Y, Height) with yaw/pitch; drag to look, wheel to change height (1.5 m … 2000 m), arrow keys
//    or WASD to sail. Reversed-Z (depth32float, compare "greater") with an infinite far plane — no z-fighting at 20 km.
//    Vertical field of view 55°. Units: metres, radians; RH +Z-up.

const ViewBytes = 224;

export class HorizonProjection
{
    static async Create(device, canvas, format)
    {
        const [shared, code] = await Promise.all(["SeaStructure", "HorizonProjection"].map(async name =>
        {
            const source = await fetch(new URL(`./Shaders/${name}.wgsl`, import.meta.url));
            if (!source.ok)
            {
                throw new Error(`HorizonProjection: cannot load ${name}.wgsl (${source.status})`);
            }
            return source.text();
        }));
        return new HorizonProjection(device, canvas, format, shared + "\n" + code);
    }

    constructor(device, canvas, format, code)
    {
        this.Device = device;
        this.Canvas = canvas;
        this.Format = format;
        this.View   = 0;                                   // 0 shaded · 1 foam · 2 Jacobian · 3 band weights · 4 speed
        this.Camera = { X: 0.0, Y: 0.0, Height: 6.0, Yaw: 0.0, Pitch: -0.1, Fov: 55.0 * Math.PI / 180.0 };
        this.Exposure = 1.0;
        this.Range = 20000.0;                              // [m] grid rim (the haze hides it)
        this.Depth = null;

        const module = device.createShaderModule({ label: "HorizonProjection", code });
        const V = GPUShaderStage.VERTEX, F = GPUShaderStage.FRAGMENT;
        this.Layout = device.createBindGroupLayout({
            label: "HorizonLayout",
            entries: [
                { binding: 0, visibility: V | F, buffer: { type: "uniform" } },
                { binding: 1, visibility: V | F, buffer: { type: "uniform" } },
                { binding: 2, visibility: V | F, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 3, visibility: V | F, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 4, visibility: V | F, texture: { sampleType: "float", viewDimension: "2d-array" } },
                { binding: 5, visibility: V | F, sampler: { type: "filtering" } },
                { binding: 6, visibility: F, texture: { sampleType: "float" } },
                { binding: 7, visibility: F, sampler: { type: "filtering" } },
            ],
        });
        const layout = device.createPipelineLayout({ bindGroupLayouts: [this.Layout] });
        this.SkyRaster = device.createRenderPipeline({
            label: "SkyRaster", layout,
            vertex: { module, entryPoint: "SkyVertex" },
            fragment: { module, entryPoint: "SkyFragment", targets: [{ format }] },
            primitive: { topology: "triangle-list" },
            depthStencil: { format: "depth32float", depthWriteEnabled: false, depthCompare: "always" },
        });
        this.SurfaceRaster = device.createRenderPipeline({
            label: "SurfaceRaster", layout,
            vertex: { module, entryPoint: "SurfaceVertex" },
            fragment: { module, entryPoint: "SurfaceFragment", targets: [{ format }] },
            primitive: { topology: "triangle-strip", stripIndexFormat: "uint32", cullMode: "none" },
            depthStencil: { format: "depth32float", depthWriteEnabled: true, depthCompare: "greater" },
        });
        this.ViewConstants = device.createBuffer({ label: "ViewConstants", size: ViewBytes, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
        this.Groups = null;
    }

    // Binds the solver's textures (two groups: the foam window ping-pongs).
    AttachSea(sea, solver, grid, cell)
    {
        this.Sea = sea;
        this.Solver = solver;
        this.Grid = grid;
        this.Cell = cell;
        this.Groups = [0, 1].map(i => this.Device.createBindGroup({
            label: `HorizonGroup${i}`, layout: this.Layout,
            entries: [
                { binding: 0, resource: { buffer: solver.Constants } },
                { binding: 1, resource: { buffer: this.ViewConstants } },
                { binding: 2, resource: solver.DisplacementView },
                { binding: 3, resource: solver.DerivativeView },
                { binding: 4, resource: solver.MotionView },
                { binding: 5, resource: solver.Wrap },
                { binding: 6, resource: solver.FoamViews[i] },
                { binding: 7, resource: solver.Clamp },
            ],
        }));
        // Triangle strips, one per grid row, joined by primitive restart.
        const columns = grid + 1;
        const indices = new Uint32Array(grid * (2 * columns + 1));
        let n = 0;
        for (let y = 0; y < grid; y++)
        {
            for (let x = 0; x < columns; x++)
            {
                indices[n++] = (y + 1) * columns + x;
                indices[n++] = y * columns + x;
            }
            indices[n++] = 0xffffffff;
        }
        this.Indices?.destroy();
        this.Indices = this.Device.createBuffer({ label: "GridIndices", size: indices.byteLength, usage: GPUBufferUsage.INDEX | GPUBufferUsage.COPY_DST });
        this.Device.queue.writeBuffer(this.Indices, 0, indices);
        this.IndexCount = indices.length;
        this.Camera.Height = sea.Camera.Height;
        this.Camera.Pitch  = sea.Camera.Pitch;
        this.Camera.Yaw    = sea.Camera.Yaw;
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                      CAMERA
    //--------------------------------------------------------------------------------------------------------------------

    // Unit basis of the camera: forward from yaw (about +Z, from +X) and pitch (positive up).
    Basis()
    {
        const c = this.Camera;
        const cp = Math.cos(c.Pitch), sp = Math.sin(c.Pitch);
        const forward = [Math.cos(c.Yaw) * cp, Math.sin(c.Yaw) * cp, sp];
        const right   = [Math.sin(c.Yaw), -Math.cos(c.Yaw), 0.0];
        const up      = [-Math.cos(c.Yaw) * sp, -Math.sin(c.Yaw) * sp, cp];
        return { Eye: [c.X, c.Y, c.Height], Forward: forward, Right: right, Up: up };
    }

    // Moves the camera along its horizontal heading: ahead [m] and sideways [m].
    Sail(ahead, sideways)
    {
        const c = this.Camera;
        c.X += Math.cos(c.Yaw) * ahead + Math.sin(c.Yaw) * sideways;
        c.Y += Math.sin(c.Yaw) * ahead - Math.cos(c.Yaw) * sideways;
    }

    // Column-major reversed-Z infinite perspective × view, for WGSL mat4x4f.
    ViewProjection(basis, aspect)
    {
        const f = 1.0 / Math.tan(0.5 * this.Camera.Fov);
        const near = 0.05;
        const rows = [
            [...basis.Right.map(v => v * f / aspect), -Dot(basis.Right, basis.Eye) * f / aspect],
            [...basis.Up.map(v => v * f), -Dot(basis.Up, basis.Eye) * f],
            [0.0, 0.0, 0.0, near],
            [...basis.Forward, -Dot(basis.Forward, basis.Eye)],
        ];
        const m = new Float32Array(16);
        for (let col = 0; col < 4; col++)
        {
            for (let row = 0; row < 4; row++)
            {
                m[col * 4 + row] = rows[row][col];
            }
        }
        return m;
    }

    // Grid warp constants: solve A α = Cell G / 2 and A (e^α − 1) = Range for α (Newton on (e^α − 1)/α = Range / c).
    Warp()
    {
        const c = this.Cell * this.Grid * 0.5;
        const target = Math.max(this.Range, 50.0 * this.Camera.Height) / c;
        let alpha = Math.log(target + 1.0);
        for (let i = 0; i < 12; i++)
        {
            const e = Math.exp(alpha);
            const f = (e - 1.0) / alpha - target;
            const df = (e * alpha - (e - 1.0)) / (alpha * alpha);
            alpha -= f / df;
            alpha = Math.max(alpha, 1.0e-3);
        }
        return { Alpha: alpha, A: c / alpha };
    }

    //--------------------------------------------------------------------------------------------------------------------
    //                                                      PRESENT
    //--------------------------------------------------------------------------------------------------------------------

    Present(encoder, context, metrics)
    {
        const canvas = this.Canvas, device = this.Device;
        const width = Math.max(8, canvas.width), height = Math.max(8, canvas.height);
        if (!this.Depth || this.Depth.width !== width || this.Depth.height !== height)
        {
            this.Depth?.destroy();
            this.Depth = device.createTexture({ label: "Depth", size: [width, height], format: "depth32float", usage: GPUTextureUsage.RENDER_ATTACHMENT });
            this.DepthView = this.Depth.createView();
        }
        const basis = this.Basis();
        const warp = this.Warp();
        const sea = this.Sea, spectrum = this.Solver.Spectrum;
        const centre = [Math.round(this.Camera.X / this.Cell) * this.Cell, Math.round(this.Camera.Y / this.Cell) * this.Cell];
        const sun = [Math.cos(sea.Sun.Elevation) * Math.cos(sea.Sun.Azimuth), Math.cos(sea.Sun.Elevation) * Math.sin(sea.Sun.Azimuth), Math.sin(sea.Sun.Elevation)];
        const pixelAngle = this.Camera.Fov / height;
        const tanHalf = Math.tan(0.5 * this.Camera.Fov);
        const words = new Float32Array(ViewBytes / 4);
        words.set(this.ViewProjection(basis, width / height), 0);
        words.set([...basis.Eye, 0.0], 16);
        words.set([...sun, 1.0], 20);
        words.set([this.Grid, this.Cell, warp.A, warp.Alpha], 24);
        words.set([pixelAngle, this.View, 1.0, 4.0 * Math.sqrt(spectrum.Total)], 28);
        words.set([centre[0], centre[1], Math.max(6000.0, 20.0 * this.Camera.Height), this.Exposure], 32);
        for (let b = 0; b < 4; b++)
        {
            words[36 + b] = b < sea.BandCount ? 2.0 * spectrum.Slope[b] : 0.0;
            words[40 + b] = b < sea.BandCount ? spectrum.LambdaMin[b] : 1.0e9;
        }
        words.set([...basis.Right, tanHalf * width / height], 44);
        words.set([...basis.Up, tanHalf], 48);
        words.set([...basis.Forward, 0.0], 52);
        device.queue.writeBuffer(this.ViewConstants, 0, words);

        const pass = encoder.beginRenderPass({
            label: "Horizon",
            colorAttachments: [{ view: context.getCurrentTexture().createView(), clearValue: { r: 0, g: 0, b: 0, a: 1 }, loadOp: "clear", storeOp: "store" }],
            depthStencilAttachment: { view: this.DepthView, depthClearValue: 0.0, depthLoadOp: "clear", depthStoreOp: "discard" },
            timestampWrites: metrics.Slot("Render"),
        });
        const group = this.Groups[this.Solver.FoamIndex];
        pass.setBindGroup(0, group);
        pass.setPipeline(this.SkyRaster);
        pass.draw(3);
        pass.setPipeline(this.SurfaceRaster);
        pass.setIndexBuffer(this.Indices, "uint32");
        pass.drawIndexed(this.IndexCount);
        pass.end();
    }
}

function Dot(a, b)
{
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
