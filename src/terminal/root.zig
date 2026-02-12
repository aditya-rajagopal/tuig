const event = @import("event.zig");
const parser = @import("parser.zig");
pub const Event = event.Event;
pub const KeyEvent = event.KeyEvent;
pub const MouseEvent = event.MouseEvent;
pub const ResizeEvent = event.ResizeEvent;
pub const Mods = event.Mods;
pub const Code = event.KeyEvent.Code;
pub const PhysicalKey = event.KeyEvent.PhysicalKey;
pub const PhysicalKeyState = std.EnumSet(KeyEvent.PhysicalKey);
pub const parseEvent = parser.parseEvent;

pub const sequences = @import("sequences.zig");

const terminal = @import("terminal.zig");
pub const Terminal = terminal.Terminal;
pub const TerminalConfig = terminal.TerminalConfig;
pub const KittyConfig = terminal.KittyConfig;
pub const MouseOptions = terminal.MouseOptions;

const std = @import("std");
test {
    _ = std.testing.refAllDecls(@This());
}
