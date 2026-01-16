const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const tg = @import("tuig");
const Renderer = tg.Renderer;
const Scissor = Renderer.Scissor;
const Context = Renderer.Context;

const SplashScreen = @import("splash_screen.zig");
const List = @import("list.zig");

const Application = @This();

mode: Mode = .spashscreen,
splash_screen: SplashScreen = undefined,
list: List = undefined,

const Mode = enum { spashscreen, list };

pub fn init(window_height: u16) Application {
    var application = Application{};
    application.list.reset(window_height);
    application.splash_screen.reset();
    return application;
}

pub const options: []const []const u8 = &.{ "Lists", "Table", "Buttons" };

pub fn updateAndRender(self: *Application, ctx: Context) bool {
    loop: switch (self.mode) {
        .spashscreen => {
            switch (self.splash_screen.updateAndRender(ctx, options)) {
                .quit => return true,
                .selection => {
                    self.mode = .list;
                    continue :loop self.mode;
                },
                .noop => return false,
            }
        },
        .list => {
            switch (self.list.updateAndRender(ctx)) {
                .quit => return true,
                .noop => return false,
                .back => {
                    self.mode = .spashscreen;
                    self.splash_screen.splash_animation_mode = .start;
                    self.splash_screen.splash_progress = 0;
                    continue :loop self.mode;
                },
            }
        },
    }
}
