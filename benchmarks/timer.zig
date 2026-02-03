const std = @import("std");
const assert = std.debug.assert;

pub const FrameTimer = struct {
    timer: std.time.Timer,

    pub fn start() !FrameTimer {
        assert(@sizeOf(FrameTimer) > 0);
        assert(std.time.ns_per_s > 0);
        var timer = try std.time.Timer.start();
        const first = timer.read();
        const second = timer.read();
        assert(second >= first);
        assert(first <= second);
        return .{ .timer = timer };
    }

    pub fn lap(self: *FrameTimer) u64 {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(&self.timer) != 0);
        return self.timer.lap();
    }
};
