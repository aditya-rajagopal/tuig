const std = @import("std");
const assert = std.debug.assert;

const bench_catalog = @import("bench_catalog.zig");
const pmc = @import("pmc/root.zig");
const renderer = @import("renderer");
const stats = @import("stats.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");

const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

pub const BenchMode = enum {
    full_redraw,
    diff_redraw,
    print,
    print_assume_no_grapheme,
};

pub const MicrobenchResult = struct {
    timing: stats.Stats,
    pmc_stats: PmcStats,
    resources: ResourceStats,
    fault_stats: FaultStats,
    bytes_total: u64,
    bytes_mean: f64,
    dirty_ratio_mean: f64,
    style_runs_mean: f64,
};

pub const PmcStats = struct {
    cycles: ?stats.Stats,
    instructions: ?stats.Stats,
    events: [pmc.MaxEvents]?stats.Stats,
};

pub const FaultStats = struct {
    minor: ?stats.Stats,
    major: ?stats.Stats,
};

pub const PmcSamples = struct {
    active: bool,
    allocated: bool,
    cycles: []u64,
    instructions: []u64,
    events: [pmc.MaxEvents][]u64,
    has_cycles: bool,
    has_instructions: bool,
    has_events: [pmc.MaxEvents]bool,

    pub fn init(allocator: std.mem.Allocator, active: bool, sample_count: usize) !PmcSamples {
        var samples = PmcSamples{
            .active = active,
            .allocated = false,
            .cycles = &.{},
            .instructions = &.{},
            .events = undefined,
            .has_cycles = false,
            .has_instructions = false,
            .has_events = .{ false, false, false, false },
        };

        if (!active or sample_count == 0) {
            samples.events = .{ &.{}, &.{}, &.{}, &.{} };
            return samples;
        }

        samples.cycles = try allocator.alignedAlloc(u64, buffer_alignment, sample_count);
        samples.instructions = try allocator.alignedAlloc(u64, buffer_alignment, sample_count);
        var i: usize = 0;
        while (i < pmc.MaxEvents) : (i += 1) {
            samples.events[i] = try allocator.alignedAlloc(u64, buffer_alignment, sample_count);
        }
        samples.allocated = true;
        return samples;
    }

    pub fn deinit(self: *PmcSamples, allocator: std.mem.Allocator) void {
        if (!self.allocated) return;
        allocator.free(self.cycles);
        allocator.free(self.instructions);
        for (self.events) |event_samples| {
            allocator.free(event_samples);
        }
    }

    pub fn record(self: *PmcSamples, index: usize, snapshot: pmc.Result) void {
        if (!self.active or !self.allocated) return;
        if (snapshot.cycles) |value| {
            self.cycles[index] = value;
            self.has_cycles = true;
        } else {
            self.cycles[index] = 0;
        }

        if (snapshot.instructions) |value| {
            self.instructions[index] = value;
            self.has_instructions = true;
        } else {
            self.instructions[index] = 0;
        }

        for (snapshot.events, 0..) |event, idx| {
            if (event.value) |value| {
                self.events[idx][index] = value;
                self.has_events[idx] = true;
            } else {
                self.events[idx][index] = 0;
            }
        }
    }

    pub fn computeStats(self: *PmcSamples, scratch: []u64) PmcStats {
        var result = PmcStats{ .cycles = null, .instructions = null, .events = .{ null, null, null, null } };
        if (!self.active or !self.allocated or self.cycles.len == 0) return result;

        if (self.has_cycles) {
            result.cycles = stats.computeStats(self.cycles, scratch);
        }
        if (self.has_instructions) {
            result.instructions = stats.computeStats(self.instructions, scratch);
        }
        var i: usize = 0;
        while (i < pmc.MaxEvents) : (i += 1) {
            if (self.has_events[i]) {
                result.events[i] = stats.computeStats(self.events[i], scratch);
            }
        }
        return result;
    }
};

pub const ResourceSamples = struct {
    active: bool,
    allocated: bool,
    minor_faults: []u64,
    major_faults: []u64,

    pub fn init(allocator: std.mem.Allocator, sample_count: usize) !ResourceSamples {
        var samples = ResourceSamples{
            .active = sample_count > 0,
            .allocated = false,
            .minor_faults = &.{},
            .major_faults = &.{},
        };

        if (sample_count == 0) return samples;

        samples.minor_faults = try allocator.alignedAlloc(u64, buffer_alignment, sample_count);
        samples.major_faults = try allocator.alignedAlloc(u64, buffer_alignment, sample_count);
        samples.allocated = true;
        return samples;
    }

    pub fn deinit(self: *ResourceSamples, allocator: std.mem.Allocator) void {
        if (!self.allocated) return;
        allocator.free(self.minor_faults);
        allocator.free(self.major_faults);
    }

    pub fn record(self: *ResourceSamples, index: usize, prev: std.posix.rusage, curr: std.posix.rusage) void {
        if (!self.active or !self.allocated) return;

        const minflt_prev = @as(i64, @intCast(prev.minflt));
        const minflt_curr = @as(i64, @intCast(curr.minflt));
        const majflt_prev = @as(i64, @intCast(prev.majflt));
        const majflt_curr = @as(i64, @intCast(curr.majflt));

        assert(minflt_curr >= minflt_prev);
        assert(majflt_curr >= majflt_prev);

        self.minor_faults[index] = @as(u64, @intCast(minflt_curr - minflt_prev));
        self.major_faults[index] = @as(u64, @intCast(majflt_curr - majflt_prev));
    }

    pub fn computeStats(self: *ResourceSamples, scratch: []u64) FaultStats {
        var result = FaultStats{ .minor = null, .major = null };
        if (!self.active or !self.allocated) return result;

        if (self.minor_faults.len > 0) {
            result.minor = stats.computeStats(self.minor_faults, scratch);
            result.major = stats.computeStats(self.major_faults, scratch);
        }
        return result;
    }
};

pub const ResourceStats = struct {
    cpu_time_ns: u64,
    cpu_user_ns: u64,
    cpu_sys_ns: u64,
    page_faults_minor: u64,
    page_faults_major: u64,
    max_rss_bytes: u64,
};

pub const StatField = enum { min, median, p95, max, mean };

pub const MicrobenchConfig = struct {
    mode: BenchMode,
    frames_total: u64,
    warmup_frames: u64,
    seed: u64,
    cols: u16,
    rows: u16,
    dataset: bench_catalog.DatasetSpec,
    text_mix: text_mix.TextMix,
    style_mix: style_mix.StyleMix,
};

pub const PrintBenchConfig = struct {
    mode: BenchMode,
    frames_total: u64,
    warmup_frames: u64,
    seed: u64,
    cols: u16,
    rows: u16,
    dataset: bench_catalog.PrintDatasetSpec,
    text_mix: text_mix.TextMix,
    style_mix: style_mix.StyleMix,
};

pub const Buffer = struct {
    fb: renderer.FrameBuffer,
    cells: []align(std.heap.page_size_min) renderer.Cell,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const cell_count = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alignedAlloc(renderer.Cell, buffer_alignment, cell_count);
        var fb = try renderer.FrameBuffer.init(cells, width, height, .default);
        fb.clear();
        return .{ .fb = fb, .cells = cells };
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.fb.deinit();
        allocator.free(self.cells);
    }
};
