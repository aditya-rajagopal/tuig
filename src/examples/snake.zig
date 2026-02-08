const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const tuig = @import("tuig");
const Context = tuig.renderer.Context;
const Scissor = tuig.renderer.Scissor;
const Cell = tuig.renderer.Cell;
const layout = tuig.layout;
const Constraint = layout.Constraint;

const Snake = @This();
const app = @import("app.zig");

state: State = .waiting,
components: std.ArrayList(tuig.renderer.Position) = .empty,
eaten_food: std.ArrayList(tuig.renderer.Position) = .empty,
scene_arena: app.MemoryPool.ArenaAllocator,
timer: ?std.time.Timer = null,
frame_tick: u8 = 0,
frame_ticked: bool = false,
frame_rate: u64 = 0,
random: std.Random.DefaultPrng,
food_position: tuig.renderer.Position,
direction: Direction,
next_direction: Direction,
game_started: bool = false,
score: u32 = 0,

const State = enum { waiting, playing, game_over };
const Direction = enum { up, down, left, right };

const gameplay_area_x: u16 = 41;
const gameplay_area_y: u16 = 21;

const waiting_prompt = "Press `ENTER` to start";
const restart_prompt = "Press `ENTER` to restart";

pub fn init(self: *Snake) void {
    self.state = .waiting;
    self.timer = null;
    self.frame_rate = 200 * 1000 * 1000;
    self.random = std.Random.DefaultPrng.init(0);
    self.direction = .right;
    self.score = 0;
}

pub fn deinit(self: *Snake) void {
    self.scene_arena.deinit();
    self.components = .empty;
    self.eaten_food = .empty;
    self.state = .waiting;
    self.frame_rate = 300 * 1000 * 1000;
    self.timer = null;
}

pub fn reset(self: *Snake, memory_pool: *app.MemoryPool, ctx: *const Context) error{Failed}!void {
    _ = ctx;
    self.scene_arena = app.MemoryPool.ArenaAllocator.init(memory_pool);
    self.components = std.ArrayList(tuig.renderer.Position).initCapacity(self.scene_arena.allocator(), 512) catch return {
        return error.Failed;
    };
    self.eaten_food = std.ArrayList(tuig.renderer.Position).initCapacity(self.scene_arena.allocator(), 256) catch return {
        return error.Failed;
    };
    self.transitonTo(.waiting);
}

fn transitonTo(self: *Snake, to: State) void {
    self.state = to;
    switch (to) {
        .game_over => {
            self.frame_rate = 200 * 1000 * 1000;
            self.game_started = false;
        },
        .waiting => {
            self.scene_arena.reset();
            self.components.clearRetainingCapacity();
            self.eaten_food.clearRetainingCapacity();
            self.frame_rate = 200 * 1000 * 1000;
            self.direction = .right;
            self.next_direction = .right;
            self.score = 0;
        },
        .playing => {
            self.frame_rate = 100 * 1000 * 1000;
            self.game_started = false;
            self.score = 0;
        },
    }
}

const SnakeResult = enum { quit, noop, back };

pub fn updateAndRender(self: *Snake, ctx: *const Context) SnakeResult {
    if (self.timer == null) {
        self.timer = std.time.Timer.start() catch return .back;
    }
    const timer = &self.timer.?;
    const delta = timer.read();
    if (delta > self.frame_rate) {
        timer.reset();
        self.frame_tick +%= 1;
        self.frame_ticked = true;
    }
    if (ctx.isKeyPressed(.Q)) return .quit;
    if (ctx.isKeyPressed(.escape)) return .back;
    switch (self.state) {
        .waiting => self.renderWaiting(ctx),
        .playing => self.renderPlaying(ctx),
        .game_over => self.renderGameOver(ctx),
    }
    return .noop;
}

fn renderWaiting(self: *Snake, ctx: *const Context) void {
    const min_width: u16 = @intCast(@max(title_width, waiting_prompt.len));
    const min_height: u16 = title_height + 1;
    if (ctx.scissor.width_global < min_width or ctx.scissor.height_global < min_height) {
        renderResizeHint(ctx.scissor, min_width, min_height);
        return;
    }

    const root_rect = ctx.scissor.toRect();
    const constraints = [_]Constraint{
        Constraint.fixed(title_height).withCross(title_width, .center),
        Constraint.flex(1),
        Constraint.fixed(1).withCross(@intCast(waiting_prompt.len), .center),
    };
    var panes: [3]layout.Rect = undefined;
    _ = root_rect.split(&constraints, .{}, &panes) catch unreachable;

    const frame = frames[self.frame_tick % frames.len];
    const title_region = ctx.scissor.initChildRect(panes[0]);
    _ = title_region.printAssumeNoGrapheme(frame, 0, 0, .{ .wrap = true, .tab_width = 4 });

    const prompt_region = ctx.scissor.initChildRect(panes[2]);
    _ = prompt_region.printAssumeNoGrapheme(waiting_prompt, 0, 0, .{ .wrap = false, .tab_width = 4 });

    if (ctx.isKeyPressed(.enter)) self.transitonTo(.playing);
}

fn renderGameOver(self: *Snake, ctx: *const Context) void {
    self.components.clearRetainingCapacity();
    const frame = game_over_frames[self.frame_tick % game_over_frames.len];

    var buf: [128]u8 = undefined;
    const score = std.fmt.bufPrint(&buf, "Score: {d}", .{self.score}) catch unreachable;
    const min_width: u16 = @intCast(@max(game_over_title_width, @max(score.len, restart_prompt.len)));
    const min_height: u16 = game_over_title_height + 5;
    if (ctx.scissor.width_global < min_width or ctx.scissor.height_global < min_height) {
        renderResizeHint(ctx.scissor, min_width, min_height);
        return;
    }

    const root_rect = ctx.scissor.toRect();
    const root_constraints = [_]Constraint{ Constraint.flex(1), Constraint.fixed(1) };
    var root_panes: [2]layout.Rect = undefined;
    _ = root_rect.split(&root_constraints, .{}, &root_panes) catch unreachable;

    const content_constraints = [_]Constraint{
        Constraint.fixed(game_over_title_height).withCross(game_over_title_width, .center),
        Constraint.fixed(1).withCross(@intCast(score.len), .center),
    };
    var content_panes: [2]layout.Rect = undefined;
    _ = root_panes[0].split(&content_constraints, .{ .gap = 3, .alignment = .center }, &content_panes) catch unreachable;

    const title_area = ctx.scissor.initChildRect(content_panes[0]);
    _ = title_area.printAssumeNoGrapheme(frame, 0, 0, .{ .wrap = true, .tab_width = 4 });

    const score_area = ctx.scissor.initChildRect(content_panes[1]);
    _ = score_area.printAssumeNoGrapheme(score, 0, 0, .{ .wrap = false, .tab_width = 4 });

    const bottom_row = ctx.scissor.initChildRect(root_panes[1]);
    const restart_area = bottom_row.centeredChild(@intCast(restart_prompt.len), 1);
    _ = restart_area.printAssumeNoGrapheme(restart_prompt, 0, 0, .{ .wrap = false, .tab_width = 4 });

    if (ctx.isKeyPressed(.enter)) self.transitonTo(.waiting);
}

fn renderPlaying(self: *Snake, ctx: *const Context) void {
    if (ctx.scissor.width_global < gameplay_area_x or ctx.scissor.height_global < gameplay_area_y) {
        renderResizeHint(ctx.scissor, gameplay_area_x, gameplay_area_y);
        return;
    }
    assert(ctx.scissor.width_global >= gameplay_area_x);
    assert(ctx.scissor.height_global >= gameplay_area_y);

    const centered_game_rect = ctx.scissor.centeredChild(gameplay_area_x, gameplay_area_y);
    var buf: [128]u8 = undefined;
    const score = std.fmt.bufPrint(&buf, "Score: {d}", .{self.score}) catch unreachable;

    const box_config = tuig.ui.DrawBoxConfig{
        .title = score,
    };
    const game_area = tuig.ui.drawBox(
        ctx.scissor,
        centered_game_rect.x_global,
        centered_game_rect.y_global,
        centered_game_rect.width_global,
        centered_game_rect.height_global,
        &box_config,
    );

    if (!self.game_started) {
        self.initSnake(game_area);
        // NOTE(adi): This is after so we can check for snake body collision when spawning
        self.newFood(game_area);
        self.game_started = true;
    }

    for (ctx.key_pressed) |key| {
        switch (key.physical_key) {
            .up, .W => {
                if (self.direction != .down) self.next_direction = .up;
            },
            .down, .S => {
                if (self.direction != .up) self.next_direction = .down;
            },
            .left, .A => {
                if (self.direction != .right) self.next_direction = .left;
            },
            .right, .D => {
                if (self.direction != .left) self.next_direction = .right;
            },
            else => {},
        }
    }

    game_area.set(self.food_position.x, self.food_position.y, Cell{ .data = .{ .codepoint = 'O' } }) catch {};
    self.renderSnake(game_area);
    if (self.frame_ticked) {
        self.moveSnake(game_area);
        self.direction = self.next_direction;
        self.frame_ticked = false;
    }
}

fn newFood(self: *Snake, scissor: Scissor) void {
    if (scissor.width_global == 0 or scissor.height_global == 0) {
        self.food_position = .{ .x = 0, .y = 0 };
        return;
    }

    self.food_position.x = self.random.random().intRangeAtMost(u16, 0, scissor.width_global - 1);
    self.food_position.y = self.random.random().intRangeAtMost(u16, 0, scissor.height_global - 1);
    while (true) {
        const cell = scissor.get(self.food_position.x, self.food_position.y) orelse {
            self.food_position.x = self.random.random().intRangeAtMost(u16, 0, scissor.width_global - 1);
            self.food_position.y = self.random.random().intRangeAtMost(u16, 0, scissor.height_global - 1);
            continue;
        };
        if (cell.data.codepoint == ' ') break;
        self.food_position.x = self.random.random().intRangeAtMost(u16, 0, scissor.width_global - 1);
        self.food_position.y = self.random.random().intRangeAtMost(u16, 0, scissor.height_global - 1);
    }
}

fn initSnake(self: *Snake, scissor: Scissor) void {
    const num_components = 4;
    const y = scissor.height_global / 2;
    const x = (scissor.width_global - num_components) / 2;
    for (0..num_components) |i| {
        self.components.appendAssumeCapacity(.{
            .x = @intCast(x + i),
            .y = @intCast(y),
        });
    }
}

fn renderSnake(self: *Snake, game_area: Scissor) void {
    for (self.components.items) |component| {
        game_area.set(component.x, component.y, Cell{ .data = .{ .codepoint = '+' } }) catch {};
    }
}

fn moveSnake(self: *Snake, game_area: Scissor) void {
    var head = self.components.getLast();
    switch (self.next_direction) {
        .up => {
            if (head.y == 0) head.y = game_area.height_global - 1 else head.y -= 1;
        },
        .down => {
            if (head.y == game_area.height_global - 1) head.y = 0 else head.y += 1;
        },
        .left => {
            if (head.x == 0) head.x = game_area.width_global - 1 else head.x -= 1;
        },
        .right => {
            if (head.x == game_area.width_global - 1) head.x = 0 else head.x += 1;
        },
    }
    const space = game_area.get(head.x, head.y) orelse {
        self.transitonTo(.game_over);
        return;
    };
    if (space.data.codepoint == '+') {
        self.transitonTo(.game_over);
    } else if (space.data.codepoint == 'O') {
        self.eaten_food.appendAssumeCapacity(head);
        self.score += 1;
        self.newFood(game_area);
    }
    self.components.appendAssumeCapacity(head);
    game_area.set(head.x, head.y, Cell{ .data = .{ .codepoint = '+' } }) catch {};

    const tail = self.components.items[0];
    if (self.eaten_food.items.len > 0) {
        const eaten_food = self.eaten_food.items[0];
        if (eaten_food.x == tail.x and eaten_food.y == tail.y) {
            _ = self.eaten_food.orderedRemove(0);
        } else {
            _ = self.components.orderedRemove(0);
            game_area.set(tail.x, tail.y, .empty) catch {};
        }
    } else {
        _ = self.components.orderedRemove(0);
        game_area.set(tail.x, tail.y, .empty) catch {};
    }
}

fn renderResizeHint(scissor: Scissor, min_width: u16, min_height: u16) void {
    var buf: [128]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "Resize to atleast {d}x{d}[Now: {d}x{d}]", .{
        min_width,
        min_height,
        scissor.width_global,
        scissor.height_global,
    }) catch unreachable;

    const area = scissor.centeredChild(@intCast(str.len), 1);
    _ = area.printAssumeNoGrapheme(str, 0, 0, .{ .wrap = false, .tab_width = 4 });
}

pub const frames: []const []const u8 = &.{
    \\  /$$$$$$  /$$   /$$  /$$$$$$  /$$   /$$ /$$$$$$$$
    \\ /$$__  $$| $$$ | $$ /$$__  $$| $$  /$$/| $$_____/
    \\| $$  \__/| $$$$| $$| $$  \ $$| $$ /$$/ | $$      
    \\|  $$$$$$ | $$ $$ $$| $$$$$$$$| $$$$$/  | $$$$$   
    \\ \____  $$| $$  $$$$| $$__  $$| $$  $$  | $$__/   
    \\ /$$  \ $$| $$\  $$$| $$  | $$| $$\  $$ | $$      
    \\|  $$$$$$/| $$ \  $$| $$  | $$| $$ \  $$| $$$$$$$$
    \\ \______/ |__/  \__/|__/  |__/|__/  \__/|________/
    \\                                                  
    \\
    ,
    \\ $$$$$$\  $$\   $$\  $$$$$$\  $$\   $$\ $$$$$$$$\ 
    \\$$  __$$\ $$$\  $$ |$$  __$$\ $$ | $$  |$$  _____|
    \\$$ /  \__|$$$$\ $$ |$$ /  $$ |$$ |$$  / $$ |      
    \\\$$$$$$\  $$ $$\$$ |$$$$$$$$ |$$$$$  /  $$$$$\    
    \\ \____$$\ $$ \$$$$ |$$  __$$ |$$  $$<   $$  __|   
    \\$$\   $$ |$$ |\$$$ |$$ |  $$ |$$ |\$$\  $$ |      
    \\\$$$$$$  |$$ | \$$ |$$ |  $$ |$$ | \$$\ $$$$$$$$\ 
    \\ \______/ \__|  \__|\__|  \__|\__|  \__|\________|
    \\                                                  
    \\
    ,
    \\  ______   __    __   ______   __    __  ________ 
    \\ /      \ /  \  /  | /      \ /  |  /  |/        |
    \\/$$$$$$  |$$  \ $$ |/$$$$$$  |$$ | /$$/ $$$$$$$$/ 
    \\$$ \__$$/ $$$  \$$ |$$ |__$$ |$$ |/$$/  $$ |__    
    \\$$      \ $$$$  $$ |$$    $$ |$$  $$<   $$    |   
    \\ $$$$$$  |$$ $$ $$ |$$$$$$$$ |$$$$$  \  $$$$$/    
    \\/  \__$$ |$$ |$$$$ |$$ |  $$ |$$ |$$  \ $$ |_____ 
    \\$$    $$/ $$ | $$$ |$$ |  $$ |$$ | $$  |$$       |
    \\ $$$$$$/  $$/   $$/ $$/   $$/ $$/   $$/ $$$$$$$$/ 
    \\
    ,
    \\  ______   __    __   ______   __    __  ________ 
    \\ /      \ |  \  |  \ /      \ |  \  /  \|        \
    \\|  $$$$$$\| $$\ | $$|  $$$$$$\| $$ /  $$| $$$$$$$$
    \\| $$___\$$| $$$\| $$| $$__| $$| $$/  $$ | $$__    
    \\ \$$    \ | $$$$\ $$| $$    $$| $$  $$  | $$  \   
    \\ _\$$$$$$\| $$\$$ $$| $$$$$$$$| $$$$$\  | $$$$$   
    \\|  \__| $$| $$ \$$$$| $$  | $$| $$ \$$\ | $$_____ 
    \\ \$$    $$| $$  \$$$| $$  | $$| $$  \$$\| $$     \
    \\  \$$$$$$  \$$   \$$ \$$   \$$ \$$   \$$ \$$$$$$$$
    \\
};

const title_width = (std.mem.findScalar(u8, frames[0], '\n') orelse @compileError("Frame has no width")) + 1;
const title_height = frames[0].len / title_width;

comptime {
    assert(frames[0].len == title_width * title_height);
    assert(frames[1].len == title_width * title_height);
    assert(frames[2].len == title_width * title_height);
    assert(frames[3].len == title_width * title_height);
}

const game_over_frames = [_][]const u8{
    \\  /$$$$$$   /$$$$$$  /$$      /$$ /$$$$$$$$        /$$$$$$  /$$    /$$ /$$$$$$$$ /$$$$$$$ 
    \\ /$$__  $$ /$$__  $$| $$$    /$$$| $$_____/       /$$__  $$| $$   | $$| $$_____/| $$__  $$
    \\| $$  \__/| $$  \ $$| $$$$  /$$$$| $$            | $$  \ $$| $$   | $$| $$      | $$  \ $$
    \\| $$ /$$$$| $$$$$$$$| $$ $$/$$ $$| $$$$$         | $$  | $$|  $$ / $$/| $$$$$   | $$$$$$$/
    \\| $$|_  $$| $$__  $$| $$  $$$| $$| $$__/         | $$  | $$ \  $$ $$/ | $$__/   | $$__  $$
    \\| $$  \ $$| $$  | $$| $$\  $ | $$| $$            | $$  | $$  \  $$$/  | $$      | $$  \ $$
    \\|  $$$$$$/| $$  | $$| $$ \/  | $$| $$$$$$$$      |  $$$$$$/   \  $/   | $$$$$$$$| $$  | $$
    \\ \______/ |__/  |__/|__/     |__/|________/       \______/     \_/    |________/|__/  |__/
    \\                                                                                          
    \\
    ,
    \\  ______    ______   __       __  ________         ______   __     __  ________  _______  
    \\ /      \  /      \ |  \     /  \|        \       /      \ |  \   |  \|        \|       \ 
    \\|  $$$$$$\|  $$$$$$\| $$\   /  $$| $$$$$$$$      |  $$$$$$\| $$   | $$| $$$$$$$$| $$$$$$$\
    \\| $$ __\$$| $$__| $$| $$$\ /  $$$| $$__          | $$  | $$| $$   | $$| $$__    | $$__| $$
    \\| $$|    \| $$    $$| $$$$\  $$$$| $$  \         | $$  | $$ \$$\ /  $$| $$  \   | $$    $$
    \\| $$ \$$$$| $$$$$$$$| $$\$$ $$ $$| $$$$$         | $$  | $$  \$$\  $$ | $$$$$   | $$$$$$$\
    \\| $$__| $$| $$  | $$| $$ \$$$| $$| $$_____       | $$__/ $$   \$$ $$  | $$_____ | $$  | $$
    \\ \$$    $$| $$  | $$| $$  \$ | $$| $$     \       \$$    $$    \$$$   | $$     \| $$  | $$
    \\  \$$$$$$  \$$   \$$ \$$      \$$ \$$$$$$$$        \$$$$$$      \$     \$$$$$$$$ \$$   \$$
    \\                                                                                          
    ,
    \\  ______    ______   __       __  ________         ______   __     __  ________  _______  
    \\ /      \  /      \ /  \     /  |/        |       /      \ /  |   /  |/        |/       \ 
    \\/$$$$$$  |/$$$$$$  |$$  \   /$$ |$$$$$$$$/       /$$$$$$  |$$ |   $$ |$$$$$$$$/ $$$$$$$  |
    \\$$ | _$$/ $$ |__$$ |$$$  \ /$$$ |$$ |__          $$ |  $$ |$$ |   $$ |$$ |__    $$ |__$$ |
    \\$$ |/    |$$    $$ |$$$$  /$$$$ |$$    |         $$ |  $$ |$$  \ /$$/ $$    |   $$    $$< 
    \\$$ |$$$$ |$$$$$$$$ |$$ $$ $$/$$ |$$$$$/          $$ |  $$ | $$  /$$/  $$$$$/    $$$$$$$  |
    \\$$ \__$$ |$$ |  $$ |$$ |$$$/ $$ |$$ |_____       $$ \__$$ |  $$ $$/   $$ |_____ $$ |  $$ |
    \\$$    $$/ $$ |  $$ |$$ | $/  $$ |$$       |      $$    $$/    $$$/    $$       |$$ |  $$ |
    \\ $$$$$$/  $$/   $$/ $$/      $$/ $$$$$$$$/        $$$$$$/      $/     $$$$$$$$/ $$/   $$/ 
    \\
    ,
    \\ $$$$$$\   $$$$$$\  $$\      $$\ $$$$$$$$\        $$$$$$\  $$\    $$\ $$$$$$$$\ $$$$$$$\  
    \\$$  __$$\ $$  __$$\ $$$\    $$$ |$$  _____|      $$  __$$\ $$ |   $$ |$$  _____|$$  __$$\ 
    \\$$ /  \__|$$ /  $$ |$$$$\  $$$$ |$$ |            $$ /  $$ |$$ |   $$ |$$ |      $$ |  $$ |
    \\$$ |$$$$\ $$$$$$$$ |$$\$$\$$ $$ |$$$$$\          $$ |  $$ |\$$\  $$  |$$$$$\    $$$$$$$  |
    \\$$ |\_$$ |$$  __$$ |$$ \$$$  $$ |$$  __|         $$ |  $$ | \$$\$$  / $$  __|   $$  __$$< 
    \\$$ |  $$ |$$ |  $$ |$$ |\$  /$$ |$$ |            $$ |  $$ |  \$$$  /  $$ |      $$ |  $$ |
    \\\$$$$$$  |$$ |  $$ |$$ | \_/ $$ |$$$$$$$$\        $$$$$$  |   \$  /   $$$$$$$$\ $$ |  $$ |
    \\ \______/ \__|  \__|\__|     \__|\________|       \______/     \_/    \________|\__|  \__|
    \\                                                                                          
    \\
};

const game_over_title_width = (std.mem.findScalar(u8, game_over_frames[0], '\n') orelse @compileError("Frame has no width")) + 1;
const game_over_title_height = game_over_frames[0].len / game_over_title_width;
