const t = @import("terminal.zig");
pub const Terminal = t.Terminal;
pub const TerminalConfig = t.TerminalConfig;
pub const Renderer = @import("renderer.zig");

pub const event = @import("event.zig");
pub const unicode = @import("unicode/root.zig");

test "All" {
    const std = @import("std");
    _ = std.testing.refAllDecls(@This());
}
