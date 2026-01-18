const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const tg = @import("tuig");
const r = tg.renderer;
const Scissor = r.Scissor;
const Context = r.Context;

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

pub const options: []const []const u8 = &.{
    "Lists",
    "Table",
    "Buttons",
    "Text Input",
    "Checkbox",
    "Spinner",
    "Slider",
    "Styled Text",
};

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
