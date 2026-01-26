const std = @import("std");

const tuig = @import("tuig");
const Context = tuig.renderer.Context;
const Cell = tuig.renderer.Cell;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const app = @import("app.zig");
const helper = @import("helper.zig");
const drawBox = helper.drawBox;

const Tetris = @This();

state: GameState = .{},
rng: std.Random.DefaultPrng,
timer: ?std.time.Timer = null,

pub fn init(self: *Tetris) void {
    self.state = .{};
    self.state.piece_state = .falling;
    self.state.lock_delay = 500 * 1000 * 1000;
    self.timer = null;
    const now = std.time.Instant.now() catch unreachable;
    self.rng = std.Random.DefaultPrng.init(@bitCast(std.mem.asBytes(&now)[0..8].*));
}

pub fn deinit(self: *Tetris) void {
    self.state = .{};
    self.timer = null;
}

pub fn reset(self: *Tetris, memory_pool: *app.MemoryPool, ctx: Context) error{Failed}!void {
    _ = ctx;
    _ = memory_pool;
    self.state = .{};
    self.rng.random().shuffle(Tetromino.Tag, &self.state.next_pieces);
    self.state.in_flight = .{ .position = .{ .x = 5, .y = 0 }, .tag = self.state.next_pieces[0] };
    self.state.ptr = 1;
    self.state.piece_state = .falling;
    self.state.lock_delay = 500 * 1000 * 1000;
    self.timer = null;
}

const TetrisResult = enum { quit, noop, back };

const Size = struct { width: u16, height: u16 };

const PlayArea = Size{ .width = 10, .height = 20 };

const GameState = struct {
    board: [PlayArea.width * PlayArea.height]u8 = @splat(0),
    in_flight: Piece = .{},
    piece_state: enum { falling, lock_delay } = .falling,
    lock_delay: i64 = 500 * 1000 * 1000,
    next_pieces: [7]Tetromino.Tag = .{ .O, .O, .O, .O, .O, .O, .O },
    // next_pieces: [7]Tetromino.Tag = .{ .I, .O, .T, .S, .Z, .J, .L },
    ptr: u8 = 0,
    gravity: f32 = 0.1,

    pub const Piece = struct {
        tag: Tetromino.Tag = .I,
        state: Tetromino.State = .O,
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
    var delta = timer.read();

    const start_x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, PlayArea.width * 2 + 2), 2);
    const start_y = @divFloor(@as(i17, ctx.scissor.height_global) - @as(i17, PlayArea.height + 2), 2);

    const game_area = drawBox(ctx.scissor, start_x, start_y, PlayArea.width * 2 + 2, PlayArea.height + 2, "", tetris_box);

    var direction: i8 = 0;
    var rotation: i8 = 0;
    if (ctx.isKeyPressed(.left)) direction -= 1;
    if (ctx.isKeyPressed(.right)) direction += 1;
    if (ctx.isKeyPressed(.a)) rotation -= 1;
    if (ctx.isKeyPressed(.d)) rotation += 1;
    if (ctx.isKeyPressed(.down)) self.state.gravity = 10.0 else self.state.gravity = 0.1;

    var pivot: Displacement = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };

    if (direction != 0) {
        for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
            const x_cell = pivot.x + cell.x;
            const y_cell = pivot.y + cell.y;
            var x: i17 = @intFromFloat(x_cell);
            x += @intCast(direction);
            const y: i17 = @intFromFloat(@floor(y_cell));
            if (x < 0 or x >= PlayArea.width or y < 0 or y >= PlayArea.height) {
                break;
            }
            if (self.state.board[@as(u16, @intCast(y)) * PlayArea.width + @as(u16, @intCast(x))] != 0) {
                break;
            }
        } else {
            self.state.in_flight.position.x += @floatFromInt(direction);
        }
    }

    pivot = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };

    if (rotation != 0) {
        const rot_current = self.state.in_flight.state;
        const rot_next = if (rotation > 0) rot_current.rotClockwise() else rot_current.rotCounterClockwise();
        switch (self.state.in_flight.tag) {
            .O => {
                const offset_next = Tetromino.OOffset[@intFromEnum(rot_next)][0];
                const offset_current = Tetromino.OOffset[@intFromEnum(rot_current)][0];
                const translations: Displacement = .{ .x = offset_current.x - offset_next.x, .y = offset_current.y - offset_next.y };
                const next_frame = self.state.in_flight.tag.get().getFrame(rot_next);
                for (next_frame) |cell| {
                    const x_cell = pivot.x + cell.x + translations.x;
                    const y_cell = pivot.y + cell.y + translations.y;
                    const x: i17 = @intFromFloat(@floor(x_cell));
                    const y: i17 = @intFromFloat(@floor(y_cell));
                    if (x < 0 or x >= PlayArea.width or y < 0 or y >= PlayArea.height) {
                        break;
                    }
                    if (self.state.board[@as(u16, @intCast(y)) * PlayArea.width + @as(u16, @intCast(x))] != 0) {
                        break;
                    }
                } else {
                    self.state.in_flight.position.x += translations.x;
                    self.state.in_flight.position.y += translations.y;
                    self.state.in_flight.state = rot_next;
                }
            },
            .I => {
                const offset_next = Tetromino.IOffset[@intFromEnum(rot_next)];
                const offset_current = Tetromino.IOffset[@intFromEnum(rot_current)];
                const translations: [5]Displacement = .{
                    .{ .x = offset_current[0].x - offset_next[0].x, .y = offset_current[0].y - offset_next[0].y },
                    .{ .x = offset_current[1].x - offset_next[1].x, .y = offset_current[1].y - offset_next[1].y },
                    .{ .x = offset_current[2].x - offset_next[2].x, .y = offset_current[2].y - offset_next[2].y },
                    .{ .x = offset_current[3].x - offset_next[3].x, .y = offset_current[3].y - offset_next[3].y },
                    .{ .x = offset_current[4].x - offset_next[4].x, .y = offset_current[4].y - offset_next[4].y },
                };
                const next_frame = self.state.in_flight.tag.get().getFrame(rot_next);
                for (translations) |translation| {
                    for (next_frame) |cell| {
                        const x_cell = pivot.x + cell.x + translation.x;
                        const y_cell = pivot.y + cell.y + translation.y;
                        const x: i17 = @intFromFloat(@floor(x_cell));
                        const y: i17 = @intFromFloat(@floor(y_cell));
                        if (x < 0 or x >= PlayArea.width or y < 0 or y >= PlayArea.height) {
                            break;
                        }
                        if (self.state.board[@as(u16, @intCast(y)) * PlayArea.width + @as(u16, @intCast(x))] != 0) {
                            break;
                        }
                    } else {
                        self.state.in_flight.position.x += translation.x;
                        self.state.in_flight.position.y += translation.y;
                        self.state.in_flight.state = rot_next;
                        break;
                    }
                }
            },
            else => {
                const offset_next = Tetromino.JLSTZOffset[@intFromEnum(rot_next)];
                const offset_current = Tetromino.JLSTZOffset[@intFromEnum(rot_current)];
                const translations: [5]Displacement = .{
                    .{ .x = offset_current[0].x - offset_next[0].x, .y = offset_current[0].y - offset_next[0].y },
                    .{ .x = offset_current[1].x - offset_next[1].x, .y = offset_current[1].y - offset_next[1].y },
                    .{ .x = offset_current[2].x - offset_next[2].x, .y = offset_current[2].y - offset_next[2].y },
                    .{ .x = offset_current[3].x - offset_next[3].x, .y = offset_current[3].y - offset_next[3].y },
                    .{ .x = offset_current[4].x - offset_next[4].x, .y = offset_current[4].y - offset_next[4].y },
                };
                const next_frame = self.state.in_flight.tag.get().getFrame(rot_next);
                for (translations) |translation| {
                    for (next_frame) |cell| {
                        const x_cell = pivot.x + cell.x + translation.x;
                        const y_cell = pivot.y + cell.y + translation.y;
                        const x: i17 = @intFromFloat(@floor(x_cell));
                        const y: i17 = @intFromFloat(@floor(y_cell));
                        if (x < 0 or x >= PlayArea.width or y < 0 or y >= PlayArea.height) {
                            break;
                        }
                        if (self.state.board[@as(u16, @intCast(y)) * PlayArea.width + @as(u16, @intCast(x))] != 0) {
                            break;
                        }
                    } else {
                        self.state.in_flight.position.x += translation.x;
                        self.state.in_flight.position.y += translation.y;
                        self.state.in_flight.state = rot_next;
                        break;
                    }
                }
            },
        }
    }

    pivot = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };

    if (self.state.piece_state == .falling) {
        self.state.piece_state = for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
            const x_cell = pivot.x + cell.x;
            const y_cell = pivot.y + cell.y;
            const x_int: u16 = @intFromFloat(x_cell);
            const y_int: i17 = @intFromFloat(@floor(y_cell));
            if (y_int < -1) continue;
            const y_test: u16 = @intCast(y_int + 1);
            if (y_test >= PlayArea.height or self.state.board[y_test * PlayArea.width + x_int] != 0) {
                // Block is occupied stop the block
                timer.reset();
                delta = 0;
                break .lock_delay;
            }
        } else .falling;
    }

    if (self.state.piece_state == .falling) {
        for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
            const x_cell = (pivot.x + cell.x) * 2;
            const y_cell = pivot.y + cell.y;
            const x_int: u16 = @intFromFloat(x_cell);
            const y_int: i17 = @intFromFloat(@floor(y_cell));
            if (y_int < 0) continue;
            _ = game_area.set(x_int - 1, @intCast(y_int), Cell{ .data = .{ .codepoint = '█' } });
            _ = game_area.set(x_int, @intCast(y_int), Cell{ .data = .{ .codepoint = '█' } });
        }
        const base_gravity_time: f32 = 1000.0 * 1000.0 * 1000.0 / 60.0;
        const gravity_time = base_gravity_time / self.state.gravity;
        if (@as(f32, @floatFromInt(delta)) > gravity_time) {
            timer.reset();
            self.state.in_flight.position.y += 1;
        }
    } else {
        if (delta >= self.state.lock_delay) {
            for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
                const x_cell = pivot.x + cell.x;
                const y_cell = pivot.y + cell.y;
                const x_int: u16 = @intFromFloat(@floor(x_cell));
                const y_int: i17 = @intFromFloat(@floor(y_cell));
                if (y_int < 0) return .back;
                self.state.board[@as(u16, @intCast(y_int)) * PlayArea.width + x_int] = 1;
            }
            self.state.in_flight = .{ .position = .{ .x = 5, .y = 0 }, .tag = self.state.next_pieces[self.state.ptr] };
            self.state.ptr += 1;
            if (self.state.ptr >= self.state.next_pieces.len) {
                self.state.ptr = 0;
                self.rng.random().shuffle(Tetromino.Tag, &self.state.next_pieces);
            }
            self.state.piece_state = .falling;
            timer.reset();
        } else {
            for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
                const x_cell = (pivot.x + cell.x) * 2;
                const y_cell = pivot.y + cell.y;
                const x_int: u16 = @intFromFloat(x_cell);
                const y_int: i17 = @intFromFloat(@floor(y_cell));
                if (y_int < 0) continue;
                _ = game_area.set(x_int - 1, @intCast(y_int), Cell{ .data = .{ .codepoint = '█' } });
                _ = game_area.set(x_int, @intCast(y_int), Cell{ .data = .{ .codepoint = '█' } });
            }
        }
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
    frames: [4][4]Displacement,

    pub fn getFrame(self: Tetromino, state: State) [4]Displacement {
        return self.frames[@intFromEnum(state)];
    }

    const State = enum(u2) {
        O = 0,
        R = 1,
        @"2" = 2,
        L = 3,

        pub inline fn rotClockwise(self: State) State {
            return @enumFromInt(@intFromEnum(self) +% 1);
        }

        pub inline fn rotCounterClockwise(self: State) State {
            return @enumFromInt(@intFromEnum(self) -% 1);
        }
    };

    pub const JLSTZOffset = [4][5]Displacement{
        .{ // O
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
        },
        .{ // R
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 1.0, .y = 0.0 },
            .{ .x = 1.0, .y = 1.0 },
            .{ .x = 0.0, .y = -2.0 },
            .{ .x = 1.0, .y = -2.0 },
        },
        .{ // 2
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
        },
        .{ // L
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = -1.0, .y = 0.0 },
            .{ .x = -1.0, .y = 1.0 },
            .{ .x = 0.0, .y = -2.0 },
            .{ .x = -1.0, .y = -2.0 },
        },
    };

    pub const IOffset = [4][5]Displacement{
        .{ // O
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = -1.0, .y = 0.0 },
            .{ .x = 2.0, .y = 0.0 },
            .{ .x = -1.0, .y = 0.0 },
            .{ .x = 2.0, .y = 0.0 },
        },
        .{ // R
            .{ .x = -1.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = 0.0 },
            .{ .x = 0.0, .y = -1.0 },
            .{ .x = 0.0, .y = 2.0 },
        },
        .{ // 2
            .{ .x = -1.0, .y = -1.0 },
            .{ .x = 1.0, .y = -1.0 },
            .{ .x = -2.0, .y = -1.0 },
            .{ .x = 1.0, .y = 0.0 },
            .{ .x = -2.0, .y = 0.0 },
        },
        .{ // L
            .{ .x = 0.0, .y = -1.0 },
            .{ .x = 0.0, .y = -1.0 },
            .{ .x = 0.0, .y = -1.0 },
            .{ .x = 0.0, .y = 1.0 },
            .{ .x = 0.0, .y = -2.0 },
        },
    };

    pub const OOffset = [4][1]Displacement{
        .{ // O
            .{ .x = 0.0, .y = 0.0 },
        },
        .{ // R
            .{ .x = 0.0, .y = 1.0 },
        },
        .{ // 2
            .{ .x = -1.0, .y = 1.0 },
        },
        .{ // L
            .{ .x = -1.0, .y = 0.0 },
        },
    };

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
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
    pub const I = Tetromino{
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 2.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 0.0, .y = 2.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -2.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = -2.0 } },
        },
    };
    pub const T = Tetromino{
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 } },
        },
    };
    pub const S = Tetromino{
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
    pub const Z = Tetromino{
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
        },
    };
    pub const J = Tetromino{
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 1.0 } },
        },
    };
    pub const L = Tetromino{
        .frames = [_][4]Displacement{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
};
