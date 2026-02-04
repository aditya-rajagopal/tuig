const std = @import("std");

const common = @import("../common.zig");
const csv_mod = @import("../csv.zig");
const reporting = @import("../reporting.zig");
const bench_catalog = @import("../bench_catalog.zig");
const dataset_setup = @import("../dataset_setup.zig");
const stats = @import("../stats.zig");
const types = @import("../types.zig");
const pmc_mod = @import("../pmc/root.zig");
const terminal_mod = @import("terminal");
const style_mix_mod = @import("../style_mix.zig");
const text_mix_mod = @import("../text_mix.zig");

const Render = @This();

dataset: common.RenderDatasetArg = common.default_render_dataset,
text_mix: common.TextMixArg = common.default_text_mix,
style_mix: common.StyleMixArg = common.default_style_mix,
e2e: bool = false,
csv: ?[]const u8 = null,
frames: u64 = common.default_frames_total,
warmup: u64 = common.default_warmup_frames,
cols: u32 = common.default_cols,
rows: u32 = common.default_rows,
seed: u64 = common.default_seed,
pmc: bool = false,

pub const help =
    \\Usage:
    \\  zig build benchmark -- render-full [options]
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
    \\  zig build benchmark -- render-full
    \\  zig build benchmark -- render-diff --dataset=all
;

pub fn execute(self: Render, ctx: common.CommandContext, mode: types.BenchMode) !void {
    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &.{});
    const stdout = &stdout_writer.interface;

    try common.validateRunArgs(self.frames, self.warmup, self.cols, self.rows);

    var pmc_state = try pmc_mod.Pmc.init(self.pmc);
    defer pmc_state.deinit();

    const e2e_active = self.e2e;
    var terminal: terminal_mod.Terminal = undefined;
    var terminal_active = false;
    var cols = self.cols;
    var rows = self.rows;
    const terminal_write_buffer: []align(std.heap.page_size_min) u8 = ctx.allocator.alignedAlloc(u8, common.buffer_alignment, 4 * 4096) catch unreachable;
    if (e2e_active) {
        const term_config: terminal_mod.TerminalConfig = .{ .raw = true, .alt_screen = true, .cursor_visable = false };
        try terminal.init(term_config, terminal_write_buffer);
        terminal_active = true;
        cols = terminal.size.width;
        rows = terminal.size.height;
    }
    defer if (terminal_active) terminal.deinit();

    const csv_enabled = self.csv != null;
    var csv_file: ?std.Io.File = null;
    var csv_file_writer: ?std.Io.File.Writer = null;
    var csv_file_buffer: [8192]u8 = undefined;
    var csv_writer: *std.Io.Writer = stdout;
    const human_writer: ?*std.Io.Writer = stdout;
    var human_header_written = false;
    var csv_needs_header = true;

    if (self.csv) |path| {
        const dir = std.Io.Dir.cwd();
        var file = dir.openFile(ctx.io, path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(ctx.io, path, .{}),
            else => return err,
        };
        csv_file = file;
        const stat = try file.stat(ctx.io);
        csv_file_writer = file.writer(ctx.io, &csv_file_buffer);
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
        if (csv_file) |file| file.close(ctx.io);
    }

    var row_buffer: ?std.ArrayList(csv_mod.Row) = null;
    if (e2e_active) {
        row_buffer = .empty;
    } else {
        if (csv_enabled and csv_needs_header) {
            try csv_mod.writeHeader(csv_writer);
        }
        if (human_writer) |writer| {
            try reporting.writeHumanHeader(writer);
            human_header_written = true;
        }
    }

    const mode_label = @tagName(mode);
    var single_dataset = [_]bench_catalog.DatasetSpec{bench_catalog.render_datasets[self.dataset.index]};
    var single_text_mix = [_]text_mix_mod.TextMix{self.text_mix.value};
    var single_style_mix = [_]style_mix_mod.StyleMix{self.style_mix.value};

    const dataset_list = if (self.dataset.mode == .all) bench_catalog.render_datasets[0..] else single_dataset[0..];
    const text_mix_list = if (self.text_mix.mode == .all) bench_catalog.all_text_mixes[0..] else single_text_mix[0..];
    const style_mix_list = if (self.style_mix.mode == .all) bench_catalog.all_style_mixes[0..] else single_style_mix[0..];
    const terminal_ptr: ?*terminal_mod.Terminal = if (terminal_active) &terminal else null;
    var local_arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer local_arena.deinit();
    const allocator = local_arena.allocator();

    for (dataset_list) |dataset_item| {
        for (text_mix_list) |text_mix_item| {
            for (style_mix_list) |style_mix_item| {
                defer _ = local_arena.reset(.retain_capacity);
                const micro_config = MicrobenchConfig{
                    .mode = mode,
                    .frames_total = self.frames,
                    .warmup_frames = self.warmup,
                    .seed = self.seed,
                    .cols = @intCast(cols),
                    .rows = @intCast(rows),
                    .dataset = dataset_item,
                    .text_mix = text_mix_item,
                    .style_mix = style_mix_item,
                };
                const timestamp_ns = common.nowTimestampNs();

                var assets = try buildDatasetAssets(allocator, micro_config);
                const result = try runEmitBenchmark(&local_arena, micro_config, &assets, &pmc_state, terminal_ptr, ctx.io);
                const pmc_stats = result.pmc_stats;
                const row = csv_mod.Row{
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
                    .page_faults_minor_min = common.statValue(result.fault_stats.minor, .min),
                    .page_faults_minor_median = common.statValue(result.fault_stats.minor, .median),
                    .page_faults_minor_p95 = common.statValue(result.fault_stats.minor, .p95),
                    .page_faults_minor_max = common.statValue(result.fault_stats.minor, .max),
                    .page_faults_minor_mean = common.statValue(result.fault_stats.minor, .mean),
                    .page_faults_major_min = common.statValue(result.fault_stats.major, .min),
                    .page_faults_major_median = common.statValue(result.fault_stats.major, .median),
                    .page_faults_major_p95 = common.statValue(result.fault_stats.major, .p95),
                    .page_faults_major_max = common.statValue(result.fault_stats.major, .max),
                    .page_faults_major_mean = common.statValue(result.fault_stats.major, .mean),
                    .max_rss_bytes = result.resources.max_rss_bytes,
                    .bytes_total = result.bytes_total,
                    .bytes_mean = result.bytes_mean,
                    .dirty_ratio_mean = result.dirty_ratio_mean,
                    .style_runs_mean = result.style_runs_mean,
                    .pmc_cycles_min = common.statValue(pmc_stats.cycles, .min),
                    .pmc_cycles_median = common.statValue(pmc_stats.cycles, .median),
                    .pmc_cycles_p95 = common.statValue(pmc_stats.cycles, .p95),
                    .pmc_cycles_max = common.statValue(pmc_stats.cycles, .max),
                    .pmc_cycles_mean = common.statValue(pmc_stats.cycles, .mean),
                    .pmc_instructions_min = common.statValue(pmc_stats.instructions, .min),
                    .pmc_instructions_median = common.statValue(pmc_stats.instructions, .median),
                    .pmc_instructions_p95 = common.statValue(pmc_stats.instructions, .p95),
                    .pmc_instructions_max = common.statValue(pmc_stats.instructions, .max),
                    .pmc_instructions_mean = common.statValue(pmc_stats.instructions, .mean),
                    .pmc_cache_misses_min = common.statValue(pmc_stats.events[0], .min),
                    .pmc_cache_misses_median = common.statValue(pmc_stats.events[0], .median),
                    .pmc_cache_misses_p95 = common.statValue(pmc_stats.events[0], .p95),
                    .pmc_cache_misses_max = common.statValue(pmc_stats.events[0], .max),
                    .pmc_cache_misses_mean = common.statValue(pmc_stats.events[0], .mean),
                    .pmc_cache_references_min = common.statValue(pmc_stats.events[1], .min),
                    .pmc_cache_references_median = common.statValue(pmc_stats.events[1], .median),
                    .pmc_cache_references_p95 = common.statValue(pmc_stats.events[1], .p95),
                    .pmc_cache_references_max = common.statValue(pmc_stats.events[1], .max),
                    .pmc_cache_references_mean = common.statValue(pmc_stats.events[1], .mean),
                    .pmc_branches_min = common.statValue(pmc_stats.events[2], .min),
                    .pmc_branches_median = common.statValue(pmc_stats.events[2], .median),
                    .pmc_branches_p95 = common.statValue(pmc_stats.events[2], .p95),
                    .pmc_branches_max = common.statValue(pmc_stats.events[2], .max),
                    .pmc_branches_mean = common.statValue(pmc_stats.events[2], .mean),
                    .pmc_branch_misses_min = common.statValue(pmc_stats.events[3], .min),
                    .pmc_branch_misses_median = common.statValue(pmc_stats.events[3], .median),
                    .pmc_branch_misses_p95 = common.statValue(pmc_stats.events[3], .p95),
                    .pmc_branch_misses_max = common.statValue(pmc_stats.events[3], .max),
                    .pmc_branch_misses_mean = common.statValue(pmc_stats.events[3], .mean),
                };
                if (row_buffer) |*rows_list| {
                    try rows_list.append(ctx.allocator, row);
                } else {
                    if (csv_enabled) {
                        try csv_mod.writeRow(csv_writer, row);
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
            try csv_mod.writeHeader(csv_writer);
        }
        if (human_writer) |writer| {
            if (!human_header_written) {
                try reporting.writeHumanHeader(writer);
                human_header_written = true;
            }
        }
        for (rows_list.items) |row| {
            if (csv_enabled) {
                try csv_mod.writeRow(csv_writer, row);
            }
            if (human_writer) |writer| {
                try reporting.writeHumanRow(writer, row);
            }
        }
        rows_list.deinit(ctx.allocator);
    }
}

const MicrobenchResult = types.MicrobenchResult;
const PmcSamples = types.PmcSamples;
const ResourceSamples = types.ResourceSamples;
const MicrobenchConfig = types.MicrobenchConfig;
const Buffer = types.Buffer;
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

fn runEmitBenchmark(
    arena: *std.heap.ArenaAllocator,
    config: MicrobenchConfig,
    assets: *DatasetAssets,
    pmc_state: *pmc_mod.Pmc,
    terminal: ?*terminal_mod.Terminal,
    io: std.Io,
) !MicrobenchResult {
    const allocator = arena.allocator();
    const warmup_frames: usize = @intCast(config.warmup_frames);
    const measured_frames: usize = @intCast(config.frames_total - config.warmup_frames);
    const durations = try allocator.alignedAlloc(u64, common.buffer_alignment, measured_frames);
    const scratch = try allocator.alignedAlloc(u64, common.buffer_alignment, measured_frames);

    var front = try Buffer.init(allocator, config.cols, config.rows);
    var back = try Buffer.init(allocator, config.cols, config.rows);

    var writer_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var sink = std.Io.Writer.Discarding.init(&writer_buf);
    var output_writer: *std.Io.Writer = &sink.writer;
    var output_count: *u64 = &sink.count;
    var count: u64 = 0;
    if (terminal) |tty| {
        output_writer = tty.getWriter();
        output_count = &count;
    }

    var frame_timer = try std.time.Timer.start();
    const pmc_active = pmc_state.start(.{
        "cache-misses",
        "cache-references",
        "branches",
        "branch-misses",
    });
    var pmc_samples = try PmcSamples.init(allocator, pmc_active, measured_frames);
    var fault_samples = try ResourceSamples.init(allocator, measured_frames);

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
        dirty_ratio_sum += common.computeDirtyRatio(&front.fb, &back.fb);
        style_runs_sum += @as(f64, @floatFromInt(common.countStyleRuns(&front.fb)));
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
    const resources = common.computeResourceStats(usage_start, usage_end);
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
