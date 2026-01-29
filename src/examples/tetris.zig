const std = @import("std");

const tuig = @import("tuig");
const Context = tuig.renderer.Context;
const Cell = tuig.renderer.Cell;
const Scissor = tuig.renderer.Scissor;

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
    self.state.gravity_delay = @intFromFloat(base_gravity_time / self.state.gravity);
}

pub fn deinit(self: *Tetris) void {
    self.state = .{};
    self.timer = null;
}

pub fn reset(self: *Tetris, memory_pool: *app.MemoryPool, ctx: *const Context) error{Failed}!void {
    _ = ctx;
    _ = memory_pool;
    self.state = .{};
    self.rng.random().shuffle(Tetromino.Tag, &self.state.next_pieces);
    self.state.in_flight = .{ .position = .{ .x = 5, .y = 0 }, .tag = self.state.next_pieces[0] };
    self.state.ptr = 1;
    self.state.piece_state = .falling;
    self.state.lock_delay = 500 * 1000 * 1000;
    self.state.gravity_delay = @intFromFloat(base_gravity_time / self.state.gravity);
    self.timer = null;
}

const TetrisResult = enum { quit, noop, back };

const Size = struct { width: u16, height: u16 };

const play_area = Size{ .width = 10, .height = 20 };

const lock_delay_ns = 500 * 1000 * 1000;
const base_gravity_time: f32 = 1000.0 * 1000.0 * 1000.0 / 60.0;

const GameState = struct {
    board: [play_area.width * play_area.height]u8 = @splat(0),
    in_flight: Piece = .{},
    piece_state: enum { falling, lock_delay } = .falling,
    lock_delay: i64 = 500 * 1000 * 1000,
    gravity_delay: i64 = @intFromFloat(base_gravity_time),
    // next_pieces: [7]Tetromino.Tag = .{ .O, .O, .O, .O, .O, .O, .O },
    next_pieces: [7]Tetromino.Tag = .{ .I, .O, .T, .S, .Z, .J, .L },
    ptr: u8 = 0,
    gravity: f32 = 0.05,

    pub const Piece = struct {
        tag: Tetromino.Tag = .I,
        state: Tetromino.State = .O,
        position: Position = .{ .x = 5, .y = 0 },
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

pub fn updateAndRender(self: *Tetris, ctx: *const Context) TetrisResult {
    if (ctx.isKeyPressed(.q)) return .quit;
    if (ctx.isKeyPressed(.escape)) return .back;

    if (ctx.scissor.width_global < play_area.width * 2 + 2 or ctx.scissor.height_global < play_area.height + 2) {
        var buf: [128]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "Resize to atleast {d}x{d}[Now: {d}x{d}]", .{ play_area.width * 2 + 2, play_area.height + 2, ctx.scissor.width_global, ctx.scissor.height_global }) catch unreachable;
        const x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, @intCast(str.len)), 2);
        const y = (ctx.scissor.height_global - 1) / 2;
        const area = ctx.scissor.initChild(@intCast(x), @intCast(y), @intCast(str.len), 1);
        _ = area.printAssumeNoGrapheme(str, 0, 0, .{ .wrap = false, .tab_width = 4 });
        return .noop;
    }

    if (self.timer == null) {
        self.timer = std.time.Timer.start() catch return .back;
    }
    const timer = &self.timer.?;
    const frame_time = timer.lap();

    const start_x = @divFloor(@as(i17, ctx.scissor.width_global) - @as(i17, play_area.width * 2 + 2), 2);
    const start_y = @divFloor(@as(i17, ctx.scissor.height_global) - @as(i17, play_area.height + 2), 2);

    const game_area = drawBox(ctx.scissor, start_x, start_y, play_area.width * 2 + 2, play_area.height + 2, "", tetris_box);

    self.handleTranslation(ctx);

    self.handleRotation(ctx);

    if (ctx.isKeyPressed(.down)) self.state.gravity = 10.0 else self.state.gravity = 0.05;

    self.handleSoftLock();

    switch (self.state.piece_state) {
        .falling => {
            self.renderInFlightPiece(game_area);
            self.state.gravity_delay -= @intCast(frame_time);
            if (self.state.gravity_delay <= 0) {
                const gravity_time = base_gravity_time / self.state.gravity;
                self.state.gravity_delay = @intFromFloat(gravity_time);
                self.state.in_flight.position.y += 1;
            }
        },
        .lock_delay => {
            self.state.lock_delay -= @intCast(frame_time);
            if (self.state.lock_delay <= 0) {
                if (self.lockInFlightPiece()) {
                    // @TODO deal with game over
                    return .back;
                }
            } else {
                self.renderInFlightPiece(game_area);
            }
        },
    }

    self.clearRows();

    self.renderGameArea(game_area);

    return .noop;
}

fn lockInFlightPiece(self: *Tetris) bool {
    const pivot = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };
    for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
        const x_cell = pivot.x + cell.x;
        const y_cell = pivot.y + cell.y;
        const x_int: u16 = @intFromFloat(@floor(x_cell));
        const y_int: i17 = @intFromFloat(@floor(y_cell));
        if (y_int < 0) return true;
        self.state.board[@as(u16, @intCast(y_int)) * play_area.width + x_int] = 1;
    }
    self.state.in_flight = .{ .position = .{ .x = 5, .y = 0 }, .tag = self.state.next_pieces[self.state.ptr] };
    self.state.ptr += 1;
    if (self.state.ptr >= self.state.next_pieces.len) {
        self.state.ptr = 0;
        self.rng.random().shuffle(Tetromino.Tag, &self.state.next_pieces);
    }
    self.state.piece_state = .falling;
    return false;
}

fn handleSoftLock(self: *Tetris) void {
    const gravity_time = base_gravity_time / self.state.gravity;

    const pivot = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };

    self.state.piece_state = for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
        const x_cell = pivot.x + cell.x;
        const y_cell = pivot.y + cell.y;
        const x_int: u16 = @intFromFloat(x_cell);
        const y_int: i17 = @intFromFloat(@floor(y_cell));
        if (y_int < -1) continue;
        const y_test: u16 = @intCast(y_int + 1);
        if (y_test >= play_area.height or self.state.board[y_test * play_area.width + x_int] != 0) {
            // Block is occupied stop the block
            if (self.state.piece_state == .falling) {
                self.state.lock_delay = lock_delay_ns;
                self.state.gravity_delay = @intFromFloat(gravity_time);
            }
            break .lock_delay;
        }
    } else blk: {
        if (self.state.piece_state == .lock_delay) {
            self.state.lock_delay = lock_delay_ns;
            self.state.gravity_delay = @intFromFloat(gravity_time);
        }
        break :blk .falling;
    };
}

fn renderInFlightPiece(self: *Tetris, game_area: Scissor) void {
    const pivot = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };

    for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
        const x_cell = (pivot.x + cell.x) * 2;
        const y_cell = pivot.y + cell.y;
        const x_int: u16 = @intFromFloat(@floor(x_cell));
        const y_int: i17 = @intFromFloat(@floor(y_cell));
        if (y_int < 0) continue;
        renderCell(game_area, x_int - 1, @intCast(y_int));
    }
}

fn handleTranslation(self: *Tetris, ctx: *const Context) void {
    var direction: i8 = 0;
    if (ctx.isKeyPressed(.left)) direction -= 1;
    if (ctx.isKeyPressed(.right)) direction += 1;

    const pivot: Position = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };

    if (direction != 0) {
        for (self.state.in_flight.tag.get().getFrame(self.state.in_flight.state)) |cell| {
            const x_cell = pivot.x + cell.x;
            const y_cell = pivot.y + cell.y;
            var x: i17 = @intFromFloat(x_cell);
            x += @intCast(direction);
            const y: i17 = @intFromFloat(@floor(y_cell));
            if (x < 0 or x >= play_area.width or y < 0 or y >= play_area.height) {
                break;
            }
            if (self.state.board[@as(u16, @intCast(y)) * play_area.width + @as(u16, @intCast(x))] != 0) {
                break;
            }
        } else {
            self.state.in_flight.position.x += @floatFromInt(direction);
        }
    }
}

fn handleRotation(self: *Tetris, ctx: *const Context) void {
    var rotation: i8 = 0;
    if (ctx.isKeyPressed(.a)) rotation -= 1;
    if (ctx.isKeyPressed(.d)) rotation += 1;

    const pivot = .{ .x = self.state.in_flight.position.x - 0.5, .y = self.state.in_flight.position.y - 0.5 };

    if (rotation != 0) {
        const rot_current = self.state.in_flight.state;
        const rot_next = if (rotation > 0) rot_current.rotClockwise() else rot_current.rotCounterClockwise();
        switch (self.state.in_flight.tag) {
            .O => {
                const offset_next = Tetromino.OOffset[@intFromEnum(rot_next)][0];
                const offset_current = Tetromino.OOffset[@intFromEnum(rot_current)][0];
                const translations: Position = .{ .x = offset_current.x - offset_next.x, .y = offset_current.y - offset_next.y };
                const next_frame = self.state.in_flight.tag.get().getFrame(rot_next);
                for (next_frame) |cell| {
                    const x_cell = pivot.x + cell.x + translations.x;
                    const y_cell = pivot.y + cell.y + translations.y;
                    const x: i17 = @intFromFloat(@floor(x_cell));
                    const y: i17 = @intFromFloat(@floor(y_cell));
                    if (x < 0 or x >= play_area.width or y < 0 or y >= play_area.height) {
                        break;
                    }
                    if (self.state.board[@as(u16, @intCast(y)) * play_area.width + @as(u16, @intCast(x))] != 0) {
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
                const translations: [5]Position = .{
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
                        if (x < 0 or x >= play_area.width or y < 0 or y >= play_area.height) {
                            break;
                        }
                        if (self.state.board[@as(u16, @intCast(y)) * play_area.width + @as(u16, @intCast(x))] != 0) {
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
                const translations: [5]Position = .{
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
                        if (x < 0 or x >= play_area.width or y < 0 or y >= play_area.height) {
                            break;
                        }
                        if (self.state.board[@as(u16, @intCast(y)) * play_area.width + @as(u16, @intCast(x))] != 0) {
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
}

fn clearRows(self: *Tetris) void {
    var row: usize = play_area.height - 1;
    while (row > 0) {
        var total: usize = 0;
        for (0..play_area.width) |col| {
            total += self.state.board[row * play_area.width + col];
        }
        if (total == play_area.width) {
            for (0..row) |r| {
                self.state.board[(row - r) * play_area.width ..][0..play_area.width].* = self.state.board[(row - r - 1) * play_area.width ..][0..play_area.width].*;
            }
        } else {
            row -= 1;
        }
    }
}

fn renderGameArea(self: *Tetris, game_area: Scissor) void {
    for (0..play_area.height) |y| {
        for (0..play_area.width) |x| {
            if (self.state.board[y * play_area.width + x] == 1) {
                const x_int: u16 = @intCast(x * 2);
                renderCell(game_area, x_int, @intCast(y));
            }
        }
    }
}

fn renderCell(game_area: Scissor, x: u16, y: u16) void {
    game_area.set(x, y, Cell{ .data = .{ .codepoint = '█' } });
    game_area.set(x + 1, y, Cell{ .data = .{ .codepoint = '█' } });
}

const Position = struct {
    x: f32,
    y: f32,
};

pub const Tetromino = struct {
    frames: [4][4]Position,

    pub fn getFrame(self: Tetromino, state: State) [4]Position {
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

    pub const JLSTZOffset = [4][5]Position{
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

    pub const IOffset = [4][5]Position{
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

    pub const OOffset = [4][1]Position{
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
        .frames = [_][4]Position{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
    pub const I = Tetromino{
        .frames = [_][4]Position{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 2.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 0.0, .y = 2.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -2.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = -2.0 } },
        },
    };
    pub const T = Tetromino{
        .frames = [_][4]Position{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 } },
        },
    };
    pub const S = Tetromino{
        .frames = [_][4]Position{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
    pub const Z = Tetromino{
        .frames = [_][4]Position{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = -1.0 }, .{ .x = 1.0, .y = 0.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
        },
    };
    pub const J = Tetromino{
        .frames = [_][4]Position{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = 1.0 } },
        },
    };
    pub const L = Tetromino{
        .frames = [_][4]Position{
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = 1.0, .y = -1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = 1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 1.0, .y = 0.0 }, .{ .x = -1.0, .y = 0.0 }, .{ .x = -1.0, .y = 1.0 } },
            .{ .{ .x = 0.0, .y = 0.0 }, .{ .x = 0.0, .y = -1.0 }, .{ .x = 0.0, .y = 1.0 }, .{ .x = -1.0, .y = -1.0 } },
        },
    };
};
