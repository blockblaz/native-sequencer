const types = @import("types.zig");

pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};

