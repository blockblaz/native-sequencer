const std = @import("std");
const types = @import("../core/types.zig");

/// Keccak-256 hash function (NOT SHA3-256)
/// Ethereum uses Keccak-256, which is the original Keccak submission
/// before it was standardized as SHA3-256 with different padding
pub const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Hash a byte slice using Keccak-256
pub fn hash(data: []const u8) types.Hash {
    var h: [32]u8 = undefined;
    Keccak256.hash(data, &h, .{});
    return types.hashFromBytes(h);
}

/// Hash multiple byte slices using Keccak-256
pub fn hashMulti(parts: []const []const u8) types.Hash {
    var hasher = Keccak256.init(.{});
    for (parts) |part| {
        hasher.update(part);
    }
    var h: [32]u8 = undefined;
    hasher.final(&h);
    return types.hashFromBytes(h);
}

/// Create a Keccak-256 hasher for incremental hashing
pub const Hasher = struct {
    inner: Keccak256,

    pub fn init() Hasher {
        return .{
            .inner = Keccak256.init(.{}),
        };
    }

    pub fn update(self: *Hasher, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn final(self: *Hasher) types.Hash {
        var h: [32]u8 = undefined;
        self.inner.final(&h);
        return types.hashFromBytes(h);
    }

    pub fn reset(self: *Hasher) void {
        self.inner = Keccak256.init(.{});
    }
};

/// Hash two hashes together (useful for Merkle trees)
pub fn hashPair(a: types.Hash, b: types.Hash) types.Hash {
    var data: [64]u8 = undefined;
    const a_bytes = types.hashToBytes(a);
    const b_bytes = types.hashToBytes(b);
    @memcpy(data[0..32], &a_bytes);
    @memcpy(data[32..64], &b_bytes);
    return hash(&data);
}

/// Calculate Ethereum function selector (first 4 bytes of function signature hash)
pub fn functionSelector(signature: []const u8) [4]u8 {
    const h = hash(signature);
    var selector: [4]u8 = undefined;
    const h_bytes = types.hashToBytes(h);
    @memcpy(&selector, h_bytes[0..4]);
    return selector;
}

/// Calculate Ethereum event signature (full hash of event signature)
pub fn eventSignature(signature: []const u8) types.Hash {
    return hash(signature);
}
