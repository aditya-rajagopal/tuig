const std = @import("std");

const common = @import("../common.zig");
const csv_mod = @import("../csv.zig");
const reporting = @import("../reporting.zig");
const bench_catalog = @import("../bench_catalog.zig");
const stats = @import("../stats.zig");
const types = @import("../types.zig");
const pmc_mod = @import("../pmc/root.zig");
const renderer = @import("renderer");
const style_mix_mod = @import("../style_mix.zig");
const text_mix_mod = @import("../text_mix.zig");
const print_helpers = @import("../print_helpers.zig");

const Print = @This();

text_mix: common.TextMixArg = common.default_text_mix,
style_mix: common.StyleMixArg = common.default_style_mix,
csv: ?[]const u8 = null,
warmup: u64 = common.default_warmup_frames,
frames: u64 = common.default_frames_total,
cols: u32 = common.default_cols,
rows: u32 = common.default_rows,
seed: u64 = common.default_seed,
pmc: bool = false,

pub const help =
    \\Usage:
    \\  zig build benchmark -- print [options]
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

pub fn execute(self: Print, ctx: common.CommandContext, mode: types.BenchMode) !void {
    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &.{});
    const stdout = &stdout_writer.interface;

    try common.validateRunArgs(self.frames, self.warmup, self.cols, self.rows);

    var pmc_state = try pmc_mod.Pmc.init(self.pmc);
    defer pmc_state.deinit();

    const e2e_active = false;
    const cols = self.cols;
    const rows = self.rows;

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
    var single_text_mix = [_]text_mix_mod.TextMix{self.text_mix.value};
    var single_style_mix = [_]style_mix_mod.StyleMix{self.style_mix.value};
    const text_mix_list = if (self.text_mix.mode == .all) bench_catalog.all_text_mixes[0..] else single_text_mix[0..];
    const style_mix_list = if (self.style_mix.mode == .all) bench_catalog.all_style_mixes[0..] else single_style_mix[0..];

    for (bench_catalog.print_datasets) |print_dataset| {
        for (text_mix_list) |text_mix_item| {
            for (style_mix_list) |style_mix_item| {
                const print_config = PrintBenchConfig{
                    .mode = mode,
                    .frames_total = self.frames,
                    .warmup_frames = self.warmup,
                    .seed = self.seed,
                    .cols = @intCast(cols),
                    .rows = @intCast(rows),
                    .dataset = print_dataset,
                    .text_mix = text_mix_item,
                    .style_mix = style_mix_item,
                };
                const timestamp_ns = common.nowTimestampNs();
                const result = try runPrintBenchmark(ctx.allocator, print_config, &pmc_state, ctx.io);
                const pmc_stats = result.pmc_stats;
                const row = csv_mod.Row{
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
                    .pmc_cache_misses_min = common.statValue(pmc_stats.cache_misses, .min),
                    .pmc_cache_misses_median = common.statValue(pmc_stats.cache_misses, .median),
                    .pmc_cache_misses_p95 = common.statValue(pmc_stats.cache_misses, .p95),
                    .pmc_cache_misses_max = common.statValue(pmc_stats.cache_misses, .max),
                    .pmc_cache_misses_mean = common.statValue(pmc_stats.cache_misses, .mean),
                    .pmc_cache_references_min = common.statValue(pmc_stats.cache_references, .min),
                    .pmc_cache_references_median = common.statValue(pmc_stats.cache_references, .median),
                    .pmc_cache_references_p95 = common.statValue(pmc_stats.cache_references, .p95),
                    .pmc_cache_references_max = common.statValue(pmc_stats.cache_references, .max),
                    .pmc_cache_references_mean = common.statValue(pmc_stats.cache_references, .mean),
                    .pmc_branches_min = common.statValue(pmc_stats.branches, .min),
                    .pmc_branches_median = common.statValue(pmc_stats.branches, .median),
                    .pmc_branches_p95 = common.statValue(pmc_stats.branches, .p95),
                    .pmc_branches_max = common.statValue(pmc_stats.branches, .max),
                    .pmc_branches_mean = common.statValue(pmc_stats.branches, .mean),
                    .pmc_branch_misses_min = common.statValue(pmc_stats.branch_misses, .min),
                    .pmc_branch_misses_median = common.statValue(pmc_stats.branch_misses, .median),
                    .pmc_branch_misses_p95 = common.statValue(pmc_stats.branch_misses, .p95),
                    .pmc_branch_misses_max = common.statValue(pmc_stats.branch_misses, .max),
                    .pmc_branch_misses_mean = common.statValue(pmc_stats.branch_misses, .mean),
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
const PrintBenchConfig = types.PrintBenchConfig;
const Buffer = types.Buffer;

fn runPrintBenchmark(
    allocator: std.mem.Allocator,
    config: PrintBenchConfig,
    pmc_state: *pmc_mod.Pmc,
    io: std.Io,
) !MicrobenchResult {
    const warmup_frames: usize = @intCast(config.warmup_frames);
    const measured_frames: usize = @intCast(config.frames_total - config.warmup_frames);
    const durations = try allocator.alignedAlloc(u64, common.buffer_alignment, measured_frames);
    const scratch = try allocator.alignedAlloc(u64, common.buffer_alignment, measured_frames);
    defer allocator.free(durations);
    defer allocator.free(scratch);

    var front = try Buffer.init(allocator, config.cols, config.rows);
    defer front.deinit(allocator);
    var back = try Buffer.init(allocator, config.cols, config.rows);
    defer back.deinit(allocator);

    const palette_len = style_mix_mod.paletteLen(config.style_mix);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    defer style_sheet.deinit(allocator);
    const style_ids = try allocator.alignedAlloc(renderer.Style.Id, common.buffer_alignment, palette_len);
    defer allocator.free(style_ids);
    const style_slice = style_mix_mod.fillStyleIds(&style_sheet, allocator, config.style_mix, style_ids);

    var text_buffer: std.ArrayList(u8) = .empty;
    defer text_buffer.deinit(allocator);
    const target_glyph_cells = @as(u32, config.dataset.width) * @as(u32, config.dataset.height) * 2;
    try print_helpers.buildPrintText(allocator, &text_buffer, config.text_mix, config.seed, target_glyph_cells);

    var frame_timer = try std.time.Timer.start();
    const pmc_active = pmc_state.start();
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
            try pmc_state.reset();
            io.sleep(.{ .nanoseconds = 50 * 1000 }, .real) catch {};
        }
        frame_timer.reset();
        const result = try print_helpers.renderPrintDataset(front.fb.scissor(), config.dataset, print_mode, codepoint_buffer[0..], text_buffer.items, style_id);
        const delta_ns = frame_timer.read();
        if (pmc_samples.active) {
            const snapshot = try pmc_state.lap();
            pmc_samples.record(measured_index, snapshot);
        }
        durations[measured_index] = delta_ns;
        bytes_total += @as(u64, @intCast(result.bytes_consumed));
        dirty_ratio_sum += common.computeDirtyRatio(&front.fb, &back.fb);
        style_runs_sum += @as(f64, @floatFromInt(common.countStyleRuns(&front.fb)));
        const usage_curr = std.posix.getrusage(std.posix.rusage.SELF);
        fault_samples.record(measured_index, usage_prev, usage_curr);
        usage_prev = usage_curr;
        std.mem.swap(Buffer, &front, &back);
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
