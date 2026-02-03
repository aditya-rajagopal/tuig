const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const parseArgs = stdx.parseArgs;

const csv = @import("csv.zig");
const reporting = @import("reporting.zig");
const bench_catalog = @import("bench_catalog.zig");
const dataset_setup = @import("dataset_setup.zig");
const inspect = @import("inspect.zig");
const print_helpers = @import("print_helpers.zig");
const stats = @import("stats.zig");
const timer = @import("timer.zig");
const types = @import("types.zig");
const pmc = @import("pmc/root.zig");
const renderer = @import("renderer");
const terminal_mod = @import("terminal");
const Terminal = terminal_mod.Terminal;
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");

const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

const default_frames_total: u64 = 10_000;
const default_warmup_frames: u64 = 1_000;
const default_seed: u64 = 0;
const default_cols: u32 = 200;
const default_rows: u32 = 60;
const BenchMode = types.BenchMode;

const RenderDatasetArg = struct {
    mode: enum { all, single },
    index: usize,

    pub fn parseFlagValue(_: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!RenderDatasetArg {
        if (flag_value.len == 0) {
            error_out.* = "Empty dataset value";
            return error.Invalid;
        }
        if (std.mem.eql(u8, flag_value, "all")) {
            return .{ .mode = .all, .index = 0 };
        }
        for (render_datasets, 0..) |dataset, idx| {
            if (std.mem.eql(u8, flag_value, dataset.name)) {
                return .{ .mode = .single, .index = idx };
            }
        }
        error_out.* = "Unknown dataset";
        return error.Invalid;
    }
};

const TextMixArg = struct {
    mode: enum { all, single },
    value: text_mix.TextMix,

    pub fn parseFlagValue(_: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!TextMixArg {
        if (flag_value.len == 0) {
            error_out.* = "Empty text mix value";
            return error.Invalid;
        }
        if (std.mem.eql(u8, flag_value, "all")) {
            return .{ .mode = .all, .value = .common };
        }
        if (std.meta.stringToEnum(text_mix.TextMix, flag_value)) |value| {
            return .{ .mode = .single, .value = value };
        }
        error_out.* = "Unknown text mix";
        return error.Invalid;
    }
};

const StyleMixArg = struct {
    mode: enum { all, single },
    value: style_mix.StyleMix,

    pub fn parseFlagValue(_: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!StyleMixArg {
        if (flag_value.len == 0) {
            error_out.* = "Empty style mix value";
            return error.Invalid;
        }
        if (std.mem.eql(u8, flag_value, "all")) {
            return .{ .mode = .all, .value = .flat };
        }
        if (std.meta.stringToEnum(style_mix.StyleMix, flag_value)) |value| {
            return .{ .mode = .single, .value = value };
        }
        error_out.* = "Unknown style mix";
        return error.Invalid;
    }
};

const default_render_dataset = RenderDatasetArg{ .mode = .all, .index = 0 };
const default_text_mix = TextMixArg{ .mode = .single, .value = .common };
const default_style_mix = StyleMixArg{ .mode = .single, .value = .flat };

const RenderFull = struct {
    dataset: RenderDatasetArg = default_render_dataset,
    text_mix: TextMixArg = default_text_mix,
    style_mix: StyleMixArg = default_style_mix,
    e2e: bool = false,
    csv: ?[]const u8 = null,
    frames: u64 = default_frames_total,
    warmup: u64 = default_warmup_frames,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
    seed: u64 = default_seed,
    pmc: bool = false,

    pub const help =
        \\Usage:
        \\  zig build benchmark -- render-full [options]
        \\
        \\Options:
        \\  --dataset=<typical_app_panel_swap|typical_app_cursor_moves|unicode_stress_width_churn|unicode_stress_style_flicker|unicode_dynamic_rect_churn|all>
        \\  --text-mix=<common|grapheme_stress|all>
        \\  --style-mix=<flat|themed|churn|all>
        \\  --e2e
        \\  --csv=<path>
        \\  --frames=<N>
        \\  --warmup=<N>
        \\  --cols=<N>
        \\  --rows=<N>
        \\  --seed=<N>
        \\  --pmc
        \\  -h, --help
        \\
        \\Dataset details:
        \\  typical_app_panel_swap       Typical UI with panel swap updates.
        \\  typical_app_cursor_moves     Typical UI with single-cell cursor moves.
        \\  unicode_stress_width_churn   Unicode text with width churn updates.
        \\  unicode_stress_style_flicker Unicode text with style-only flicker.
        \\  unicode_dynamic_rect_churn   Dynamic layout with random rect churn.
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
        \\Examples:
        \\  zig build benchmark -- render-full
        \\  zig build benchmark -- render-full --dataset=typical_app_panel_swap
    ;
};

const RenderDiff = struct {
    dataset: RenderDatasetArg = default_render_dataset,
    text_mix: TextMixArg = default_text_mix,
    style_mix: StyleMixArg = default_style_mix,
    e2e: bool = false,
    csv: ?[]const u8 = null,
    frames: u64 = default_frames_total,
    warmup: u64 = default_warmup_frames,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
    seed: u64 = default_seed,
    pmc: bool = false,

    pub const help =
        \\Usage:
        \\  zig build benchmark -- render-diff [options]
        \\
        \\Options:
        \\  --dataset=<typical_app_panel_swap|typical_app_cursor_moves|unicode_stress_width_churn|unicode_stress_style_flicker|unicode_dynamic_rect_churn|all>
        \\  --text-mix=<common|grapheme_stress|all>
        \\  --style-mix=<flat|themed|churn|all>
        \\  --e2e
        \\  --csv=<path>
        \\  --frames=<N>
        \\  --warmup=<N>
        \\  --cols=<N>
        \\  --rows=<N>
        \\  --seed=<N>
        \\  --pmc
        \\  -h, --help
        \\
        \\Dataset details:
        \\  typical_app_panel_swap       Typical UI with panel swap updates.
        \\  typical_app_cursor_moves     Typical UI with single-cell cursor moves.
        \\  unicode_stress_width_churn   Unicode text with width churn updates.
        \\  unicode_stress_style_flicker Unicode text with style-only flicker.
        \\  unicode_dynamic_rect_churn   Dynamic layout with random rect churn.
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
        \\Examples:
        \\  zig build benchmark -- render-diff
        \\  zig build benchmark -- render-diff --dataset=all
    ;
};

const Print = struct {
    text_mix: TextMixArg = default_text_mix,
    style_mix: StyleMixArg = default_style_mix,
    csv: ?[]const u8 = null,
    warmup: u64 = default_warmup_frames,
    frames: u64 = default_frames_total,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
    seed: u64 = default_seed,
    pmc: bool = false,

    pub const help =
        \\Usage:
        \\  zig build benchmark -- print [options]
        \\
        \\Options:
        \\  --text-mix=<common|grapheme_stress|all>
        \\  --style-mix=<flat|themed|churn|all>
        \\  --csv=<path>
        \\  --frames=<N>
        \\  --warmup=<N>
        \\  --cols=<N>
        \\  --rows=<N>
        \\  --seed=<N>
        \\  --pmc
        \\  -h, --help
        \\
        \\Print datasets:
        \\  scissor_small
        \\  scissor_large
        \\  scissor_out_of_bounds
    ;
};

const PrintNoGrapheme = struct {
    text_mix: TextMixArg = default_text_mix,
    style_mix: StyleMixArg = default_style_mix,
    csv: ?[]const u8 = null,
    frames: u64 = default_frames_total,
    warmup: u64 = default_warmup_frames,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
    seed: u64 = default_seed,
    pmc: bool = false,

    pub const help =
        \\Usage:
        \\  zig build benchmark -- print-no-grapheme [options]
        \\
        \\Options:
        \\  --text-mix=<common|grapheme_stress|all>
        \\  --style-mix=<flat|themed|churn|all>
        \\  --csv=<path>
        \\  --frames=<N>
        \\  --warmup=<N>
        \\  --cols=<N>
        \\  --rows=<N>
        \\  --seed=<N>
        \\  --pmc
        \\  -h, --help
        \\
        \\Print datasets:
        \\  scissor_small
        \\  scissor_large
        \\  scissor_out_of_bounds
    ;
};

const CLIArgs = union(enum) {
    render_full: RenderFull,
    render_diff: RenderDiff,
    print_no_grapheme: PrintNoGrapheme,
    print: Print,
    inspect,

    pub const help =
        \\TUIG benchmark
        \\
        \\Usage:
        \\  zig build benchmark -- <command> [options]
        \\
        \\Commands:
        \\  render_full        Render and emit a full frame each iteration.
        \\  render_diff        Render, diff with previous, emit only changed cells.
        \\  print              Print full frame with grapheme-aware path.
        \\  print_no_grapheme  Print full frame assuming no grapheme clusters.
        \\  inspect            Launch the interactive inspector.
        \\
        \\Options:
        \\  -h, --help
        \\      Prints this help message.
    ;
};

const MicrobenchResult = types.MicrobenchResult;
const PmcSamples = types.PmcSamples;
const ResourceSamples = types.ResourceSamples;
const ResourceStats = types.ResourceStats;
const StatField = types.StatField;
const MicrobenchConfig = types.MicrobenchConfig;
const PrintBenchConfig = types.PrintBenchConfig;
const Buffer = types.Buffer;

fn statValue(stat: ?stats.Stats, field: StatField) ?u64 {
    if (stat) |value| {
        return switch (field) {
            .min => value.min,
            .median => value.median,
            .p95 => value.p95,
            .max => value.max,
            .mean => value.mean,
        };
    }
    return null;
}

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

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (Terminal.global_tty) |tty| {
        tty.deinit();
    }

    std.debug.defaultPanic(msg, ret_addr);
}

var io: std.Io = undefined;

pub fn main(init: std.process.Init) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    io = threaded.ioBasic();

    var args_iter = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args_iter.deinit();
    const cli = parseArgs(io, init.arena.allocator(), &args_iter, CLIArgs);

    switch (cli) {
        .render_full => |args| try runRenderCommand(init, args, .full_redraw),
        .render_diff => |args| try runRenderCommand(init, args, .diff_redraw),
        .print => |args| try runPrintCommand(init, args, .print),
        .print_no_grapheme => |args| try runPrintCommand(init, args, .print_assume_no_grapheme),
        .inspect => try runInspectCommand(),
    }
}

fn runInspectCommand() !void {
    const inspect_config = inspect.InspectConfig{
        .bench_mode = .full_redraw,
        .dataset_name = dataset_typical_panel_swap.name,
        .text_mix = .common,
        .style_mix = .flat,
        .seed = default_seed,
    };
    try inspect.runInspect(inspect_config);
}

fn validateRunArgs(frames: u64, warmup: u64, cols: u32, rows: u32) !void {
    if (frames == 0) {
        std.log.err("frames must be > 0", .{});
        return error.InvalidArgs;
    }
    if (warmup >= frames) {
        std.log.err("warmup must be < frames", .{});
        return error.InvalidArgs;
    }
    if (cols == 0 or rows == 0) {
        std.log.err("cols and rows must be > 0", .{});
        return error.InvalidArgs;
    }
}

fn runRenderCommand(init: std.process.Init, args: anytype, mode: BenchMode) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    try validateRunArgs(args.frames, args.warmup, args.cols, args.rows);

    var pmc_state = try pmc.Pmc.init(args.pmc);
    defer pmc_state.deinit();

    const e2e_active = args.e2e;
    var terminal: terminal_mod.Terminal = undefined;
    var terminal_active = false;
    var cols = args.cols;
    var rows = args.rows;
    const terminal_write_buffer: []align(std.heap.page_size_min) u8 = init.arena.allocator().alignedAlloc(u8, buffer_alignment, 4 * 4096) catch unreachable;
    if (e2e_active) {
        const term_config: terminal_mod.TerminalConfig = .{ .raw = true, .alt_screen = true, .cursor_visable = false };
        try terminal.init(term_config, terminal_write_buffer);
        terminal_active = true;
        cols = terminal.size.width;
        rows = terminal.size.height;
    }
    defer if (terminal_active) terminal.deinit();

    const csv_enabled = args.csv != null;
    var csv_file: ?std.Io.File = null;
    var csv_file_writer: ?std.Io.File.Writer = null;
    var csv_file_buffer: [8192]u8 = undefined;
    var csv_writer: *std.Io.Writer = stdout;
    const human_writer: ?*std.Io.Writer = stdout;
    var human_header_written = false;
    var csv_needs_header = true;

    if (args.csv) |path| {
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

    const mode_label = @tagName(mode);
    var single_dataset = [_]DatasetSpec{render_datasets[args.dataset.index]};
    var single_text_mix = [_]text_mix.TextMix{args.text_mix.value};
    var single_style_mix = [_]style_mix.StyleMix{args.style_mix.value};

    const dataset_list = if (args.dataset.mode == .all) render_datasets[0..] else single_dataset[0..];
    const text_mix_list = if (args.text_mix.mode == .all) all_text_mixes[0..] else single_text_mix[0..];
    const style_mix_list = if (args.style_mix.mode == .all) all_style_mixes[0..] else single_style_mix[0..];
    const terminal_ptr: ?*terminal_mod.Terminal = if (terminal_active) &terminal else null;

    for (dataset_list) |dataset_item| {
        for (text_mix_list) |text_mix_item| {
            for (style_mix_list) |style_mix_item| {
                const micro_config = MicrobenchConfig{
                    .mode = mode,
                    .frames_total = args.frames,
                    .warmup_frames = args.warmup,
                    .seed = args.seed,
                    .cols = @intCast(cols),
                    .rows = @intCast(rows),
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
                    .time_min_ns = result.timing.min,
                    .time_median_ns = result.timing.median,
                    .time_p95_ns = result.timing.p95,
                    .time_max_ns = result.timing.max,
                    .time_mean_ns = result.timing.mean,
                    .cpu_time_ns = result.resources.cpu_time_ns,
                    .cpu_user_ns = result.resources.cpu_user_ns,
                    .cpu_sys_ns = result.resources.cpu_sys_ns,
                    .page_faults_minor = result.resources.page_faults_minor,
                    .page_faults_major = result.resources.page_faults_major,
                    .page_faults_minor_min = statValue(result.fault_stats.minor, .min),
                    .page_faults_minor_median = statValue(result.fault_stats.minor, .median),
                    .page_faults_minor_p95 = statValue(result.fault_stats.minor, .p95),
                    .page_faults_minor_max = statValue(result.fault_stats.minor, .max),
                    .page_faults_minor_mean = statValue(result.fault_stats.minor, .mean),
                    .page_faults_major_min = statValue(result.fault_stats.major, .min),
                    .page_faults_major_median = statValue(result.fault_stats.major, .median),
                    .page_faults_major_p95 = statValue(result.fault_stats.major, .p95),
                    .page_faults_major_max = statValue(result.fault_stats.major, .max),
                    .page_faults_major_mean = statValue(result.fault_stats.major, .mean),
                    .max_rss_bytes = result.resources.max_rss_bytes,
                    .bytes_total = result.bytes_total,
                    .bytes_mean = result.bytes_mean,
                    .dirty_ratio_mean = result.dirty_ratio_mean,
                    .style_runs_mean = result.style_runs_mean,
                    .pmc_cycles_min = statValue(pmc_stats.cycles, .min),
                    .pmc_cycles_median = statValue(pmc_stats.cycles, .median),
                    .pmc_cycles_p95 = statValue(pmc_stats.cycles, .p95),
                    .pmc_cycles_max = statValue(pmc_stats.cycles, .max),
                    .pmc_cycles_mean = statValue(pmc_stats.cycles, .mean),
                    .pmc_instructions_min = statValue(pmc_stats.instructions, .min),
                    .pmc_instructions_median = statValue(pmc_stats.instructions, .median),
                    .pmc_instructions_p95 = statValue(pmc_stats.instructions, .p95),
                    .pmc_instructions_max = statValue(pmc_stats.instructions, .max),
                    .pmc_instructions_mean = statValue(pmc_stats.instructions, .mean),
                    .pmc_cache_misses_min = statValue(pmc_stats.events[0], .min),
                    .pmc_cache_misses_median = statValue(pmc_stats.events[0], .median),
                    .pmc_cache_misses_p95 = statValue(pmc_stats.events[0], .p95),
                    .pmc_cache_misses_max = statValue(pmc_stats.events[0], .max),
                    .pmc_cache_misses_mean = statValue(pmc_stats.events[0], .mean),
                    .pmc_cache_references_min = statValue(pmc_stats.events[1], .min),
                    .pmc_cache_references_median = statValue(pmc_stats.events[1], .median),
                    .pmc_cache_references_p95 = statValue(pmc_stats.events[1], .p95),
                    .pmc_cache_references_max = statValue(pmc_stats.events[1], .max),
                    .pmc_cache_references_mean = statValue(pmc_stats.events[1], .mean),
                    .pmc_branches_min = statValue(pmc_stats.events[2], .min),
                    .pmc_branches_median = statValue(pmc_stats.events[2], .median),
                    .pmc_branches_p95 = statValue(pmc_stats.events[2], .p95),
                    .pmc_branches_max = statValue(pmc_stats.events[2], .max),
                    .pmc_branches_mean = statValue(pmc_stats.events[2], .mean),
                    .pmc_branch_misses_min = statValue(pmc_stats.events[3], .min),
                    .pmc_branch_misses_median = statValue(pmc_stats.events[3], .median),
                    .pmc_branch_misses_p95 = statValue(pmc_stats.events[3], .p95),
                    .pmc_branch_misses_max = statValue(pmc_stats.events[3], .max),
                    .pmc_branch_misses_mean = statValue(pmc_stats.events[3], .mean),
                };
                if (row_buffer) |*rows_list| {
                    try rows_list.append(init.arena.allocator(), row);
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

    if (row_buffer) |*rows_list| {
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
        for (rows_list.items) |row| {
            if (csv_enabled) {
                try csv.writeRow(csv_writer, row);
            }
            if (human_writer) |writer| {
                try reporting.writeHumanRow(writer, row);
            }
        }
        rows_list.deinit(init.arena.allocator());
    }
}

fn runPrintCommand(init: std.process.Init, args: anytype, mode: BenchMode) !void {
    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    try validateRunArgs(args.frames, args.warmup, args.cols, args.rows);

    var pmc_state = try pmc.Pmc.init(args.pmc);
    defer pmc_state.deinit();

    const e2e_active = false;
    const cols = args.cols;
    const rows = args.rows;

    const csv_enabled = args.csv != null;
    var csv_file: ?std.Io.File = null;
    var csv_file_writer: ?std.Io.File.Writer = null;
    var csv_file_buffer: [8192]u8 = undefined;
    var csv_writer: *std.Io.Writer = stdout;
    const human_writer: ?*std.Io.Writer = stdout;
    var human_header_written = false;
    var csv_needs_header = true;

    if (args.csv) |path| {
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

    const mode_label = @tagName(mode);
    var single_text_mix = [_]text_mix.TextMix{args.text_mix.value};
    var single_style_mix = [_]style_mix.StyleMix{args.style_mix.value};
    const text_mix_list = if (args.text_mix.mode == .all) all_text_mixes[0..] else single_text_mix[0..];
    const style_mix_list = if (args.style_mix.mode == .all) all_style_mixes[0..] else single_style_mix[0..];

    for (print_datasets) |print_dataset| {
        for (text_mix_list) |text_mix_item| {
            for (style_mix_list) |style_mix_item| {
                const print_config = PrintBenchConfig{
                    .mode = mode,
                    .frames_total = args.frames,
                    .warmup_frames = args.warmup,
                    .seed = args.seed,
                    .cols = @intCast(cols),
                    .rows = @intCast(rows),
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
                    .time_min_ns = result.timing.min,
                    .time_median_ns = result.timing.median,
                    .time_p95_ns = result.timing.p95,
                    .time_max_ns = result.timing.max,
                    .time_mean_ns = result.timing.mean,
                    .cpu_time_ns = result.resources.cpu_time_ns,
                    .cpu_user_ns = result.resources.cpu_user_ns,
                    .cpu_sys_ns = result.resources.cpu_sys_ns,
                    .page_faults_minor = result.resources.page_faults_minor,
                    .page_faults_major = result.resources.page_faults_major,
                    .page_faults_minor_min = statValue(result.fault_stats.minor, .min),
                    .page_faults_minor_median = statValue(result.fault_stats.minor, .median),
                    .page_faults_minor_p95 = statValue(result.fault_stats.minor, .p95),
                    .page_faults_minor_max = statValue(result.fault_stats.minor, .max),
                    .page_faults_minor_mean = statValue(result.fault_stats.minor, .mean),
                    .page_faults_major_min = statValue(result.fault_stats.major, .min),
                    .page_faults_major_median = statValue(result.fault_stats.major, .median),
                    .page_faults_major_p95 = statValue(result.fault_stats.major, .p95),
                    .page_faults_major_max = statValue(result.fault_stats.major, .max),
                    .page_faults_major_mean = statValue(result.fault_stats.major, .mean),
                    .max_rss_bytes = result.resources.max_rss_bytes,
                    .bytes_total = result.bytes_total,
                    .bytes_mean = result.bytes_mean,
                    .dirty_ratio_mean = result.dirty_ratio_mean,
                    .style_runs_mean = result.style_runs_mean,
                    .pmc_cycles_min = statValue(pmc_stats.cycles, .min),
                    .pmc_cycles_median = statValue(pmc_stats.cycles, .median),
                    .pmc_cycles_p95 = statValue(pmc_stats.cycles, .p95),
                    .pmc_cycles_max = statValue(pmc_stats.cycles, .max),
                    .pmc_cycles_mean = statValue(pmc_stats.cycles, .mean),
                    .pmc_instructions_min = statValue(pmc_stats.instructions, .min),
                    .pmc_instructions_median = statValue(pmc_stats.instructions, .median),
                    .pmc_instructions_p95 = statValue(pmc_stats.instructions, .p95),
                    .pmc_instructions_max = statValue(pmc_stats.instructions, .max),
                    .pmc_instructions_mean = statValue(pmc_stats.instructions, .mean),
                    .pmc_cache_misses_min = statValue(pmc_stats.events[0], .min),
                    .pmc_cache_misses_median = statValue(pmc_stats.events[0], .median),
                    .pmc_cache_misses_p95 = statValue(pmc_stats.events[0], .p95),
                    .pmc_cache_misses_max = statValue(pmc_stats.events[0], .max),
                    .pmc_cache_misses_mean = statValue(pmc_stats.events[0], .mean),
                    .pmc_cache_references_min = statValue(pmc_stats.events[1], .min),
                    .pmc_cache_references_median = statValue(pmc_stats.events[1], .median),
                    .pmc_cache_references_p95 = statValue(pmc_stats.events[1], .p95),
                    .pmc_cache_references_max = statValue(pmc_stats.events[1], .max),
                    .pmc_cache_references_mean = statValue(pmc_stats.events[1], .mean),
                    .pmc_branches_min = statValue(pmc_stats.events[2], .min),
                    .pmc_branches_median = statValue(pmc_stats.events[2], .median),
                    .pmc_branches_p95 = statValue(pmc_stats.events[2], .p95),
                    .pmc_branches_max = statValue(pmc_stats.events[2], .max),
                    .pmc_branches_mean = statValue(pmc_stats.events[2], .mean),
                    .pmc_branch_misses_min = statValue(pmc_stats.events[3], .min),
                    .pmc_branch_misses_median = statValue(pmc_stats.events[3], .median),
                    .pmc_branch_misses_p95 = statValue(pmc_stats.events[3], .p95),
                    .pmc_branch_misses_max = statValue(pmc_stats.events[3], .max),
                    .pmc_branch_misses_mean = statValue(pmc_stats.events[3], .mean),
                };
                if (row_buffer) |*rows_list| {
                    try rows_list.append(init.arena.allocator(), row);
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

    if (row_buffer) |*rows_list| {
        if (csv_enabled and csv_needs_header) {
            try csv.writeHeader(csv_writer);
        }
        if (human_writer) |writer| {
            if (!human_header_written) {
                try reporting.writeHumanHeader(writer);
                human_header_written = true;
            }
        }
        for (rows_list.items) |row| {
            if (csv_enabled) {
                try csv.writeRow(csv_writer, row);
            }
            if (human_writer) |writer| {
                try reporting.writeHumanRow(writer, row);
            }
        }
        rows_list.deinit(init.arena.allocator());
    }
}

const DatasetAssets = dataset_setup.DatasetAssets;

fn buildDatasetAssets(allocator: std.mem.Allocator, config: MicrobenchConfig) !DatasetAssets {
    var base = try Buffer.init(allocator, config.cols, config.rows);
    defer base.deinit(allocator);
    return dataset_setup.buildDatasetAssets(
        allocator,
        config.dataset,
        config.text_mix,
        config.style_mix,
        config.seed,
        &base.fb,
    );
}

fn runMicroBenchmark(
    allocator: std.mem.Allocator,
    config: MicrobenchConfig,
    pmc_state: *pmc.Pmc,
    terminal: ?*terminal_mod.Terminal,
) !MicrobenchResult {
    var assets = try buildDatasetAssets(allocator, config);
    defer assets.deinit(allocator);
    return runEmitBenchmark(allocator, config, &assets, pmc_state, terminal);
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
    const target_glyph_cells = @as(u32, config.dataset.width) * @as(u32, config.dataset.height) * 2;
    try print_helpers.buildPrintText(allocator, &text_buffer, config.text_mix, config.seed, target_glyph_cells);

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
    const print_mode: print_helpers.PrintMode = switch (config.mode) {
        .print => .print,
        .print_assume_no_grapheme => .print_assume_no_grapheme,
        else => unreachable,
    };

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

fn nowTimestampNs() u64 {
    var tv: std.posix.timeval = undefined;
    std.posix.gettimeofday(&tv, null);

    const sec_ns = @as(u64, @intCast(tv.sec)) * std.time.ns_per_s;
    const usec_ns = @as(u64, @intCast(tv.usec)) * std.time.ns_per_us;
    return sec_ns + usec_ns;
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
    return sec_ns + usec_ns;
}
