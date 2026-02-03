const std = @import("std");
const assert = std.debug.assert;

pub const TimingStats = struct {
    min_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    max_ns: u64,
    mean_ns: u64,
};

pub fn computeStats(durations_ns: []const u64, scratch_ns: []u64) TimingStats {
    assert(durations_ns.len > 0);
    assert(scratch_ns.len >= durations_ns.len);

    const count = durations_ns.len;
    std.mem.copyForwards(u64, scratch_ns[0..count], durations_ns);
    std.sort.pdq(u64, scratch_ns[0..count], {}, std.sort.asc(u64));

    const last_index = count - 1;
    const min_ns = scratch_ns[0];
    const max_ns = scratch_ns[last_index];
    assert(min_ns <= max_ns);
    assert(max_ns >= min_ns);

    const median_ns = computeMedian(scratch_ns[0..count]);
    const p95_ns = computeP95(scratch_ns[0..count]);

    var sum_ns: u128 = 0;
    for (durations_ns) |value| {
        sum_ns += value;
    }
    const mean_ns = @as(u64, @intCast(sum_ns / count));
    assert(mean_ns >= min_ns);
    assert(mean_ns <= max_ns);

    return .{
        .min_ns = min_ns,
        .median_ns = median_ns,
        .p95_ns = p95_ns,
        .max_ns = max_ns,
        .mean_ns = mean_ns,
    };
}

fn computeMedian(sorted_ns: []const u64) u64 {
    assert(sorted_ns.len > 0);
    assert(sorted_ns.len <= std.math.maxInt(usize));

    const mid = sorted_ns.len / 2;
    if ((sorted_ns.len & 1) == 1) {
        assert(mid < sorted_ns.len);
        assert(sorted_ns.len > 0);
        return sorted_ns[mid];
    }

    assert(mid > 0);
    const upper = sorted_ns[mid];
    const lower = sorted_ns[mid - 1];
    const sum = @as(u128, lower) + @as(u128, upper);
    const median = @as(u64, @intCast(sum / 2));
    assert(median >= lower);
    assert(median <= upper);
    return median;
}

fn computeP95(sorted_ns: []const u64) u64 {
    assert(sorted_ns.len > 0);
    assert(sorted_ns.len <= std.math.maxInt(usize));

    const last_index = sorted_ns.len - 1;
    const p95_index = (last_index * 95) / 100;
    assert(p95_index <= last_index);
    assert(p95_index < sorted_ns.len);
    return sorted_ns[p95_index];
}
