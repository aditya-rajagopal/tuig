const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const layout = @import("root.zig");
const Constraint = layout.Constraint;
const Ratio = Constraint.Ratio;
const Axis = layout.Axis;
const Align = layout.Align;
const Overflow = layout.Overflow;

const max_children = layout.max_children;

pub const SplitOptions = struct {
    axis: Axis = .vertical,
    gap: u16 = 0,
    overflow: Overflow = .truncate_tail,
    alignment: Align = .start,
};

pub const SplitResult = struct {
    count: usize,
    used_cells: u16,
    overflowed: bool,
};

pub const Error = error{
    InvalidConstraint,
    OutputTooSmall,
    TooManyChildren,
    GapTooLarge,
    PositionTooLarge,
};

const Rect = @This();

x: u16,
y: u16,
width: u16,
height: u16,

const empty = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub fn split(self: Rect, constraints: []const Constraint, options: SplitOptions, out_rects: []Rect) Error!SplitResult {
    const child_count = constraints.len;
    if (child_count == 0) return .{ .count = 0, .used_cells = 0, .overflowed = false };
    if (child_count > max_children) return error.TooManyChildren;
    if (out_rects.len < child_count) return error.OutputTooSmall;

    try validateConstraints(constraints);

    const axis_cells = computeAxisCells(self, options.axis);
    const split_budget = try computeSplitBudget(child_count, axis_cells.main, options.gap);

    var child_sizes: [max_children]u16 = undefined;
    const preferred_size_seed = seedPreferredSizes(constraints, split_budget.content, child_sizes[0..child_count]);

    const content_cells_budget = split_budget.content;
    var content_cells_allocated = preferred_size_seed.content_cells_allocated;

    if (preferred_size_seed.has_fills and content_cells_allocated < content_cells_budget) {
        const fill_remainder: u16 = @intCast(content_cells_budget - content_cells_allocated);
        distributeFillWithCaps(constraints, child_sizes[0..child_count], fill_remainder);
        content_cells_allocated = sumChildSizes(child_sizes[0..child_count]);
    }

    var overflowed = false;
    if (content_cells_allocated > content_cells_budget) {
        overflowed = true;
        switch (options.overflow) {
            .truncate_tail => resolveOverflowTruncateTail(child_sizes[0..child_count], content_cells_budget),
            .truncate_head => resolveOverflowTruncateHead(child_sizes[0..child_count], content_cells_budget),
            .proportional => resolveOverflowProportional(
                constraints,
                child_sizes[0..child_count],
                content_cells_budget,
                content_cells_allocated,
            ),
        }
        content_cells_allocated = sumChildSizes(child_sizes[0..child_count]);
    }

    assert(content_cells_allocated <= content_cells_budget);

    const align_offset = computeAlignOffset(
        content_cells_allocated,
        content_cells_budget,
        options.alignment,
    );

    try emitRects(
        self,
        constraints,
        child_sizes[0..child_count],
        options.axis,
        options.gap,
        axis_cells.cross,
        align_offset,
        out_rects[0..child_count],
    );

    return .{
        .count = child_count,
        .used_cells = computeUsedCells(content_cells_allocated, split_budget.gap, axis_cells.main),
        .overflowed = overflowed,
    };
}

pub inline fn centeredChild(self: Rect, width: u16, height: u16) Rect {
    const child_width = @min(width, self.width);
    const child_height = @min(height, self.height);

    const x_offset: u16 = (self.width - child_width) / 2;
    const y_offset: u16 = (self.height - child_height) / 2;

    const child_x: u32 = @as(u32, self.x) + x_offset;
    const child_y: u32 = @as(u32, self.y) + y_offset;
    assert(child_x <= std.math.maxInt(u16));
    assert(child_y <= std.math.maxInt(u16));

    return .{
        .x = @intCast(child_x),
        .y = @intCast(child_y),
        .width = child_width,
        .height = child_height,
    };
}

fn validateConstraints(constraints: []const Constraint) Error!void {
    for (constraints) |constraint| {
        switch (constraint.basis) {
            .ratio => |ratio| if (ratio.den == 0) return error.InvalidConstraint,
            .fill => |weight| if (weight == 0) return error.InvalidConstraint,
            .fixed => {},
        }
        if (constraint.min > constraint.max) return error.InvalidConstraint;
    }
}

const AxisCells = struct {
    main: u16,
    cross: u16,
};

fn computeAxisCells(self: Rect, axis: Axis) AxisCells {
    return .{
        .main = switch (axis) {
            .horizontal => self.width,
            .vertical => self.height,
        },
        .cross = switch (axis) {
            .horizontal => self.height,
            .vertical => self.width,
        },
    };
}

const SplitBudget = struct {
    gap: u16,
    content: u16,
};

fn computeSplitBudget(child_count: usize, main_axis_cells: u16, gap: u16) Error!SplitBudget {
    const total_gap: u16 = if (child_count > 1)
        std.math.mul(u16, gap, @intCast(child_count - 1)) catch return error.GapTooLarge
    else
        0;

    if (total_gap > main_axis_cells) return error.GapTooLarge;
    return .{
        .gap = total_gap,
        .content = main_axis_cells - total_gap,
    };
}

const PreferredSizeSeed = struct {
    content_cells_allocated: u32,
    has_fills: bool,
};

fn seedPreferredSizes(constraints: []const Constraint, content_cells_budget: u16, child_sizes: []u16) PreferredSizeSeed {
    assert(constraints.len == child_sizes.len);

    var content_cells_allocated: u32 = 0;
    var has_fills = false;

    for (constraints, 0..) |constraint, i| {
        const preferred_cells: u16 = switch (constraint.basis) {
            .fixed => |fixed| std.math.clamp(fixed, constraint.min, constraint.max),
            .ratio => |ratio| blk: {
                const ratio_cells_unclamped: u32 = ratio.mul(u32, content_cells_budget);
                const ratio_cells_clamped: u32 = std.math.clamp(
                    ratio_cells_unclamped,
                    @as(u32, constraint.min),
                    @as(u32, constraint.max),
                );
                break :blk @intCast(ratio_cells_clamped);
            },
            .fill => blk: {
                has_fills = true;
                break :blk constraint.min;
            },
        };

        child_sizes[i] = preferred_cells;
        content_cells_allocated += preferred_cells;
    }

    return .{
        .content_cells_allocated = content_cells_allocated,
        .has_fills = has_fills,
    };
}

fn sumChildSizes(child_sizes: []const u16) u32 {
    var total: u32 = 0;
    for (child_sizes) |size| total += size;
    return total;
}

fn resolveOverflowTruncateTail(child_sizes: []u16, content_cells_budget: u16) void {
    var size_remaining: u32 = content_cells_budget;
    for (child_sizes) |*child_size| {
        if (child_size.* <= size_remaining) {
            size_remaining -= child_size.*;
        } else {
            child_size.* = @intCast(size_remaining);
            size_remaining = 0;
        }
    }
}

fn resolveOverflowTruncateHead(child_sizes: []u16, content_cells_budget: u16) void {
    var size_remaining: u32 = content_cells_budget;
    var i: usize = child_sizes.len;
    while (i > 0) {
        i -= 1;
        if (child_sizes[i] <= size_remaining) {
            size_remaining -= child_sizes[i];
        } else {
            child_sizes[i] = @intCast(size_remaining);
            size_remaining = 0;
        }
    }
}

fn resolveOverflowProportional(
    constraints: []const Constraint,
    child_sizes: []u16,
    content_cells_budget: u16,
    content_cells_allocated: u32,
) void {
    assert(constraints.len == child_sizes.len);

    const content_cells_excess: u32 = content_cells_allocated - content_cells_budget;
    var content_cells_shrinkable: u32 = 0;
    for (constraints, 0..) |constraint, i| {
        assert(child_sizes[i] >= constraint.min);
        content_cells_shrinkable += child_sizes[i] - constraint.min;
    }

    if (content_cells_shrinkable == 0) {
        resolveOverflowTruncateTail(child_sizes, content_cells_budget);
        return;
    }

    var shrunk: u32 = 0;
    var shrink_remainders: [max_children]u64 = undefined;
    var shrink_indices: [max_children]usize = undefined;
    var shrink_count: usize = 0;
    const effective_excess = @min(content_cells_excess, content_cells_shrinkable);
    const excess_ratio: Ratio(u32) = .{ .num = effective_excess, .den = content_cells_shrinkable };

    for (constraints, 0..) |constraint, i| {
        assert(child_sizes[i] >= constraint.min);
        const shrinkable: u32 = child_sizes[i] - constraint.min;
        if (shrinkable == 0) continue;

        const ideal_shrink: u32 = excess_ratio.mul(u32, shrinkable);
        child_sizes[i] -= @intCast(ideal_shrink);
        shrunk += ideal_shrink;

        const frac = @as(u64, effective_excess) * shrinkable - @as(u64, ideal_shrink) * content_cells_shrinkable;
        shrink_remainders[shrink_count] = frac;
        shrink_indices[shrink_count] = i;
        shrink_count += 1;
    }

    assert(shrunk <= effective_excess);

    var leftover: u32 = effective_excess - shrunk;
    if (leftover > 0 and shrink_count > 0) {
        sortByRemainder(shrink_indices[0..shrink_count], shrink_remainders[0..shrink_count]);
        for (shrink_indices[0..shrink_count]) |idx| {
            if (leftover == 0) break;
            if (child_sizes[idx] > constraints[idx].min) {
                child_sizes[idx] -= 1;
                leftover -= 1;
            }
        }
    }

    if (leftover > 0) {
        for (shrink_indices[0..shrink_count]) |idx| {
            assert(child_sizes[idx] == constraints[idx].min);
        }
    }

    if (content_cells_excess > content_cells_shrinkable) {
        resolveOverflowTruncateTail(child_sizes, content_cells_budget);
    }
}

fn computeAlignOffset(content_cells_allocated: u32, content_cells_budget: u16, alignment: Align) u16 {
    assert(content_cells_allocated <= content_cells_budget);

    const content_slack: u16 = @intCast(content_cells_budget - content_cells_allocated);
    return switch (alignment) {
        .start => 0,
        .center => content_slack / 2,
        .end => content_slack,
    };
}

fn emitRects(
    self: Rect,
    constraints: []const Constraint,
    child_sizes: []const u16,
    axis: Axis,
    gap: u16,
    cross_axis_cells: u16,
    align_offset: u16,
    out_rects: []Rect,
) Error!void {
    assert(constraints.len == child_sizes.len);
    assert(out_rects.len == child_sizes.len);

    const base_position_main = switch (axis) {
        .horizontal => self.x,
        .vertical => self.y,
    };
    const base_position_cross = switch (axis) {
        .horizontal => self.y,
        .vertical => self.x,
    };

    var out_index: usize = 0;
    errdefer @memset(out_rects[0..out_index], empty);

    var position_main: u32 = @as(u32, base_position_main) + align_offset;
    for (constraints, child_sizes, out_rects, 0..) |constraint, size, *out_rect, i| {
        var cross_size: u16 = undefined;
        var cross_pos: u32 = undefined;
        if (constraint.cross.size) |cross_size_constraint| {
            cross_size = @min(cross_size_constraint, cross_axis_cells);
            assert(cross_axis_cells >= cross_size);

            const cross_slack = cross_axis_cells - cross_size;
            cross_pos = @as(u32, base_position_cross) + switch (constraint.cross.alignment) {
                .start => 0,
                .center => cross_slack / 2,
                .end => cross_slack,
            };
        } else {
            cross_size = cross_axis_cells;
            cross_pos = base_position_cross;
        }

        if (position_main > std.math.maxInt(u16)) return error.PositionTooLarge;
        if (cross_pos > std.math.maxInt(u16)) return error.PositionTooLarge;

        out_rect.* = switch (axis) {
            .horizontal => .{
                .x = @intCast(position_main),
                .y = @intCast(cross_pos),
                .width = size,
                .height = cross_size,
            },
            .vertical => .{
                .x = @intCast(cross_pos),
                .y = @intCast(position_main),
                .width = cross_size,
                .height = size,
            },
        };
        out_index = i + 1;

        position_main += size;
        if (i < child_sizes.len - 1) position_main += gap;
    }
}

fn computeUsedCells(content_cells_allocated: u32, total_gap: u16, main_axis_cells: u16) u16 {
    const total_with_gap: u32 = content_cells_allocated + total_gap;
    return @intCast(@min(total_with_gap, @as(u32, main_axis_cells)));
}

fn distributeFillWithCaps(constraints: []const Constraint, child_sizes: []u16, remainder_initial: u16) void {
    assert(constraints.len == child_sizes.len);

    var remainder: u32 = remainder_initial;
    if (remainder == 0) return;

    var fill_indices: [max_children]usize = undefined;
    var fill_remainders: [max_children]u64 = undefined;

    var rounds_remaining: usize = max_children + 1;

    // @NOTE this loop is needed to handle cases where distribution is capped by
    //       per-child max size constraints.
    //       Eg. If remainder = 40 and we have 4 children to fill who all have weight 1
    //       but 1 of them has a max of 2. We will first distribute 10 to each child but the
    //       last one will be capped at 2 and we will have a remainder of 8.
    //       Fill by definition should use up all the remainder. So we distribute the remaining 8 to the other children
    //
    //       The loop’s worst-case progress is tied to how many fill children can become newly capped,
    //       and that count is globally bounded by max_children
    while (remainder > 0 and rounds_remaining > 0) : (rounds_remaining -= 1) {
        var fill_count: usize = 0;
        var fill_total_weight: u32 = 0;

        for (constraints, 0..) |constraint, i| {
            switch (constraint.basis) {
                .fill => |weight| {
                    if (child_sizes[i] < constraint.max) {
                        fill_indices[fill_count] = i;
                        fill_count += 1;
                        fill_total_weight += weight;
                    }
                },
                else => {},
            }
        }

        if (fill_count == 0) break;
        assert(fill_total_weight > 0);

        var distributed_floor: u32 = 0;
        const round_budget: u32 = remainder;
        var capped_this_round = false;

        for (fill_indices[0..fill_count], 0..) |idx, i| {
            const constraint = constraints[idx];
            const weight: u32 = switch (constraint.basis) {
                .fill => |w| w,
                else => unreachable,
            };

            const product: u64 = @as(u64, round_budget) * weight;
            const ideal: u32 = @intCast(@divTrunc(product, fill_total_weight));
            const headroom: u32 = @as(u32, constraint.max) - child_sizes[idx];
            const growth: u32 = @min(ideal, headroom);
            child_sizes[idx] += @intCast(growth);
            distributed_floor += growth;
            if (growth == headroom and headroom > 0) capped_this_round = true;

            // @NOTE https://en.wikipedia.org/wiki/Quota_method
            // Fractional remainder for largest-remainder distribution.
            const frac = product - @as(u64, ideal) * fill_total_weight;
            fill_remainders[i] = frac;
        }

        assert(distributed_floor <= remainder);
        remainder -= distributed_floor;
        if (remainder == 0) break;

        sortByRemainder(fill_indices[0..fill_count], fill_remainders[0..fill_count]);
        var distributed_units: u32 = 0;
        for (fill_indices[0..fill_count]) |idx| {
            if (remainder == 0) break;
            const constraint = constraints[idx];
            if (child_sizes[idx] < constraint.max) {
                child_sizes[idx] += 1;
                remainder -= 1;
                distributed_units += 1;
                if (child_sizes[idx] == constraint.max) capped_this_round = true;
            }
        }

        if (distributed_units == 0) break;

        if (remainder > 0) {
            // If work remains after a full quota+remainder round, at least one active fill
            // must have been capped this round; otherwise the round would have exhausted
            // remainder by quota properties.
            assert(capped_this_round);
        }
    }

    if (remainder > 0) {
        for (constraints, 0..) |constraint, i| {
            if (constraint.basis == .fill) {
                assert(child_sizes[i] == constraint.max);
            }
        }
    }
}

fn sortByRemainder(indices: []usize, remainders: []u64) void {
    if (indices.len <= 1) return;
    for (1..indices.len) |i| {
        const key_idx = indices[i];
        const key_rem = remainders[i];
        var j: usize = i;
        while (j > 0) {
            const prev_rem = remainders[j - 1];
            const prev_idx = indices[j - 1];
            // Sort descending by remainder, ascending by index on ties
            const should_swap = key_rem > prev_rem or (key_rem == prev_rem and key_idx < prev_idx);
            if (!should_swap) break;
            indices[j] = prev_idx;
            remainders[j] = prev_rem;
            j -= 1;
        }
        indices[j] = key_idx;
        remainders[j] = key_rem;
    }
}

const testing = std.testing;

fn makeRect(x: u16, y: u16, w: u16, h: u16) Rect {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

fn expectRect(actual: Rect, x: u16, y: u16, w: u16, h: u16) !void {
    try testing.expectEqual(x, actual.x);
    try testing.expectEqual(y, actual.y);
    try testing.expectEqual(w, actual.width);
    try testing.expectEqual(h, actual.height);
}

const SplitCase = struct {
    name: []const u8,
    parent: Rect,
    constraints: []const Constraint,
    options: SplitOptions = .{},
    expected_rects: []const Rect,
    expected_used_cells: u16,
    expected_overflowed: bool,
};

const SplitErrorCase = struct {
    name: []const u8,
    parent: Rect,
    constraints: []const Constraint,
    options: SplitOptions = .{},
    out_len: ?usize = null,
    expected_error: Error,
};

fn runSplitCase(case: SplitCase) !void {
    errdefer std.log.err("split case failed: {s}", .{case.name});
    try testing.expectEqual(case.constraints.len, case.expected_rects.len);

    var out: [max_children]Rect = undefined;
    const result = try case.parent.split(case.constraints, case.options, out[0..case.constraints.len]);

    try testing.expectEqual(case.constraints.len, result.count);
    try testing.expectEqual(case.expected_used_cells, result.used_cells);
    try testing.expectEqual(case.expected_overflowed, result.overflowed);
    for (case.expected_rects, 0..) |expected_rect, i| {
        try expectRect(out[i], expected_rect.x, expected_rect.y, expected_rect.width, expected_rect.height);
    }
}

fn runSplitCases(cases: []const SplitCase) !void {
    for (cases) |case| {
        try runSplitCase(case);
    }
}

fn runSplitErrorCase(case: SplitErrorCase) !void {
    errdefer std.log.err("split error case failed: {s}", .{case.name});
    var out: [max_children + 1]Rect = undefined;

    const out_len = case.out_len orelse case.constraints.len;
    try testing.expect(out_len <= out.len);
    try testing.expectError(case.expected_error, case.parent.split(case.constraints, case.options, out[0..out_len]));
}

fn runSplitErrorCases(cases: []const SplitErrorCase) !void {
    for (cases) |case| {
        try runSplitErrorCase(case);
    }
}

test "centeredChild" {
    const parent = makeRect(10, 20, 100, 60);

    try expectRect(parent.centeredChild(40, 20), 40, 40, 40, 20);
    try expectRect(parent.centeredChild(100, 60), 10, 20, 100, 60);
    try expectRect(parent.centeredChild(200, 120), 10, 20, 100, 60);
    try expectRect(parent.centeredChild(0, 0), 60, 50, 0, 0);
}

test "split table cases" {
    const cases = [_]SplitCase{
        .{
            .name = "single fixed",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "single ratio",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.ratio(1, 2)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 25)},
            .expected_used_cells = 25,
            .expected_overflowed = false,
        },
        .{
            .name = "single fill",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.flex(1)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 50)},
            .expected_used_cells = 50,
            .expected_overflowed = false,
        },
        .{
            .name = "fixed clamped by min",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(5).withMin(10)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 10)},
            .expected_used_cells = 10,
            .expected_overflowed = false,
        },
        .{
            .name = "fixed clamped by max",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(30).withMax(15)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 15)},
            .expected_used_cells = 15,
            .expected_overflowed = false,
        },
        .{
            .name = "fill clamped by max",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.flex(1).withMax(30)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 30)},
            .expected_used_cells = 30,
            .expected_overflowed = false,
        },
        .{
            .name = "ratio clamped by min",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.ratio(1, 10).withMin(10)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 10)},
            .expected_used_cells = 10,
            .expected_overflowed = false,
        },
        .{
            .name = "ratio larger than 1 clamps without overflow",
            .parent = makeRect(0, 0, 100, std.math.maxInt(u16)),
            .constraints = &[_]Constraint{Constraint.ratio(std.math.maxInt(u16), 1).withMax(123)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 123)},
            .expected_used_cells = 123,
            .expected_overflowed = false,
        },
        .{
            .name = "fixed plus fill",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{ Constraint.fixed(20), Constraint.flex(1) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 20), makeRect(0, 20, 100, 30) },
            .expected_used_cells = 50,
            .expected_overflowed = false,
        },
        .{
            .name = "fixed plus ratio plus fill",
            .parent = makeRect(0, 0, 100, 60),
            .constraints = &[_]Constraint{ Constraint.fixed(10), Constraint.ratio(1, 3), Constraint.flex(1) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 10), makeRect(0, 10, 100, 20), makeRect(0, 30, 100, 30) },
            .expected_used_cells = 60,
            .expected_overflowed = false,
        },
        .{
            .name = "weighted fills",
            .parent = makeRect(0, 0, 100, 90),
            .constraints = &[_]Constraint{ Constraint.flex(1), Constraint.flex(2) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 30), makeRect(0, 30, 100, 60) },
            .expected_used_cells = 90,
            .expected_overflowed = false,
        },
        .{
            .name = "weighted fills redistribute when one child is capped",
            .parent = makeRect(0, 0, 100, 100),
            .constraints = &[_]Constraint{ Constraint.flex(1).withMax(1), Constraint.flex(1) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 1), makeRect(0, 1, 100, 99) },
            .expected_used_cells = 100,
            .expected_overflowed = false,
        },
        .{
            .name = "gap between children",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{ Constraint.flex(1), Constraint.flex(1) },
            .options = .{ .gap = 10 },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 20), makeRect(0, 30, 100, 20) },
            .expected_used_cells = 50,
            .expected_overflowed = false,
        },
        .{
            .name = "align start",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20)},
            .options = .{ .alignment = .start },
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "align center",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20)},
            .options = .{ .alignment = .center },
            .expected_rects = &[_]Rect{makeRect(0, 15, 100, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "align end",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20)},
            .options = .{ .alignment = .end },
            .expected_rects = &[_]Rect{makeRect(0, 30, 100, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "align center odd rounding",
            .parent = makeRect(0, 0, 100, 51),
            .constraints = &[_]Constraint{Constraint.fixed(20)},
            .options = .{ .alignment = .center },
            .expected_rects = &[_]Rect{makeRect(0, 15, 100, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "align has no effect when fills consume all space",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.flex(1)},
            .options = .{ .alignment = .center },
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 50)},
            .expected_used_cells = 50,
            .expected_overflowed = false,
        },
        .{
            .name = "truncate tail reduces tail child",
            .parent = makeRect(0, 0, 100, 30),
            .constraints = &[_]Constraint{ Constraint.fixed(20), Constraint.fixed(20) },
            .options = .{ .overflow = .truncate_tail },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 20), makeRect(0, 20, 100, 10) },
            .expected_used_cells = 30,
            .expected_overflowed = true,
        },
        .{
            .name = "truncate tail zeroes overflow children",
            .parent = makeRect(0, 0, 100, 15),
            .constraints = &[_]Constraint{ Constraint.fixed(20), Constraint.fixed(20) },
            .options = .{ .overflow = .truncate_tail },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 15), makeRect(0, 15, 100, 0) },
            .expected_used_cells = 15,
            .expected_overflowed = true,
        },
        .{
            .name = "truncate head reduces head child",
            .parent = makeRect(0, 0, 100, 30),
            .constraints = &[_]Constraint{ Constraint.fixed(20), Constraint.fixed(20) },
            .options = .{ .overflow = .truncate_head },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 10), makeRect(0, 10, 100, 20) },
            .expected_used_cells = 30,
            .expected_overflowed = true,
        },
        .{
            .name = "truncate head zeroes overflow children",
            .parent = makeRect(0, 0, 100, 15),
            .constraints = &[_]Constraint{ Constraint.fixed(20), Constraint.fixed(20) },
            .options = .{ .overflow = .truncate_head },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 0), makeRect(0, 0, 100, 15) },
            .expected_used_cells = 15,
            .expected_overflowed = true,
        },
        .{
            .name = "proportional shrink",
            .parent = makeRect(0, 0, 100, 40),
            .constraints = &[_]Constraint{ Constraint.fixed(30), Constraint.fixed(20) },
            .options = .{ .overflow = .proportional },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 24), makeRect(0, 24, 100, 16) },
            .expected_used_cells = 40,
            .expected_overflowed = true,
        },
        .{
            .name = "proportional all at min",
            .parent = makeRect(0, 0, 100, 10),
            .constraints = &[_]Constraint{ Constraint.fixed(20).withMin(20), Constraint.fixed(20).withMin(20) },
            .options = .{ .overflow = .proportional },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 10), makeRect(0, 10, 100, 0) },
            .expected_used_cells = 10,
            .expected_overflowed = true,
        },
        .{
            .name = "proportional excess greater than shrinkable",
            .parent = makeRect(0, 0, 100, 10),
            .constraints = &[_]Constraint{ Constraint.fixed(30).withMin(5), Constraint.fixed(20).withMin(5) },
            .options = .{ .overflow = .proportional },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 5), makeRect(0, 5, 100, 5) },
            .expected_used_cells = 10,
            .expected_overflowed = true,
        },
        .{
            .name = "cross axis stretch default",
            .parent = makeRect(10, 20, 80, 60),
            .constraints = &[_]Constraint{Constraint.fixed(30)},
            .expected_rects = &[_]Rect{makeRect(10, 20, 80, 30)},
            .expected_used_cells = 30,
            .expected_overflowed = false,
        },
        .{
            .name = "cross axis fixed size start",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20).withCross(30, .start)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 30, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "cross axis fixed size center",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20).withCross(30, .center)},
            .expected_rects = &[_]Rect{makeRect(35, 0, 30, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "cross axis fixed size end",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20).withCross(30, .end)},
            .expected_rects = &[_]Rect{makeRect(70, 0, 30, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "cross axis clamped to parent",
            .parent = makeRect(0, 0, 50, 50),
            .constraints = &[_]Constraint{Constraint.fixed(20).withCross(100, .start)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 50, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "cross axis mixed alignment",
            .parent = makeRect(0, 0, 100, 60),
            .constraints = &[_]Constraint{ Constraint.fixed(20).withCross(40, .start), Constraint.fixed(20).withCross(40, .end) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 40, 20), makeRect(60, 20, 40, 20) },
            .expected_used_cells = 40,
            .expected_overflowed = false,
        },
        .{
            .name = "parent size 0",
            .parent = makeRect(0, 0, 100, 0),
            .constraints = &[_]Constraint{Constraint.flex(1)},
            .expected_rects = &[_]Rect{makeRect(0, 0, 100, 0)},
            .expected_used_cells = 0,
            .expected_overflowed = false,
        },
        .{
            .name = "parent size 1",
            .parent = makeRect(0, 0, 100, 1),
            .constraints = &[_]Constraint{ Constraint.flex(1), Constraint.flex(1) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 1), makeRect(0, 1, 100, 0) },
            .expected_used_cells = 1,
            .expected_overflowed = false,
        },
        .{
            .name = "n equals 0",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{},
            .expected_rects = &[_]Rect{},
            .expected_used_cells = 0,
            .expected_overflowed = false,
        },
        .{
            .name = "all fixed 0",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{ Constraint.fixed(0), Constraint.fixed(0) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 0), makeRect(0, 0, 100, 0) },
            .expected_used_cells = 0,
            .expected_overflowed = false,
        },
        .{
            .name = "3 equal fills in 100 cells",
            .parent = makeRect(0, 0, 100, 100),
            .constraints = &[_]Constraint{ Constraint.flex(1), Constraint.flex(1), Constraint.flex(1) },
            .expected_rects = &[_]Rect{ makeRect(0, 0, 100, 34), makeRect(0, 34, 100, 33), makeRect(0, 67, 100, 33) },
            .expected_used_cells = 100,
            .expected_overflowed = false,
        },
        .{
            .name = "axis symmetry vertical",
            .parent = makeRect(10, 20, 100, 80),
            .constraints = &[_]Constraint{ Constraint.fixed(30), Constraint.flex(1) },
            .options = .{ .axis = .vertical },
            .expected_rects = &[_]Rect{ makeRect(10, 20, 100, 30), makeRect(10, 50, 100, 50) },
            .expected_used_cells = 80,
            .expected_overflowed = false,
        },
        .{
            .name = "axis symmetry horizontal",
            .parent = makeRect(10, 20, 100, 80),
            .constraints = &[_]Constraint{ Constraint.fixed(30), Constraint.flex(1) },
            .options = .{ .axis = .horizontal },
            .expected_rects = &[_]Rect{ makeRect(10, 20, 30, 80), makeRect(40, 20, 70, 80) },
            .expected_used_cells = 100,
            .expected_overflowed = false,
        },
        .{
            .name = "content sizing constructor",
            .parent = makeRect(10, 20, 100, 80),
            .constraints = &[_]Constraint{Constraint.content(20, 10, 30)},
            .expected_rects = &[_]Rect{makeRect(10, 20, 100, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
        .{
            .name = "content sizing equivalent fixed+bounds",
            .parent = makeRect(10, 20, 100, 80),
            .constraints = &[_]Constraint{Constraint.fixed(20).withMin(10).withMax(30)},
            .expected_rects = &[_]Rect{makeRect(10, 20, 100, 20)},
            .expected_used_cells = 20,
            .expected_overflowed = false,
        },
    };

    try runSplitCases(&cases);
}

test "split large fixed counts" {
    const parent = makeRect(0, 0, 100, 640);
    var constraints: [64]Constraint = undefined;
    for (&constraints) |*constraint| constraint.* = Constraint.fixed(10);

    var out: [64]Rect = undefined;
    const result = try parent.split(&constraints, .{}, &out);
    try testing.expectEqual(@as(usize, 64), result.count);
    for (out, 0..) |rect, i| {
        try testing.expectEqual(@as(u16, @intCast(i * 10)), rect.y);
        try testing.expectEqual(@as(u16, 10), rect.height);
    }
}

test "split overflow with very large fixed inputs" {
    const parent = makeRect(0, 0, 100, 10);
    var constraints: [64]Constraint = undefined;
    for (&constraints) |*constraint| {
        constraint.* = Constraint.fixed(std.math.maxInt(u16));
    }

    var out: [64]Rect = undefined;
    const result = try parent.split(&constraints, .{}, &out);
    try testing.expect(result.overflowed);
    try testing.expectEqual(@as(u16, 10), result.used_cells);
    try testing.expectEqual(@as(u16, 10), out[0].height);
    for (out[1..]) |rect| {
        try testing.expectEqual(@as(u16, 0), rect.height);
    }
}

test "split proportional overflow with very large excess" {
    const parent = makeRect(0, 0, 100, std.math.maxInt(u16));
    var constraints: [64]Constraint = undefined;
    for (&constraints) |*constraint| {
        constraint.* = Constraint.fixed(std.math.maxInt(u16));
    }

    var out: [64]Rect = undefined;
    const result = try parent.split(&constraints, .{ .overflow = .proportional }, &out);
    try testing.expect(result.overflowed);

    var total: u32 = 0;
    for (out) |rect| total += rect.height;
    try testing.expectEqual(@as(u32, std.math.maxInt(u16)), total);
}

test "split error table cases" {
    const cases = [_]SplitErrorCase{
        .{
            .name = "error den equals 0",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{.{ .basis = .{ .ratio = .{ .num = 1, .den = 0 } } }},
            .expected_error = error.InvalidConstraint,
        },
        .{
            .name = "error weight equals 0",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{.{ .basis = .{ .fill = 0 } }},
            .expected_error = error.InvalidConstraint,
        },
        .{
            .name = "error min greater than max",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{.{ .basis = .{ .fixed = 10 }, .min = 20, .max = 10 }},
            .expected_error = error.InvalidConstraint,
        },
        .{
            .name = "error output too small",
            .parent = makeRect(0, 0, 100, 50),
            .constraints = &[_]Constraint{ Constraint.fixed(10), Constraint.fixed(10) },
            .out_len = 1,
            .expected_error = error.OutputTooSmall,
        },
        .{
            .name = "error position too large on main axis",
            .parent = makeRect(0, std.math.maxInt(u16), 10, 2),
            .constraints = &[_]Constraint{ Constraint.fixed(1), Constraint.fixed(1) },
            .expected_error = error.PositionTooLarge,
        },
        .{
            .name = "error position too large on cross axis",
            .parent = makeRect(std.math.maxInt(u16), 0, 10, 10),
            .constraints = &[_]Constraint{Constraint.fixed(1).withCross(1, .end)},
            .expected_error = error.PositionTooLarge,
        },
    };

    try runSplitErrorCases(&cases);

    var too_many_constraints: [65]Constraint = undefined;
    for (&too_many_constraints) |*constraint| constraint.* = Constraint.fixed(1);

    try runSplitErrorCase(.{
        .name = "error too many children",
        .parent = makeRect(0, 0, 100, 50),
        .constraints = too_many_constraints[0..],
        .out_len = 65,
        .expected_error = error.TooManyChildren,
    });
}

test "remainder determinism" {
    const parent = makeRect(0, 0, 100, 100);
    const constraints = [_]Constraint{ Constraint.flex(1), Constraint.flex(1), Constraint.flex(1) };

    var out1: [3]Rect = undefined;
    var out2: [3]Rect = undefined;
    _ = try parent.split(&constraints, .{}, &out1);
    _ = try parent.split(&constraints, .{}, &out2);

    for (0..3) |i| {
        try testing.expectEqual(out1[i].height, out2[i].height);
        try testing.expectEqual(out1[i].y, out2[i].y);
    }
}

// @TODO try to use fuzzing
test "property: conservation and bounds" {
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();

    for (0..1000) |_| {
        const parent_w = random.intRangeAtMost(u16, 1, 200);
        const parent_h = random.intRangeAtMost(u16, 1, 200);
        const parent = makeRect(0, 0, parent_w, parent_h);

        const n = random.intRangeAtMost(usize, 1, 8);
        var constraints: [8]Constraint = undefined;
        for (0..n) |i| {
            const kind = random.intRangeAtMost(u8, 0, 2);
            constraints[i] = switch (kind) {
                0 => Constraint.fixed(random.intRangeAtMost(u16, 0, 100)),
                1 => Constraint.flex(random.intRangeAtMost(u16, 1, 5)),
                2 => Constraint.ratio(random.intRangeAtMost(u16, 1, 10), random.intRangeAtMost(u16, 1, 10)),
                else => unreachable,
            };
        }

        var out: [8]Rect = undefined;
        const result = try parent.split(constraints[0..n], .{}, out[0..n]);

        var total: u32 = 0;
        for (out[0..result.count]) |r| total += r.height;
        try testing.expect(total <= parent_h);

        // monotonic positioning
        for (1..result.count) |i| {
            const prev_end = @as(u32, out[i - 1].y) + out[i - 1].height;
            try testing.expect(prev_end <= out[i].y);
        }

        //no overlap
        for (0..result.count) |i| {
            for (i + 1..result.count) |j| {
                if (out[i].height == 0 or out[j].height == 0) continue;
                const i_end = @as(u32, out[i].y) + out[i].height;
                try testing.expect(i_end <= out[j].y);
            }
        }

        // min/max honored
        if (!result.overflowed) {
            for (constraints[0..n], 0..) |c, i| {
                try testing.expect(out[i].height >= c.min);
                try testing.expect(out[i].height <= c.max);
            }
        }
    }
}
