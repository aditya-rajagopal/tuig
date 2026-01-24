const std = @import("std");

const tuig = @import("tuig");
const Context = tuig.renderer.Context;
const Cell = tuig.renderer.Cell;

const app = @import("app.zig");
const helper = @import("helper.zig");
const drawBox = helper.drawBox;

const Tetris = @This();

state: GameState = .{},
frame: u8 = 0,
rng: std.Random.DefaultPrng,
timer: ?std.time.Timer = null,

const State = enum { waiting, playing, game_over };

pub fn init(self: *Tetris) void {
    self.state = .{};
    self.frame = 0;
    self.timer = null;
    self.rng = std.Random.DefaultPrng.init(0);
}

pub fn deinit(self: *Tetris) void {
    self.state = .{};
    self.frame = 0;
    self.timer = null;
}

pub fn reset(self: *Tetris, memory_pool: *app.MemoryPool, ctx: Context) error{Failed}!void {
    _ = ctx;
    _ = memory_pool;
    self.state = .{};
    self.rng.random().shuffle(Tetromino.Tag, &self.state.next_pieces);
    self.state.in_flight = .{ .position = .{ .x = 5, .y = 0 }, .tag = self.state.next_pieces[0] };
    self.state.ptr = 1;
    self.frame = 0;
    self.timer = null;
}

const TetrisResult = enum { quit, noop, back };

const Size = struct { width: u16, height: u16 };

const PlayArea = Size{ .width = 10, .height = 20 };

const GameState = struct {
    board: [PlayArea.width * PlayArea.height]u8 = @splat(0),
    in_flight: Piece = .{},
    next_pieces: [7]Tetromino.Tag = .{ .I, .O, .T, .S, .Z, .J, .L },
    ptr: u8 = 0,

    pub const Piece = struct {
        tag: Tetromino.Tag = .I,
        frame: u8 = 0,
        position: Displacement = .{ .x = 5, .y = 0 },
    };
};

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

    if (ctx.scissor.width_global < PlayArea.width * 2 + 2 or ctx.scissor.height_global < PlayArea.height + 2) {
        var buf: [128]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "Resize to atleast {d}x{d}[Now: {d}x{d}]", .{ PlayArea.width * 2 + 2, PlayArea.height + 2, ctx.scissor.width_global, ctx.scissor.height_global }) catch unreachable;
        const x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, @intCast(str.len)), 2);
        const y = (ctx.scissor.height_global - 1) / 2;
        const area = ctx.scissor.initChild(@intCast(x), @intCast(y), @intCast(str.len), 1);
        _ = area.renderLineDelimiter(0, 0, str, null, false);
        return .noop;
    }

    if (self.timer == null) {
        self.timer = std.time.Timer.start() catch return .back;
    }
    const timer = &self.timer.?;
    const delta = timer.read();

    const start_x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, PlayArea.width * 2 + 2), 2);
    const start_y = @divFloor(@as(i17, ctx.scissor.height_global) - @as(i17, PlayArea.height + 2), 2);

    const game_area = drawBox(ctx.scissor, start_x, start_y, PlayArea.width * 2 + 2, PlayArea.height + 2, "", tetris_box);

    var direction: i8 = 0;
    if (ctx.isKeyPressed(.left)) direction -= 1;
    if (ctx.isKeyPressed(.right)) direction += 1;
    if (ctx.isKeyPressed(.up)) self.state.in_flight.frame +%= 1;
    if (ctx.isKeyPressed(.down)) self.state.in_flight.frame -%= 1;

    const render_position: Displacement = switch (self.state.in_flight.tag.get().center) {
        .bottom => self.state.in_flight.position,
        .middle => .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 },
    };

    const Result = enum { success, fail };

    if (direction != 0) {
        const result: Result = for (self.state.in_flight.tag.get().frames[self.state.in_flight.frame % 4]) |cell| {
            const x_cell = render_position.x + cell.x;
            var x_int: i17 = @intFromFloat(x_cell);
            x_int += @intCast(direction);
            if (x_int < 0 or x_int >= PlayArea.width) break .fail;
        } else .success;
        if (result == .success) {
            self.state.in_flight.position.x += @floatFromInt(direction);
        }
    }

    const result: Result = for (self.state.in_flight.tag.get().frames[self.state.in_flight.frame % 4]) |cell| {
        const x_cell = render_position.x + cell.x;
        const y_cell = render_position.y + cell.y;
        const x_int: u16 = @intFromFloat(x_cell);
        const y_int: i17 = @intFromFloat(@floor(y_cell));
        if (y_int < -1) continue;
        const y_test: u16 = @intCast(y_int + 1);
        if (y_test >= PlayArea.height or self.state.board[y_test * PlayArea.width + x_int] != 0) {
            // Block is occupied stop the block
            break .fail;
        }
    } else .success;

    if (result == .success) {
        for (self.state.in_flight.tag.get().frames[self.state.in_flight.frame % 4]) |cell| {
            const x_cell = (render_position.x + cell.x) * 2;
            const y_cell = render_position.y + cell.y;
            const x_int: u16 = @intFromFloat(x_cell);
            const y_int: i17 = @intFromFloat(@floor(y_cell));
            if (y_int < 0) continue;
            _ = game_area.set(x_int - 1, @intCast(y_int), Cell{ .data = .{ .codepoint = '█' } });
            _ = game_area.set(x_int, @intCast(y_int), Cell{ .data = .{ .codepoint = '█' } });
        }
        if (delta > 200 * 1000 * 1000) {
            timer.reset();
            self.state.in_flight.position.y += 1;
        }
    } else {
        for (self.state.in_flight.tag.get().frames[self.state.in_flight.frame % 4]) |cell| {
            const x_cell = render_position.x + cell.x;
            const y_cell = render_position.y + cell.y;
            const x_int: u16 = @intFromFloat(x_cell);
            const y_int: i17 = @intFromFloat(@floor(y_cell));
            if (y_int < 0) return .back;
            self.state.board[@as(u16, @intCast(y_int)) * PlayArea.width + x_int] = 1;
        }
        if (self.state.ptr >= self.state.next_pieces.len) {
            self.state.ptr = 0;
            self.rng.random().shuffle(Tetromino.Tag, &self.state.next_pieces);
        }
        defer self.state.ptr += 1;
        self.state.in_flight = .{ .position = .{ .x = 5, .y = 0 }, .tag = self.state.next_pieces[self.state.ptr] };
    }

    for (0..PlayArea.height) |y| {
        for (0..PlayArea.width) |x| {
            if (self.state.board[y * PlayArea.width + x] == 1) {
                const x_int: u16 = @intCast(x * 2);
                _ = game_area.set(x_int, @intCast(y), Cell{ .data = .{ .codepoint = '█' } });
                _ = game_area.set(x_int + 1, @intCast(y), Cell{ .data = .{ .codepoint = '█' } });
            }
        }
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

    pub const Tag = enum {
        I,
        O,
        T,
        S,
        Z,
        J,
        L,

        pub fn get(tag: Tag) Tetromino {
            switch (tag) {
                .I => return .I,
                .O => return .O,
                .T => return .T,
                .S => return .S,
                .Z => return .Z,
                .J => return .J,
                .L => return .L,
            }
        }
    };

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
