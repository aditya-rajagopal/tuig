const tuig = @import("tuig");
const Scissor = tuig.renderer.Scissor;
const Cell = tuig.renderer.Cell;

pub const BoxCharacters = struct {
    top_left: u21,
    top_right: u21,
    top_horizontal: u21,
    bottom_left: u21,
    bottom_right: u21,
    bottom_horizontal: u21,
    left: u21,
    right: u21,

    pub const default = BoxCharacters{
        .top_left = '┌',
        .top_right = '┐',
        .top_horizontal = '─',
        .bottom_left = '└',
        .bottom_right = '┘',
        .bottom_horizontal = '─',
        .left = '│',
        .right = '│',
    };
};

pub fn drawBox(area: Scissor, x: i17, y: i17, width: u16, height: u16, title: []const u8, border: BoxCharacters) Scissor {
    const whole_area = area.initChild(@intCast(x), @intCast(y), width, height);

    // Draw first row of border
    for (1..width - 1) |column| {
        whole_area.set(@intCast(column), 0, Cell{ .data = .{ .codepoint = border.top_horizontal } });
        whole_area.set(@intCast(column), height - 1, Cell{ .data = .{ .codepoint = border.bottom_horizontal } });
    }
    for (0..height - 1) |row| {
        whole_area.set(0, @intCast(row), Cell{ .data = .{ .codepoint = border.left } });
        whole_area.set(width - 1, @intCast(row), Cell{ .data = .{ .codepoint = border.right } });
    }
    whole_area.set(0, 0, Cell{ .data = .{ .codepoint = border.top_left } });
    whole_area.set(width - 1, 0, Cell{ .data = .{ .codepoint = border.top_right } });
    whole_area.set(0, height - 1, Cell{ .data = .{ .codepoint = border.bottom_left } });
    whole_area.set(width - 1, height - 1, Cell{ .data = .{ .codepoint = border.bottom_right } });

    if (title.len > 0) {
        const text_area = whole_area.initChild(2, 0, width - 4, height);
        _ = text_area.printAssumeNoGrapheme(title, 0, 0, .default);
    }
    return whole_area.inner();
}
