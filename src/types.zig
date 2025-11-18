const std = @import("std");
const crypto = @import("crypto.zig");

pub const Address = [20]u8;
pub const Hash = [32]u8;
pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};

pub const Transaction = struct {
    nonce: u64,
    gas_price: u256,
    gas_limit: u64,
    to: ?Address,
    value: u256,
    data: []const u8,
    v: u8,
    r: [32]u8,
    s: [32]u8,

    pub fn hash(self: *const Transaction, allocator: std.mem.Allocator) !Hash {
        const serialized = try self.serialize(allocator);
        defer allocator.free(serialized);
        return crypto.keccak256(serialized);
    }

    pub fn serialize(self: *const Transaction, allocator: std.mem.Allocator) ![]u8 {
        // Simplified RLP encoding - in production use proper RLP
        var list = std.array_list.Managed(u8).init(allocator);
        defer list.deinit();

        // Encode fields (simplified)
        try encodeUint(&list, self.nonce);
        try encodeUint(&list, self.gas_price);
        try encodeUint(&list, self.gas_limit);
        if (self.to) |to| {
            try list.appendSlice(&to);
        } else {
            try list.append(0);
        }
        try encodeUint(&list, self.value);
        try list.appendSlice(self.data);
        try encodeUint(&list, self.v);
        try list.appendSlice(&self.r);
        try list.appendSlice(&self.s);

        return list.toOwnedSlice();
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

    pub fn fromRaw(raw: []const u8) !Transaction {
        // Simplified parsing - in production use proper RLP decoding
        _ = raw;
        return error.NotImplemented;
    }

    pub fn sender(self: *const Transaction) !Address {
        return crypto.recoverAddress(self);
    }

    pub fn priority(self: *const Transaction) u256 {
        return self.gas_price;
    }
};

pub const Block = struct {
    number: u64,
    parent_hash: Hash,
    timestamp: u64,
    transactions: []Transaction,
    gas_used: u64,
    gas_limit: u64,
    state_root: Hash,
    receipts_root: Hash,
    logs_bloom: [256]u8,

    pub fn hash(self: *const Block) Hash {
        // Simplified - in production use proper block header hashing
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        const number_bytes = std.mem.asBytes(&self.number);
        hasher.update(number_bytes);
        hasher.update(&self.parent_hash);
        const timestamp_bytes = std.mem.asBytes(&self.timestamp);
        hasher.update(timestamp_bytes);
        var block_hash: Hash = undefined;
        hasher.final(&block_hash);
        return block_hash;
    }
};

pub const Batch = struct {
    blocks: []Block,
    l1_tx_hash: ?Hash,
    l1_block_number: ?u64,
    created_at: u64,

    pub fn serialize(self: *const Batch, allocator: std.mem.Allocator) ![]u8 {
        var list = std.array_list.Managed(u8).init(allocator);
        defer list.deinit();

        const created_at_bytes = std.mem.asBytes(&self.created_at);
        try list.appendSlice(created_at_bytes);
        for (self.blocks) |block| {
            const block_bytes = std.mem.asBytes(&block.number);
            try list.appendSlice(block_bytes);
            const block_hash = block.hash();
            try list.appendSlice(&block_hash);
        }

        return list.toOwnedSlice();
    }
};

pub const Receipt = struct {
    transaction_hash: Hash,
    block_number: u64,
    block_hash: Hash,
    transaction_index: u32,
    gas_used: u64,
    status: bool,
    logs: []Log,

    pub const Log = struct {
        address: Address,
        topics: []Hash,
        data: []const u8,
    };
};

pub const MempoolEntry = struct {
    tx: Transaction,
    hash: Hash,
    priority: u256,
    received_at: u64,

    pub fn compare(_: void, a: MempoolEntry, b: MempoolEntry) std.math.Order {
        if (a.priority > b.priority) return .gt;
        if (a.priority < b.priority) return .lt;
        if (a.received_at < b.received_at) return .lt;
        if (a.received_at > b.received_at) return .gt;
        return .eq;
    }
};

