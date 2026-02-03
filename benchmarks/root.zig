const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const parseArgs = stdx.parseArgs;

const csv = @import("csv.zig");
const reporting = @import("reporting.zig");
const bench_catalog = @import("bench_catalog.zig");
const inspect = @import("inspect.zig");
const print_helpers = @import("print_helpers.zig");
const stats = @import("stats.zig");
const timer = @import("timer.zig");
const pmc = @import("pmc/root.zig");
const renderer = @import("renderer");
const terminal_mod = @import("terminal");
const patterns = @import("patterns.zig");
const rng = @import("rng.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");
const ui = @import("ui.zig");

const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

const default_frames_total: u64 = 10_000;
const default_warmup_frames: u64 = 1_000;
const default_seed: u64 = 0;
const default_cols: u32 = 200;
const default_rows: u32 = 60;
const default_mode: BenchmarkMode = .dummy;
const default_dataset: Dataset = .typical_app_panel_swap;
const default_text_mix: TextMix = .common;
const default_style_mix: StyleMix = .flat;
const workload_buffer_len_default: usize = 1 << 20;
const workload_buffer_len_pmc: usize = 1 << 23;
const workload_iterations: usize = 1024;

const Config = struct {
    frames_total: u64,
    warmup_frames: u64,
    seed: u64,
    cols: u32,
    rows: u32,
    enable_pmc: bool,
    enable_e2e: bool,
    mode: BenchmarkMode,
    dataset: Dataset,
    text_mix: TextMix,
    style_mix: StyleMix,
    inspect: bool,
    csv_path: ?[]const u8,
};

const BenchmarkMode = enum {
    dummy,
    full_redraw,
    diff_redraw,
    print,
    print_assume_no_grapheme,
};

const Dataset = enum {
    typical_app_panel_swap,
    typical_app_cursor_moves,
    unicode_stress_width_churn,
    unicode_stress_style_flicker,
    unicode_dynamic_rect_churn,
    all,
};

const TextMix = enum {
    common,
    grapheme_stress,
    all,
};

const StyleMix = enum {
    flat,
    themed,
    churn,
    all,
};

const CLIArgs = struct {
    mode: BenchmarkMode = default_mode,
    dataset: ?Dataset = null,
    text_mix: TextMix = default_text_mix,
    style_mix: StyleMix = default_style_mix,
    e2e: bool = false,
    inspect: bool = false,
    csv: ?[]const u8 = null,
    frames: u64 = default_frames_total,
    warmup: u64 = default_warmup_frames,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
    seed: u64 = default_seed,
    pmc: bool = false,

    pub const help =
        \\TUIG benchmark
        \\
        \\Usage:
        \\  zig build benchmark -- [options]
        \\
        \\Options:
        \\  --mode=<dummy|full_redraw|diff_redraw|print|print_assume_no_grapheme>
        \\  --dataset=<typical_app_panel_swap|typical_app_cursor_moves|unicode_stress_width_churn|unicode_stress_style_flicker|unicode_dynamic_rect_churn|all>
        \\  --text-mix=<common|grapheme_stress|all>
        \\  --style-mix=<flat|themed|churn|all>
        \\  --e2e
        \\  --inspect
        \\  --csv=<path>
        \\  --frames=<N>
        \\  --warmup=<N>
        \\  --cols=<N>
        \\  --rows=<N>
        \\  --seed=<N>
        \\  --pmc
        \\  --help
        \\
        \\Mode details:
        \\  dummy                  Synthetic workload only (timing/PMC sanity check).
        \\  full_redraw            Render and emit a full frame each iteration.
        \\  diff_redraw            Render, diff with previous, emit only changed cells.
        \\  print                  Print full frame with grapheme-aware path.
        \\  print_assume_no_grapheme  Print full frame assuming no grapheme clusters.
        \\
        \\Dataset details (render modes):
        \\  typical_app_panel_swap       Typical UI with panel swap updates.
        \\  typical_app_cursor_moves     Typical UI with single-cell cursor moves.
        \\  unicode_stress_width_churn   Unicode text with width churn updates.
        \\  unicode_stress_style_flicker Unicode text with style-only flicker.
        \\  unicode_dynamic_rect_churn   Dynamic layout with random rect churn.
        \\
        \\Dataset details (print modes):
        \\  scissor-small                Print into 20x6 scissor.
        \\  scissor-large                Print into 40x12 scissor.
        \\  scissor-out-of-bounds        Print into 40x12 scissor with negative origin.
        \\  (print modes ignore --dataset; all three run automatically)
        \\
        \\Text mix details:
        \\  common               70% ASCII, 20% mixed Unicode, 10% wide.
        \\  grapheme_stress      50% ASCII, 20% mixed Unicode, 20% ZWJ, 10% combining.
        \\
        \\Style mix details:
        \\  flat                  Single style.
        \\  themed                5-8 styles, longer runs.
        \\  churn                 Mixed short runs, longer runs, and reverse/bold bursts.
        \\
        \\Matrix runs:
        \\  Render modes: use 'all' for dataset/text-mix/style-mix to run every option.
        \\  Render modes default to dataset=all when --dataset is omitted.
        \\  Print modes: dataset is fixed to scissor-small/large/out-of-bounds.
        \\
        \\Examples:
        \\  zig build benchmark -- --mode=full_redraw --dataset=typical_app_panel_swap
        \\  zig build benchmark -- --mode=diff_redraw --dataset=all
    ;
};

const DummyResult = struct {
    timing: stats.TimingStats,
    pmc_stats: PmcStats,
    resources: ResourceStats,
    fault_stats: FaultStats,
};

const MicrobenchResult = struct {
    timing: stats.TimingStats,
    pmc_stats: PmcStats,
    resources: ResourceStats,
    fault_stats: FaultStats,
    bytes_total: u64,
    bytes_mean: f64,
    dirty_ratio_mean: f64,
    style_runs_mean: f64,
};

const PmcStats = struct {
    cycles: ?stats.TimingStats,
    instructions: ?stats.TimingStats,
    events: [pmc.MaxEvents]?stats.TimingStats,
};

const FaultStats = struct {
    minor: ?stats.TimingStats,
    major: ?stats.TimingStats,
};

const PmcSamples = struct {
    active: bool,
    allocated: bool,
    cycles: []u64,
    instructions: []u64,
    events: [pmc.MaxEvents][]u64,
    event_names: [pmc.MaxEvents]?[]const u8,
    has_cycles: bool,
    has_instructions: bool,
    has_events: [pmc.MaxEvents]bool,

    fn init(allocator: std.mem.Allocator, active: bool, sample_count: usize) !PmcSamples {
        var samples = PmcSamples{
            .active = active,
            .allocated = false,
            .cycles = &.{},
            .instructions = &.{},
            .events = undefined,
            .event_names = .{ null, null, null, null },
            .has_cycles = false,
            .has_instructions = false,
            .has_events = .{ false, false, false, false },
        };

        if (!active or sample_count == 0) {
            samples.events = .{
                &.{},
                &.{},
                &.{},
                &.{},
            };
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

    fn deinit(self: *PmcSamples, allocator: std.mem.Allocator) void {
        if (!self.allocated) return;
        allocator.free(self.cycles);
        allocator.free(self.instructions);
        for (self.events) |event_samples| {
            allocator.free(event_samples);
        }
    }

    fn record(self: *PmcSamples, index: usize, snapshot: pmc.Result) void {
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
            if (event.name) |name| {
                if (self.event_names[idx] == null) self.event_names[idx] = name;
            }
            if (event.value) |value| {
                self.events[idx][index] = value;
                self.has_events[idx] = true;
            } else {
                self.events[idx][index] = 0;
            }
        }
    }

    fn computeStats(self: *PmcSamples, scratch: []u64) PmcStats {
        var result = PmcStats{
            .cycles = null,
            .instructions = null,
            .events = .{ null, null, null, null },
        };

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

const ResourceSamples = struct {
    active: bool,
    allocated: bool,
    minor_faults: []u64,
    major_faults: []u64,

    fn init(allocator: std.mem.Allocator, sample_count: usize) !ResourceSamples {
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

    fn deinit(self: *ResourceSamples, allocator: std.mem.Allocator) void {
        if (!self.allocated) return;
        allocator.free(self.minor_faults);
        allocator.free(self.major_faults);
    }

    fn record(self: *ResourceSamples, index: usize, prev: std.posix.rusage, curr: std.posix.rusage) void {
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

    fn computeStats(self: *ResourceSamples, scratch: []u64) FaultStats {
        var result = FaultStats{ .minor = null, .major = null };
        if (!self.active or !self.allocated) return result;

        if (self.minor_faults.len > 0) {
            result.minor = stats.computeStats(self.minor_faults, scratch);
            result.major = stats.computeStats(self.major_faults, scratch);
        }
        return result;
    }
};

const PmcStatField = enum { min, median, p95, max, mean };

fn pmcStatValue(stat: ?stats.TimingStats, field: PmcStatField) ?u64 {
    if (stat) |value| {
        return switch (field) {
            .min => value.min_ns,
            .median => value.median_ns,
            .p95 => value.p95_ns,
            .max => value.max_ns,
            .mean => value.mean_ns,
        };
    }
    return null;
}

fn faultStatValue(stat: ?stats.TimingStats, field: PmcStatField) ?u64 {
    if (stat) |value| {
        return switch (field) {
            .min => value.min_ns,
            .median => value.median_ns,
            .p95 => value.p95_ns,
            .max => value.max_ns,
            .mean => value.mean_ns,
        };
    }
    return null;
}

const ResourceStats = struct {
    cpu_time_ns: u64,
    cpu_user_ns: u64,
    cpu_sys_ns: u64,
    page_faults_minor: u64,
    page_faults_major: u64,
    max_rss_bytes: u64,
};

const DatasetSpec = bench_catalog.DatasetSpec;
const PrintDatasetSpec = bench_catalog.PrintDatasetSpec;
const dataset_typical_panel_swap = bench_catalog.dataset_typical_panel_swap;
const dataset_typical_cursor_moves = bench_catalog.dataset_typical_cursor_moves;
const dataset_unicode_width_churn = bench_catalog.dataset_unicode_width_churn;
const dataset_unicode_style_flicker = bench_catalog.dataset_unicode_style_flicker;
const dataset_unicode_dynamic_rect = bench_catalog.dataset_unicode_dynamic_rect;
const render_datasets = bench_catalog.render_datasets;
const print_datasets = bench_catalog.print_datasets;
const all_text_mixes = bench_catalog.all_text_mixes;
const all_style_mixes = bench_catalog.all_style_mixes;

const MicrobenchConfig = struct {
    mode: BenchmarkMode,
    frames_total: u64,
    warmup_frames: u64,
    seed: u64,
    cols: u16,
    rows: u16,
    dataset: DatasetSpec,
    text_mix: text_mix.TextMix,
    style_mix: style_mix.StyleMix,
};

const PrintBenchConfig = struct {
    mode: BenchmarkMode,
    frames_total: u64,
    warmup_frames: u64,
    seed: u64,
    cols: u16,
    rows: u16,
    dataset: PrintDatasetSpec,
    text_mix: text_mix.TextMix,
    style_mix: style_mix.StyleMix,
};

const Buffer = struct {
    fb: renderer.FrameBuffer,
    cells: []align(std.heap.page_size_min) renderer.Cell,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const cell_count = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alignedAlloc(renderer.Cell, buffer_alignment, cell_count);
        var fb = try renderer.FrameBuffer.init(cells, width, height, .default);
        fb.clear();
        return .{ .fb = fb, .cells = cells };
    }

    fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.fb.deinit();
        allocator.free(self.cells);
    }
};

const CountingWriter = struct {
    count: u64,
    downstream: *std.Io.Writer,
    writer: std.Io.Writer,

    fn init(downstream: *std.Io.Writer, buffer: []u8) CountingWriter {
        return .{
            .count = 0,
            .downstream = downstream,
            .writer = .{
                .vtable = &.{ .drain = CountingWriter.drain },
                .buffer = buffer,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CountingWriter = @alignCast(@fieldParentPtr("writer", w));
        if (w.end > 0) {
            try self.downstream.writeAll(w.buffer[0..w.end]);
            self.count += w.end;
            w.end = 0;
        }

        var written: usize = 0;
        const last_index = data.len - 1;
        for (data[0..last_index]) |bytes| {
            if (bytes.len == 0) continue;
            try self.downstream.writeAll(bytes);
            self.count += bytes.len;
            written += bytes.len;
        }

        const pattern = data[last_index];
        if (pattern.len > 0 and splat > 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                try self.downstream.writeAll(pattern);
            }
            const pattern_total = pattern.len * splat;
            self.count += pattern_total;
            written += pattern_total;
        }
        return written;
    }
};

var io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    io = threaded.ioBasic();

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    var args_iter = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args_iter.deinit();
    const cli = parseArgs(io, init.arena.allocator(), &args_iter, CLIArgs);

    var config = Config{
        .frames_total = cli.frames,
        .warmup_frames = cli.warmup,
        .seed = cli.seed,
        .cols = cli.cols,
        .rows = cli.rows,
        .enable_pmc = cli.pmc,
        .enable_e2e = cli.e2e,
        .mode = cli.mode,
        .dataset = cli.dataset orelse default_dataset,
        .text_mix = cli.text_mix,
        .style_mix = cli.style_mix,
        .inspect = cli.inspect,
        .csv_path = cli.csv,
    };
    normalizeConfig(&config);

    const mode = config.mode;
    const mode_label = @tagName(mode);
    if (cli.dataset == null and (mode == .full_redraw or mode == .diff_redraw)) {
        config.dataset = .all;
    }

    if (config.inspect) {
        const inspect_config = inspect.InspectConfig{
            .bench_mode = inspect.benchModeFromRoot(config.mode),
            .dataset_name = resolveDatasetSpec(config.dataset).name,
            .text_mix = resolveTextMix(config.text_mix),
            .style_mix = resolveStyleMix(config.style_mix),
            .seed = config.seed,
        };
        try inspect.runInspect(inspect_config);
        return;
    }

    var pmc_state = try pmc.Pmc.init(config.enable_pmc);
    defer pmc_state.deinit();
    const e2e_active = config.enable_e2e and (mode == .full_redraw or mode == .diff_redraw);
    var terminal: terminal_mod.Terminal = undefined;
    var terminal_active = false;
    const terminal_write_buffer: []align(std.heap.page_size_min) u8 = init.arena.allocator().alignedAlloc(u8, buffer_alignment, 4 * 4096) catch unreachable;
    if (e2e_active) {
        const term_config: terminal_mod.TerminalConfig = .{ .raw = true, .alt_screen = true, .cursor_visable = false };
        try terminal.init(term_config, terminal_write_buffer);
        terminal_active = true;
        config.cols = terminal.size.width;
        config.rows = terminal.size.height;
    }
    defer if (terminal_active) terminal.deinit();

    const csv_enabled = config.csv_path != null;
    var csv_file: ?std.Io.File = null;
    var csv_file_writer: ?std.Io.File.Writer = null;
    var csv_file_buffer: [8192]u8 = undefined;
    var csv_writer: *std.Io.Writer = stdout;
    const human_writer: ?*std.Io.Writer = stdout;
    var human_header_written = false;
    var csv_needs_header = true;

    if (config.csv_path) |path| {
        const dir = std.Io.Dir.cwd();
        var file = dir.openFile(io, path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, path, .{}),
            else => return err,
        };
        csv_file = file;
        const stat = try file.stat(io);
        csv_file_writer = file.writer(io, &csv_file_buffer);
        csv_writer = &csv_file_writer.?.interface;
        if (stat.size > 0) {
            csv_needs_header = false;
            try csv_file_writer.?.seekTo(stat.size);
        }
    }
    defer {
        if (csv_file_writer) |*writer| {
            writer.flush() catch {};
        }
        if (csv_file) |file| file.close(io);
    }

    var row_buffer: ?std.ArrayList(csv.Row) = null;
    if (e2e_active) {
        row_buffer = .empty;
    } else {
        if (csv_enabled and csv_needs_header) {
            try csv.writeHeader(csv_writer);
        }
        if (human_writer) |writer| {
            try reporting.writeHumanHeader(writer);
            human_header_written = true;
        }
    }

    switch (mode) {
        .dummy => {
            const timestamp_ns = nowTimestampNs();
            const result = try runDummyBenchmark(init.arena.allocator(), config, &pmc_state);
            const pmc_stats = result.pmc_stats;
            const row = csv.Row{
                .timestamp_ns = timestamp_ns,
                .mode = mode_label,
                .e2e = e2e_active,
                .dataset = null,
                .text_mix = null,
                .style_mix = null,
                .cols = null,
                .rows = null,
                .frames_total = config.frames_total,
                .warmup_frames = config.warmup_frames,
                .seed = config.seed,
                .time_min_ns = result.timing.min_ns,
                .time_median_ns = result.timing.median_ns,
                .time_p95_ns = result.timing.p95_ns,
                .time_max_ns = result.timing.max_ns,
                .time_mean_ns = result.timing.mean_ns,
                .cpu_time_ns = result.resources.cpu_time_ns,
                .cpu_user_ns = result.resources.cpu_user_ns,
                .cpu_sys_ns = result.resources.cpu_sys_ns,
                .page_faults_minor = result.resources.page_faults_minor,
                .page_faults_major = result.resources.page_faults_major,
                .page_faults_minor_min = faultStatValue(result.fault_stats.minor, .min),
                .page_faults_minor_median = faultStatValue(result.fault_stats.minor, .median),
                .page_faults_minor_p95 = faultStatValue(result.fault_stats.minor, .p95),
                .page_faults_minor_max = faultStatValue(result.fault_stats.minor, .max),
                .page_faults_minor_mean = faultStatValue(result.fault_stats.minor, .mean),
                .page_faults_major_min = faultStatValue(result.fault_stats.major, .min),
                .page_faults_major_median = faultStatValue(result.fault_stats.major, .median),
                .page_faults_major_p95 = faultStatValue(result.fault_stats.major, .p95),
                .page_faults_major_max = faultStatValue(result.fault_stats.major, .max),
                .page_faults_major_mean = faultStatValue(result.fault_stats.major, .mean),
                .max_rss_bytes = result.resources.max_rss_bytes,
                .bytes_total = null,
                .bytes_mean = null,
                .dirty_ratio_mean = null,
                .style_runs_mean = null,
                .pmc_cycles_min = pmcStatValue(pmc_stats.cycles, .min),
                .pmc_cycles_median = pmcStatValue(pmc_stats.cycles, .median),
                .pmc_cycles_p95 = pmcStatValue(pmc_stats.cycles, .p95),
                .pmc_cycles_max = pmcStatValue(pmc_stats.cycles, .max),
                .pmc_cycles_mean = pmcStatValue(pmc_stats.cycles, .mean),
                .pmc_instructions_min = pmcStatValue(pmc_stats.instructions, .min),
                .pmc_instructions_median = pmcStatValue(pmc_stats.instructions, .median),
                .pmc_instructions_p95 = pmcStatValue(pmc_stats.instructions, .p95),
                .pmc_instructions_max = pmcStatValue(pmc_stats.instructions, .max),
                .pmc_instructions_mean = pmcStatValue(pmc_stats.instructions, .mean),
                .pmc_cache_misses_min = pmcStatValue(pmc_stats.events[0], .min),
                .pmc_cache_misses_median = pmcStatValue(pmc_stats.events[0], .median),
                .pmc_cache_misses_p95 = pmcStatValue(pmc_stats.events[0], .p95),
                .pmc_cache_misses_max = pmcStatValue(pmc_stats.events[0], .max),
                .pmc_cache_misses_mean = pmcStatValue(pmc_stats.events[0], .mean),
                .pmc_cache_references_min = pmcStatValue(pmc_stats.events[1], .min),
                .pmc_cache_references_median = pmcStatValue(pmc_stats.events[1], .median),
                .pmc_cache_references_p95 = pmcStatValue(pmc_stats.events[1], .p95),
                .pmc_cache_references_max = pmcStatValue(pmc_stats.events[1], .max),
                .pmc_cache_references_mean = pmcStatValue(pmc_stats.events[1], .mean),
                .pmc_branches_min = pmcStatValue(pmc_stats.events[2], .min),
                .pmc_branches_median = pmcStatValue(pmc_stats.events[2], .median),
                .pmc_branches_p95 = pmcStatValue(pmc_stats.events[2], .p95),
                .pmc_branches_max = pmcStatValue(pmc_stats.events[2], .max),
                .pmc_branches_mean = pmcStatValue(pmc_stats.events[2], .mean),
                .pmc_branch_misses_min = pmcStatValue(pmc_stats.events[3], .min),
                .pmc_branch_misses_median = pmcStatValue(pmc_stats.events[3], .median),
                .pmc_branch_misses_p95 = pmcStatValue(pmc_stats.events[3], .p95),
                .pmc_branch_misses_max = pmcStatValue(pmc_stats.events[3], .max),
                .pmc_branch_misses_mean = pmcStatValue(pmc_stats.events[3], .mean),
            };
            if (row_buffer) |*rows| {
                try rows.append(init.arena.allocator(), row);
            } else {
                if (csv_enabled) {
                    try csv.writeRow(csv_writer, row);
                }
                if (human_writer) |writer| {
                    if (!human_header_written) {
                        try reporting.writeHumanHeader(writer);
                        human_header_written = true;
                    }
                    try reporting.writeHumanRow(writer, row);
                }
            }
        },
        .full_redraw, .diff_redraw => {
            const dataset_spec = resolveDatasetSpec(config.dataset);
            const mix_text = resolveTextMix(config.text_mix);
            const mix_style = resolveStyleMix(config.style_mix);

            var single_dataset = [_]DatasetSpec{dataset_spec};
            var single_text_mix = [_]text_mix.TextMix{mix_text};
            var single_style_mix = [_]style_mix.StyleMix{mix_style};

            const dataset_list = if (config.dataset == .all) render_datasets[0..] else single_dataset[0..];
            const text_mix_list = if (config.text_mix == .all) all_text_mixes[0..] else single_text_mix[0..];
            const style_mix_list = if (config.style_mix == .all) all_style_mixes[0..] else single_style_mix[0..];
            const terminal_ptr: ?*terminal_mod.Terminal = if (terminal_active) &terminal else null;

            for (dataset_list) |dataset_item| {
                for (text_mix_list) |text_mix_item| {
                    for (style_mix_list) |style_mix_item| {
                        const micro_config = MicrobenchConfig{
                            .mode = mode,
                            .frames_total = config.frames_total,
                            .warmup_frames = config.warmup_frames,
                            .seed = config.seed,
                            .cols = @intCast(config.cols),
                            .rows = @intCast(config.rows),
                            .dataset = dataset_item,
                            .text_mix = text_mix_item,
                            .style_mix = style_mix_item,
                        };
                        const timestamp_ns = nowTimestampNs();
                        const result = try runMicroBenchmark(init.arena.allocator(), micro_config, &pmc_state, terminal_ptr);
                        const pmc_stats = result.pmc_stats;
                        const row = csv.Row{
                            .timestamp_ns = timestamp_ns,
                            .mode = mode_label,
                            .e2e = e2e_active,
                            .dataset = dataset_item.name,
                            .text_mix = @tagName(text_mix_item),
                            .style_mix = @tagName(style_mix_item),
                            .cols = @as(u32, micro_config.cols),
                            .rows = @as(u32, micro_config.rows),
                            .frames_total = micro_config.frames_total,
                            .warmup_frames = micro_config.warmup_frames,
                            .seed = micro_config.seed,
                            .time_min_ns = result.timing.min_ns,
                            .time_median_ns = result.timing.median_ns,
                            .time_p95_ns = result.timing.p95_ns,
                            .time_max_ns = result.timing.max_ns,
                            .time_mean_ns = result.timing.mean_ns,
                            .cpu_time_ns = result.resources.cpu_time_ns,
                            .cpu_user_ns = result.resources.cpu_user_ns,
                            .cpu_sys_ns = result.resources.cpu_sys_ns,
                            .page_faults_minor = result.resources.page_faults_minor,
                            .page_faults_major = result.resources.page_faults_major,
                            .page_faults_minor_min = faultStatValue(result.fault_stats.minor, .min),
                            .page_faults_minor_median = faultStatValue(result.fault_stats.minor, .median),
                            .page_faults_minor_p95 = faultStatValue(result.fault_stats.minor, .p95),
                            .page_faults_minor_max = faultStatValue(result.fault_stats.minor, .max),
                            .page_faults_minor_mean = faultStatValue(result.fault_stats.minor, .mean),
                            .page_faults_major_min = faultStatValue(result.fault_stats.major, .min),
                            .page_faults_major_median = faultStatValue(result.fault_stats.major, .median),
                            .page_faults_major_p95 = faultStatValue(result.fault_stats.major, .p95),
                            .page_faults_major_max = faultStatValue(result.fault_stats.major, .max),
                            .page_faults_major_mean = faultStatValue(result.fault_stats.major, .mean),
                            .max_rss_bytes = result.resources.max_rss_bytes,
                            .bytes_total = result.bytes_total,
                            .bytes_mean = result.bytes_mean,
                            .dirty_ratio_mean = result.dirty_ratio_mean,
                            .style_runs_mean = result.style_runs_mean,
                            .pmc_cycles_min = pmcStatValue(pmc_stats.cycles, .min),
                            .pmc_cycles_median = pmcStatValue(pmc_stats.cycles, .median),
                            .pmc_cycles_p95 = pmcStatValue(pmc_stats.cycles, .p95),
                            .pmc_cycles_max = pmcStatValue(pmc_stats.cycles, .max),
                            .pmc_cycles_mean = pmcStatValue(pmc_stats.cycles, .mean),
                            .pmc_instructions_min = pmcStatValue(pmc_stats.instructions, .min),
                            .pmc_instructions_median = pmcStatValue(pmc_stats.instructions, .median),
                            .pmc_instructions_p95 = pmcStatValue(pmc_stats.instructions, .p95),
                            .pmc_instructions_max = pmcStatValue(pmc_stats.instructions, .max),
                            .pmc_instructions_mean = pmcStatValue(pmc_stats.instructions, .mean),
                            .pmc_cache_misses_min = pmcStatValue(pmc_stats.events[0], .min),
                            .pmc_cache_misses_median = pmcStatValue(pmc_stats.events[0], .median),
                            .pmc_cache_misses_p95 = pmcStatValue(pmc_stats.events[0], .p95),
                            .pmc_cache_misses_max = pmcStatValue(pmc_stats.events[0], .max),
                            .pmc_cache_misses_mean = pmcStatValue(pmc_stats.events[0], .mean),
                            .pmc_cache_references_min = pmcStatValue(pmc_stats.events[1], .min),
                            .pmc_cache_references_median = pmcStatValue(pmc_stats.events[1], .median),
                            .pmc_cache_references_p95 = pmcStatValue(pmc_stats.events[1], .p95),
                            .pmc_cache_references_max = pmcStatValue(pmc_stats.events[1], .max),
                            .pmc_cache_references_mean = pmcStatValue(pmc_stats.events[1], .mean),
                            .pmc_branches_min = pmcStatValue(pmc_stats.events[2], .min),
                            .pmc_branches_median = pmcStatValue(pmc_stats.events[2], .median),
                            .pmc_branches_p95 = pmcStatValue(pmc_stats.events[2], .p95),
                            .pmc_branches_max = pmcStatValue(pmc_stats.events[2], .max),
                            .pmc_branches_mean = pmcStatValue(pmc_stats.events[2], .mean),
                            .pmc_branch_misses_min = pmcStatValue(pmc_stats.events[3], .min),
                            .pmc_branch_misses_median = pmcStatValue(pmc_stats.events[3], .median),
                            .pmc_branch_misses_p95 = pmcStatValue(pmc_stats.events[3], .p95),
                            .pmc_branch_misses_max = pmcStatValue(pmc_stats.events[3], .max),
                            .pmc_branch_misses_mean = pmcStatValue(pmc_stats.events[3], .mean),
                        };
                        if (row_buffer) |*rows| {
                            try rows.append(init.arena.allocator(), row);
                        } else {
                            if (csv_enabled) {
                                try csv.writeRow(csv_writer, row);
                            }
                            if (human_writer) |writer| {
                                if (!human_header_written) {
                                    try reporting.writeHumanHeader(writer);
                                    human_header_written = true;
                                }
                                try reporting.writeHumanRow(writer, row);
                            }
                        }
                    }
                }
            }
        },
        .print, .print_assume_no_grapheme => {
            const mix_text = resolveTextMix(config.text_mix);
            const mix_style = resolveStyleMix(config.style_mix);

            var single_text_mix = [_]text_mix.TextMix{mix_text};
            var single_style_mix = [_]style_mix.StyleMix{mix_style};
            const text_mix_list = if (config.text_mix == .all) all_text_mixes[0..] else single_text_mix[0..];
            const style_mix_list = single_style_mix[0..];

            for (print_datasets) |print_dataset| {
                for (text_mix_list) |text_mix_item| {
                    for (style_mix_list) |style_mix_item| {
                        const print_config = PrintBenchConfig{
                            .mode = mode,
                            .frames_total = config.frames_total,
                            .warmup_frames = config.warmup_frames,
                            .seed = config.seed,
                            .cols = @intCast(config.cols),
                            .rows = @intCast(config.rows),
                            .dataset = print_dataset,
                            .text_mix = text_mix_item,
                            .style_mix = style_mix_item,
                        };
                        const timestamp_ns = nowTimestampNs();
                        const result = try runPrintBenchmark(init.arena.allocator(), print_config, &pmc_state);
                        const pmc_stats = result.pmc_stats;
                        const row = csv.Row{
                            .timestamp_ns = timestamp_ns,
                            .mode = mode_label,
                            .e2e = e2e_active,
                            .dataset = print_dataset.name,
                            .text_mix = @tagName(text_mix_item),
                            .style_mix = @tagName(style_mix_item),
                            .cols = @as(u32, print_config.cols),
                            .rows = @as(u32, print_config.rows),
                            .frames_total = print_config.frames_total,
                            .warmup_frames = print_config.warmup_frames,
                            .seed = print_config.seed,
                            .time_min_ns = result.timing.min_ns,
                            .time_median_ns = result.timing.median_ns,
                            .time_p95_ns = result.timing.p95_ns,
                            .time_max_ns = result.timing.max_ns,
                            .time_mean_ns = result.timing.mean_ns,
                            .cpu_time_ns = result.resources.cpu_time_ns,
                            .cpu_user_ns = result.resources.cpu_user_ns,
                            .cpu_sys_ns = result.resources.cpu_sys_ns,
                            .page_faults_minor = result.resources.page_faults_minor,
                            .page_faults_major = result.resources.page_faults_major,
                            .page_faults_minor_min = faultStatValue(result.fault_stats.minor, .min),
                            .page_faults_minor_median = faultStatValue(result.fault_stats.minor, .median),
                            .page_faults_minor_p95 = faultStatValue(result.fault_stats.minor, .p95),
                            .page_faults_minor_max = faultStatValue(result.fault_stats.minor, .max),
                            .page_faults_minor_mean = faultStatValue(result.fault_stats.minor, .mean),
                            .page_faults_major_min = faultStatValue(result.fault_stats.major, .min),
                            .page_faults_major_median = faultStatValue(result.fault_stats.major, .median),
                            .page_faults_major_p95 = faultStatValue(result.fault_stats.major, .p95),
                            .page_faults_major_max = faultStatValue(result.fault_stats.major, .max),
                            .page_faults_major_mean = faultStatValue(result.fault_stats.major, .mean),
                            .max_rss_bytes = result.resources.max_rss_bytes,
                            .bytes_total = result.bytes_total,
                            .bytes_mean = result.bytes_mean,
                            .dirty_ratio_mean = result.dirty_ratio_mean,
                            .style_runs_mean = result.style_runs_mean,
                            .pmc_cycles_min = pmcStatValue(pmc_stats.cycles, .min),
                            .pmc_cycles_median = pmcStatValue(pmc_stats.cycles, .median),
                            .pmc_cycles_p95 = pmcStatValue(pmc_stats.cycles, .p95),
                            .pmc_cycles_max = pmcStatValue(pmc_stats.cycles, .max),
                            .pmc_cycles_mean = pmcStatValue(pmc_stats.cycles, .mean),
                            .pmc_instructions_min = pmcStatValue(pmc_stats.instructions, .min),
                            .pmc_instructions_median = pmcStatValue(pmc_stats.instructions, .median),
                            .pmc_instructions_p95 = pmcStatValue(pmc_stats.instructions, .p95),
                            .pmc_instructions_max = pmcStatValue(pmc_stats.instructions, .max),
                            .pmc_instructions_mean = pmcStatValue(pmc_stats.instructions, .mean),
                            .pmc_cache_misses_min = pmcStatValue(pmc_stats.events[0], .min),
                            .pmc_cache_misses_median = pmcStatValue(pmc_stats.events[0], .median),
                            .pmc_cache_misses_p95 = pmcStatValue(pmc_stats.events[0], .p95),
                            .pmc_cache_misses_max = pmcStatValue(pmc_stats.events[0], .max),
                            .pmc_cache_misses_mean = pmcStatValue(pmc_stats.events[0], .mean),
                            .pmc_cache_references_min = pmcStatValue(pmc_stats.events[1], .min),
                            .pmc_cache_references_median = pmcStatValue(pmc_stats.events[1], .median),
                            .pmc_cache_references_p95 = pmcStatValue(pmc_stats.events[1], .p95),
                            .pmc_cache_references_max = pmcStatValue(pmc_stats.events[1], .max),
                            .pmc_cache_references_mean = pmcStatValue(pmc_stats.events[1], .mean),
                            .pmc_branches_min = pmcStatValue(pmc_stats.events[2], .min),
                            .pmc_branches_median = pmcStatValue(pmc_stats.events[2], .median),
                            .pmc_branches_p95 = pmcStatValue(pmc_stats.events[2], .p95),
                            .pmc_branches_max = pmcStatValue(pmc_stats.events[2], .max),
                            .pmc_branches_mean = pmcStatValue(pmc_stats.events[2], .mean),
                            .pmc_branch_misses_min = pmcStatValue(pmc_stats.events[3], .min),
                            .pmc_branch_misses_median = pmcStatValue(pmc_stats.events[3], .median),
                            .pmc_branch_misses_p95 = pmcStatValue(pmc_stats.events[3], .p95),
                            .pmc_branch_misses_max = pmcStatValue(pmc_stats.events[3], .max),
                            .pmc_branch_misses_mean = pmcStatValue(pmc_stats.events[3], .mean),
                        };
                        if (row_buffer) |*rows| {
                            try rows.append(init.arena.allocator(), row);
                        } else {
                            if (csv_enabled) {
                                try csv.writeRow(csv_writer, row);
                            }
                            if (human_writer) |writer| {
                                if (!human_header_written) {
                                    try reporting.writeHumanHeader(writer);
                                    human_header_written = true;
                                }
                                try reporting.writeHumanRow(writer, row);
                            }
                        }
                    }
                }
            }
        },
    }

    if (row_buffer) |*rows| {
        if (terminal_active) {
            terminal.deinit();
            terminal_active = false;
        }
        if (csv_enabled and csv_needs_header) {
            try csv.writeHeader(csv_writer);
        }
        if (human_writer) |writer| {
            if (!human_header_written) {
                try reporting.writeHumanHeader(writer);
                human_header_written = true;
            }
        }
        for (rows.items) |row| {
            if (csv_enabled) {
                try csv.writeRow(csv_writer, row);
            }
            if (human_writer) |writer| {
                try reporting.writeHumanRow(writer, row);
            }
        }
        rows.deinit(init.arena.allocator());
    }
}

fn normalizeConfig(config: *Config) void {
    assert(@intFromPtr(config) != 0);
    if (config.frames_total == 0) {
        config.frames_total = 1;
    }
    if (config.warmup_frames >= config.frames_total) {
        config.warmup_frames = config.frames_total - 1;
    }
    if (config.cols == 0) {
        config.cols = default_cols;
    }
    if (config.rows == 0) {
        config.rows = default_rows;
    }
}
fn resolveDatasetSpec(dataset: Dataset) DatasetSpec {
    return switch (dataset) {
        .typical_app_panel_swap => dataset_typical_panel_swap,
        .typical_app_cursor_moves => dataset_typical_cursor_moves,
        .unicode_stress_width_churn => dataset_unicode_width_churn,
        .unicode_stress_style_flicker => dataset_unicode_style_flicker,
        .unicode_dynamic_rect_churn => dataset_unicode_dynamic_rect,
        .all => dataset_typical_panel_swap,
    };
}

fn resolveTextMix(value: TextMix) text_mix.TextMix {
    return switch (value) {
        .common => .common,
        .grapheme_stress => .grapheme_stress,
        .all => .common,
    };
}

fn resolveStyleMix(value: StyleMix) style_mix.StyleMix {
    return switch (value) {
        .flat => .flat,
        .themed => .themed,
        .churn => .churn,
        .all => .flat,
    };
}

fn isPrintMode(mode: BenchmarkMode) bool {
    return switch (mode) {
        .print, .print_assume_no_grapheme => true,
        else => false,
    };
}

fn printModeFromBenchmark(mode: BenchmarkMode) print_helpers.PrintMode {
    return switch (mode) {
        .print => .print,
        .print_assume_no_grapheme => .print_assume_no_grapheme,
        else => unreachable,
    };
}

const DatasetAssets = struct {
    style_sheet: renderer.Style.Sheet,
    style_ids: []renderer.Style.Id,
    pattern_state: patterns.PatternState,

    fn deinit(self: *DatasetAssets, allocator: std.mem.Allocator) void {
        self.pattern_state.deinit(allocator);
        self.style_sheet.deinit(allocator);
        allocator.free(self.style_ids);
    }
};

fn buildDatasetAssets(allocator: std.mem.Allocator, config: MicrobenchConfig) !DatasetAssets {
    const palette_len = style_mix.paletteLen(config.style_mix);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    const style_ids = try allocator.alignedAlloc(renderer.Style.Id, buffer_alignment, palette_len);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, config.style_mix, style_ids);

    var base = try Buffer.init(allocator, config.cols, config.rows);
    defer base.deinit(allocator);

    var prng = rng.init(config.seed);
    const random = prng.random();
    var style_sequence = style_mix.StyleSequence.init(config.style_mix, random, palette_len);
    var codepoint_buffer: [256]u21 = undefined;
    var ctx = ui.PrimitiveContext{
        .random = random,
        .text_mix = config.text_mix,
        .style_sequence = &style_sequence,
        .style_ids = style_slice,
        .codepoint_buffer = codepoint_buffer[0..],
    };

    try config.dataset.render(base.fb.scissor(), &ctx);

    const pattern_state = try patterns.PatternState.init(allocator, config.dataset.pattern, &base.fb, config.seed, style_slice);

    return .{
        .style_sheet = style_sheet,
        .style_ids = style_ids,
        .pattern_state = pattern_state,
    };
}

fn runMicroBenchmark(
    allocator: std.mem.Allocator,
    config: MicrobenchConfig,
    pmc_state: *pmc.Pmc,
    terminal: ?*terminal_mod.Terminal,
) !MicrobenchResult {
    var assets = try buildDatasetAssets(allocator, config);
    defer assets.deinit(allocator);

    return switch (config.mode) {
        .full_redraw, .diff_redraw => runEmitBenchmark(allocator, config, &assets, pmc_state, terminal),
        else => runEmitBenchmark(allocator, config, &assets, pmc_state, terminal),
    };
}

fn runEmitBenchmark(
    allocator: std.mem.Allocator,
    config: MicrobenchConfig,
    assets: *DatasetAssets,
    pmc_state: *pmc.Pmc,
    terminal: ?*terminal_mod.Terminal,
) !MicrobenchResult {
    const warmup_frames: usize = @intCast(config.warmup_frames);
    const measured_frames: usize = @intCast(config.frames_total - config.warmup_frames);
    const durations = try allocator.alignedAlloc(u64, buffer_alignment, measured_frames);
    const scratch = try allocator.alignedAlloc(u64, buffer_alignment, measured_frames);
    defer allocator.free(durations);
    defer allocator.free(scratch);

    var front = try Buffer.init(allocator, config.cols, config.rows);
    defer front.deinit(allocator);
    var back = try Buffer.init(allocator, config.cols, config.rows);
    defer back.deinit(allocator);

    var writer_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var sink = std.Io.Writer.Discarding.init(&writer_buf);
    var output_writer: *std.Io.Writer = &sink.writer;
    var output_count: *u64 = &sink.count;
    // var counting_writer: CountingWriter = undefined;
    var count: u64 = 0;
    if (terminal) |tty| {
        output_writer = tty.getWriter();
        output_count = &count;
    }

    var frame_timer = try timer.FrameTimer.start();
    const pmc_active = pmc_state.start(.{
        "cache-misses",
        "cache-references",
        "branches",
        "branch-misses",
    });
    var pmc_samples = try PmcSamples.init(allocator, pmc_active, measured_frames);
    defer pmc_samples.deinit(allocator);
    var fault_samples = try ResourceSamples.init(allocator, measured_frames);
    defer fault_samples.deinit(allocator);

    var frame_index: u64 = 0;
    var warmup_index: usize = 0;
    while (warmup_index < warmup_frames) : (warmup_index += 1) {
        try assets.pattern_state.renderFrame(&front.fb, frame_index);
        output_count.* = 0;
        _ = frame_timer.lap();
        switch (config.mode) {
            .diff_redraw => front.fb.diffRedraw(&back.fb, &assets.style_sheet, output_writer) catch {},
            else => front.fb.fullRedraw(&assets.style_sheet, output_writer) catch {},
        }
        _ = frame_timer.lap();
        std.mem.swap(Buffer, &front, &back);
        frame_index += 1;
    }

    const usage_start = std.posix.getrusage(std.posix.rusage.SELF);
    var usage_prev = usage_start;

    var bytes_total: u64 = 0;
    var dirty_ratio_sum: f64 = 0;
    var style_runs_sum: f64 = 0;
    var measured_index: usize = 0;
    while (measured_index < measured_frames) : (measured_index += 1) {
        try assets.pattern_state.renderFrame(&front.fb, frame_index);
        dirty_ratio_sum += computeDirtyRatio(&front.fb, &back.fb);
        style_runs_sum += @as(f64, @floatFromInt(countStyleRuns(&front.fb)));
        output_count.* = 0;
        if (pmc_samples.active) {
            _ = try pmc_state.resetStart();
            io.sleep(.{ .nanoseconds = 50 * 1000 }, .real) catch {};
        }
        _ = frame_timer.lap();
        try output_writer.writeAll("\x1bP=1s\x1b\\");
        switch (config.mode) {
            .diff_redraw => front.fb.diffRedraw(&back.fb, &assets.style_sheet, output_writer) catch {},
            else => front.fb.fullRedraw(&assets.style_sheet, output_writer) catch {},
        }
        try output_writer.writeAll("\x1bP=2s\x1b\\");
        output_writer.flush() catch {};
        const delta_ns = frame_timer.lap();
        if (pmc_samples.active) {
            const snapshot = try pmc_state.snapshot();
            pmc_samples.record(measured_index, snapshot);
        }
        const usage_curr = std.posix.getrusage(std.posix.rusage.SELF);
        fault_samples.record(measured_index, usage_prev, usage_curr);
        usage_prev = usage_curr;
        durations[measured_index] = delta_ns;
        bytes_total += @as(u64, @intCast(output_count.*));
        std.mem.swap(Buffer, &front, &back);
        frame_index += 1;
    }

    if (pmc_samples.active) {
        _ = try pmc_state.stop();
    }
    const timing = stats.computeStats(durations, scratch);
    const usage_end = if (measured_frames == 0) usage_start else usage_prev;
    const resources = computeResourceStats(usage_start, usage_end);
    const pmc_stats = pmc_samples.computeStats(scratch);
    const fault_stats = fault_samples.computeStats(scratch);

    const measured_f64 = @as(f64, @floatFromInt(measured_frames));
    const bytes_mean = if (measured_frames == 0) 0 else @as(f64, @floatFromInt(bytes_total)) / measured_f64;
    const dirty_ratio_mean = if (measured_frames == 0) 0 else dirty_ratio_sum / measured_f64;
    const style_runs_mean = if (measured_frames == 0) 0 else style_runs_sum / measured_f64;

    return .{
        .timing = timing,
        .pmc_stats = pmc_stats,
        .resources = resources,
        .fault_stats = fault_stats,
        .bytes_total = bytes_total,
        .bytes_mean = bytes_mean,
        .dirty_ratio_mean = dirty_ratio_mean,
        .style_runs_mean = style_runs_mean,
    };
}

fn runPrintBenchmark(
    allocator: std.mem.Allocator,
    config: PrintBenchConfig,
    pmc_state: *pmc.Pmc,
) !MicrobenchResult {
    const warmup_frames: usize = @intCast(config.warmup_frames);
    const measured_frames: usize = @intCast(config.frames_total - config.warmup_frames);
    const durations = try allocator.alignedAlloc(u64, buffer_alignment, measured_frames);
    const scratch = try allocator.alignedAlloc(u64, buffer_alignment, measured_frames);
    defer allocator.free(durations);
    defer allocator.free(scratch);

    var front = try Buffer.init(allocator, config.cols, config.rows);
    defer front.deinit(allocator);
    var back = try Buffer.init(allocator, config.cols, config.rows);
    defer back.deinit(allocator);

    const palette_len = style_mix.paletteLen(config.style_mix);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    defer style_sheet.deinit(allocator);
    const style_ids = try allocator.alignedAlloc(renderer.Style.Id, buffer_alignment, palette_len);
    defer allocator.free(style_ids);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, config.style_mix, style_ids);

    var text_buffer: std.ArrayList(u8) = .empty;
    defer text_buffer.deinit(allocator);
    const target_cells = @as(u32, config.dataset.width) * @as(u32, config.dataset.height) * 2;
    try print_helpers.buildPrintText(allocator, &text_buffer, config.text_mix, config.seed, target_cells);

    var frame_timer = try timer.FrameTimer.start();
    const pmc_active = pmc_state.start(.{
        "cache-misses",
        "cache-references",
        "branches",
        "branch-misses",
    });
    var pmc_samples = try PmcSamples.init(allocator, pmc_active, measured_frames);
    defer pmc_samples.deinit(allocator);
    var fault_samples = try ResourceSamples.init(allocator, measured_frames);
    defer fault_samples.deinit(allocator);

    const style_id = if (style_slice.len > 0) style_slice[0] else .default;
    var codepoint_buffer: [256]u21 = undefined;
    const print_mode = printModeFromBenchmark(config.mode);

    var warmup_index: usize = 0;
    while (warmup_index < warmup_frames) : (warmup_index += 1) {
        front.fb.clear();
        _ = frame_timer.lap();
        _ = try print_helpers.renderPrintDataset(front.fb.scissor(), config.dataset, print_mode, codepoint_buffer[0..], text_buffer.items, style_id);
        _ = frame_timer.lap();
        std.mem.swap(Buffer, &front, &back);
    }

    const usage_start = std.posix.getrusage(std.posix.rusage.SELF);
    var usage_prev = usage_start;

    var bytes_total: u64 = 0;
    var dirty_ratio_sum: f64 = 0;
    var style_runs_sum: f64 = 0;
    var measured_index: usize = 0;
    while (measured_index < measured_frames) : (measured_index += 1) {
        front.fb.clear();
        if (pmc_samples.active) {
            _ = try pmc_state.resetStart();
        }
        _ = frame_timer.lap();
        const result = try print_helpers.renderPrintDataset(front.fb.scissor(), config.dataset, print_mode, codepoint_buffer[0..], text_buffer.items, style_id);
        const delta_ns = frame_timer.lap();
        durations[measured_index] = delta_ns;
        bytes_total += @as(u64, @intCast(result.bytes_consumed));
        dirty_ratio_sum += computeDirtyRatio(&front.fb, &back.fb);
        style_runs_sum += @as(f64, @floatFromInt(countStyleRuns(&front.fb)));
        if (pmc_samples.active) {
            const snapshot = try pmc_state.snapshot();
            pmc_samples.record(measured_index, snapshot);
        }
        const usage_curr = std.posix.getrusage(std.posix.rusage.SELF);
        fault_samples.record(measured_index, usage_prev, usage_curr);
        usage_prev = usage_curr;
        std.mem.swap(Buffer, &front, &back);
    }

    if (pmc_samples.active) {
        _ = try pmc_state.stop();
    }
    const timing = stats.computeStats(durations, scratch);
    const usage_end = if (measured_frames == 0) usage_start else usage_prev;
    const resources = computeResourceStats(usage_start, usage_end);
    const pmc_stats = pmc_samples.computeStats(scratch);
    const fault_stats = fault_samples.computeStats(scratch);

    const measured_f64 = @as(f64, @floatFromInt(measured_frames));
    const bytes_mean = if (measured_frames == 0) 0 else @as(f64, @floatFromInt(bytes_total)) / measured_f64;
    const dirty_ratio_mean = if (measured_frames == 0) 0 else dirty_ratio_sum / measured_f64;
    const style_runs_mean = if (measured_frames == 0) 0 else style_runs_sum / measured_f64;

    return .{
        .timing = timing,
        .pmc_stats = pmc_stats,
        .resources = resources,
        .fault_stats = fault_stats,
        .bytes_total = bytes_total,
        .bytes_mean = bytes_mean,
        .dirty_ratio_mean = dirty_ratio_mean,
        .style_runs_mean = style_runs_mean,
    };
}

fn computeDirtyRatio(front: *const renderer.FrameBuffer, back: *const renderer.FrameBuffer) f64 {
    const total_cells = @as(u64, front.width) * @as(u64, front.height);
    if (total_cells == 0) return 0;
    const width: usize = front.width;
    const height: usize = front.height;
    var changed: u64 = 0;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        var col: usize = 0;
        while (col < width) : (col += 1) {
            if (front.isDiff(back, row, col)) changed += 1;
        }
    }
    return @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(total_cells));
}

const DirtyRatioTestBuffer = struct {
    fb: renderer.FrameBuffer,
    cells: []renderer.Cell,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) !DirtyRatioTestBuffer {
        const cell_count = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alignedAlloc(renderer.Cell, buffer_alignment, cell_count);
        var fb = try renderer.FrameBuffer.init(cells, width, height, .tiny);
        fb.clear();
        return .{ .fb = fb, .cells = cells };
    }

    fn deinit(self: *DirtyRatioTestBuffer, allocator: std.mem.Allocator) void {
        self.fb.deinit();
        allocator.free(self.cells);
    }
};

fn makeDirtyRatioCell(codepoint: u21) renderer.Cell {
    var cell = renderer.Cell.empty;
    cell.data = .{ .codepoint = codepoint };
    return cell;
}

test "computeDirtyRatio no changes" {
    const allocator = std.testing.allocator;
    var front = try DirtyRatioTestBuffer.init(allocator, 4, 3);
    defer front.deinit(allocator);
    var back = try DirtyRatioTestBuffer.init(allocator, 4, 3);
    defer back.deinit(allocator);

    try std.testing.expectEqual(@as(f64, 0), computeDirtyRatio(&front.fb, &back.fb));
}

test "computeDirtyRatio single cell change" {
    const allocator = std.testing.allocator;
    var front = try DirtyRatioTestBuffer.init(allocator, 4, 3);
    defer front.deinit(allocator);
    var back = try DirtyRatioTestBuffer.init(allocator, 4, 3);
    defer back.deinit(allocator);

    front.fb.set(1, 1, makeDirtyRatioCell('A'));
    const expected = @as(f64, 1) / @as(f64, 12);
    try std.testing.expectEqual(expected, computeDirtyRatio(&front.fb, &back.fb));
}

test "computeDirtyRatio multi cell change" {
    const allocator = std.testing.allocator;
    var front = try DirtyRatioTestBuffer.init(allocator, 4, 3);
    defer front.deinit(allocator);
    var back = try DirtyRatioTestBuffer.init(allocator, 4, 3);
    defer back.deinit(allocator);

    front.fb.set(0, 0, makeDirtyRatioCell('A'));
    front.fb.set(3, 2, makeDirtyRatioCell('B'));
    front.fb.set(2, 1, makeDirtyRatioCell('C'));
    const expected = @as(f64, 3) / @as(f64, 12);
    try std.testing.expectEqual(expected, computeDirtyRatio(&front.fb, &back.fb));
}

test "computeDirtyRatio non-square buffer" {
    const allocator = std.testing.allocator;
    var front = try DirtyRatioTestBuffer.init(allocator, 5, 2);
    defer front.deinit(allocator);
    var back = try DirtyRatioTestBuffer.init(allocator, 5, 2);
    defer back.deinit(allocator);

    front.fb.set(0, 0, makeDirtyRatioCell('A'));
    front.fb.set(4, 1, makeDirtyRatioCell('B'));
    const expected = @as(f64, 2) / @as(f64, 10);
    try std.testing.expectEqual(expected, computeDirtyRatio(&front.fb, &back.fb));
}

fn countStyleRuns(buffer: *const renderer.FrameBuffer) u64 {
    if (buffer.width == 0 or buffer.height == 0) return 0;
    var runs: u64 = 0;
    var current_style: renderer.Style.Id = .default;
    const width: usize = buffer.width;
    const height: usize = buffer.height;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const row_start = row * width;
        var col: usize = 0;
        while (col < width) : (col += 1) {
            const cell = buffer.cells[row_start + col];
            if (cell.width == .wide_end) continue;
            if (cell.style != current_style) {
                runs += 1;
                current_style = cell.style;
            }
        }
    }
    return runs;
}

fn buildFrameText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), buffer: *const renderer.FrameBuffer) !void {
    out.clearRetainingCapacity();
    const width: usize = buffer.width;
    const height: usize = buffer.height;
    if (width == 0 or height == 0) return;

    var row: usize = 0;
    while (row < height) : (row += 1) {
        const row_start = row * width;
        var col: usize = 0;
        while (col < width) : (col += 1) {
            const cell = buffer.cells[row_start + col];
            if (cell.width == .wide_end) continue;
            try appendCellUtf8(allocator, out, buffer, cell);
        }
        if (row + 1 < height) {
            try out.append(allocator, '\n');
        }
    }
}

fn appendCellUtf8(allocator: std.mem.Allocator, out: *std.ArrayList(u8), buffer: *const renderer.FrameBuffer, cell: renderer.Cell) !void {
    switch (cell.tag) {
        .codepoint => {
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.data.codepoint, &bytes) catch blk: {
                bytes = [_]u8{ 0xEF, 0xBF, 0xBD, 0x00 };
                break :blk 3;
            };
            try out.appendSlice(allocator, bytes[0..len]);
        },
        .grapheme => {
            const id: renderer.GraphemeIndex = @truncate(@as(renderer.CellSize, @bitCast(cell)));
            const bytes = buffer.grapheme_buffer.get(id) orelse "\xEF\xBF\xBD";
            try out.appendSlice(allocator, bytes);
        },
    }
}

fn runDummyBenchmark(
    allocator: std.mem.Allocator,
    config: Config,
    pmc_state: *pmc.Pmc,
) !DummyResult {
    const warmup_frames: usize = @intCast(config.warmup_frames);
    const measured_frames: usize = @intCast(config.frames_total - config.warmup_frames);
    const durations = try allocator.alignedAlloc(u64, buffer_alignment, measured_frames);
    const scratch = try allocator.alignedAlloc(u64, buffer_alignment, measured_frames);

    const workload_len = if (pmc_state.enabled) workload_buffer_len_pmc else workload_buffer_len_default;
    assert((workload_len & (workload_len - 1)) == 0);
    const workload_buffer = try allocator.alignedAlloc(u64, buffer_alignment, workload_len);
    for (workload_buffer, 0..) |*value, idx| {
        value.* = @intCast(idx);
    }
    var workload_state: u64 = config.seed ^ 0x9e3779b97f4a7c15;
    var fault_samples = try ResourceSamples.init(allocator, measured_frames);
    defer fault_samples.deinit(allocator);

    var frame_timer = try timer.FrameTimer.start();
    const pmc_active = pmc_state.start(.{
        "cache-misses",
        "cache-references",
        "branches",
        "branch-misses",
    });
    var pmc_samples = try PmcSamples.init(allocator, pmc_active, measured_frames);
    defer pmc_samples.deinit(allocator);

    var index: usize = 0;
    while (index < warmup_frames) : (index += 1) {
        _ = runWorkload(workload_buffer, &workload_state, workload_iterations);
        _ = frame_timer.lap();
    }

    const usage_start = std.posix.getrusage(std.posix.rusage.SELF);
    var usage_prev = usage_start;

    var measured_index: usize = 0;
    while (measured_index < measured_frames) : (measured_index += 1) {
        if (pmc_samples.active) {
            _ = try pmc_state.resetStart();
        }
        _ = frame_timer.lap();
        const result = runWorkload(workload_buffer, &workload_state, workload_iterations);
        std.mem.doNotOptimizeAway(&result);
        const delta_ns = frame_timer.lap();
        durations[measured_index] = delta_ns;
        if (pmc_samples.active) {
            const snapshot = try pmc_state.snapshot();
            pmc_samples.record(measured_index, snapshot);
        }
        const usage_curr = std.posix.getrusage(std.posix.rusage.SELF);
        fault_samples.record(measured_index, usage_prev, usage_curr);
        usage_prev = usage_curr;
    }

    if (pmc_samples.active) {
        _ = try pmc_state.stop();
    }
    const timing = stats.computeStats(durations, scratch);
    const usage_end = if (measured_frames == 0) usage_start else usage_prev;
    const resources = computeResourceStats(usage_start, usage_end);
    const pmc_stats = pmc_samples.computeStats(scratch);
    const fault_stats = fault_samples.computeStats(scratch);
    return .{ .timing = timing, .pmc_stats = pmc_stats, .resources = resources, .fault_stats = fault_stats };
}

fn runWorkload(buffer: []u64, state: *u64, iterations: usize) u64 {
    assert(buffer.len > 0);
    assert(iterations > 0);
    assert(@intFromPtr(state) != 0);

    const mask = buffer.len - 1;
    assert((buffer.len & mask) == 0);
    assert(mask < buffer.len);

    var sum: u64 = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
        const index = @as(usize, @intCast(state.*)) & mask;
        const value = buffer[index];
        if ((state.* & 1) == 0) {
            buffer[index] = value +% 1;
            sum +%= buffer[index];
        } else {
            buffer[index] = value ^ sum;
            sum +%= buffer[index];
        }
    }

    std.mem.doNotOptimizeAway(sum);
    return sum;
}

fn nowTimestampNs() u64 {
    var tv: std.posix.timeval = undefined;
    std.posix.gettimeofday(&tv, null);

    const sec_ns = @as(u64, @intCast(tv.sec)) * std.time.ns_per_s;
    const usec_ns = @as(u64, @intCast(tv.usec)) * std.time.ns_per_us;
    const total = sec_ns + usec_ns;
    assert(total >= sec_ns);
    assert(total >= usec_ns);
    return total;
}

fn computeResourceStats(start: std.posix.rusage, end: std.posix.rusage) ResourceStats {
    const user_start_ns = timevalToNs(start.utime);
    const user_end_ns = timevalToNs(end.utime);
    const sys_start_ns = timevalToNs(start.stime);
    const sys_end_ns = timevalToNs(end.stime);

    assert(user_end_ns >= user_start_ns);
    assert(sys_end_ns >= sys_start_ns);

    const cpu_user_ns = user_end_ns - user_start_ns;
    const cpu_sys_ns = sys_end_ns - sys_start_ns;
    const cpu_time_ns = cpu_user_ns + cpu_sys_ns;

    const minflt_start = @as(i64, @intCast(start.minflt));
    const minflt_end = @as(i64, @intCast(end.minflt));
    const majflt_start = @as(i64, @intCast(start.majflt));
    const majflt_end = @as(i64, @intCast(end.majflt));
    assert(minflt_end >= minflt_start);
    assert(majflt_end >= majflt_start);

    const maxrss_start = @as(i64, @intCast(start.maxrss));
    const maxrss_end = @as(i64, @intCast(end.maxrss));
    assert(maxrss_start >= 0);
    assert(maxrss_end >= 0);

    const max_rss = if (maxrss_end >= maxrss_start) maxrss_end else maxrss_start;
    return .{
        .cpu_time_ns = cpu_time_ns,
        .cpu_user_ns = cpu_user_ns,
        .cpu_sys_ns = cpu_sys_ns,
        .page_faults_minor = @as(u64, @intCast(minflt_end - minflt_start)),
        .page_faults_major = @as(u64, @intCast(majflt_end - majflt_start)),
        .max_rss_bytes = @as(u64, @intCast(max_rss)),
    };
}

fn timevalToNs(tv: std.posix.timeval) u64 {
    const sec = @as(i64, @intCast(tv.sec));
    const usec = @as(i64, @intCast(tv.usec));
    assert(sec >= 0);
    assert(usec >= 0);
    assert(usec < 1_000_000);

    const sec_ns = @as(u64, @intCast(sec)) * std.time.ns_per_s;
    const usec_ns = @as(u64, @intCast(usec)) * std.time.ns_per_us;
    const total = sec_ns + usec_ns;
    assert(total >= sec_ns);
    assert(total >= usec_ns);
    return total;
}
