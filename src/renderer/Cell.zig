pub const Cell = @This();

codepoint: u21,

pub const empty = Cell{ .codepoint = ' ' };

pub fn eql(self: Cell, other: Cell) bool {
    return self.codepoint == other.codepoint;
}
