pub const Cell = packed struct(u32) {
    data: Data = .{ .codepoint = ' ' },
    tag: Tag = .codepoint,
    width: Width = .narrow,
    _padding1: u8 = 0,

    pub const Width = enum(u2) {
        narrow = 0,
        wide_start = 1,
        wide_end = 2,
    };

    pub const Tag = enum(u1) {
        codepoint = 0,
        grapheme = 1,
    };

    pub const Data = packed union {
        codepoint: u21,
        grapheme_id: u21,
    };

    pub const empty = Cell{ .data = .{ .codepoint = ' ' }, .tag = .codepoint, .width = .narrow };

    pub fn eql(self: Cell, other: Cell) bool {
        return @as(u21, @bitCast(self.data)) == @as(u21, @bitCast(other.data)) and
            self.tag == other.tag and
            self.width == other.width;
    }
};
