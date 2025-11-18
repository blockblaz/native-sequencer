const std = @import("std");
const types = @import("../core/types.zig");
const keccak = @import("keccak.zig");

/// Keccak-256 hash function using Zig stdlib
pub fn keccak256(data: []const u8) types.Hash {
    return keccak.hash(data);
}

