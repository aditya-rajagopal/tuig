pub const Cell = packed struct(u64) {
    codepoint: u21 = ' ',
    _padding1: u11 = 0,
    tag: Tag = .codepoint,
    width: Width = .narrow,
    _padding2: u29 = 0,

    pub const Width = enum(u2) {
        narrow = 0,
        wide_start = 1,
        wide_end = 2,
    };

    pub const Tag = enum(u1) {
        codepoint = 0,
        grapheme = 1,
    };

    pub const empty = Cell{ .codepoint = ' ', .tag = .codepoint, .width = .narrow };

    pub fn eql(self: Cell, other: Cell) bool {
        return self.codepoint == other.codepoint and
            self.tag == other.tag and
            self.width == other.width;
    }
};
