const std = @import("std");
const types = @import("types.zig");
const transaction = @import("transaction.zig");

pub const Block = struct {
    number: u64,
    parent_hash: types.Hash,
    timestamp: u64,
    transactions: []transaction.Transaction,
    gas_used: u64,
    gas_limit: u64,
    state_root: types.Hash,
    receipts_root: types.Hash,
    logs_bloom: [256]u8,

    pub fn hash(self: *const Block) types.Hash {
        // Simplified - in production use proper block header hashing
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        const number_bytes = std.mem.asBytes(&self.number);
        hasher.update(number_bytes);
        const parent_hash_bytes = types.hashToBytes(self.parent_hash);
        hasher.update(&parent_hash_bytes);
        const timestamp_bytes = std.mem.asBytes(&self.timestamp);
        hasher.update(timestamp_bytes);
        var block_hash_bytes: [32]u8 = undefined;
        hasher.final(&block_hash_bytes);
        return types.hashFromBytes(block_hash_bytes);
    }
};
