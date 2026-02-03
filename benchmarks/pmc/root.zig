const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

const macos = @import("macos.zig");

pub const MaxEvents = macos.MaxEvents;
pub const EventResult = macos.EventResult;
pub const Result = macos.Result;

pub const Pmc = if (builtin.os.tag == .macos) macos.Pmc else NoPmc;

const NoPmc = struct {
    enabled: bool,

    pub fn init(enable: bool) NoPmc {
        assert(enable == true or enable == false);
        assert(@sizeOf(NoPmc) > 0);
        return .{ .enabled = enable };
    }

    pub fn deinit(self: *NoPmc) void {
        assert(@intFromPtr(self) != 0);
        assert(@sizeOf(NoPmc) > 0);
    }

    pub fn start(self: *NoPmc, event_names: [MaxEvents][]const u8) bool {
        assert(@intFromPtr(self) != 0);
        assert(event_names.len == MaxEvents);
        return false;
    }

    pub fn resetStart(self: *NoPmc) error{Failed}!bool {
        assert(@intFromPtr(self) != 0);
        return false;
    }

    pub fn snapshot(self: *NoPmc) error{Failed}!Result {
        assert(@intFromPtr(self) != 0);
        assert(@sizeOf(Result) > 0);
        return .{
            .cycles = null,
            .instructions = null,
            .events = .{
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
            },
        };
    }

    pub fn stop(self: *NoPmc) error{Failed}!Result {
        assert(@intFromPtr(self) != 0);
        assert(@sizeOf(Result) > 0);
        return .{
            .cycles = null,
            .instructions = null,
            .events = .{
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
            },
        };
    }
};
