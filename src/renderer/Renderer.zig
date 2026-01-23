const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const term = @import("terminal");
const Terminal = term.Terminal;
const Event = term.Event;
const KeyEvent = term.KeyEvent;
const MouseEvent = term.MouseEvent;

const Cell = @import("root.zig").Cell;
const Context = @import("Context.zig");
const FrameBuffer = @import("FrameBuffer.zig");
const Scissor = @import("Scissor.zig");
const t = @import("types.zig");
const MouseState = t.MouseState;

const log = std.log.scoped(.tui);

const Options = struct {
    memory_pool: stdx.BufferPoolOptions,

    pub const default = Options{
        .memory_pool = .{
            .block_size = stdx.MB(8),
            .size_limit = 256,
        },
    };
};

const root = @import("root");
const renderer_options: Options = if (@hasDecl(root, "renderer_options")) root.renderer_options else .default;

pub const MemoryPool = stdx.BufferPoolExtra(renderer_options.memory_pool);

const Renderer = @This();

buffers: [2]FrameBuffer,
render_buffer: *FrameBuffer,
back_buffer: *FrameBuffer,
terminal: *Terminal,
redraw: bool = true,
mouse_x: u16 = 0,
mouse_y: u16 = 0,
current_mouse_down: MouseState = .{},
previous_mouse_down: MouseState = .{},
memory_pool: MemoryPool,
arena: MemoryPool.ArenaAllocator,

pub fn init(self: *Renderer, terminal: *Terminal, options: FrameBuffer.Options) error{ OutOfMemory, ReserveFailed }!void {
    self.buffers[0] = try FrameBuffer.init(terminal.size.width, terminal.size.height, options);
    self.buffers[1] = try FrameBuffer.init(terminal.size.width, terminal.size.height, options);
    self.render_buffer = &self.buffers[0];
    self.back_buffer = &self.buffers[1];
    self.render_buffer.clear();
    self.back_buffer.clear();
    self.redraw = true;
    self.terminal = terminal;
    self.current_mouse_down = .{};
    self.previous_mouse_down = .{};
    self.memory_pool = try MemoryPool.init();
    self.arena = MemoryPool.ArenaAllocator.init(&self.memory_pool);

    terminal.clearScreen() catch {};
}

pub fn deinit(self: *Renderer) void {
    self.terminal.clearScreen() catch {};
    self.buffers[0].deinit();
    self.buffers[1].deinit();
    self.arena.deinit();
}

pub fn beginFrame(self: *Renderer, events: []const Event) error{OutOfMemory}!Context {
    var ctx: Context = .{
        .frame_arena = &self.arena,
        .events = events,
    };
    for (events) |event| {
        switch (event) {
            .key_pressed, .key_repeat => |key| {
                ctx.key_pressed = key;
            },
            .mouse_scroll_up => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                ctx.mouse_scroll += 1;
            },
            .mouse_scroll_down => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                ctx.mouse_scroll -= 1;
            },
            .mouse_move => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
            },
            .mouse_left_pressed,
            .mouse_left_released,
            .mouse_right_pressed,
            .mouse_right_released,
            .mouse_drag_left,
            .mouse_drag_middle,
            .mouse_drag_right,
            .mouse_middle_pressed,
            .mouse_middle_released,
            .mouse_released,
            => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                switch (event) {
                    .mouse_left_pressed => self.current_mouse_down.left = true,
                    .mouse_left_released => self.current_mouse_down.left = false,
                    .mouse_right_pressed => self.current_mouse_down.right = true,
                    .mouse_right_released => self.current_mouse_down.right = false,
                    .mouse_middle_pressed => self.current_mouse_down.middle = true,
                    .mouse_middle_released => self.current_mouse_down.middle = false,
                    .mouse_drag_left => self.current_mouse_down.left = true,
                    .mouse_drag_middle => self.current_mouse_down.middle = true,
                    .mouse_drag_right => self.current_mouse_down.right = true,
                    .mouse_released => {
                        self.current_mouse_down.left = false;
                        self.current_mouse_down.right = false;
                        self.current_mouse_down.middle = false;
                    },
                    else => unreachable,
                }
            },
            .resize => |resize| {
                ctx.resize = resize;
                const new_cells = @as(usize, resize.width) * @as(usize, resize.height);
                if (new_cells > self.buffers[0].cells.max_elements_count) {
                    log.err("Resized to too large a size", .{});
                    return error.OutOfMemory;
                }
                try self.buffers[0].cells.ensureTotalCapacity(new_cells);
                try self.buffers[1].cells.ensureTotalCapacity(new_cells);
                self.buffers[0].width = resize.width;
                self.buffers[0].height = resize.height;
                self.buffers[1].width = resize.width;
                self.buffers[1].height = resize.height;
                self.redraw = true;
                self.terminal.clearScreen() catch {};
            },
            else => {},
        }
    }
    self.render_buffer.clear();
    ctx.mouse_x = self.mouse_x;
    ctx.mouse_y = self.mouse_y;

    ctx.mouse_down.left = self.current_mouse_down.left and self.previous_mouse_down.left;
    ctx.mouse_down.right = self.current_mouse_down.right and self.previous_mouse_down.right;
    ctx.mouse_down.middle = self.current_mouse_down.middle and self.previous_mouse_down.middle;
    ctx.mouse_pressed.left = self.current_mouse_down.left and !self.previous_mouse_down.left;
    ctx.mouse_pressed.right = self.current_mouse_down.right and !self.previous_mouse_down.right;
    ctx.mouse_pressed.middle = self.current_mouse_down.middle and !self.previous_mouse_down.middle;
    ctx.mouse_released.left = !self.current_mouse_down.left and self.previous_mouse_down.left;
    ctx.mouse_released.right = !self.current_mouse_down.right and self.previous_mouse_down.right;
    ctx.mouse_released.middle = !self.current_mouse_down.middle and self.previous_mouse_down.middle;

    ctx.scissor = self.render_buffer.scissor();
    return ctx;
}

pub fn endFrame(self: *Renderer) void {
    if (self.redraw) {
        self.render_buffer.fullRedraw(self.terminal.getWriter()) catch {};
        self.redraw = false;
    } else {
        @branchHint(.likely);
        self.render_buffer.diffRedraw(self.back_buffer, self.terminal.getWriter()) catch {};
    }
    self.terminal.flush() catch {};
    self.swapBuffers();
    self.arena.reset();
    self.previous_mouse_down = self.current_mouse_down;
}

pub fn swapBuffers(self: *Renderer) void {
    std.mem.swap(*FrameBuffer, &self.back_buffer, &self.render_buffer);
}
