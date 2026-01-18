const event = @import("event.zig");
pub const Event = event.Event;
pub const KeyEvent = event.KeyEvent;
pub const MouseEvent = event.MouseEvent;
pub const ResizeEvent = event.ResizeEvent;
pub const Mods = event.Mods;

const terminal = @import("terminal.zig");
pub const Terminal = terminal.Terminal;
pub const TerminalConfig = terminal.TerminalConfig;
pub const KittyConfig = terminal.KittyConfig;
pub const MouseOptions = terminal.MouseOptions;

pub var global_tty: ?*Terminal = null;

const std = @import("std");
test {
    _ = std.testing.refAllDecls(@This());
}
