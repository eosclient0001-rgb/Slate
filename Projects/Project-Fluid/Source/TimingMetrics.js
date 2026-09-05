//============================================================================================================================================
// 📦 Frontier/Projects/Project-Fluid/Source/TimingMetrics.js — GPU Timestamp Telemetry (per-pass durations, rolling averages, CSV)
//============================================================================================================================================
//
//    Wraps the WebGPU "timestamp-query" feature: every GPU dispatch that asks for a Slot(label) gets a begin/end timestamp
//    pair; after the submit the pairs are resolved, copied to a mappable block and folded into rolling sums per label.
//    If the adapter lacks the feature (or the browser quantises it — Chrome rounds to 100 µs unless developer features
//    are on) the host still gets wall-clock tick times from performance.now(), so the page never depends on the feature.
//
//    Units: nanoseconds on the GPU, reported in milliseconds.

const MaxSlots = 256;   // per-kernel timing at 12 sub-steps × 2 iterations × 5 kernels needs 120 + presentation

export class TimingMetrics
{
    constructor(device, enabled)
    {
        this.Device   = device;
        this.Enabled  = enabled;
        this.PerKernel = false;
        this.Labels   = [];
        this.Sums     = new Map();      // label → { Total [ms], Count, Last [ms] }
        this.Ticks    = 0;
        this.Busy     = false;          // resolve + copy recorded, readback not yet folded
        this.Mapping  = false;          // mapAsync in flight
        this.WallLast = 0.0;            // [ms] last frame wall time
        this.WallAverage = 0.0;         // [ms] exponential average
        if (enabled)
        {
            this.QuerySet = device.createQuerySet({ type: "timestamp", count: MaxSlots * 2 });
            this.Resolve  = device.createBuffer({ size: MaxSlots * 16, usage: GPUBufferUsage.QUERY_RESOLVE | GPUBufferUsage.COPY_SRC });
            this.Staging  = device.createBuffer({ size: MaxSlots * 16, usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST });
        }
    }

    Begin()
    {
        this.Labels.length = 0;
        this.Overflow = false;
    }

    // timestampWrites descriptor for one pass, or undefined when disabled / out of slots / previous readback pending.
    Slot(label)
    {
        if (!this.Enabled || this.Busy)
        {
            return undefined;
        }
        if (this.Labels.length >= MaxSlots)
        {
            this.Overflow = true;
            return undefined;
        }
        const index = this.Labels.length;
        this.Labels.push(label);
        return { querySet: this.QuerySet, beginningOfPassWriteIndex: index * 2, endOfPassWriteIndex: index * 2 + 1 };
    }

    // Append resolve + copy to the encoder (before submit).
    End(encoder)
    {
        if (!this.Enabled || this.Busy || this.Labels.length === 0)
        {
            return;
        }
        encoder.resolveQuerySet(this.QuerySet, 0, this.Labels.length * 2, this.Resolve, 0);
        encoder.copyBufferToBuffer(this.Resolve, 0, this.Staging, 0, this.Labels.length * 16);
        this.Busy = true;
        this.PendingLabels = this.Labels.slice();
    }

    // Fold the readback into the sums (after submit; awaits the map). Idempotent while a map is pending.
    async Collect()
    {
        if (!this.Busy || this.Mapping)
        {
            return;
        }
        this.Mapping = true;
        const labels = this.PendingLabels;
        try
        {
            await this.Staging.mapAsync(GPUMapMode.READ);
        }
        catch (error)
        {
            this.Mapping = false;
            this.Busy = false;
            return;
        }
        const stamps = new BigUint64Array(this.Staging.getMappedRange(0, labels.length * 16));
        for (let i = 0; i < labels.length; i++)
        {
            const begin = stamps[i * 2];
            const end   = stamps[i * 2 + 1];
            const ms    = end >= begin ? Number(end - begin) * 1.0e-6 : 0.0;
            const entry = this.Sums.get(labels[i]) ?? { Total: 0.0, Count: 0, Last: 0.0 };
            entry.Total += ms;
            entry.Count += 1;
            entry.Last   = ms;
            this.Sums.set(labels[i], entry);
        }
        this.Staging.unmap();
        this.Mapping = false;
        this.Busy = false;
    }

    RecordWall(ms)
    {
        this.WallLast    = ms;
        this.WallAverage = this.Ticks === 0 ? ms : this.WallAverage * 0.95 + ms * 0.05;
        this.Ticks++;
    }

    // Cost of a label per tick since the last Reset (a sub-stepped kernel appears subSteps times per tick, so the
    // per-tick cost is Total / Ticks, not Total / Count).
    PerTick(label)
    {
        const entry = this.Sums.get(label);
        return entry && this.Ticks > 0 ? entry.Total / this.Ticks : NaN;
    }

    Reset()
    {
        this.Sums.clear();
        this.Ticks = 0;
    }

    Rows()
    {
        const rows = [];
        for (const [label, entry] of this.Sums)
        {
            rows.push({ Label: label, PerTick: this.Ticks > 0 ? entry.Total / this.Ticks : NaN, PerCall: entry.Total / entry.Count, Calls: entry.Count });
        }
        return rows;
    }

    Csv()
    {
        const lines = ["label,ms_per_tick,ms_per_call,calls"];
        for (const row of this.Rows())
        {
            lines.push(`${row.Label},${row.PerTick.toFixed(4)},${row.PerCall.toFixed(4)},${row.Calls}`);
        }
        lines.push(`wall,${this.WallAverage.toFixed(4)},,${this.Ticks}`);
        return lines.join("\n");
    }
}
