const std = @import("std");
const assert = std.debug.assert;

const terminal_mod = @import("terminal");

const common = @import("../common.zig");
const stats = @import("../stats.zig");
const pmc_mod = @import("../pmc/root.zig");
const types = @import("../types.zig");
const rng = @import("../rng.zig");

const EventParse = @This();

const default_frames: u64 = 5_000;
const default_warmup: u64 = 500;
const default_events_per_iter: u32 = 4_096;

const parser_name = "parseEvent";

const mix_roll_scale: u32 = 1000;
const keyboard_weight_permille: u32 = 490;
const mouse_weight_permille: u32 = 490;
const other_weight_permille: u32 = 20;

comptime {
    if (keyboard_weight_permille + mouse_weight_permille + other_weight_permille != mix_roll_scale) {
        @compileError("event_parse mix weights must sum to mix_roll_scale");
    }
}

const keyboard_threshold: u32 = keyboard_weight_permille;
const mouse_threshold: u32 = keyboard_threshold + mouse_weight_permille;

csv: ?[]const u8 = null,
frames: u64 = default_frames,
warmup: u64 = default_warmup,
seed: u64 = common.default_seed,
events_per_iter: u32 = default_events_per_iter,
pmc: bool = false,

pub const help =
    \\Usage:
    \\  zig build benchmark -- event_parse [options]
    \\
    \\Options:
    \\  --csv=<path>
    \\  --frames=<N>
    \\  --warmup=<N>
    \\  --seed=<N>
    \\  --events-per-iter=<N>
    \\  --pmc
    \\  -h, --help
    \\
    \\Generator defaults:
    \\  events-per-iter: 4096 generated sequences
    \\  mix: 49% keyboard, 49% mouse, 2% other
    \\  malformed/incomplete generation disabled
    \\  feed: concatenated stream parsed using consumed_bytes stepping
;

const IterationCounters = struct {
    generated_events: u64 = 0,
    emitted_events: u64 = 0,
    parse_calls: u64 = 0,
    consumed_zero_calls: u64 = 0,
    consumed_bytes: u64 = 0,
};

const BenchmarkResult = struct {
    timing: stats.Stats,
    pmc_stats: types.PmcStats,
    resources: types.ResourceStats,
    fault_stats: types.FaultStats,

    generated_events_total: u64,
    emitted_events_total: u64,
    consumed_bytes_total: u64,

    ns_per_event_mean: f64,
    events_per_sec_mean: f64,
    bytes_per_event_mean: f64,
    consumed_zero_rate_mean: f64,
};

const Row = struct {
    timestamp_ns: u64,
    mode: []const u8,
    parser: []const u8,
    frames_total: u64,
    warmup_frames: u64,
    seed: u64,
    events_per_iter: u32,

    time_min_ns: u64,
    time_median_ns: u64,
    time_p95_ns: u64,
    time_max_ns: u64,
    time_mean_ns: u64,

    generated_events_total: u64,
    emitted_events_total: u64,
    consumed_bytes_total: u64,

    ns_per_event_mean: f64,
    events_per_sec_mean: f64,
    bytes_per_event_mean: f64,
    consumed_zero_rate_mean: f64,

    cpu_time_ns: u64,
    cpu_user_ns: u64,
    cpu_sys_ns: u64,
    page_faults_minor: u64,
    page_faults_major: u64,
    max_rss_bytes: u64,

    page_faults_minor_min: ?u64,
    page_faults_minor_median: ?u64,
    page_faults_minor_p95: ?u64,
    page_faults_minor_max: ?u64,
    page_faults_minor_mean: ?u64,

    page_faults_major_min: ?u64,
    page_faults_major_median: ?u64,
    page_faults_major_p95: ?u64,
    page_faults_major_max: ?u64,
    page_faults_major_mean: ?u64,

    pmc_cycles_min: ?u64,
    pmc_cycles_median: ?u64,
    pmc_cycles_p95: ?u64,
    pmc_cycles_max: ?u64,
    pmc_cycles_mean: ?u64,

    pmc_instructions_min: ?u64,
    pmc_instructions_median: ?u64,
    pmc_instructions_p95: ?u64,
    pmc_instructions_max: ?u64,
    pmc_instructions_mean: ?u64,

    pmc_cache_misses_min: ?u64,
    pmc_cache_misses_median: ?u64,
    pmc_cache_misses_p95: ?u64,
    pmc_cache_misses_max: ?u64,
    pmc_cache_misses_mean: ?u64,

    pmc_cache_references_min: ?u64,
    pmc_cache_references_median: ?u64,
    pmc_cache_references_p95: ?u64,
    pmc_cache_references_max: ?u64,
    pmc_cache_references_mean: ?u64,

    pmc_branches_min: ?u64,
    pmc_branches_median: ?u64,
    pmc_branches_p95: ?u64,
    pmc_branches_max: ?u64,
    pmc_branches_mean: ?u64,

    pmc_branch_misses_min: ?u64,
    pmc_branch_misses_median: ?u64,
    pmc_branch_misses_p95: ?u64,
    pmc_branch_misses_max: ?u64,
    pmc_branch_misses_mean: ?u64,
};

pub fn execute(self: EventParse, ctx: common.CommandContext) !void {
    if (self.frames == 0) {
        std.log.err("frames must be > 0", .{});
        return error.InvalidArgs;
    }
    if (self.warmup >= self.frames) {
        std.log.err("warmup must be < frames", .{});
        return error.InvalidArgs;
    }
    if (self.events_per_iter == 0) {
        std.log.err("events-per-iter must be > 0", .{});
        return error.InvalidArgs;
    }

    var pmc_state = try pmc_mod.Pmc.init(self.pmc);
    defer pmc_state.deinit();

    const result = try runBenchmark(ctx.allocator, self, &pmc_state, ctx.io);

    const row = Row{
        .timestamp_ns = common.nowTimestampNs(),
        .mode = "event_parse",
        .parser = parser_name,
        .frames_total = self.frames,
        .warmup_frames = self.warmup,
        .seed = self.seed,
        .events_per_iter = self.events_per_iter,

        .time_min_ns = result.timing.min,
        .time_median_ns = result.timing.median,
        .time_p95_ns = result.timing.p95,
        .time_max_ns = result.timing.max,
        .time_mean_ns = result.timing.mean,

        .generated_events_total = result.generated_events_total,
        .emitted_events_total = result.emitted_events_total,
        .consumed_bytes_total = result.consumed_bytes_total,

        .ns_per_event_mean = result.ns_per_event_mean,
        .events_per_sec_mean = result.events_per_sec_mean,
        .bytes_per_event_mean = result.bytes_per_event_mean,
        .consumed_zero_rate_mean = result.consumed_zero_rate_mean,

        .cpu_time_ns = result.resources.cpu_time_ns,
        .cpu_user_ns = result.resources.cpu_user_ns,
        .cpu_sys_ns = result.resources.cpu_sys_ns,
        .page_faults_minor = result.resources.page_faults_minor,
        .page_faults_major = result.resources.page_faults_major,
        .max_rss_bytes = result.resources.max_rss_bytes,

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

        .pmc_cycles_min = common.statValue(result.pmc_stats.cycles, .min),
        .pmc_cycles_median = common.statValue(result.pmc_stats.cycles, .median),
        .pmc_cycles_p95 = common.statValue(result.pmc_stats.cycles, .p95),
        .pmc_cycles_max = common.statValue(result.pmc_stats.cycles, .max),
        .pmc_cycles_mean = common.statValue(result.pmc_stats.cycles, .mean),

        .pmc_instructions_min = common.statValue(result.pmc_stats.instructions, .min),
        .pmc_instructions_median = common.statValue(result.pmc_stats.instructions, .median),
        .pmc_instructions_p95 = common.statValue(result.pmc_stats.instructions, .p95),
        .pmc_instructions_max = common.statValue(result.pmc_stats.instructions, .max),
        .pmc_instructions_mean = common.statValue(result.pmc_stats.instructions, .mean),

        .pmc_cache_misses_min = common.statValue(result.pmc_stats.cache_misses, .min),
        .pmc_cache_misses_median = common.statValue(result.pmc_stats.cache_misses, .median),
        .pmc_cache_misses_p95 = common.statValue(result.pmc_stats.cache_misses, .p95),
        .pmc_cache_misses_max = common.statValue(result.pmc_stats.cache_misses, .max),
        .pmc_cache_misses_mean = common.statValue(result.pmc_stats.cache_misses, .mean),

        .pmc_cache_references_min = common.statValue(result.pmc_stats.cache_references, .min),
        .pmc_cache_references_median = common.statValue(result.pmc_stats.cache_references, .median),
        .pmc_cache_references_p95 = common.statValue(result.pmc_stats.cache_references, .p95),
        .pmc_cache_references_max = common.statValue(result.pmc_stats.cache_references, .max),
        .pmc_cache_references_mean = common.statValue(result.pmc_stats.cache_references, .mean),

        .pmc_branches_min = common.statValue(result.pmc_stats.branches, .min),
        .pmc_branches_median = common.statValue(result.pmc_stats.branches, .median),
        .pmc_branches_p95 = common.statValue(result.pmc_stats.branches, .p95),
        .pmc_branches_max = common.statValue(result.pmc_stats.branches, .max),
        .pmc_branches_mean = common.statValue(result.pmc_stats.branches, .mean),

        .pmc_branch_misses_min = common.statValue(result.pmc_stats.branch_misses, .min),
        .pmc_branch_misses_median = common.statValue(result.pmc_stats.branch_misses, .median),
        .pmc_branch_misses_p95 = common.statValue(result.pmc_stats.branch_misses, .p95),
        .pmc_branch_misses_max = common.statValue(result.pmc_stats.branch_misses, .max),
        .pmc_branch_misses_mean = common.statValue(result.pmc_stats.branch_misses, .mean),
    };

    var stdout_writer = std.Io.File.stdout().writer(ctx.io, &.{});
    const stdout = &stdout_writer.interface;
    try writeHuman(stdout, row);

    if (self.csv) |path| {
        try writeCsvFile(ctx, path, row);
    }
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    cfg: EventParse,
    pmc_state: *pmc_mod.Pmc,
    io: std.Io,
) !BenchmarkResult {
    const warmup_frames: usize = @intCast(cfg.warmup);
    const measured_frames: usize = @intCast(cfg.frames - cfg.warmup);

    const durations = try allocator.alignedAlloc(u64, common.buffer_alignment, measured_frames);
    defer allocator.free(durations);
    const scratch = try allocator.alignedAlloc(u64, common.buffer_alignment, measured_frames);
    defer allocator.free(scratch);

    var ns_per_event_sum: f64 = 0;
    var events_per_sec_sum: f64 = 0;
    var bytes_per_event_sum: f64 = 0;
    var consumed_zero_rate_sum: f64 = 0;

    var generated_events_total: u64 = 0;
    var emitted_events_total: u64 = 0;
    var consumed_bytes_total: u64 = 0;

    var prng = rng.init(cfg.seed);
    const random = prng.random();

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    try stream.ensureTotalCapacityPrecise(allocator, @as(usize, cfg.events_per_iter) * 40);

    var timer = try std.time.Timer.start();

    const pmc_active = pmc_state.start();
    var pmc_samples = try types.PmcSamples.init(allocator, pmc_active, measured_frames);
    defer pmc_samples.deinit(allocator);

    var fault_samples = try types.ResourceSamples.init(allocator, measured_frames);
    defer fault_samples.deinit(allocator);

    var warmup_index: usize = 0;
    while (warmup_index < warmup_frames) : (warmup_index += 1) {
        var counters = IterationCounters{};
        stream.clearRetainingCapacity();
        try generateIterationStream(allocator, random, cfg.events_per_iter, &stream, &counters);
        parseStream(stream.items, &counters);
    }

    const usage_start = std.posix.getrusage(std.posix.rusage.SELF);
    var usage_prev = usage_start;

    var measured_index: usize = 0;
    while (measured_index < measured_frames) : (measured_index += 1) {
        var counters = IterationCounters{};
        stream.clearRetainingCapacity();
        try generateIterationStream(allocator, random, cfg.events_per_iter, &stream, &counters);

        if (pmc_samples.active) {
            try pmc_state.reset();
            io.sleep(.{ .nanoseconds = 50 * 1000 }, .real) catch {};
        }

        timer.reset();
        parseStream(stream.items, &counters);
        const delta_ns = timer.read();

        if (pmc_samples.active) {
            const snapshot = try pmc_state.read();
            pmc_samples.record(measured_index, snapshot);
        }

        const usage_curr = std.posix.getrusage(std.posix.rusage.SELF);
        fault_samples.record(measured_index, usage_prev, usage_curr);
        usage_prev = usage_curr;

        durations[measured_index] = delta_ns;

        generated_events_total += counters.generated_events;
        emitted_events_total += counters.emitted_events;
        consumed_bytes_total += counters.consumed_bytes;

        const emitted_f64 = @as(f64, @floatFromInt(counters.emitted_events));
        const consumed_f64 = @as(f64, @floatFromInt(counters.consumed_bytes));
        const parse_calls_f64 = @as(f64, @floatFromInt(@max(counters.parse_calls, 1)));
        const delta_f64 = @as(f64, @floatFromInt(delta_ns));

        ns_per_event_sum += if (counters.emitted_events == 0) 0 else delta_f64 / emitted_f64;
        events_per_sec_sum += if (delta_ns == 0) 0 else emitted_f64 / (delta_f64 / @as(f64, std.time.ns_per_s));
        bytes_per_event_sum += if (counters.emitted_events == 0) 0 else consumed_f64 / emitted_f64;
        consumed_zero_rate_sum += @as(f64, @floatFromInt(counters.consumed_zero_calls)) / parse_calls_f64;
    }

    const timing = stats.computeStats(durations, scratch);
    const usage_end = if (measured_frames == 0) usage_start else usage_prev;
    const resources = common.computeResourceStats(usage_start, usage_end);
    const pmc_stats = pmc_samples.computeStats(scratch);
    const fault_stats = fault_samples.computeStats(scratch);

    const measured_f64 = @as(f64, @floatFromInt(@max(measured_frames, 1)));

    return .{
        .timing = timing,
        .pmc_stats = pmc_stats,
        .resources = resources,
        .fault_stats = fault_stats,
        .generated_events_total = generated_events_total,
        .emitted_events_total = emitted_events_total,
        .consumed_bytes_total = consumed_bytes_total,
        .ns_per_event_mean = ns_per_event_sum / measured_f64,
        .events_per_sec_mean = events_per_sec_sum / measured_f64,
        .bytes_per_event_mean = bytes_per_event_sum / measured_f64,
        .consumed_zero_rate_mean = consumed_zero_rate_sum / measured_f64,
    };
}

fn parseStream(stream: []const u8, counters: *IterationCounters) void {
    var offset: usize = 0;

    while (offset < stream.len) {
        var consumed: usize = 0;
        const emitted = blk: {
            const event = terminal_mod.parseEvent(stream[offset..], &consumed);
            std.mem.doNotOptimizeAway(event);
            break :blk @as(std.meta.Tag(@TypeOf(event)), event) != .none;
        };

        counters.parse_calls += 1;
        if (consumed == 0) {
            counters.consumed_zero_calls += 1;
            break;
        }

        assert(consumed <= stream.len - offset);
        counters.consumed_bytes += consumed;
        offset += consumed;

        if (emitted) counters.emitted_events += 1;
    }
}

fn generateIterationStream(
    allocator: std.mem.Allocator,
    random: std.Random,
    events_per_iter: u32,
    stream: *std.ArrayList(u8),
    counters: *IterationCounters,
) !void {
    var i: u32 = 0;
    while (i < events_per_iter) : (i += 1) {
        const roll = random.intRangeLessThan(u32, 0, mix_roll_scale);
        if (roll < keyboard_threshold) {
            try appendKeyboardSequence(allocator, random, stream);
        } else if (roll < mouse_threshold) {
            try appendMouseSequence(allocator, random, stream);
        } else {
            try appendOtherSequence(allocator, random, stream);
        }

        counters.generated_events += 1;
    }
}

fn appendKeyboardSequence(allocator: std.mem.Allocator, random: std.Random, stream: *std.ArrayList(u8)) !void {
    const roll = random.intRangeLessThan(u32, 0, 1000);

    if (roll < 260) {
        try stream.append(allocator, ascii_keys[rng.index(random, ascii_keys.len)]);
        return;
    }

    if (roll < 380) {
        try stream.append(allocator, '\x1b');
        try stream.append(allocator, ascii_keys[rng.index(random, ascii_keys.len)]);
        return;
    }

    if (roll < 620) {
        const final = cursor_finals[rng.index(random, cursor_finals.len)];
        const mod_value = randomModifierValue(random);
        const event_type = randomEventType(random);

        var buffer: [48]u8 = undefined;
        const sequence = if (random.boolean())
            try std.fmt.bufPrint(&buffer, "\x1b[{c}", .{final})
        else if (random.boolean())
            try std.fmt.bufPrint(&buffer, "\x1b[1;{d}{c}", .{ mod_value, final })
        else
            try std.fmt.bufPrint(&buffer, "\x1b[1;{d}:{d}{c}", .{ mod_value, event_type, final });

        try stream.appendSlice(allocator, sequence);
        return;
    }

    if (roll < 760) {
        const sequence = [3]u8{ '\x1b', 'O', ss3_finals[rng.index(random, ss3_finals.len)] };
        try stream.appendSlice(allocator, sequence[0..]);
        return;
    }

    if (roll < 900) {
        const code = tilde_codes[rng.index(random, tilde_codes.len)];
        const mod_value = randomModifierValue(random);
        const event_type = randomEventType(random);

        var buffer: [48]u8 = undefined;
        const sequence = if (random.boolean())
            try std.fmt.bufPrint(&buffer, "\x1b[{d}~", .{code})
        else if (random.boolean())
            try std.fmt.bufPrint(&buffer, "\x1b[{d};{d}~", .{ code, mod_value })
        else
            try std.fmt.bufPrint(&buffer, "\x1b[{d};{d}:{d}~", .{ code, mod_value, event_type });

        try stream.appendSlice(allocator, sequence);
        return;
    }

    const code = kitty_key_codes[rng.index(random, kitty_key_codes.len)];
    const mod_value = randomModifierValue(random);
    const event_type = randomEventType(random);

    var buffer: [64]u8 = undefined;
    const sequence = if (random.boolean())
        try std.fmt.bufPrint(&buffer, "\x1b[{d};{d}:{d}u", .{ code, mod_value, event_type })
    else
        try std.fmt.bufPrint(&buffer, "\x1b[{d}:{d};{d}:{d}u", .{ code, code, mod_value, event_type });

    try stream.appendSlice(allocator, sequence);
}

fn appendMouseSequence(allocator: std.mem.Allocator, random: std.Random, stream: *std.ArrayList(u8)) !void {
    const use_sgr = random.intRangeLessThan(u32, 0, 100) < 85;

    if (use_sgr) {
        const x = random.intRangeLessThan(u16, 1, 4096);
        const y = random.intRangeLessThan(u16, 1, 4096);
        const mods = randomMouseMods(random);
        const variant = random.intRangeLessThan(u32, 0, 100);

        var number: u16 = undefined;
        var suffix: u8 = 'M';

        if (variant < 35) {
            const button = mouse_buttons_press[rng.index(random, mouse_buttons_press.len)];
            number = button + mods;
            suffix = if (random.boolean()) 'M' else 'm';
        } else if (variant < 65) {
            const button = mouse_buttons_press[rng.index(random, mouse_buttons_press.len)];
            number = 32 + button + mods;
        } else if (variant < 80) {
            number = 32 + 3 + mods;
        } else {
            const button = mouse_scroll_buttons[rng.index(random, mouse_scroll_buttons.len)];
            number = 64 + button + mods;
        }

        var buffer: [64]u8 = undefined;
        const sequence = try std.fmt.bufPrint(&buffer, "\x1b[<{d};{d};{d}{c}", .{ number, x, y, suffix });
        try stream.appendSlice(allocator, sequence);
        return;
    }

    const mods = randomMouseMods(random);
    const variant = random.intRangeLessThan(u32, 0, 100);

    var number: u16 = undefined;
    if (variant < 40) {
        number = mouse_buttons_press[rng.index(random, mouse_buttons_press.len)] + mods;
    } else if (variant < 60) {
        number = 3 + mods;
    } else if (variant < 80) {
        number = 32 + mouse_buttons_press[rng.index(random, mouse_buttons_press.len)] + mods;
    } else {
        number = 64 + mouse_scroll_buttons[rng.index(random, mouse_scroll_buttons.len)] + mods;
    }

    const x = random.intRangeLessThan(u16, 1, 96);
    const y = random.intRangeLessThan(u16, 1, 96);
    const sequence = [6]u8{
        '\x1b',
        '[',
        'M',
        @as(u8, @intCast(number + 32)),
        @as(u8, @intCast(x + 32)),
        @as(u8, @intCast(y + 32)),
    };

    try stream.appendSlice(allocator, sequence[0..]);
}

fn appendOtherSequence(allocator: std.mem.Allocator, random: std.Random, stream: *std.ArrayList(u8)) !void {
    const variant = random.intRangeLessThan(u32, 0, 4);

    var buffer: [80]u8 = undefined;
    const sequence: []const u8 = switch (variant) {
        0 => blk: {
            const flags = random.intRangeLessThan(u16, 0, 256);
            break :blk try std.fmt.bufPrint(&buffer, "\x1b[?{d}u", .{flags});
        },
        1 => blk: {
            const mode = decrpm_modes[rng.index(random, decrpm_modes.len)];
            const status = random.intRangeLessThan(u8, 0, 5);
            break :blk try std.fmt.bufPrint(&buffer, "\x1b[?{d};{d}$y", .{ mode, status });
        },
        2 => blk: {
            if (random.boolean()) {
                break :blk "\x1b[?64;4;6;18;21;22;46;52c";
            }
            const extension = random.intRangeLessThan(u16, 70, 130);
            break :blk try std.fmt.bufPrint(&buffer, "\x1b[?64;{d}c", .{extension});
        },
        else => blk: {
            const id = da2_identification_codes[rng.index(random, da2_identification_codes.len)];
            const firmware = random.intRangeLessThan(u16, 1, 500);
            const keyboard_option = random.intRangeLessThan(u16, 0, 10);
            break :blk try std.fmt.bufPrint(&buffer, "\x1b[>{d};{d};{d}c", .{ id, firmware, keyboard_option });
        },
    };

    try stream.appendSlice(allocator, sequence);
}

fn randomModifierValue(random: std.Random) u16 {
    return random.intRangeLessThan(u16, 1, 257);
}

fn randomEventType(random: std.Random) u8 {
    return random.intRangeLessThan(u8, 1, 4);
}

fn randomMouseMods(random: std.Random) u16 {
    var mods: u16 = 0;
    if (random.boolean()) mods |= 4;
    if (random.boolean()) mods |= 8;
    if (random.boolean()) mods |= 16;
    return mods;
}

fn writeCsvFile(ctx: common.CommandContext, path: []const u8, row: Row) !void {
    const dir = std.Io.Dir.cwd();
    var file = dir.openFile(ctx.io, path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(ctx.io, path, .{}),
        else => return err,
    };
    defer file.close(ctx.io);

    const stat = try file.stat(ctx.io);
    var file_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(ctx.io, &file_buffer);
    const writer = &file_writer.interface;

    if (stat.size > 0) {
        try file_writer.seekTo(stat.size);
    } else {
        try writer.writeAll(
            "timestamp_ns,mode,parser,frames_total,warmup_frames,seed,events_per_iter," ++
                "time_min_ns,time_median_ns,time_p95_ns,time_max_ns,time_mean_ns," ++
                "generated_events_total,emitted_events_total,consumed_bytes_total," ++
                "ns_per_event_mean,events_per_sec_mean,bytes_per_event_mean,consumed_zero_rate_mean," ++
                "cpu_time_ns,cpu_user_ns,cpu_sys_ns,page_faults_minor,page_faults_major,max_rss_bytes," ++
                "page_faults_minor_min,page_faults_minor_median,page_faults_minor_p95,page_faults_minor_max,page_faults_minor_mean," ++
                "page_faults_major_min,page_faults_major_median,page_faults_major_p95,page_faults_major_max,page_faults_major_mean," ++
                "pmc_cycles_min,pmc_cycles_median,pmc_cycles_p95,pmc_cycles_max,pmc_cycles_mean," ++
                "pmc_instructions_min,pmc_instructions_median,pmc_instructions_p95,pmc_instructions_max,pmc_instructions_mean," ++
                "pmc_cache_misses_min,pmc_cache_misses_median,pmc_cache_misses_p95,pmc_cache_misses_max,pmc_cache_misses_mean," ++
                "pmc_cache_references_min,pmc_cache_references_median,pmc_cache_references_p95,pmc_cache_references_max,pmc_cache_references_mean," ++
                "pmc_branches_min,pmc_branches_median,pmc_branches_p95,pmc_branches_max,pmc_branches_mean," ++
                "pmc_branch_misses_min,pmc_branch_misses_median,pmc_branch_misses_p95,pmc_branch_misses_max,pmc_branch_misses_mean\n",
        );
    }

    try writer.print(
        "{d},{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.6},{d:.6},{d:.6},{d:.6},{d},{d},{d},{d},{d},{d},",
        .{
            row.timestamp_ns,
            row.mode,
            row.parser,
            row.frames_total,
            row.warmup_frames,
            row.seed,
            row.events_per_iter,
            row.time_min_ns,
            row.time_median_ns,
            row.time_p95_ns,
            row.time_max_ns,
            row.time_mean_ns,
            row.generated_events_total,
            row.emitted_events_total,
            row.consumed_bytes_total,
            row.ns_per_event_mean,
            row.events_per_sec_mean,
            row.bytes_per_event_mean,
            row.consumed_zero_rate_mean,
            row.cpu_time_ns,
            row.cpu_user_ns,
            row.cpu_sys_ns,
            row.page_faults_minor,
            row.page_faults_major,
            row.max_rss_bytes,
        },
    );

    try writeOptionalU64(writer, row.page_faults_minor_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_minor_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_minor_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_minor_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_minor_mean);
    try writer.writeAll(",");

    try writeOptionalU64(writer, row.page_faults_major_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_major_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_major_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_major_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.page_faults_major_mean);
    try writer.writeAll(",");

    try writeOptionalU64(writer, row.pmc_cycles_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cycles_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cycles_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cycles_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cycles_mean);
    try writer.writeAll(",");

    try writeOptionalU64(writer, row.pmc_instructions_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_instructions_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_instructions_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_instructions_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_instructions_mean);
    try writer.writeAll(",");

    try writeOptionalU64(writer, row.pmc_cache_misses_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_misses_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_misses_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_misses_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_misses_mean);
    try writer.writeAll(",");

    try writeOptionalU64(writer, row.pmc_cache_references_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_references_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_references_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_references_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_cache_references_mean);
    try writer.writeAll(",");

    try writeOptionalU64(writer, row.pmc_branches_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branches_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branches_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branches_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branches_mean);
    try writer.writeAll(",");

    try writeOptionalU64(writer, row.pmc_branch_misses_min);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branch_misses_median);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branch_misses_p95);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branch_misses_max);
    try writer.writeAll(",");
    try writeOptionalU64(writer, row.pmc_branch_misses_mean);
    try writer.writeAll("\n");

    try file_writer.flush();
}

fn writeHuman(writer: *std.Io.Writer, row: Row) !void {
    try writer.writeAll("Benchmark results\n");
    try writer.writeAll("summary\n");
    try writer.print("mode: {s}\n", .{row.mode});
    try writer.print("parser: {s}\n", .{row.parser});
    try writer.print("frames: {d} (warmup {d})\n", .{ row.frames_total, row.warmup_frames });
    try writer.print("seed: {d}\n", .{row.seed});
    try writer.print("events_per_iter: {d}\n\n", .{row.events_per_iter});

    try writer.writeAll("timing(ms)\n");
    try writer.print("{s: <10} {s: >10} {s: >10} {s: >10} {s: >10} {s: >10}\n", .{ "metric", "min", "med", "p95", "mean", "max" });
    try writer.print(
        "{s: <10} {d: >10.3} {d: >10.3} {d: >10.3} {d: >10.3} {d: >10.3}\n\n",
        .{
            "frame",
            nsToMs(row.time_min_ns),
            nsToMs(row.time_median_ns),
            nsToMs(row.time_p95_ns),
            nsToMs(row.time_mean_ns),
            nsToMs(row.time_max_ns),
        },
    );

    try writer.writeAll("parser\n");
    try writer.print("generated_events_total: {d}\n", .{row.generated_events_total});
    try writer.print("emitted_events_total: {d}\n", .{row.emitted_events_total});
    try writer.print("consumed_bytes_total: {d}\n", .{row.consumed_bytes_total});
    try writer.print("ns_per_event_mean: {d:.3}\n", .{row.ns_per_event_mean});
    try writer.print("events_per_sec_mean: {d:.3}\n", .{row.events_per_sec_mean});
    try writer.print("bytes_per_event_mean: {d:.3}\n", .{row.bytes_per_event_mean});
    try writer.print("consumed_zero_rate_mean: {d:.6}\n", .{row.consumed_zero_rate_mean});
    try writer.writeAll("\n");

    try writer.writeAll("cpu(ms)\n");
    try writer.print("process: total={d:.3} user={d:.3} sys={d:.3}\n\n", .{
        nsToMs(row.cpu_time_ns),
        nsToMs(row.cpu_user_ns),
        nsToMs(row.cpu_sys_ns),
    });

    try writer.writeAll("memory(bytes)\n");
    try writer.print("rss: {d}\n\n", .{row.max_rss_bytes});

    if (row.page_faults_minor_mean != null or row.page_faults_major_mean != null) {
        try writer.writeAll("faults(counts)\n");
        try writeOptionalU64Human(writer, "minor mean", row.page_faults_minor_mean);
        try writeOptionalU64Human(writer, "major mean", row.page_faults_major_mean);
        try writer.writeAll("\n");
    }

    if (row.pmc_cycles_mean != null or row.pmc_instructions_mean != null) {
        try writer.writeAll("pmc(counts)\n");
        try writeOptionalU64Human(writer, "cycles mean", row.pmc_cycles_mean);
        try writeOptionalU64Human(writer, "instr mean", row.pmc_instructions_mean);
        try writeOptionalU64Human(writer, "cache_miss mean", row.pmc_cache_misses_mean);
        try writeOptionalU64Human(writer, "cache_ref mean", row.pmc_cache_references_mean);
        try writeOptionalU64Human(writer, "branches mean", row.pmc_branches_mean);
        try writeOptionalU64Human(writer, "branch_miss mean", row.pmc_branch_misses_mean);
    }

    try writer.writeAll("\n");
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |v| {
        try writer.print("{d}", .{v});
    } else {
        try writer.writeAll("NA");
    }
}

fn writeOptionalU64Human(writer: *std.Io.Writer, label: []const u8, value: ?u64) !void {
    if (value) |v| {
        try writer.print("{s}: {d}\n", .{ label, v });
    } else {
        try writer.print("{s}: NA\n", .{label});
    }
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

const ascii_keys = [_]u8{
    'a', 'A', 'b', 'B', 'c', 'C', 'x', 'X', 'y', 'Y', 'z', 'Z',
    ';', '=', '-', '/', ']', '0', '1', '2', '3', '4', '5', '6',
    '7', '8', '9',
};

const cursor_finals = [_]u8{ 'A', 'B', 'C', 'D' };
const ss3_finals = [_]u8{ 'A', 'B', 'C', 'D', 'P', 'Q', 'R', 'S' };

const tilde_codes = [_]u16{
    2,
    3,
    5,
    6,
    7,
    8,
    11,
    12,
    13,
    14,
    15,
    17,
    18,
    19,
    20,
    21,
    23,
    24,
};

const kitty_key_codes = [_]u16{ 13, 27, 32, 59, 65, 97, 98, 99, 120, 57358 };

const mouse_buttons_press = [_]u16{ 0, 1, 2 };
const mouse_scroll_buttons = [_]u16{ 0, 1 };

const decrpm_modes = [_]u16{ 1006, 1016, 2004, 1049 };
const da2_identification_codes = [_]u16{ 41, 61, 62, 65 };
