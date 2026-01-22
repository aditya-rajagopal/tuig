const std = @import("std");

const tuig = @import("tuig");
const Context = tuig.renderer.Context;
const Cell = tuig.renderer.Cell;

const app = @import("app.zig");
const helper = @import("helper.zig");
const drawBox = helper.drawBox;

const Tetris = @This();

state: State = .waiting,
frame: u8 = 0,
selection: u8 = 0,

const State = enum { waiting, playing, game_over };

pub fn init(self: *Tetris) void {
    self.state = .waiting;
    self.frame = 0;
    self.selection = 0;
}

pub fn deinit(self: *Tetris) void {
    self.state = .waiting;
    self.frame = 0;
    self.selection = 0;
}

pub fn reset(self: *Tetris, memory_pool: *app.MemoryPool, ctx: Context) error{Failed}!void {
    _ = ctx;
    _ = memory_pool;
    self.state = .waiting;
    self.frame = 0;
    self.selection = 0;
}

const TetrisResult = enum { quit, noop, back };

const Size = struct {
    width: u16,
    height: u16,
};

const Playfield = Size{ .width = 22, .height = 22 };

const tetris_box = helper.BoxCharacters{
    .bottom_horizontal = '\u{1FB02}',
    .top_horizontal = '\u{1FB2D}',
    .right = '\u{258D}',
    .left = '\u{1FB88}',
    .top_right = '\u{1FB0F}',
    .top_left = '\u{1FB1E}',
    .bottom_left = '\u{1FB01}',
    .bottom_right = '\u{1FB00}',
};

pub fn updateAndRender(self: *Tetris, ctx: Context) TetrisResult {
    if (ctx.isKeyPressed(.q)) return .quit;
    if (ctx.isKeyPressed(.escape)) return .back;

    if (ctx.scissor.width_global < Playfield.width or ctx.scissor.height_global < Playfield.height) {
        var buf: [128]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "Resize to atleast {d}x{d}[Now: {d}x{d}]", .{ Playfield.width, Playfield.height, ctx.scissor.width_global, ctx.scissor.height_global }) catch unreachable;
        const x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, @intCast(str.len)), 2);
        const y = (ctx.scissor.height_global - 1) / 2;
        const area = ctx.scissor.initChild(@intCast(x), @intCast(y), @intCast(str.len), 1);
        _ = area.renderLineDelimiter(0, 0, str, null, false);
        return .noop;
    }

    const start_x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, Playfield.width), 2);
    const start_y = @divFloor(@as(i17, ctx.scissor.height_global) - @as(i17, Playfield.height), 2);

    const game_area = drawBox(ctx.scissor, start_x, start_y, Playfield.width, Playfield.height, "", tetris_box);

    if (ctx.isKeyPressed(.down)) {
        self.selection -%= 1;
    }
    if (ctx.isKeyPressed(.up)) {
        self.selection +%= 1;
    }

    const ts = [_]Tetromino{ Tetromino.I, Tetromino.O, Tetromino.T, Tetromino.S, Tetromino.Z, Tetromino.J, Tetromino.L };
    const t = ts[self.selection % ts.len];
    const position: Displacement = .{ .x = 5, .y = 10 };
    if (ctx.isKeyPressed(.right)) {
        self.frame +%= 1;
    }
    if (ctx.isKeyPressed(.left)) {
        self.frame -%= 1;
    }
    switch (t.center) {
        .bottom => {
            const render_position = position;
            for (t.frames[self.frame % 4], 0..) |cell, i| {
                _ = i;
                const x_cell = (render_position.x + cell.x) * 2;
                const y_cell = render_position.y + cell.y;
                // var buf: [128]u8 = undefined;
                // const str = std.fmt.bufPrint(&buf, "[{d},{d}]", .{ x_cell, y_cell }) catch unreachable;
                // const x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, @intCast(str.len)), 2);
                // const y = ctx.scissor.height_global - i - 1;
                // const area = ctx.scissor.initChild(@intCast(x), @intCast(y), @intCast(str.len), 1);
                // _ = area.renderLineDelimiter(0, 0, str, null, false);
                const x_int: u16 = @intFromFloat(x_cell);
                const y_int: u16 = @intFromFloat(@floor(y_cell));
                _ = game_area.set(x_int - 1, y_int, Cell{ .codepoint = '█' });
                _ = game_area.set(x_int, y_int, Cell{ .codepoint = '█' });
            }
        },
        .middle => {
            const render_position: Displacement = .{ .x = position.x, .y = position.y - 0.5 };
            for (t.frames[self.frame % 4], 0..) |cell, i| {
                _ = i;
                const x_cell = (render_position.x + cell.x) * 2;
                const y_cell = render_position.y + cell.y;
                // var buf: [128]u8 = undefined;
                // const str = std.fmt.bufPrint(&buf, "[{d},{d}]", .{ x_cell, y_cell }) catch unreachable;
                // const x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, @intCast(str.len)), 2);
                // const y = ctx.scissor.height_global - i - 1;
                // const area = ctx.scissor.initChild(@intCast(x), @intCast(y), @intCast(str.len), 1);
                // _ = area.renderLineDelimiter(0, 0, str, null, false);
                const x_int: u16 = @intFromFloat(x_cell);
                const y_int: u16 = @intFromFloat(@floor(y_cell));
                _ = game_area.set(x_int - 1, y_int, Cell{ .codepoint = '█' });
                _ = game_area.set(x_int, y_int, Cell{ .codepoint = '█' });
            }
        },
    }

    return .noop;
}

const Displacement = struct {
    x: f32,
    y: f32,
};

pub const Tetromino = struct {
    center: Center,
    frames: [4][4]Displacement,

    const Center = enum { bottom, middle };

    pub const O = Tetromino{
        .center = .bottom,
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.5, .y = 0.5 }, .{ .x = -0.5, .y = 0.5 }, .{ .x = 0.5, .y = -0.5 }, .{ .x = -0.5, .y = -0.5 } },
            .{ .{ .x = 0.5, .y = 0.5 }, .{ .x = -0.5, .y = 0.5 }, .{ .x = 0.5, .y = -0.5 }, .{ .x = -0.5, .y = -0.5 } },
            .{ .{ .x = 0.5, .y = 0.5 }, .{ .x = -0.5, .y = 0.5 }, .{ .x = 0.5, .y = -0.5 }, .{ .x = -0.5, .y = -0.5 } },
            .{ .{ .x = 0.5, .y = 0.5 }, .{ .x = -0.5, .y = 0.5 }, .{ .x = 0.5, .y = -0.5 }, .{ .x = -0.5, .y = -0.5 } },
        },
    };
    pub const I = Tetromino{
        .center = .bottom,
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.5, .y = -0.5 }, .{ .x = -0.5, .y = -0.5 }, .{ .x = 1.5, .y = -0.5 }, .{ .x = -1.5, .y = -0.5 } },
            .{ .{ .x = 0.5, .y = 0.5 }, .{ .x = 0.5, .y = -0.5 }, .{ .x = 0.5, .y = 1.5 }, .{ .x = 0.5, .y = -1.5 } },
            .{ .{ .x = 0.5, .y = 0.5 }, .{ .x = -0.5, .y = 0.5 }, .{ .x = 1.5, .y = 0.5 }, .{ .x = -1.5, .y = 0.5 } },
            .{ .{ .x = -0.5, .y = 0.5 }, .{ .x = -0.5, .y = -0.5 }, .{ .x = -0.5, .y = 1.5 }, .{ .x = -0.5, .y = -1.5 } },
        },
    };
    pub const T = Tetromino{
        .center = .middle,
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 } },
        },
    };
    pub const S = Tetromino{
        .center = .middle,
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
    pub const Z = Tetromino{
        .center = .middle,
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
        },
    };
    pub const J = Tetromino{
        .center = .middle,
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 1.0 } },
        },
    };
    pub const L = Tetromino{
        .center = .middle,
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
};
