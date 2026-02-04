const std = @import("std");
const assert = std.debug.assert;

const bench_catalog = @import("bench_catalog.zig");
const stats = @import("stats.zig");
const renderer = @import("renderer");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");
const types = @import("types.zig");

pub const CommandContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
};

pub const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

pub const default_frames_total: u64 = 10_000;
pub const default_warmup_frames: u64 = 1_000;
pub const default_seed: u64 = 0;
pub const default_cols: u32 = 200;
pub const default_rows: u32 = 60;

const render_datasets = bench_catalog.render_datasets;

pub const RenderDatasetArg = struct {
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

pub const TextMixArg = struct {
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

pub const StyleMixArg = struct {
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

pub const default_render_dataset = RenderDatasetArg{ .mode = .all, .index = 0 };
pub const default_text_mix = TextMixArg{ .mode = .single, .value = .common };
pub const default_style_mix = StyleMixArg{ .mode = .single, .value = .flat };

const StatField = types.StatField;
const ResourceStats = types.ResourceStats;

pub fn statValue(stat: ?stats.Stats, field: StatField) ?u64 {
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

pub fn validateRunArgs(frames: u64, warmup: u64, cols: u32, rows: u32) !void {
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

pub fn nowTimestampNs() u64 {
    var tv: std.posix.timeval = undefined;
    std.posix.gettimeofday(&tv, null);

    const sec_ns = @as(u64, @intCast(tv.sec)) * std.time.ns_per_s;
    const usec_ns = @as(u64, @intCast(tv.usec)) * std.time.ns_per_us;
    return sec_ns + usec_ns;
}

pub fn computeDirtyRatio(front: *const renderer.FrameBuffer, back: *const renderer.FrameBuffer) f64 {
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

pub fn countStyleRuns(buffer: *const renderer.FrameBuffer) u64 {
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

pub fn computeResourceStats(start: std.posix.rusage, end: std.posix.rusage) ResourceStats {
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
