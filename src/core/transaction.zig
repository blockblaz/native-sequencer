const std = @import("std");
const types = @import("types.zig");
const crypto_hash = @import("../crypto/hash.zig");
const signature = @import("signature.zig");

pub const Transaction = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?types.Address,
    value: u256,
    data: []const u8,
    v: u8,
    r: [32]u8,
    s: [32]u8,

    pub fn hash(self: *const Transaction, allocator: std.mem.Allocator) !types.Hash {
        const serialized = try self.serialize(allocator);
        defer allocator.free(serialized);
        return crypto_hash.keccak256(serialized);
    }

    pub fn serialize(self: *const Transaction, allocator: std.mem.Allocator) ![]u8 {
        // Use RLP encoding
        const rlp_module = @import("rlp.zig");
        return try rlp_module.encodeTransaction(allocator, self);
    }

    fn encodeUint(list: *std.array_list.Managed(u8), value: anytype) !void {
        var buf: [32]u8 = undefined;
        std.mem.writeInt(u256, &buf, value, .big);
        var start: usize = 0;
        while (start < buf.len and buf[start] == 0) start += 1;
        if (start == buf.len) {
            try list.append(0);
        } else {
            try list.appendSlice(buf[start..]);
        }
    }

    pub fn fromRaw(allocator: std.mem.Allocator, raw: []const u8) !Transaction {
        const rlp_module = @import("rlp.zig");
        return try rlp_module.decodeTransaction(allocator, raw);
    }

    pub fn sender(self: *const Transaction) !types.Address {
        const sig = @import("../crypto/signature.zig");
        return sig.recoverAddress(self);
    }

    pub fn priority(self: *const Transaction) u256 {
        return self.gas_price;
    }
};

