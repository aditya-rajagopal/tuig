const std = @import("std");

const csv = @import("csv.zig");

pub fn writeHumanHeader(writer: *std.Io.Writer) !void {
    try writer.writeAll("Benchmark results\n");
}

pub fn writeHumanRow(writer: *std.Io.Writer, row: csv.Row) !void {
    const dataset = row.dataset orelse "NA";
    const text_mix_label = row.text_mix orelse "NA";
    const style_mix_label = row.style_mix orelse "NA";
    const e2e_label = if (row.e2e) "yes" else "no";

    var cols_buf: [16]u8 = undefined;
    var rows_buf: [16]u8 = undefined;
    const cols_str = if (row.cols) |cols| std.fmt.bufPrint(&cols_buf, "{d}", .{cols}) catch "NA" else "NA";
    const rows_str = if (row.rows) |rows| std.fmt.bufPrint(&rows_buf, "{d}", .{rows}) catch "NA" else "NA";
    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{s}x{s}", .{ cols_str, rows_str }) catch "NAxNA";

    var frames_buf: [64]u8 = undefined;
    const frames_str = std.fmt.bufPrint(&frames_buf, "{d} (warmup {d})", .{ row.frames_total, row.warmup_frames }) catch "NA";

    try writer.writeAll("summary\n");
    try writer.print("{s}: {s}\n", .{ "mode", row.mode });
    try writer.print("{s}: {s}\n", .{ "e2e", e2e_label });
    try writer.print("{s}: {s}\n", .{ "dataset", dataset });
    try writer.print("{s}: {s}\n", .{ "text_mix", text_mix_label });
    try writer.print("{s}: {s}\n", .{ "style_mix", style_mix_label });
    try writer.print("{s}: {s}\n", .{ "size", size_str });
    try writer.print("{s}: {s}\n", .{ "frames", frames_str });
    try writer.print("{s}: {d}\n\n", .{ "seed", row.seed });

    try writer.writeAll("timing(ms)\n");
    try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ "metric", "min", "med", "p95", "mean", "max" });
    try writeStatsRowF64(
        writer,
        "frame",
        nsToMs(row.time_min_ns),
        nsToMs(row.time_median_ns),
        nsToMs(row.time_p95_ns),
        nsToMs(row.time_mean_ns),
        nsToMs(row.time_max_ns),
    );
    try writer.writeAll("\n");

    try writer.writeAll("bytes\n");
    try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ "metric", "total", "mean", "dirty", "style" });
    try writeBytesRow(writer, "frame", row.bytes_total, row.bytes_mean, row.dirty_ratio_mean, row.style_runs_mean);
    try writer.writeAll("\n");

    try writer.writeAll("cpu(ms)\n");
    try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ "metric", "total", "user", "sys", "rss" });
    try writeCpuRow(writer, "process", row.cpu_time_ns, row.cpu_user_ns, row.cpu_sys_ns, row.max_rss_bytes);

    if (hasFaultStats(row)) {
        try writer.writeAll("\nfaults(counts)\n");
        try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ "metric", "min", "med", "p95", "mean", "max" });
        try writeStatsRowU64(
            writer,
            "minor",
            row.page_faults_minor_min,
            row.page_faults_minor_median,
            row.page_faults_minor_p95,
            row.page_faults_minor_mean,
            row.page_faults_minor_max,
        );
        try writeStatsRowU64(
            writer,
            "major",
            row.page_faults_major_min,
            row.page_faults_major_median,
            row.page_faults_major_p95,
            row.page_faults_major_mean,
            row.page_faults_major_max,
        );
    }

    if (hasPmcData(row)) {
        try writer.writeAll("\npmc(counts)\n");
        try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ "metric", "min", "med", "p95", "mean", "max" });
        try writeStatsRowU64(writer, "cycles", row.pmc_cycles_min, row.pmc_cycles_median, row.pmc_cycles_p95, row.pmc_cycles_mean, row.pmc_cycles_max);
        try writeStatsRowU64(writer, "instr", row.pmc_instructions_min, row.pmc_instructions_median, row.pmc_instructions_p95, row.pmc_instructions_mean, row.pmc_instructions_max);
        try writeStatsRowU64(writer, "cache-miss", row.pmc_cache_misses_min, row.pmc_cache_misses_median, row.pmc_cache_misses_p95, row.pmc_cache_misses_mean, row.pmc_cache_misses_max);
        try writeStatsRowU64(writer, "cache-ref", row.pmc_cache_references_min, row.pmc_cache_references_median, row.pmc_cache_references_p95, row.pmc_cache_references_mean, row.pmc_cache_references_max);
        try writeStatsRowU64(writer, "branches", row.pmc_branches_min, row.pmc_branches_median, row.pmc_branches_p95, row.pmc_branches_mean, row.pmc_branches_max);
        try writeStatsRowU64(writer, "branch-ms", row.pmc_branch_misses_min, row.pmc_branch_misses_median, row.pmc_branch_misses_p95, row.pmc_branch_misses_mean, row.pmc_branch_misses_max);
    }

    try writer.writeAll("\n");
}

fn hasPmcData(row: csv.Row) bool {
    return row.pmc_cycles_mean != null or
        row.pmc_instructions_mean != null or
        row.pmc_cache_misses_mean != null or
        row.pmc_cache_references_mean != null or
        row.pmc_branches_mean != null or
        row.pmc_branch_misses_mean != null;
}

fn hasFaultStats(row: csv.Row) bool {
    return row.page_faults_minor_mean != null or row.page_faults_major_mean != null;
}

fn writeStatsRowF64(
    writer: *std.Io.Writer,
    label: []const u8,
    min: f64,
    median: f64,
    p95: f64,
    mean: f64,
    max: f64,
) !void {
    var min_buf: [24]u8 = undefined;
    var median_buf: [24]u8 = undefined;
    var p95_buf: [24]u8 = undefined;
    var mean_buf: [24]u8 = undefined;
    var max_buf: [24]u8 = undefined;
    const min_str = formatF64(&min_buf, min);
    const median_str = formatF64(&median_buf, median);
    const p95_str = formatF64(&p95_buf, p95);
    const mean_str = formatF64(&mean_buf, mean);
    const max_str = formatF64(&max_buf, max);
    try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ label, min_str, median_str, p95_str, mean_str, max_str });
}

fn writeStatsRowU64(
    writer: *std.Io.Writer,
    label: []const u8,
    min: ?u64,
    median: ?u64,
    p95: ?u64,
    mean: ?u64,
    max: ?u64,
) !void {
    var min_buf: [24]u8 = undefined;
    var median_buf: [24]u8 = undefined;
    var p95_buf: [24]u8 = undefined;
    var mean_buf: [24]u8 = undefined;
    var max_buf: [24]u8 = undefined;
    const min_str = formatOptionalU64(&min_buf, min);
    const median_str = formatOptionalU64(&median_buf, median);
    const p95_str = formatOptionalU64(&p95_buf, p95);
    const mean_str = formatOptionalU64(&mean_buf, mean);
    const max_str = formatOptionalU64(&max_buf, max);
    try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ label, min_str, median_str, p95_str, mean_str, max_str });
}

fn writeBytesRow(
    writer: *std.Io.Writer,
    label: []const u8,
    total: ?u64,
    mean: ?f64,
    dirty: ?f64,
    style_runs: ?f64,
) !void {
    var total_buf: [24]u8 = undefined;
    var mean_buf: [24]u8 = undefined;
    var dirty_buf: [24]u8 = undefined;
    var style_buf: [24]u8 = undefined;
    const total_str = formatOptionalU64(&total_buf, total);
    const mean_str = formatOptionalF64(&mean_buf, mean);
    const dirty_str = formatOptionalF64(&dirty_buf, dirty);
    const style_str = formatOptionalF64(&style_buf, style_runs);
    try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ label, total_str, mean_str, dirty_str, style_str });
}

fn writeCpuRow(
    writer: *std.Io.Writer,
    label: []const u8,
    total: ?u64,
    user: ?u64,
    sys: ?u64,
    rss: ?u64,
) !void {
    var total_buf: [24]u8 = undefined;
    var user_buf: [24]u8 = undefined;
    var sys_buf: [24]u8 = undefined;
    var rss_buf: [24]u8 = undefined;
    const total_str = formatOptionalNsMs(&total_buf, total);
    const user_str = formatOptionalNsMs(&user_buf, user);
    const sys_str = formatOptionalNsMs(&sys_buf, sys);
    const rss_str = formatOptionalU64(&rss_buf, rss);
    try writer.print("{s: <9} {s: >9} {s: >9} {s: >9} {s: >9}\n", .{ label, total_str, user_str, sys_str, rss_str });
}

fn formatOptionalU64(buf: []u8, value: ?u64) []const u8 {
    if (value) |val| {
        return std.fmt.bufPrint(buf, "{d}", .{val}) catch "NA";
    }
    return "NA";
}

fn formatOptionalF64(buf: []u8, value: ?f64) []const u8 {
    if (value) |val| {
        return std.fmt.bufPrint(buf, "{d:.3}", .{val}) catch "NA";
    }
    return "NA";
}

fn formatOptionalNsMs(buf: []u8, value: ?u64) []const u8 {
    if (value) |ns| {
        return std.fmt.bufPrint(buf, "{d:.3}", .{nsToMs(ns)}) catch "NA";
    }
    return "NA";
}

fn formatF64(buf: []u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch "NA";
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}
