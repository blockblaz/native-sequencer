const std = @import("std");
const types = @import("../core/types.zig");
const crypto_root = @import("root.zig");
const zigeth = crypto_root.zigeth;

/// Keccak-256 hash function using zigeth's implementation
pub fn keccak256(data: []const u8) types.Hash {
    const hash_result = zigeth.crypto.keccak.hash(data);
    return hash_result.bytes;
}

