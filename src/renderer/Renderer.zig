const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const term = @import("terminal");
const seq = term.sequences;
const Terminal = term.Terminal;
const Event = term.Event;
const KeyEvent = term.KeyEvent;
const MouseEvent = term.MouseEvent;

const c = @import("cell.zig");
const Cell = c.Cell;
const Style = c.Style;
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
            .block_size = stdx.MB(1),
            .size_limit = 256,
        },
    };
};

const root = @import("root");
const renderer_options: Options = if (@hasDecl(root, "renderer_options")) root.renderer_options else .default;

pub const MemoryPool = stdx.BufferPoolExtra(renderer_options.memory_pool);

const Renderer = @This();

cell_buffers: [2]t.CellBuffer,
buffers: [2]FrameBuffer,
render_buffer: *FrameBuffer,
back_buffer: *FrameBuffer,
terminal: *Terminal,
redraw: bool = true,
mouse_x: u16 = 0,
mouse_y: u16 = 0,
current_mouse_down: MouseState = .{},
previous_mouse_down: MouseState = .{},
// @TODO GILA(generous_magma_3gs)
memory_pool: MemoryPool,
arena: MemoryPool.ArenaAllocator,

pub const Config = struct {
    max_cells: usize,
    grapheme_buffer_size: t.GraphemeBuffer.Size,

    pub const default_screen = Config{
        .max_cells = 512 * 512, // 2MB cache
        .grapheme_buffer_size = .{ .max = stdx.MB(2), .initial = stdx.KB(16) },
    };

    pub const small_buffer = Config{
        .max_cells = 128 * 128, // 128kb buffer
        .grapheme_buffer_size = .{ .max = stdx.KB(16), .initial = stdx.KB(4) },
    };

    pub const tiny_buffer = Config{
        .max_cells = 64 * 64, // 32kb buffer
        .grapheme_buffer_size = .{ .max = stdx.KB(8), .initial = stdx.KB(4) },
    };
};

pub fn init(self: *Renderer, terminal: *Terminal, config: Config) error{ OutOfMemory, ReserveFailed, BufferTooLarge }!void {
    const width = terminal.size.width;
    const height = terminal.size.height;
    const size: usize = @as(usize, width) * @as(usize, height);

    self.cell_buffers[0] = try t.CellBuffer.initCapacity(config.max_cells, size);
    self.cell_buffers[1] = try t.CellBuffer.initCapacity(config.max_cells, size);
    self.buffers[0] = try FrameBuffer.init(
        self.cell_buffers[0].reserved_pages[0..size],
        width,
        height,
        config.grapheme_buffer_size,
    );
    self.buffers[1] = try FrameBuffer.init(
        self.cell_buffers[1].reserved_pages[0..size],
        width,
        height,
        config.grapheme_buffer_size,
    );
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

    terminal.write(seq.screen.clear_and_home) catch {};
    terminal.flush() catch {};
}

pub fn deinit(self: *Renderer) void {
    self.terminal.write(seq.screen.clear_and_home) catch {};
    self.terminal.flush() catch {};
    self.cell_buffers[0].deinit();
    self.cell_buffers[1].deinit();
    self.buffers[0].deinit();
    self.buffers[1].deinit();
    self.arena.deinit();
}

pub fn beginFrame(self: *Renderer, events: []const Event) error{OutOfMemory}!Context {
    var ctx: Context = .{
        .frame_arena = &self.arena,
        .events = events,
    };
    var key_pressed = std.ArrayList(KeyEvent).initBuffer(try self.arena.pushArray(KeyEvent, events.len));
    var key_released = std.ArrayList(KeyEvent).initBuffer(try self.arena.pushArray(KeyEvent, events.len));
    var key_repeat = std.ArrayList(KeyEvent).initBuffer(try self.arena.pushArray(KeyEvent, events.len));

    for (events) |event| {
        switch (event) {
            .key_pressed => |key| {
                try key_pressed.appendBounded(key);
            },
            .key_repeat => |key| {
                try key_repeat.appendBounded(key);
            },
            .key_released => |key| {
                try key_released.appendBounded(key);
            },
            .mouse_scroll_up => |info| {
                assert(info.x >= 1);
                assert(info.y >= 1);
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                ctx.mouse_scroll += 1;
            },
            .mouse_scroll_down => |info| {
                assert(info.x >= 1);
                assert(info.y >= 1);
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                ctx.mouse_scroll -= 1;
            },
            .mouse_move => |info| {
                assert(info.x >= 1);
                assert(info.y >= 1);
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
                assert(info.x >= 1);
                assert(info.y >= 1);
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                switch (event) {
                    .mouse_left_pressed => {
                        ctx.mouse_pressed.left = true;
                        ctx.mouse_down.left = true;
                        self.current_mouse_down.left = true;
                    },
                    .mouse_left_released => {
                        ctx.mouse_released.left = true;
                        ctx.mouse_down.left = false;
                        self.current_mouse_down.left = false;
                    },
                    .mouse_right_pressed => {
                        ctx.mouse_pressed.right = true;
                        ctx.mouse_down.right = true;
                        self.current_mouse_down.right = true;
                    },
                    .mouse_right_released => {
                        ctx.mouse_released.right = true;
                        ctx.mouse_down.right = false;
                        self.current_mouse_down.right = false;
                    },
                    .mouse_middle_pressed => {
                        ctx.mouse_pressed.middle = true;
                        ctx.mouse_down.middle = true;
                        self.current_mouse_down.middle = true;
                    },
                    .mouse_middle_released => {
                        ctx.mouse_released.middle = true;
                        ctx.mouse_down.middle = false;
                        self.current_mouse_down.middle = false;
                    },
                    .mouse_drag_left => {
                        ctx.mouse_down.left = true;
                        self.current_mouse_down.left = true;
                    },
                    .mouse_drag_middle => {
                        ctx.mouse_down.middle = true;
                        self.current_mouse_down.middle = true;
                    },
                    .mouse_drag_right => {
                        ctx.mouse_down.right = true;
                        self.current_mouse_down.right = true;
                    },
                    .mouse_released => {
                        ctx.mouse_released.left = true;
                        ctx.mouse_released.right = true;
                        ctx.mouse_released.middle = true;
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
                if (new_cells > self.cell_buffers[0].max_elements_count) {
                    log.err("Resized to too large a size", .{});
                    return error.OutOfMemory;
                }
                try self.cell_buffers[0].ensureTotalCapacity(new_cells);
                try self.cell_buffers[1].ensureTotalCapacity(new_cells);
                self.buffers[0].cells = self.cell_buffers[0].reserved_pages[0..new_cells];
                self.buffers[0].width = resize.width;
                self.buffers[0].height = resize.height;
                self.buffers[1].cells = self.cell_buffers[1].reserved_pages[0..new_cells];
                self.buffers[1].width = resize.width;
                self.buffers[1].height = resize.height;
                self.redraw = true;
                self.terminal.write(seq.screen.clear_and_home) catch {};
                self.terminal.flush() catch {};
            },
            else => {},
        }
    }
    self.render_buffer.clear();
    ctx.mouse_x = self.mouse_x;
    ctx.mouse_y = self.mouse_y;
    ctx.key_pressed = key_pressed.items;
    ctx.key_released = key_released.items;
    ctx.key_repeat = key_repeat.items;
    ctx.mouse_down.left = ctx.mouse_down.left or self.current_mouse_down.left and self.previous_mouse_down.left;
    ctx.mouse_down.right = ctx.mouse_down.right or self.current_mouse_down.right and self.previous_mouse_down.right;
    ctx.mouse_down.middle = ctx.mouse_down.middle or self.current_mouse_down.middle and self.previous_mouse_down.middle;

    ctx.scissor = self.render_buffer.scissor();
    return ctx;
}

pub fn endFrame(self: *Renderer, force_redraw: bool, style_sheet: *const Style.Sheet) void {
    self.terminal.write(seq.sync_update.begin) catch {};
    if (self.redraw or force_redraw) {
        self.render_buffer.fullRedraw(style_sheet, self.terminal.getWriter()) catch {};
        self.redraw = false;
    } else {
        self.render_buffer.diffRedraw(self.back_buffer, style_sheet, self.terminal.getWriter()) catch {};
    }
    self.terminal.write(seq.sync_update.end ++ seq.sgr.reset_all) catch {};
    self.terminal.flush() catch {};
    self.swapBuffers();
    self.arena.reset();
    self.previous_mouse_down = self.current_mouse_down;
}

pub fn swapBuffers(self: *Renderer) void {
    std.mem.swap(*FrameBuffer, &self.back_buffer, &self.render_buffer);
}
