pub const terminal = @import("terminal");
pub const renderer = @import("renderer");
pub const unicode = @import("unicode");
pub const ui = @import("ui");
pub const layout = @import("layout");

pub const Terminal = terminal.Terminal;
pub const TerminalConfig = terminal.TerminalConfig;
pub const MouseOptions = terminal.MouseOptions;
pub const KittyConfig = terminal.KittyConfig;
pub const Event = terminal.Event;
pub const KeyEvent = terminal.KeyEvent;
pub const MouseEvent = terminal.MouseEvent;
pub const ResizeEvent = terminal.ResizeEvent;

pub const Renderer = renderer.Renderer;
pub const Context = renderer.Context;
pub const FrameBuffer = renderer.FrameBuffer;
pub const Scissor = renderer.Scissor;
pub const Cell = renderer.Cell;
pub const Style = renderer.Style;
pub const Position = renderer.Position;

pub const UTF8Decoder = unicode.UTF8Decoder;
pub const GraphemeIterator = unicode.GraphemeIterator;

pub const Rect = layout.Rect;
pub const Constraint = layout.Constraint;

pub const DrawBoxConfig = ui.DrawBoxConfig;
pub const drawBox = ui.drawBox;

test {
    const std = @import("std");
    _ = std.testing.refAllDecls(@This());
}
