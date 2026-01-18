pub const Cell = @This();

codepoint: u21,

pub fn eql(self: Cell, other: Cell) bool {
    return self.codepoint == other.codepoint;
}
