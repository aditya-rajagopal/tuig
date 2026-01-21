const std = @import("std");

const term = @import("terminal");
const Event = term.Event;
const KeyEvent = term.KeyEvent;
const MouseEvent = term.MouseEvent;
const ResizeEvent = term.ResizeEvent;

const t = @import("types.zig");
const Position = t.Position;
const MouseState = t.MouseState;

const Scissor = @import("Scissor.zig");
const MemoryPool = @import("Renderer.zig").MemoryPool;

const Context = @This();

frame_arena: *MemoryPool.ArenaAllocator,
events: []const Event = undefined,
scissor: Scissor = undefined,
key_pressed: ?KeyEvent = null,
resize: ?ResizeEvent = null,
mouse_scroll: i8 = 0,
mouse_x: u16 = 0,
mouse_y: u16 = 0,
mouse_down: MouseState = .{},
mouse_pressed: MouseState = .{},
mouse_released: MouseState = .{},

pub fn isKeyPressed(self: Context, code: KeyEvent.Code) bool {
    if (self.key_pressed) |key| {
        return key.code == code;
    } else {
        return false;
    }
}

pub fn isHovered(self: Context, scissor: Scissor) ?Position {
    if (scissor.contains(self.mouse_x, self.mouse_y)) {
        return .{
            .x = @intCast(@as(i17, self.mouse_x) - scissor.x_global),
            .y = @intCast(@as(i17, self.mouse_y) - scissor.y_global),
        };
    } else return null;
}
