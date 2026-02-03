const std = @import("std");
const assert = std.debug.assert;

pub const Stats = struct {
    min: u64,
    median: u64,
    p95: u64,
    max: u64,
    mean: u64,
};

pub fn computeStats(samples: []const u64, scratch: []u64) Stats {
    assert(samples.len > 0);
    assert(scratch.len >= samples.len);

    const count = samples.len;
    std.mem.copyForwards(u64, scratch[0..count], samples);
    std.sort.pdq(u64, scratch[0..count], {}, std.sort.asc(u64));

    const last_index = count - 1;
    const min = scratch[0];
    const max = scratch[last_index];

    const median = computeMedian(scratch[0..count]);
    const p95 = computeP95(scratch[0..count]);

    var sum_ns: u128 = 0;
    for (samples) |value| {
        sum_ns += value;
    }
    const mean = @as(u64, @intCast(sum_ns / count));

    return .{
        .min = min,
        .median = median,
        .p95 = p95,
        .max = max,
        .mean = mean,
    };
}

fn computeMedian(sorted_ns: []const u64) u64 {
    assert(sorted_ns.len > 0);
    assert(sorted_ns.len <= std.math.maxInt(usize));

    const mid = sorted_ns.len / 2;
    if ((sorted_ns.len & 1) == 1) {
        return sorted_ns[mid];
    }

    const upper = sorted_ns[mid];
    const lower = sorted_ns[mid - 1];
    const sum = @as(u128, lower) + @as(u128, upper);
    const median = @as(u64, @intCast(sum / 2));
    return median;
}

fn computeP95(sorted_ns: []const u64) u64 {
    assert(sorted_ns.len > 0);
    assert(sorted_ns.len <= std.math.maxInt(usize));

    const last_index = sorted_ns.len - 1;
    const p95_index = (last_index * 95) / 100;
    return sorted_ns[p95_index];
}
