const t = @import("types.zig");
const GraphemeIndex = t.GraphemeBuffer.GraphemeIndex;

pub const Cell = packed struct(u64) {
    data: Data = .{ .codepoint = ' ' },
    grapheme_id_extension: u4 = 0,
    tag: Tag = .codepoint,
    width: Width = .narrow,
    _padding1: u4 = 0,
    _padding2: u32 = 0,

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
    pub const zero = Cell{ .data = .{ .codepoint = 0 }, .tag = .codepoint, .width = .narrow };

    pub const wide_end = Cell{ .data = .{ .codepoint = ' ' }, .tag = .codepoint, .width = .wide_end };

    pub inline fn initGrapheme(id: GraphemeIndex, width: Width) Cell {
        var cell: Cell = .zero;
        cell = @bitCast(@as(u64, @bitCast(cell)) | @as(u64, id));
        cell.width = width;
        cell.tag = .grapheme;
        return cell;
    }

    pub fn eql(self: Cell, other: Cell) bool {
        // NOTE(adi): Ordered in the order of fields most likely to be different
        return @as(u21, @bitCast(self.data)) == @as(u21, @bitCast(other.data)) and
            self.width == other.width and
            self.tag == other.tag and
            self.grapheme_id_extension == other.grapheme_id_extension;
    }
};
