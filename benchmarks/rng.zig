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
