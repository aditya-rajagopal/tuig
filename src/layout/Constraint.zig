const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const layout = @import("root.zig");
const Align = layout.Align;

pub fn Ratio(comptime Int: type) type {
    return switch (@typeInfo(Int)) {
        .int => struct {
            num: Int,
            den: Int,

            pub fn mul(self: @This(), comptime T: type, value: T) T {
                assert(self.den != 0);
                const info = @typeInfo(T);
                switch (info) {
                    .float => {
                        const num = @as(T, @floatFromInt(self.num));
                        const den = @as(T, @floatFromInt(self.den));
                        return value * num / den;
                    },
                    .int => {
                        const product = std.math.mulWide(T, value, @intCast(self.num));
                        const result = @divTrunc(product, @as(@TypeOf(product), @intCast(self.den)));
                        return @intCast(result);
                    },
                    else => @compileError("Ratio.mul requires an integer or float type."),
                }
            }
        },
        else => @compileError("Ratio requires an integer type."),
    };
}

pub const Basis = union(enum) {
    fixed: u16,
    ratio: Ratio(u16),
    fill: u16,
};

pub const Cross = struct {
    size: ?u16 = null,
    alignment: Align = .start,
};

const Constraint = @This();

basis: Basis = .{ .fill = 1 },
min: u16 = 0,
max: u16 = std.math.maxInt(u16),
cross: Cross = .{},

pub inline fn fixed(size: u16) Constraint {
    return .{ .basis = .{ .fixed = size } };
}

pub inline fn flex(weight: u16) Constraint {
    assert(weight != 0);
    return .{ .basis = .{ .fill = weight } };
}

pub inline fn ratio(num: u16, den: u16) Constraint {
    assert(den != 0);
    return .{ .basis = .{ .ratio = .{ .num = num, .den = den } } };
}

pub inline fn content(preferred: u16, min_size: u16, max_size: u16) Constraint {
    assert(min_size <= max_size);
    return .{
        .basis = .{ .fixed = preferred },
        .min = min_size,
        .max = max_size,
    };
}

pub inline fn between(min_size: u16, max_size: u16) Constraint {
    assert(min_size <= max_size);
    return .{
        .basis = .{ .fill = 1 },
        .min = min_size,
        .max = max_size,
    };
}

pub inline fn withMin(self: Constraint, min_size: u16) Constraint {
    assert(min_size <= self.max);
    var c = self;
    c.min = min_size;
    return c;
}

pub inline fn withMax(self: Constraint, max_size: u16) Constraint {
    assert(self.min <= max_size);
    var c = self;
    c.max = max_size;
    return c;
}

pub inline fn withCross(self: Constraint, size: ?u16, cross_align: Align) Constraint {
    var c = self;
    c.cross = .{ .size = size, .alignment = cross_align };
    return c;
}

pub inline fn crossCenter(self: Constraint) Constraint {
    var c = self;
    c.cross.alignment = .center;
    return c;
}

const testing = std.testing;

fn expectConstraintEqual(actual: Constraint, expected: Constraint) !void {
    try testing.expectEqual(expected.basis, actual.basis);
    try testing.expectEqual(expected.min, actual.min);
    try testing.expectEqual(expected.max, actual.max);
    try testing.expectEqual(expected.cross.size, actual.cross.size);
    try testing.expectEqual(expected.cross.alignment, actual.cross.alignment);
}

test "constructor table cases" {
    const ConstructorCase = struct {
        name: []const u8,
        actual: Constraint,
        expected: Constraint,
    };

    const cases = [_]ConstructorCase{
        .{
            .name = "fixed",
            .actual = fixed(42),
            .expected = .{ .basis = .{ .fixed = 42 } },
        },
        .{
            .name = "flex",
            .actual = flex(3),
            .expected = .{ .basis = .{ .fill = 3 } },
        },
        .{
            .name = "ratio",
            .actual = ratio(1, 3),
            .expected = .{ .basis = .{ .ratio = .{ .num = 1, .den = 3 } } },
        },
        .{
            .name = "content",
            .actual = content(20, 10, 30),
            .expected = .{
                .basis = .{ .fixed = 20 },
                .min = 10,
                .max = 30,
            },
        },
        .{
            .name = "between",
            .actual = between(5, 50),
            .expected = .{
                .basis = .{ .fill = 1 },
                .min = 5,
                .max = 50,
            },
        },
    };

    for (cases) |case| {
        errdefer std.log.err("constructor case failed: {s}", .{case.name});
        try expectConstraintEqual(case.actual, case.expected);
    }

    const content_constraint = content(20, 10, 30);
    const equivalent = fixed(20).withMin(10).withMax(30);
    try expectConstraintEqual(content_constraint, equivalent);
}

test "modifier table cases" {
    const ModifierCase = struct {
        name: []const u8,
        actual: Constraint,
        expected: Constraint,
    };

    const cases = [_]ModifierCase{
        .{
            .name = "withMin",
            .actual = fixed(20).withMin(5),
            .expected = .{
                .basis = .{ .fixed = 20 },
                .min = 5,
            },
        },
        .{
            .name = "withMax",
            .actual = flex(1).withMax(100),
            .expected = .{
                .basis = .{ .fill = 1 },
                .max = 100,
            },
        },
        .{
            .name = "withCross",
            .actual = fixed(20).withCross(10, .center),
            .expected = .{
                .basis = .{ .fixed = 20 },
                .cross = .{ .size = 10, .alignment = .center },
            },
        },
        .{
            .name = "crossCenter",
            .actual = fixed(20).crossCenter(),
            .expected = .{
                .basis = .{ .fixed = 20 },
                .cross = .{ .alignment = .center },
            },
        },
        .{
            .name = "modifier chaining",
            .actual = flex(2).withMin(10).withMax(50).withCross(30, .end),
            .expected = .{
                .basis = .{ .fill = 2 },
                .min = 10,
                .max = 50,
                .cross = .{ .size = 30, .alignment = .end },
            },
        },
    };

    for (cases) |case| {
        errdefer std.log.err("modifier case failed: {s}", .{case.name});
        try expectConstraintEqual(case.actual, case.expected);
    }
}
