const std = @import("std");
const assert = std.debug.assert;

const csv = @import("csv.zig");
const stats = @import("stats.zig");
const timer = @import("timer.zig");
const pmc = @import("pmc/root.zig");
const renderer = @import("renderer");
const terminal_mod = @import("terminal");
const datasets = @import("datasets.zig");
const patterns = @import("patterns.zig");
const primitives = @import("primitives.zig");
const rng = @import("rng.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");

const default_frames_total: u64 = 10_000;
const default_warmup_frames: u64 = 1_000;
const default_seed: u64 = 0;
const default_cols: u32 = 200;
const default_rows: u32 = 60;
const default_mode: []const u8 = "dummy";
const default_dataset: []const u8 = "typical-app-panel-swap";
const default_text_mix: []const u8 = "common";
const default_style_mix: []const u8 = "flat";
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
    mode: []const u8,
    dataset: []const u8,
    dataset_set: bool,
    text_mix: []const u8,
    style_mix: []const u8,
    dump_frame_path: ?[]const u8,
    dump_frame_count: u64,
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

const DummyResult = struct {
    timing: stats.TimingStats,
    pmc_stats: PmcStats,
    resources: ResourceStats,
};

const MicrobenchResult = struct {
    timing: stats.TimingStats,
    pmc_stats: PmcStats,
    resources: ResourceStats,
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

        samples.cycles = try allocator.alloc(u64, sample_count);
        samples.instructions = try allocator.alloc(u64, sample_count);
        var i: usize = 0;
        while (i < pmc.MaxEvents) : (i += 1) {
            samples.events[i] = try allocator.alloc(u64, sample_count);
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

const ResourceStats = struct {
    cpu_time_ns: u64,
    cpu_user_ns: u64,
    cpu_sys_ns: u64,
    page_faults_minor: u64,
    page_faults_major: u64,
    max_rss_bytes: u64,
};

const DatasetSpec = struct {
    name: []const u8,
    render: *const fn (renderer.Scissor, *primitives.PrimitiveContext) renderer.Scissor.PrintError!void,
    pattern: patterns.Pattern,
};

const PrintDatasetOffset = struct { x: i17, y: i17 };

const PrintDatasetOrigin = union(enum) {
    centered,
    offset: PrintDatasetOffset,
};

const PrintDatasetSpec = struct {
    name: []const u8,
    width: u16,
    height: u16,
    origin: PrintDatasetOrigin,
};

const dataset_typical_panel_swap = DatasetSpec{
    .name = "typical-app-panel-swap",
    .render = datasets.datasetTypical,
    .pattern = .panel_swap,
};
const dataset_typical_cursor_moves = DatasetSpec{
    .name = "typical-app-cursor-moves",
    .render = datasets.datasetTypical,
    .pattern = .cursor_move,
};
const dataset_unicode_width_churn = DatasetSpec{
    .name = "unicode-stress-width-churn",
    .render = datasets.datasetUnicodeStress,
    .pattern = .unicode_width_churn,
};
const dataset_unicode_style_flicker = DatasetSpec{
    .name = "unicode-stress-style-flicker",
    .render = datasets.datasetUnicodeStress,
    .pattern = .style_flicker,
};
const dataset_unicode_dynamic_rect = DatasetSpec{
    .name = "unicode-dynamic-rect-churn",
    .render = datasets.datasetDynamic,
    .pattern = .rect_churn,
};

const render_datasets = [_]DatasetSpec{
    dataset_typical_panel_swap,
    dataset_typical_cursor_moves,
    dataset_unicode_width_churn,
    dataset_unicode_style_flicker,
    dataset_unicode_dynamic_rect,
};

const print_datasets = [_]PrintDatasetSpec{
    .{ .name = "scissor-small", .width = 20, .height = 6, .origin = .centered },
    .{ .name = "scissor-large", .width = 40, .height = 12, .origin = .centered },
    .{ .name = "scissor-out-of-bounds", .width = 40, .height = 12, .origin = .{ .offset = .{ .x = -5, .y = -2 } } },
};

const all_text_mixes = [_]text_mix.TextMix{
    .common,
    .grapheme_stress,
};

const all_style_mixes = [_]style_mix.StyleMix{
    .flat,
    .themed,
    .churn,
};

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
    cells: []renderer.Cell,

    fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Buffer {
        const cell_count = @as(usize, width) * @as(usize, height);
        const cells = try allocator.alloc(renderer.Cell, cell_count);
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

    var config = Config{
        .frames_total = default_frames_total,
        .warmup_frames = default_warmup_frames,
        .seed = default_seed,
        .cols = default_cols,
        .rows = default_rows,
        .enable_pmc = false,
        .enable_e2e = false,
        .mode = default_mode,
        .dataset = default_dataset,
        .dataset_set = false,
        .text_mix = default_text_mix,
        .style_mix = default_style_mix,
        .dump_frame_path = null,
        .dump_frame_count = 1,
        .inspect = false,
        .csv_path = null,
    };

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (hasHelp(args)) {
        try printHelp(stdout);
        return;
    }
    parseArgs(args, &config);
    normalizeConfig(&config);

    const mode = parseMode(config.mode) orelse .dummy;
    if (!config.dataset_set and (mode == .full_redraw or mode == .diff_redraw)) {
        config.dataset = "all";
    }

    if (config.inspect) {
        try runInspect(config);
        return;
    }
    if (config.dump_frame_path) |path| {
        try dumpFrames(init.arena.allocator(), config, path);
        return;
    }

    var pmc_state = try pmc.Pmc.init(config.enable_pmc);
    defer pmc_state.deinit();
    const e2e_active = config.enable_e2e and (mode == .full_redraw or mode == .diff_redraw);
    var terminal: terminal_mod.Terminal = undefined;
    var terminal_active = false;
    var terminal_write_buffer: [4096]u8 align(4096) = undefined;
    if (e2e_active) {
        const term_config: terminal_mod.TerminalConfig = .{ .raw = true, .alt_screen = true, .cursor_visable = false };
        try terminal.init(term_config, &terminal_write_buffer);
        terminal_active = true;
        config.cols = terminal.size.width;
        config.rows = terminal.size.height;
    }
    defer if (terminal_active) terminal.deinit();

    var csv_file: ?std.Io.File = null;
    var csv_file_writer: ?std.Io.File.Writer = null;
    var csv_file_buffer: [8192]u8 = undefined;
    var csv_writer: *std.Io.Writer = stdout;
    var human_writer: ?*std.Io.Writer = null;
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
        human_writer = stdout;
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
        if (csv_needs_header) {
            try csv.writeHeader(csv_writer);
        }
        if (human_writer) |writer| {
            try writeHumanHeader(writer);
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
                .mode = config.mode,
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
                try csv.writeRow(csv_writer, row);
                if (human_writer) |writer| {
                    if (!human_header_written) {
                        try writeHumanHeader(writer);
                        human_header_written = true;
                    }
                    try writeHumanRow(writer, row);
                }
            }
        },
        .full_redraw, .diff_redraw => {
            const dataset_spec = resolveDataset(config.dataset);
            const mix_text = parseTextMix(config.text_mix);
            const mix_style = parseStyleMix(config.style_mix);

            var single_dataset = [_]DatasetSpec{dataset_spec};
            var single_text_mix = [_]text_mix.TextMix{mix_text};
            var single_style_mix = [_]style_mix.StyleMix{mix_style};

            const dataset_list = if (isAll(config.dataset)) render_datasets[0..] else single_dataset[0..];
            const text_mix_list = if (isAll(config.text_mix)) all_text_mixes[0..] else single_text_mix[0..];
            const style_mix_list = if (isAll(config.style_mix)) all_style_mixes[0..] else single_style_mix[0..];
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
                            .mode = config.mode,
                            .e2e = e2e_active,
                            .dataset = dataset_item.name,
                            .text_mix = textMixName(text_mix_item),
                            .style_mix = styleMixName(style_mix_item),
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
                            try csv.writeRow(csv_writer, row);
                            if (human_writer) |writer| {
                                if (!human_header_written) {
                                    try writeHumanHeader(writer);
                                    human_header_written = true;
                                }
                                try writeHumanRow(writer, row);
                            }
                        }
                    }
                }
            }
        },
        .print, .print_assume_no_grapheme => {
            const mix_text = parseTextMix(config.text_mix);
            const mix_style = parseStyleMix(config.style_mix);

            var single_text_mix = [_]text_mix.TextMix{mix_text};
            var single_style_mix = [_]style_mix.StyleMix{mix_style};
            const text_mix_list = if (isAll(config.text_mix)) all_text_mixes[0..] else single_text_mix[0..];
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
                            .mode = config.mode,
                            .e2e = e2e_active,
                            .dataset = print_dataset.name,
                            .text_mix = textMixName(text_mix_item),
                            .style_mix = styleMixName(style_mix_item),
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
                            try csv.writeRow(csv_writer, row);
                            if (human_writer) |writer| {
                                if (!human_header_written) {
                                    try writeHumanHeader(writer);
                                    human_header_written = true;
                                }
                                try writeHumanRow(writer, row);
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
        if (csv_needs_header) {
            try csv.writeHeader(csv_writer);
        }
        if (human_writer) |writer| {
            if (!human_header_written) {
                try writeHumanHeader(writer);
                human_header_written = true;
            }
        }
        for (rows.items) |row| {
            try csv.writeRow(csv_writer, row);
            if (human_writer) |writer| {
                try writeHumanRow(writer, row);
            }
        }
        rows.deinit(init.arena.allocator());
    }
}

fn parseArgs(args: []const []const u8, config: *Config) void {
    assert(args.len > 0);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "dummy")) {
            config.mode = "dummy";
            continue;
        }
        if (std.mem.eql(u8, arg, "--pmc")) {
            config.enable_pmc = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--e2e")) {
            config.enable_e2e = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--inspect")) {
            config.inspect = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            config.mode = arg[7..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--mode")) {
            if (i + 1 < args.len) {
                config.mode = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dataset=")) {
            config.dataset = arg[10..];
            config.dataset_set = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dataset")) {
            if (i + 1 < args.len) {
                config.dataset = args[i + 1];
                config.dataset_set = true;
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--text-mix=")) {
            config.text_mix = arg[11..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--text-mix")) {
            if (i + 1 < args.len) {
                config.text_mix = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--style-mix=")) {
            config.style_mix = arg[12..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--style-mix")) {
            if (i + 1 < args.len) {
                config.style_mix = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dump-frame=")) {
            config.dump_frame_path = arg[13..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-frame")) {
            if (i + 1 < args.len) {
                config.dump_frame_path = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--dump-count=")) {
            config.dump_frame_count = parseU64(arg[13..], config.dump_frame_count);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--csv=")) {
            config.csv_path = arg[6..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--dump-count")) {
            if (i + 1 < args.len) {
                config.dump_frame_count = parseU64(args[i + 1], config.dump_frame_count);
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--csv")) {
            if (i + 1 < args.len) {
                config.csv_path = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--frames=")) {
            config.frames_total = parseU64(arg[9..], config.frames_total);
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            if (i + 1 < args.len) {
                config.frames_total = parseU64(args[i + 1], config.frames_total);
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--warmup=")) {
            config.warmup_frames = parseU64(arg[9..], config.warmup_frames);
            continue;
        }
        if (std.mem.eql(u8, arg, "--warmup")) {
            if (i + 1 < args.len) {
                config.warmup_frames = parseU64(args[i + 1], config.warmup_frames);
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            config.seed = parseU64(arg[7..], config.seed);
            continue;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            if (i + 1 < args.len) {
                config.seed = parseU64(args[i + 1], config.seed);
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--cols=")) {
            config.cols = parseU32(arg[7..], config.cols);
            continue;
        }
        if (std.mem.eql(u8, arg, "--cols")) {
            if (i + 1 < args.len) {
                config.cols = parseU32(args[i + 1], config.cols);
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--rows=")) {
            config.rows = parseU32(arg[7..], config.rows);
            continue;
        }
        if (std.mem.eql(u8, arg, "--rows")) {
            if (i + 1 < args.len) {
                config.rows = parseU32(args[i + 1], config.rows);
                i += 1;
            }
            continue;
        }
    }
}

fn parseU64(text: []const u8, fallback: u64) u64 {
    assert(text.len > 0);
    assert(text.len < 32);

    return std.fmt.parseInt(u64, text, 10) catch fallback;
}

fn parseU32(text: []const u8, fallback: u32) u32 {
    assert(text.len > 0);
    assert(text.len < 16);

    return std.fmt.parseInt(u32, text, 10) catch fallback;
}

fn normalizeConfig(config: *Config) void {
    assert(@intFromPtr(config) != 0);
    if (config.frames_total == 0) {
        config.frames_total = 1;
    }
    if (config.warmup_frames >= config.frames_total) {
        config.warmup_frames = config.frames_total - 1;
    }
    if (config.dump_frame_count == 0) {
        config.dump_frame_count = 1;
    } else if (config.dump_frame_count > 2) {
        config.dump_frame_count = 2;
    }
    if (config.cols == 0) {
        config.cols = default_cols;
    }
    if (config.rows == 0) {
        config.rows = default_rows;
    }
}

fn isAll(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "all");
}

fn hasHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return true;
    }
    return false;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "TUIG benchmark\n" ++
            "\n" ++
            "Usage:\n" ++
            "  zig build benchmark -- [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --mode <name>          dummy | fullRedraw | diffRedraw | print | printAssumeNoGrapheme\n" ++
            "  --dataset <name>       typical-app-panel-swap | typical-app-cursor-moves | unicode-stress-width-churn\n" ++
            "                         unicode-stress-style-flicker | unicode-dynamic-rect-churn\n" ++
            "                         aliases: A..E, dataset-a..dataset-e, typical/unicode/dynamic\n" ++
            "  --text-mix <name>      common | grapheme-stress\n" ++
            "                         aliases: ascii-heavy/unicode-lite/unicode-dense/box-ascii -> common, grapheme-focused -> grapheme-stress\n" ++
            "  --style-mix <name>     flat | themed | churn\n" ++
            "  --e2e                  render to the terminal instead of a sink (fullRedraw/diffRedraw only; uses terminal size)\n" ++
            "  --dump-frame <path>    write 1-2 frames to a file and exit\n" ++
            "  --dump-count <N>       number of frames to dump (1 or 2; default: 1)\n" ++
            "  --inspect              launch interactive frame viewer\n" ++
            "  --csv <path>           write CSV output to a file (append if it exists; stdout shows a human summary)\n" ++
            "  --frames <N>           total frames (default: 10000)\n" ++
            "  --warmup <N>           warmup frames excluded from stats (default: 1000)\n" ++
            "  --cols <N>             buffer columns (default: 200)\n" ++
            "  --rows <N>             buffer rows (default: 60)\n" ++
            "  --seed <N>             RNG seed (default: 0)\n" ++
            "  --pmc                  enable macOS PMC collection\n" ++
            "  -h, --help             show this help and exit\n" ++
            "\n" ++
            "Mode details:\n" ++
            "  dummy                 Synthetic workload only (timing/PMC sanity check).\n" ++
            "  fullRedraw            Render and emit a full frame each iteration.\n" ++
            "  diffRedraw            Render, diff with previous, emit only changed cells.\n" ++
            "  print                 Print full frame with grapheme-aware path.\n" ++
            "  printAssumeNoGrapheme  Print full frame assuming no grapheme clusters.\n" ++
            "\n" ++
            "Dataset details (render modes):\n" ++
            "  typical-app-panel-swap         Typical UI with panel swap updates.\n" ++
            "  typical-app-cursor-moves       Typical UI with single-cell cursor moves.\n" ++
            "  unicode-stress-width-churn     Unicode text with width churn updates.\n" ++
            "  unicode-stress-style-flicker   Unicode text with style-only flicker.\n" ++
            "  unicode-dynamic-rect-churn     Dynamic layout with random rect churn.\n" ++
            "\n" ++
            "Dataset details (print modes):\n" ++
            "  scissor-small                  Print into 20x6 scissor.\n" ++
            "  scissor-large                  Print into 40x12 scissor.\n" ++
            "  scissor-out-of-bounds          Print into 40x12 scissor with negative origin.\n" ++
            "  (print modes ignore --dataset; all three run automatically)\n" ++
            "\n" ++
            "Text mix details:\n" ++
            "  common               70% ASCII, 20% mixed Unicode, 10% wide.\n" ++
            "  grapheme-stress      50% ASCII, 20% mixed Unicode, 20% ZWJ, 10% combining.\n" ++
            "\n" ++
            "Style mix details:\n" ++
            "  flat                  Single style.\n" ++
            "  themed                5-8 styles, longer runs.\n" ++
            "  churn                 Mixed short runs, longer runs, and reverse/bold bursts.\n" ++
            "\n" ++
            "Matrix runs:\n" ++
            "  Render modes: use 'all' for dataset/text-mix/style-mix to run every option.\n" ++
            "  Render modes default to dataset=all when --dataset is omitted.\n" ++
            "  Print modes: dataset is fixed to scissor-small/large/out-of-bounds.\n" ++
            "\n" ++
            "Examples:\n" ++
            "  zig build benchmark -- --mode=fullRedraw --dataset typical-app-panel-swap\n" ++
            "  zig build benchmark -- --mode=diffRedraw --dataset all\n",
    );
}

fn parseMode(name: []const u8) ?BenchmarkMode {
    if (std.mem.eql(u8, name, "dummy")) return .dummy;
    if (std.mem.eql(u8, name, "fullRedraw") or std.mem.eql(u8, name, "full-redraw") or std.mem.eql(u8, name, "full_redraw")) {
        return .full_redraw;
    }
    if (std.mem.eql(u8, name, "diffRedraw") or std.mem.eql(u8, name, "diff-redraw") or std.mem.eql(u8, name, "diff_redraw")) {
        return .diff_redraw;
    }
    if (std.mem.eql(u8, name, "print")) return .print;
    if (std.mem.eql(u8, name, "printAssumeNoGrapheme") or
        std.mem.eql(u8, name, "print-assume-no-grapheme") or
        std.mem.eql(u8, name, "print_assume_no_grapheme"))
    {
        return .print_assume_no_grapheme;
    }
    return null;
}

fn isPrintMode(mode: BenchmarkMode) bool {
    return switch (mode) {
        .print, .print_assume_no_grapheme => true,
        else => false,
    };
}

fn modeLabel(mode: BenchmarkMode) []const u8 {
    return switch (mode) {
        .dummy => "dummy",
        .full_redraw => "fullRedraw",
        .diff_redraw => "diffRedraw",
        .print => "print",
        .print_assume_no_grapheme => "printAssumeNoGrapheme",
    };
}

fn resolveDataset(name: []const u8) DatasetSpec {
    if (name.len == 1) {
        return switch (std.ascii.toUpper(name[0])) {
            'A' => dataset_typical_panel_swap,
            'B' => dataset_typical_cursor_moves,
            'C' => dataset_unicode_width_churn,
            'D' => dataset_unicode_style_flicker,
            'E' => dataset_unicode_dynamic_rect,
            else => dataset_typical_panel_swap,
        };
    }
    if (std.ascii.eqlIgnoreCase(name, "A") or std.ascii.eqlIgnoreCase(name, "dataset-a") or
        std.ascii.eqlIgnoreCase(name, "typical") or std.ascii.eqlIgnoreCase(name, "typical-app") or
        std.ascii.eqlIgnoreCase(name, "typical-app-panel-swap"))
    {
        return dataset_typical_panel_swap;
    }
    if (std.ascii.eqlIgnoreCase(name, "B") or std.ascii.eqlIgnoreCase(name, "dataset-b") or
        std.ascii.eqlIgnoreCase(name, "typical-app-cursor-move") or std.ascii.eqlIgnoreCase(name, "typical-app-cursor-moves"))
    {
        return dataset_typical_cursor_moves;
    }
    if (std.ascii.eqlIgnoreCase(name, "C") or std.ascii.eqlIgnoreCase(name, "dataset-c") or
        std.ascii.eqlIgnoreCase(name, "unicode") or std.ascii.eqlIgnoreCase(name, "unicode-stress") or
        std.ascii.eqlIgnoreCase(name, "unicode-stress-width-churn"))
    {
        return dataset_unicode_width_churn;
    }
    if (std.ascii.eqlIgnoreCase(name, "D") or std.ascii.eqlIgnoreCase(name, "dataset-d") or
        std.ascii.eqlIgnoreCase(name, "unicode-stress-style-flicker"))
    {
        return dataset_unicode_style_flicker;
    }
    if (std.ascii.eqlIgnoreCase(name, "E") or std.ascii.eqlIgnoreCase(name, "dataset-e") or
        std.ascii.eqlIgnoreCase(name, "dynamic") or std.ascii.eqlIgnoreCase(name, "unicode-dynamic") or
        std.ascii.eqlIgnoreCase(name, "unicode-dynamic-rect-churn") or std.ascii.eqlIgnoreCase(name, "dynamic-unicode"))
    {
        return dataset_unicode_dynamic_rect;
    }
    return dataset_typical_panel_swap;
}

fn parseTextMix(name: []const u8) text_mix.TextMix {
    if (std.mem.eql(u8, name, "common")) return .common;
    if (std.mem.eql(u8, name, "grapheme-stress") or std.mem.eql(u8, name, "grapheme_stress")) return .grapheme_stress;
    return .common;
}

fn textMixName(mix: text_mix.TextMix) []const u8 {
    return switch (mix) {
        .common => "common",
        .grapheme_stress => "grapheme-stress",
    };
}

fn parseStyleMix(name: []const u8) style_mix.StyleMix {
    if (std.mem.eql(u8, name, "flat")) return .flat;
    if (std.mem.eql(u8, name, "themed")) return .themed;
    if (std.mem.eql(u8, name, "churn")) return .churn;
    return .flat;
}

fn styleMixName(mix: style_mix.StyleMix) []const u8 {
    return switch (mix) {
        .flat => "flat",
        .themed => "themed",
        .churn => "churn",
    };
}

fn writeHumanHeader(writer: *std.Io.Writer) !void {
    try writer.writeAll("Benchmark results\n");
}

fn writeHumanRow(writer: *std.Io.Writer, row: csv.Row) !void {
    const dataset = row.dataset orelse "NA";
    const text_mix_label = row.text_mix orelse "NA";
    const style_mix_label = row.style_mix orelse "NA";
    const e2e_label = if (row.e2e) "yes" else "no";

    try writer.print("mode: {s}  e2e: {s}\n", .{ row.mode, e2e_label });
    try writer.print("dataset: {s}  text: {s}  style: {s}\n", .{ dataset, text_mix_label, style_mix_label });

    try writer.writeAll("size: ");
    if (row.cols) |cols| {
        try writer.print("{d}", .{cols});
    } else {
        try writer.writeAll("NA");
    }
    try writer.writeAll("x");
    if (row.rows) |rows| {
        try writer.print("{d}", .{rows});
    } else {
        try writer.writeAll("NA");
    }
    try writer.print("  frames: {d} (warmup {d}) seed {d}\n", .{ row.frames_total, row.warmup_frames, row.seed });

    try writer.print(
        "time: mean {d:.3}ms median {d:.3}ms p95 {d:.3}ms min {d:.3}ms max {d:.3}ms\n",
        .{
            nsToMs(row.time_mean_ns),
            nsToMs(row.time_median_ns),
            nsToMs(row.time_p95_ns),
            nsToMs(row.time_min_ns),
            nsToMs(row.time_max_ns),
        },
    );

    try writer.writeAll("bytes: total ");
    try writeOptionalU64(writer, row.bytes_total);
    try writer.writeAll("  mean ");
    try writeOptionalF64(writer, row.bytes_mean);
    try writer.writeAll("  dirty ");
    try writeOptionalF64(writer, row.dirty_ratio_mean);
    try writer.writeAll("  style_runs ");
    try writeOptionalF64(writer, row.style_runs_mean);
    try writer.writeAll("\n");

    try writer.writeAll("cpu: total ");
    try writeOptionalNsMs(writer, row.cpu_time_ns);
    try writer.writeAll("  user ");
    try writeOptionalNsMs(writer, row.cpu_user_ns);
    try writer.writeAll("  sys ");
    try writeOptionalNsMs(writer, row.cpu_sys_ns);
    try writer.writeAll("  rss ");
    try writeOptionalU64(writer, row.max_rss_bytes);
    try writer.writeAll(" bytes\n\n");
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |val| {
        try writer.print("{d}", .{val});
    } else {
        try writer.writeAll("NA");
    }
}

fn writeOptionalF64(writer: *std.Io.Writer, value: ?f64) !void {
    if (value) |val| {
        try writer.print("{d:.3}", .{val});
    } else {
        try writer.writeAll("NA");
    }
}

fn writeOptionalNsMs(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |ns| {
        try writer.print("{d:.3}ms", .{nsToMs(ns)});
    } else {
        try writer.writeAll("NA");
    }
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
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
    const style_ids = try allocator.alloc(renderer.Style.Id, palette_len);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, config.style_mix, style_ids);

    var base = try Buffer.init(allocator, config.cols, config.rows);
    defer base.deinit(allocator);

    var prng = rng.init(config.seed);
    const random = prng.random();
    var style_sequence = style_mix.StyleSequence.init(config.style_mix, random, palette_len);
    var codepoint_buffer: [256]u21 = undefined;
    var ctx = primitives.PrimitiveContext{
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
    const durations = try allocator.alloc(u64, measured_frames);
    const scratch = try allocator.alloc(u64, measured_frames);
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
    var counting_writer: CountingWriter = undefined;
    if (terminal) |tty| {
        counting_writer = CountingWriter.init(tty.getWriter(), &writer_buf);
        output_writer = &counting_writer.writer;
        output_count = &counting_writer.count;
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
        switch (config.mode) {
            .diff_redraw => front.fb.diffRedraw(&back.fb, &assets.style_sheet, output_writer) catch {},
            else => front.fb.fullRedraw(&assets.style_sheet, output_writer) catch {},
        }
        const delta_ns = frame_timer.lap();
        if (pmc_samples.active) {
            const snapshot = try pmc_state.snapshot();
            pmc_samples.record(measured_index, snapshot);
        }
        durations[measured_index] = delta_ns;
        bytes_total += @as(u64, @intCast(output_count.*));
        std.mem.swap(Buffer, &front, &back);
        frame_index += 1;
    }

    if (pmc_samples.active) {
        _ = try pmc_state.stop();
    }
    const timing = stats.computeStats(durations, scratch);
    const usage_end = std.posix.getrusage(std.posix.rusage.SELF);
    const resources = computeResourceStats(usage_start, usage_end);
    const pmc_stats = pmc_samples.computeStats(scratch);

    const measured_f64 = @as(f64, @floatFromInt(measured_frames));
    const bytes_mean = if (measured_frames == 0) 0 else @as(f64, @floatFromInt(bytes_total)) / measured_f64;
    const dirty_ratio_mean = if (measured_frames == 0) 0 else dirty_ratio_sum / measured_f64;
    const style_runs_mean = if (measured_frames == 0) 0 else style_runs_sum / measured_f64;

    return .{
        .timing = timing,
        .pmc_stats = pmc_stats,
        .resources = resources,
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
    const durations = try allocator.alloc(u64, measured_frames);
    const scratch = try allocator.alloc(u64, measured_frames);
    defer allocator.free(durations);
    defer allocator.free(scratch);

    var front = try Buffer.init(allocator, config.cols, config.rows);
    defer front.deinit(allocator);
    var back = try Buffer.init(allocator, config.cols, config.rows);
    defer back.deinit(allocator);

    const palette_len = style_mix.paletteLen(config.style_mix);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    defer style_sheet.deinit(allocator);
    const style_ids = try allocator.alloc(renderer.Style.Id, palette_len);
    defer allocator.free(style_ids);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, config.style_mix, style_ids);

    var text_buffer: std.ArrayList(u8) = .empty;
    defer text_buffer.deinit(allocator);
    const target_cells = @as(u32, config.dataset.width) * @as(u32, config.dataset.height) * 2;
    try buildPrintText(allocator, &text_buffer, config.text_mix, config.seed, target_cells);

    var frame_timer = try timer.FrameTimer.start();
    const pmc_active = pmc_state.start(.{
        "cache-misses",
        "cache-references",
        "branches",
        "branch-misses",
    });
    var pmc_samples = try PmcSamples.init(allocator, pmc_active, measured_frames);
    defer pmc_samples.deinit(allocator);

    const style_id = if (style_slice.len > 0) style_slice[0] else .default;
    var codepoint_buffer: [256]u21 = undefined;

    var warmup_index: usize = 0;
    while (warmup_index < warmup_frames) : (warmup_index += 1) {
        front.fb.clear();
        _ = frame_timer.lap();
        _ = try renderPrintDataset(front.fb.scissor(), config.dataset, config.mode, codepoint_buffer[0..], text_buffer.items, style_id);
        _ = frame_timer.lap();
        std.mem.swap(Buffer, &front, &back);
    }

    const usage_start = std.posix.getrusage(std.posix.rusage.SELF);

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
        const result = try renderPrintDataset(front.fb.scissor(), config.dataset, config.mode, codepoint_buffer[0..], text_buffer.items, style_id);
        const delta_ns = frame_timer.lap();
        durations[measured_index] = delta_ns;
        bytes_total += @as(u64, @intCast(result.bytes_consumed));
        dirty_ratio_sum += computeDirtyRatio(&front.fb, &back.fb);
        style_runs_sum += @as(f64, @floatFromInt(countStyleRuns(&front.fb)));
        if (pmc_samples.active) {
            const snapshot = try pmc_state.snapshot();
            pmc_samples.record(measured_index, snapshot);
        }
        std.mem.swap(Buffer, &front, &back);
    }

    if (pmc_samples.active) {
        _ = try pmc_state.stop();
    }
    const timing = stats.computeStats(durations, scratch);
    const usage_end = std.posix.getrusage(std.posix.rusage.SELF);
    const resources = computeResourceStats(usage_start, usage_end);
    const pmc_stats = pmc_samples.computeStats(scratch);

    const measured_f64 = @as(f64, @floatFromInt(measured_frames));
    const bytes_mean = if (measured_frames == 0) 0 else @as(f64, @floatFromInt(bytes_total)) / measured_f64;
    const dirty_ratio_mean = if (measured_frames == 0) 0 else dirty_ratio_sum / measured_f64;
    const style_runs_mean = if (measured_frames == 0) 0 else style_runs_sum / measured_f64;

    return .{
        .timing = timing,
        .pmc_stats = pmc_stats,
        .resources = resources,
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

fn buildPrintText(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mix: text_mix.TextMix,
    seed: u64,
    target_cells: u32,
) !void {
    out.clearRetainingCapacity();

    var prng = rng.init(seed ^ 0x9e3779b97f4a7c15);
    const random = prng.random();
    var cell_count: u32 = 0;
    var word_index: u32 = 0;

    while (cell_count < target_cells) {
        const word_len = random.intRangeLessThan(u8, 3, 9);
        var i: u8 = 0;
        while (i < word_len) : (i += 1) {
            const glyph = text_mix.pickGlyph(random, mix);
            try out.appendSlice(allocator, glyph.bytes);
            cell_count += @as(u32, glyph.width);
        }

        word_index += 1;
        if (word_index % 25 == 0) {
            const long_len = random.intRangeLessThan(u8, 10, 18);
            var j: u8 = 0;
            try out.append(allocator, '\n');
            while (j < long_len) : (j += 1) {
                const glyph = text_mix.pickGlyph(random, mix);
                try out.appendSlice(allocator, glyph.bytes);
                cell_count += @as(u32, glyph.width);
            }
            try out.append(allocator, '\n');
        } else if (word_index % 12 == 0) {
            try out.append(allocator, '\n');
        } else if (word_index % 7 == 0) {
            try out.append(allocator, '\t');
        } else {
            try out.append(allocator, ' ');
        }
    }
}

fn printDatasetScissor(base: renderer.Scissor, dataset: PrintDatasetSpec) renderer.Scissor {
    const base_w: i17 = @intCast(base.width_global);
    const base_h: i17 = @intCast(base.height_global);
    const width: i17 = @intCast(dataset.width);
    const height: i17 = @intCast(dataset.height);

    const offset: PrintDatasetOffset = switch (dataset.origin) {
        .centered => .{ .x = @divTrunc(base_w - width, 2), .y = @divTrunc(base_h - height, 2) },
        .offset => |value| value,
    };

    return base.initChild(offset.x, offset.y, dataset.width, dataset.height);
}

fn renderPrintDataset(
    base: renderer.Scissor,
    dataset: PrintDatasetSpec,
    mode: BenchmarkMode,
    codepoint_buffer: []u21,
    text: []const u8,
    style_id: renderer.Style.Id,
) !renderer.Scissor.PrintResult {
    const scissor = printDatasetScissor(base, dataset);
    return switch (mode) {
        .print => try scissor.print(
            codepoint_buffer,
            text,
            0,
            0,
            .{ .wrap = true, .tab_width = 4, .style = style_id },
        ),
        .print_assume_no_grapheme => scissor.printAssumeNoGrapheme(
            text,
            0,
            0,
            .{ .wrap = true, .tab_width = 4, .style = style_id },
        ),
        else => unreachable,
    };
}

const InspectMode = enum { form, view };

const InspectFrames = struct {
    style_sheet: renderer.Style.Sheet,
    frames: [2]Buffer,
    frame_count: u8,

    fn deinit(self: *InspectFrames, allocator: std.mem.Allocator) void {
        self.frames[0].deinit(allocator);
        self.frames[1].deinit(allocator);
        self.style_sheet.deinit(allocator);
    }
};

const InspectState = struct {
    mode: InspectMode,
    bench_mode: BenchmarkMode,
    print_mode: bool,
    field_index: u8,
    dataset_index: usize,
    text_mix_index: usize,
    style_mix_index: usize,
    seed: u64,
    frame_index: u8,
    show_help: bool,
    frames: ?InspectFrames,
};

fn runInspect(config: Config) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var write_buffer: [4096]u8 align(4096) = undefined;
    var term_config: terminal_mod.TerminalConfig = .tui_default;
    term_config.cursor_visable = false;
    var terminal: terminal_mod.Terminal = undefined;
    try terminal.init(term_config, &write_buffer);
    defer terminal.deinit();

    var renderer_state: renderer.Renderer = undefined;
    try renderer_state.init(&terminal, .default_screen);

    var style_buffer: [64]renderer.Style = undefined;
    var generation_buffer: [64]u8 = undefined;
    var ui_style_sheet = renderer.Style.Sheet.initBuffer(style_buffer[0..], generation_buffer[0..]);

    var state = initInspectState(config);
    defer if (state.frames) |*frames| frames.deinit(allocator);

    var quit = false;
    while (!quit) {
        const events = try terminal.pollEvents(15);
        const ctx = try renderer_state.beginFrame(events);
        defer renderer_state.endFrame(true, activeStyleSheet(&state, &ui_style_sheet));

        switch (state.mode) {
            .form => {
                renderInspectForm(&ctx, &state);
                quit = try handleInspectFormInput(&ctx, &state, allocator);
            },
            .view => {
                try renderInspectView(&ctx, &state);
                quit = handleInspectViewInput(&ctx, &state, allocator);
            },
        }
    }
}

fn initInspectState(config: Config) InspectState {
    var bench_mode = parseMode(config.mode) orelse .full_redraw;
    if (bench_mode == .dummy) bench_mode = .full_redraw;
    const print_mode = isPrintMode(bench_mode);
    const dataset_index = if (print_mode) 0 else findRenderDatasetIndex(resolveDataset(config.dataset).name);
    return .{
        .mode = .form,
        .bench_mode = bench_mode,
        .print_mode = print_mode,
        .field_index = 0,
        .dataset_index = dataset_index,
        .text_mix_index = findTextMixIndex(parseTextMix(config.text_mix)),
        .style_mix_index = findStyleMixIndex(parseStyleMix(config.style_mix)),
        .seed = config.seed,
        .frame_index = 0,
        .show_help = true,
        .frames = null,
    };
}

fn activeStyleSheet(state: *InspectState, ui_style_sheet: *renderer.Style.Sheet) *renderer.Style.Sheet {
    if (state.mode == .view) {
        if (state.frames) |*frames| {
            return &frames.style_sheet;
        }
    }
    return ui_style_sheet;
}

fn handleInspectFormInput(ctx: *const renderer.Context, state: *InspectState, allocator: std.mem.Allocator) !bool {
    if (ctx.isKeyPressedThisFrame(.escape)) return true;
    if (ctx.isKeyPressedThisFrame(.enter)) {
        if (state.frames) |*frames| {
            frames.deinit(allocator);
            state.frames = null;
        }
        const cols = ctx.scissor.width_global;
        const rows = ctx.scissor.height_global;
        const text_mix_item = all_text_mixes[state.text_mix_index];
        const style_mix_item = all_style_mixes[state.style_mix_index];
        if (state.print_mode) {
            const dataset = inspectPrintDataset(state, state.dataset_index);
            const frames = try buildInspectPrintFrames(allocator, dataset, text_mix_item, style_mix_item, state.seed, cols, rows, state.bench_mode, 2);
            state.frames = frames;
        } else {
            const dataset = inspectRenderDataset(state, state.dataset_index);
            const frames = try buildInspectRenderFrames(allocator, dataset, text_mix_item, style_mix_item, state.seed, cols, rows, 2);
            state.frames = frames;
        }
        state.mode = .view;
        state.frame_index = 0;
        return false;
    }

    if (ctx.isKeyPressedThisFrame(.up)) {
        state.field_index = if (state.field_index == 0) 3 else state.field_index - 1;
    } else if (ctx.isKeyPressedThisFrame(.down)) {
        state.field_index = if (state.field_index == 3) 0 else state.field_index + 1;
    } else if (ctx.isKeyPressedThisFrame(.left)) {
        adjustInspectField(state, false);
    } else if (ctx.isKeyPressedThisFrame(.right)) {
        adjustInspectField(state, true);
    }

    return false;
}

fn handleInspectViewInput(ctx: *const renderer.Context, state: *InspectState, allocator: std.mem.Allocator) bool {
    if (ctx.resize != null) {
        if (state.frames) |*frames| {
            frames.deinit(allocator);
            state.frames = null;
        }
        state.mode = .form;
        return false;
    }
    if (ctx.isKeyPressedThisFrame(.escape)) {
        if (state.frames) |*frames| {
            frames.deinit(allocator);
            state.frames = null;
        }
        state.mode = .form;
        return false;
    }
    if (ctx.isKeyPressedThisFrame(.Q)) return true;
    if (ctx.isKeyPressedThisFrame(.H)) state.show_help = !state.show_help;

    if (ctx.isKeyPressedThisFrame(.left)) {
        state.frame_index = 0;
    } else if (ctx.isKeyPressedThisFrame(.right)) {
        if (state.frames) |frames| {
            if (frames.frame_count > 1) state.frame_index = 1;
        }
    }

    return false;
}

fn adjustInspectField(state: *InspectState, forward: bool) void {
    switch (state.field_index) {
        0 => state.dataset_index = rotateIndex(state.dataset_index, inspectDatasetCount(state), forward),
        1 => state.text_mix_index = rotateIndex(state.text_mix_index, all_text_mixes.len, forward),
        2 => state.style_mix_index = rotateIndex(state.style_mix_index, all_style_mixes.len, forward),
        3 => {
            if (forward) {
                if (state.seed != std.math.maxInt(u64)) state.seed += 1;
            } else {
                if (state.seed > 0) state.seed -= 1;
            }
        },
        else => {},
    }
}

fn rotateIndex(current: usize, len: usize, forward: bool) usize {
    if (len == 0) return 0;
    if (forward) return (current + 1) % len;
    return if (current == 0) len - 1 else current - 1;
}

fn findRenderDatasetIndex(name: []const u8) usize {
    for (render_datasets, 0..) |dataset, idx| {
        if (std.mem.eql(u8, dataset.name, name)) return idx;
    }
    return 0;
}

fn findPrintDatasetIndex(name: []const u8) usize {
    for (print_datasets, 0..) |dataset, idx| {
        if (std.mem.eql(u8, dataset.name, name)) return idx;
    }
    return 0;
}

fn inspectDatasetCount(state: *InspectState) usize {
    return if (state.print_mode) print_datasets.len else render_datasets.len;
}

fn inspectDatasetName(state: *InspectState, index: usize) []const u8 {
    return if (state.print_mode) print_datasets[index].name else render_datasets[index].name;
}

fn inspectRenderDataset(state: *InspectState, index: usize) DatasetSpec {
    if (state.print_mode) return render_datasets[0];
    return render_datasets[index];
}

fn inspectPrintDataset(state: *InspectState, index: usize) PrintDatasetSpec {
    if (!state.print_mode) return print_datasets[0];
    return print_datasets[index];
}

fn findTextMixIndex(mix: text_mix.TextMix) usize {
    for (all_text_mixes, 0..) |item, idx| {
        if (item == mix) return idx;
    }
    return 0;
}

fn findStyleMixIndex(mix: style_mix.StyleMix) usize {
    for (all_style_mixes, 0..) |item, idx| {
        if (item == mix) return idx;
    }
    return 0;
}

fn renderInspectForm(ctx: *const renderer.Context, state: *InspectState) void {
    const scissor = ctx.scissor;
    scissor.clear();

    _ = scissor.printAssumeNoGrapheme("Benchmark Inspector", 0, 0, .{ .wrap = false, .tab_width = 4 });
    var mode_buf: [64]u8 = undefined;
    const mode_line = std.fmt.bufPrint(&mode_buf, "Mode: {s}", .{modeLabel(state.bench_mode)}) catch "";
    _ = scissor.printAssumeNoGrapheme(mode_line, 0, 1, .{ .wrap = false, .tab_width = 4 });

    var line_buf: [256]u8 = undefined;
    const dataset_name = inspectDatasetName(state, state.dataset_index);
    const text_mix_name = textMixName(all_text_mixes[state.text_mix_index]);
    const style_mix_name = styleMixName(all_style_mixes[state.style_mix_index]);

    var y: u16 = 3;
    const dataset_line = std.fmt.bufPrint(&line_buf, "{s} Dataset: {s}", .{ fieldPrefix(state, 0), dataset_name }) catch "";
    _ = scissor.printAssumeNoGrapheme(dataset_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;
    const text_line = std.fmt.bufPrint(&line_buf, "{s} Text mix: {s}", .{ fieldPrefix(state, 1), text_mix_name }) catch "";
    _ = scissor.printAssumeNoGrapheme(text_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;
    const style_line = std.fmt.bufPrint(&line_buf, "{s} Style mix: {s}", .{ fieldPrefix(state, 2), style_mix_name }) catch "";
    _ = scissor.printAssumeNoGrapheme(style_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;
    const seed_line = std.fmt.bufPrint(&line_buf, "{s} Seed: {d}", .{ fieldPrefix(state, 3), state.seed }) catch "";
    _ = scissor.printAssumeNoGrapheme(seed_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;

    var size_buf: [64]u8 = undefined;
    const size_line = std.fmt.bufPrint(&size_buf, "Size: {d}x{d} (terminal)", .{ scissor.width_global, scissor.height_global }) catch "";
    _ = scissor.printAssumeNoGrapheme(size_line, 0, y + 1, .{ .wrap = false, .tab_width = 4 });

    const help_line = "Up/Down: field  Left/Right: change  Enter: view  Esc: quit";
    if (scissor.height_global > 1) {
        const help_y = scissor.height_global - 1;
        _ = scissor.printAssumeNoGrapheme(help_line, 0, help_y, .{ .wrap = false, .tab_width = 4 });
    }
}

fn fieldPrefix(state: *InspectState, index: u8) []const u8 {
    return if (state.field_index == index) ">" else " ";
}

fn renderInspectView(ctx: *const renderer.Context, state: *InspectState) !void {
    const scissor = ctx.scissor;
    scissor.clear();

    if (state.frames) |frames| {
        const frame_index: u8 = if (state.frame_index > 0 and frames.frame_count > 1) 1 else 0;
        try blitFrame(scissor, &frames.frames[frame_index].fb);

        if (state.show_help and scissor.height_global > 0) {
            const bar = scissor.initChild(0, @intCast(scissor.height_global - 1), scissor.width_global, 1);
            clearScissorRow(bar, 0);
            var info_buf: [160]u8 = undefined;
            const info = std.fmt.bufPrint(
                &info_buf,
                "Frame {d}/{d}  Left/Right: swap  Esc: back  Q: quit  H: toggle help",
                .{ frame_index + 1, frames.frame_count },
            ) catch "";
            _ = bar.printAssumeNoGrapheme(info, 0, 0, .{ .wrap = false, .tab_width = 4 });
        }
        return;
    }

    _ = scissor.printAssumeNoGrapheme("No frames generated", 0, 0, .{ .wrap = false, .tab_width = 4 });
}

fn clearScissorRow(scissor: renderer.Scissor, row: u16) void {
    if (row >= scissor.height_global) return;
    const width = scissor.width_global;
    var x: u16 = 0;
    while (x < width) : (x += 1) {
        scissor.set(x, row, renderer.Cell.empty);
    }
}

fn blitFrame(dest: renderer.Scissor, src: *const renderer.FrameBuffer) !void {
    const width: u16 = @min(dest.width_global, src.width);
    const height: u16 = @min(dest.height_global, src.height);
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const cell = src.get(x, y);
            dest.set(x, y, cell);
        }
    }
    try copyGraphemeBuffer(dest.buffer, src);
}

fn copyGraphemeBuffer(dest: *renderer.FrameBuffer, src: *const renderer.FrameBuffer) !void {
    const src_end = src.grapheme_buffer.end_index;
    try dest.grapheme_buffer.ensureTotalCapacity(src_end);
    dest.grapheme_buffer.end_index = src_end;
    dest.grapheme_buffer.generation = src.grapheme_buffer.generation;
    if (src_end > 0) {
        @memcpy(
            dest.grapheme_buffer.buffer.reserved_pages[0..src_end],
            src.grapheme_buffer.buffer.reserved_pages[0..src_end],
        );
    }
}

fn buildInspectRenderFrames(
    allocator: std.mem.Allocator,
    dataset: DatasetSpec,
    text_mix_item: text_mix.TextMix,
    style_mix_item: style_mix.StyleMix,
    seed: u64,
    cols: u16,
    rows: u16,
    frame_count: u8,
) !InspectFrames {
    const palette_len = style_mix.paletteLen(style_mix_item);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    const style_ids = try allocator.alloc(renderer.Style.Id, palette_len);
    defer allocator.free(style_ids);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, style_mix_item, style_ids);

    var base = try Buffer.init(allocator, cols, rows);
    defer base.deinit(allocator);

    var prng = rng.init(seed);
    const random = prng.random();
    var style_sequence = style_mix.StyleSequence.init(style_mix_item, random, palette_len);
    var codepoint_buffer: [256]u21 = undefined;
    var ctx = primitives.PrimitiveContext{
        .random = random,
        .text_mix = text_mix_item,
        .style_sequence = &style_sequence,
        .style_ids = style_slice,
        .codepoint_buffer = codepoint_buffer[0..],
    };

    try dataset.render(base.fb.scissor(), &ctx);

    var pattern_state = try patterns.PatternState.init(allocator, dataset.pattern, &base.fb, seed, style_slice);
    defer pattern_state.deinit(allocator);

    var frame0 = try Buffer.init(allocator, cols, rows);
    var frame1 = try Buffer.init(allocator, cols, rows);
    try pattern_state.renderFrame(&frame0.fb, 0);
    if (frame_count > 1) {
        try pattern_state.renderFrame(&frame1.fb, 1);
    }

    return .{
        .style_sheet = style_sheet,
        .frames = .{ frame0, frame1 },
        .frame_count = frame_count,
    };
}

fn buildInspectPrintFrames(
    allocator: std.mem.Allocator,
    dataset: PrintDatasetSpec,
    text_mix_item: text_mix.TextMix,
    style_mix_item: style_mix.StyleMix,
    seed: u64,
    cols: u16,
    rows: u16,
    mode: BenchmarkMode,
    frame_count: u8,
) !InspectFrames {
    const palette_len = style_mix.paletteLen(style_mix_item);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    const style_ids = try allocator.alloc(renderer.Style.Id, palette_len);
    defer allocator.free(style_ids);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, style_mix_item, style_ids);

    var frame0 = try Buffer.init(allocator, cols, rows);
    var frame1 = try Buffer.init(allocator, cols, rows);

    var text_buffer: std.ArrayList(u8) = .empty;
    defer text_buffer.deinit(allocator);
    const target_cells = @as(u32, dataset.width) * @as(u32, dataset.height) * 2;
    try buildPrintText(allocator, &text_buffer, text_mix_item, seed, target_cells);

    const style_id = if (style_slice.len > 0) style_slice[0] else .default;
    var codepoint_buffer: [256]u21 = undefined;

    frame0.fb.clear();
    _ = try renderPrintDataset(frame0.fb.scissor(), dataset, mode, codepoint_buffer[0..], text_buffer.items, style_id);
    if (frame_count > 1) {
        frame1.fb.clear();
        _ = try renderPrintDataset(frame1.fb.scissor(), dataset, mode, codepoint_buffer[0..], text_buffer.items, style_id);
    }

    return .{
        .style_sheet = style_sheet,
        .frames = .{ frame0, frame1 },
        .frame_count = frame_count,
    };
}

fn dumpFrames(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    const mode = parseMode(config.mode) orelse .dummy;
    const mix_text = parseTextMix(config.text_mix);
    const mix_style = parseStyleMix(config.style_mix);

    var single_text_mix = [_]text_mix.TextMix{mix_text};
    var single_style_mix = [_]style_mix.StyleMix{mix_style};
    const text_mix_list = if (isAll(config.text_mix)) all_text_mixes[0..] else single_text_mix[0..];
    const style_mix_list = if (isAll(config.style_mix)) all_style_mixes[0..] else single_style_mix[0..];

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var file_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const writer = &file_writer.interface;

    var text_buffer: std.ArrayList(u8) = .empty;
    defer text_buffer.deinit(allocator);
    var print_text: std.ArrayList(u8) = .empty;
    defer print_text.deinit(allocator);

    const frame_count = config.dump_frame_count;

    if (isPrintMode(mode)) {
        var single_style_list = [_]style_mix.StyleMix{mix_style};
        const print_style_list = single_style_list[0..];
        for (print_datasets) |print_dataset| {
            for (text_mix_list) |text_mix_item| {
                for (print_style_list) |style_mix_item| {
                    const print_config = PrintBenchConfig{
                        .mode = mode,
                        .frames_total = frame_count,
                        .warmup_frames = 0,
                        .seed = config.seed,
                        .cols = @intCast(config.cols),
                        .rows = @intCast(config.rows),
                        .dataset = print_dataset,
                        .text_mix = text_mix_item,
                        .style_mix = style_mix_item,
                    };

                    var frame = try Buffer.init(allocator, print_config.cols, print_config.rows);
                    defer frame.deinit(allocator);

                    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, style_mix.paletteLen(style_mix_item));
                    defer style_sheet.deinit(allocator);
                    const style_ids = try allocator.alloc(renderer.Style.Id, style_mix.paletteLen(style_mix_item));
                    defer allocator.free(style_ids);
                    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, style_mix_item, style_ids);
                    const style_id = if (style_slice.len > 0) style_slice[0] else .default;

                    const target_cells = @as(u32, print_dataset.width) * @as(u32, print_dataset.height) * 2;
                    try buildPrintText(allocator, &print_text, text_mix_item, config.seed, target_cells);

                    var codepoint_buffer: [256]u21 = undefined;

                    try writer.print(
                        "## dataset={s} text_mix={s} style_mix={s} size={d}x{d}\n",
                        .{ print_dataset.name, textMixName(text_mix_item), styleMixName(style_mix_item), print_config.cols, print_config.rows },
                    );

                    var frame_index: u64 = 0;
                    while (frame_index < frame_count) : (frame_index += 1) {
                        frame.fb.clear();
                        _ = try renderPrintDataset(frame.fb.scissor(), print_dataset, mode, codepoint_buffer[0..], print_text.items, style_id);
                        try buildFrameText(allocator, &text_buffer, &frame.fb);
                        try writer.print("-- frame {d} --\n", .{frame_index});
                        try writer.writeAll(text_buffer.items);
                        try writer.writeAll("\n");
                    }

                    try writer.writeAll("\n");
                }
            }
        }
    } else {
        const dataset_spec = resolveDataset(config.dataset);
        var single_dataset = [_]DatasetSpec{dataset_spec};
        const dataset_list = if (isAll(config.dataset)) render_datasets[0..] else single_dataset[0..];

        for (dataset_list) |dataset_item| {
            for (text_mix_list) |text_mix_item| {
                for (style_mix_list) |style_mix_item| {
                    const micro_config = MicrobenchConfig{
                        .mode = .full_redraw,
                        .frames_total = frame_count,
                        .warmup_frames = 0,
                        .seed = config.seed,
                        .cols = @intCast(config.cols),
                        .rows = @intCast(config.rows),
                        .dataset = dataset_item,
                        .text_mix = text_mix_item,
                        .style_mix = style_mix_item,
                    };

                    var assets = try buildDatasetAssets(allocator, micro_config);
                    defer assets.deinit(allocator);

                    var frame = try Buffer.init(allocator, micro_config.cols, micro_config.rows);
                    defer frame.deinit(allocator);

                    try writer.print(
                        "## dataset={s} text_mix={s} style_mix={s} size={d}x{d}\n",
                        .{ dataset_item.name, textMixName(text_mix_item), styleMixName(style_mix_item), micro_config.cols, micro_config.rows },
                    );

                    var frame_index: u64 = 0;
                    while (frame_index < frame_count) : (frame_index += 1) {
                        try assets.pattern_state.renderFrame(&frame.fb, frame_index);
                        try buildFrameText(allocator, &text_buffer, &frame.fb);
                        try writer.print("-- frame {d} --\n", .{frame_index});
                        try writer.writeAll(text_buffer.items);
                        try writer.writeAll("\n");
                    }

                    try writer.writeAll("\n");
                }
            }
        }
    }

    try file_writer.flush();
}

fn runDummyBenchmark(
    allocator: std.mem.Allocator,
    config: Config,
    pmc_state: *pmc.Pmc,
) !DummyResult {
    const warmup_frames: usize = @intCast(config.warmup_frames);
    const measured_frames: usize = @intCast(config.frames_total - config.warmup_frames);
    const durations = try allocator.alloc(u64, measured_frames);
    const scratch = try allocator.alloc(u64, measured_frames);

    const workload_len = if (pmc_state.enabled) workload_buffer_len_pmc else workload_buffer_len_default;
    assert((workload_len & (workload_len - 1)) == 0);
    const workload_buffer = try allocator.alloc(u64, workload_len);
    for (workload_buffer, 0..) |*value, idx| {
        value.* = @intCast(idx);
    }
    var workload_state: u64 = config.seed ^ 0x9e3779b97f4a7c15;

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
    }

    if (pmc_samples.active) {
        _ = try pmc_state.stop();
    }
    const timing = stats.computeStats(durations, scratch);
    const usage_end = std.posix.getrusage(std.posix.rusage.SELF);
    const resources = computeResourceStats(usage_start, usage_end);
    const pmc_stats = pmc_samples.computeStats(scratch);
    return .{ .timing = timing, .pmc_stats = pmc_stats, .resources = resources };
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
