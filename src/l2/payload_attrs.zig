// Payload Attributes Builder
// Builds payload attributes for engine_forkchoiceUpdated (op-node style)

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const transaction = @import("../core/transaction.zig");

pub const PayloadAttributes = struct {
    timestamp: u64,
    prev_randao: types.Hash,
    suggested_fee_recipient: types.Address,
    transactions: []transaction.Transaction,
    withdrawals: []void = &[_]void{}, // Empty for now

    pub fn deinit(self: *PayloadAttributes, allocator: std.mem.Allocator) void {
        allocator.free(self.transactions);
    }
};

pub const PayloadAttributesBuilder = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Build payload attributes from transactions
    pub fn build(self: *Self, transactions: []transaction.Transaction, fee_recipient: types.Address) !PayloadAttributes {
        // Clone transactions
        const txs = try self.allocator.dupe(transaction.Transaction, transactions);

        return PayloadAttributes{
            .timestamp = @intCast(std.time.timestamp()),
            .prev_randao = types.hashFromBytes([_]u8{0} ** 32), // TODO: Get from L1
            .suggested_fee_recipient = fee_recipient,
            .transactions = txs,
            .withdrawals = &[_]void{},
        };
    }

    /// Convert to JSON-RPC format for engine_forkchoiceUpdated
    pub fn toJsonRpc(self: *Self, attrs: PayloadAttributes) !std.json.ObjectMap {
        var obj = std.json.ObjectMap.init(self.allocator);

        // Timestamp
        const timestamp_hex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{attrs.timestamp});
        defer self.allocator.free(timestamp_hex);
        try obj.put("timestamp", std.json.Value{ .string = timestamp_hex });

        // PrevRandao
        const prev_randao_bytes = types.hashToBytes(attrs.prev_randao);
        const prev_randao_hex = try self.hashToHex(&prev_randao_bytes);
        defer self.allocator.free(prev_randao_hex);
        try obj.put("prevRandao", std.json.Value{ .string = prev_randao_hex });

        // SuggestedFeeRecipient
        const fee_recipient_bytes = types.addressToBytes(attrs.suggested_fee_recipient);
        const fee_recipient_hex = try self.hashToHex(&fee_recipient_bytes);
        defer self.allocator.free(fee_recipient_hex);
        try obj.put("suggestedFeeRecipient", std.json.Value{ .string = fee_recipient_hex });

        // Transactions (serialize to RLP hex)
        var tx_array = std.json.Array.init(self.allocator);
        defer tx_array.deinit();
        for (attrs.transactions) |tx| {
            const tx_rlp = try tx.serialize(self.allocator);
            defer self.allocator.free(tx_rlp);
            const tx_hex = try self.hashToHex(tx_rlp);
            defer self.allocator.free(tx_hex);
            try tx_array.append(std.json.Value{ .string = tx_hex });
        }
        try obj.put("transactions", std.json.Value{ .array = tx_array });

        // Withdrawals (empty for now)
        var withdrawals_array = std.json.Array.init(self.allocator);
        defer withdrawals_array.deinit();
        try obj.put("withdrawals", std.json.Value{ .array = withdrawals_array });

        return obj;
    }

    fn hashToHex(self: *Self, bytes: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        try result.appendSlice("0x");
        const hex_digits = "0123456789abcdef";
        for (bytes) |byte| {
            try result.append(hex_digits[byte >> 4]);
            try result.append(hex_digits[byte & 0xf]);
        }

        return result.toOwnedSlice();
    }
};
