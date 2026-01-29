const renderer = @import("renderer");
const Scissor = renderer.Scissor;
const Cell = renderer.Cell;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

/// Alignment of the title in the box.
/// There is always a padding of 2 characters on each side of the title (corner + space).
pub const TitleAlignment = enum {
    /// Align the title to the left.
    /// ┌─Title──────────┐
    left,
    /// Align the title to the center.
    /// ┌──────Title─────┐
    center,
    /// Align the title to the right.
    /// ┌──────────Title─┐
    right,
};

/// Characters used to draw the border of the box.
pub const BoxCharacters = struct {
    top: u21,
    bottom: u21,
    left: u21,
    right: u21,
    top_left: u21,
    top_right: u21,
    bottom_left: u21,
    bottom_right: u21,

    /// ┌──┐
    /// │██│  ██ <- inner area
    /// └──┘
    pub const single = BoxCharacters{
        .top = '─',
        .bottom = '─',
        .left = '│',
        .right = '│',
        .top_left = '┌',
        .top_right = '┐',
        .bottom_left = '└',
        .bottom_right = '┘',
    };

    /// ╔══╗
    /// ║██║  ██ <- inner area
    /// ╚══╝
    pub const double = BoxCharacters{
        .top = '═',
        .bottom = '═',
        .left = '║',
        .right = '║',
        .top_left = '╔',
        .top_right = '╗',
        .bottom_left = '╚',
        .bottom_right = '╝',
    };

    /// ╭──╮
    /// │██│  ██ <- inner area
    /// ╰──╯
    pub const rounded = BoxCharacters{
        .top = '─',
        .bottom = '─',
        .left = '│',
        .right = '│',
        .top_left = '╭',
        .top_right = '╮',
        .bottom_left = '╰',
        .bottom_right = '╯',
    };

    /// ┏━━┓
    /// ┃██┃  ██ <- inner area
    /// ┗━━┛
    pub const thick = BoxCharacters{
        .top = '━',
        .bottom = '━',
        .left = '┃',
        .right = '┃',
        .top_left = '┏',
        .top_right = '┓',
        .bottom_left = '┗',
        .bottom_right = '┛',
    };
};

pub const DrawBoxConfig = struct {
    title: []const u8 = "",
    title_alignment: TitleAlignment = .left,
    border: BoxCharacters = .single,

    pub const default = DrawBoxConfig{
        .title = "",
        .title_alignment = .left,
        .border = .single,
    };
};

/// Draws a box at the given bounds within a given scissor. No box is drawn if the width or height is less than 2.
///
/// The inner area of the box is returned as a scissor.
pub fn drawBox(
    /// Scissor to draw the box within.
    area: Scissor,
    /// X position of the top left corner of the box.
    x: i17,
    /// Y position of the top left corner of the box.
    y: i17,
    /// Width of the box.
    width: u16,
    /// Height of the box.
    height: u16,
    /// Configuration of the box.
    config: *const DrawBoxConfig,
) Scissor {
    if (width < 2 or height < 2) return area.initChild(x, y, width, height);

    const box = area.initChild(x, y, width, height);

    for (1..width - 1) |column| {
        box.set(@intCast(column), 0, Cell{ .data = .{ .codepoint = config.border.top } });
        box.set(@intCast(column), height - 1, Cell{ .data = .{ .codepoint = config.border.bottom } });
    }

    for (0..height - 1) |row| {
        box.set(0, @intCast(row), Cell{ .data = .{ .codepoint = config.border.left } });
        box.set(width - 1, @intCast(row), Cell{ .data = .{ .codepoint = config.border.right } });
    }

    box.set(0, 0, Cell{ .data = .{ .codepoint = config.border.top_left } });
    box.set(width - 1, 0, Cell{ .data = .{ .codepoint = config.border.top_right } });
    box.set(0, height - 1, Cell{ .data = .{ .codepoint = config.border.bottom_left } });
    box.set(width - 1, height - 1, Cell{ .data = .{ .codepoint = config.border.bottom_right } });

    if (config.title.len > 0 and width > 4) {
        // @TODO this is wrong if there are graphemes in the title
        const title_x = calculateTitleX(config.title.len, width, config.title_alignment);
        const title_area = box.initChild(title_x, 0, width - title_x - 2, 1);
        _ = title_area.printAssumeNoGrapheme(config.title, 0, 0, .default);
    }

    return box.inner();
}

fn calculateTitleX(length_title: usize, width_box: u16, alignment: TitleAlignment) u16 {
    assert(width_box > 4);
    const available: i32 = @as(i32, width_box) - 4; // 2 chars padding each side (corner + space)
    const title_len_i32: i32 = @intCast(length_title);
    return switch (alignment) {
        .left => 2,
        .center => @intCast(2 + @max(0, @divFloor(available - title_len_i32, 2))),
        .right => @intCast(@max(2, @as(i32, width_box) - 2 - title_len_i32)),
    };
}
