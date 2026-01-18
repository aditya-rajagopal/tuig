pub const Position = struct {
    x: u16,
    y: u16,
};

pub const MouseState = packed struct {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
};
