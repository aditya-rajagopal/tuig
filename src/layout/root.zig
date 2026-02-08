const std = @import("std");

pub const Rect = @import("Rect.zig");
pub const Constraint = @import("Constraint.zig");

pub const max_children: usize = 64;

pub const Axis = enum { horizontal, vertical };

pub const Align = enum { start, center, end };

pub const Overflow = enum { truncate_tail, truncate_head, proportional };

test {
    _ = std.testing.refAllDecls(@This());
}
