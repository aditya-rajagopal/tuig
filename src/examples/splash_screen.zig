const std = @import("std");

const tuig = @import("tuig");
const e = @import("event.zig");
const Scissor = tuig.renderer.Scissor;

const SplashScreen = @This();

fn spashScreen(self: *SplashScreen, scissor: Scissor, events: []const e.Event) usize {
    for (events) |event| {
        switch (event) {
            .key_pressed, .key_repeat => |key| {
                switch (key.physical_key) {
                    .q => return .quit,
                    else => {
                        if (self.splash_animation_mode == .start) {
                            self.splash_animation_mode = .done;
                            self.splash_progress = 0;
                        } else {
                            self.mode = .tasklist;
                            return .scene_change;
                        }
                    },
                }
            },
            else => {},
        }
    }
    const width = scissor.width;
    const height = scissor.height;
    const start_x = width / 2 - codepoint_width / 2;

    const area = loop: switch (self.splash_animation_mode) {
        .start => blk: {
            const start_y = height / 2 - codepoint_height / 2;
            if (self.splash_progress < codepoint_width) {
                self.splash_progress += 1;
            } else {
                self.splash_animation_mode = .move_to_top;
                self.splash_progress = @intCast(start_y);
                continue :loop .move_to_top;
            }
            break :blk scissor.initChild(@intCast(start_x), @intCast(start_y), self.splash_progress, codepoint_height);
        },
        .move_to_top, .done => blk: {
            if (self.splash_progress > 0) {
                self.splash_progress -= 1;
            } else {
                self.splash_animation_mode = .done;
            }
            break :blk scissor.initChild(@intCast(start_x), @intCast(self.splash_progress), codepoint_width, codepoint_height);
        },
    };
    var start: usize = 0;
    // @FIXME this needs to have a sub-scissor
    for (0..codepoint_height) |row| {
        start += area.renderLineDelimiter(
            0,
            @intCast(row),
            splash_text[start..],
            '\n',
            true,
        );
    }
    return .success;
}
