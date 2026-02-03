const std = @import("std");
const assert = std.debug.assert;

pub const DefaultPrng = std.Random.DefaultPrng;

pub fn init(seed: u64) DefaultPrng {
    return DefaultPrng.init(seed);
}

pub fn index(random: std.Random, len: usize) usize {
    assert(len > 0);
    return random.intRangeLessThan(usize, 0, len);
}

pub fn rangeU16(random: std.Random, min: u16, max_exclusive: u16) u16 {
    assert(max_exclusive > min);
    return random.intRangeLessThan(u16, min, max_exclusive);
}

pub fn rangeU32(random: std.Random, min: u32, max_exclusive: u32) u32 {
    assert(max_exclusive > min);
    return random.intRangeLessThan(u32, min, max_exclusive);
}

pub fn rangeUsize(random: std.Random, min: usize, max_exclusive: usize) usize {
    assert(max_exclusive > min);
    return random.intRangeLessThan(usize, min, max_exclusive);
}

pub const WeightedTable = struct {
    weights: []const u32,
    total: u32,

    pub fn init(weights: []const u32) WeightedTable {
        var total: u32 = 0;
        for (weights) |weight| {
            total += weight;
        }
        assert(total > 0);
        return .{ .weights = weights, .total = total };
    }

    pub fn pick(self: WeightedTable, random: std.Random) usize {
        const roll = random.intRangeLessThan(u32, 0, self.total);
        var acc: u32 = 0;
        for (self.weights, 0..) |weight, idx| {
            acc += weight;
            if (roll < acc) return idx;
        }
        return self.weights.len - 1;
    }
};
