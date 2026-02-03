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
        return .{ .enabled = enable };
    }

    pub fn deinit(self: *NoPmc) void {
        _ = self;
    }

    pub fn start(self: *NoPmc, event_names: [MaxEvents][]const u8) bool {
        _ = self;
        _ = event_names;
        return false;
    }

    pub fn resetStart(self: *NoPmc) error{Failed}!bool {
        _ = self;
        return false;
    }

    pub fn snapshot(self: *NoPmc) error{Failed}!Result {
        _ = self;
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
        _ = self;
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
