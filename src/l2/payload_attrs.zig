// Payload Attributes Builder
// Builds payload attributes for engine_forkchoiceUpdatedV3 (op-node style)

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
    parent_beacon_block_root: ?types.Hash = null, // Required for V3 (Cancun), optional for V1/V2

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
            .parent_beacon_block_root = types.hashFromBytes([_]u8{0} ** 32), // Default to zero hash for now (required for V3)
        };
    }

    /// Convert to JSON-RPC format for engine_forkchoiceUpdatedV3
    /// Note: The returned ObjectMap owns the string memory - caller must use deinitJsonRpc to free
    pub fn toJsonRpc(self: *Self, attrs: PayloadAttributes) !std.json.ObjectMap {
        var obj = std.json.ObjectMap.init(self.allocator);

        // Timestamp
        const timestamp_hex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{attrs.timestamp});
        // String is stored in JSON object - will be freed in deinitJsonRpc
        try obj.put("timestamp", std.json.Value{ .string = timestamp_hex });

        // PrevRandao
        const prev_randao_bytes = types.hashToBytes(attrs.prev_randao);
        const prev_randao_hex = try self.hashToHex(&prev_randao_bytes);
        // String is stored in JSON object - will be freed in deinitJsonRpc
        try obj.put("prevRandao", std.json.Value{ .string = prev_randao_hex });

        // SuggestedFeeRecipient
        const fee_recipient_bytes = types.addressToBytes(attrs.suggested_fee_recipient);
        const fee_recipient_hex = try self.hashToHex(&fee_recipient_bytes);
        // String is stored in JSON object - will be freed in deinitJsonRpc
        try obj.put("suggestedFeeRecipient", std.json.Value{ .string = fee_recipient_hex });

        // Transactions (serialize to RLP hex)
        var tx_array = std.json.Array.init(self.allocator);
        // Array is stored in JSON object - will be freed in deinitJsonRpc
        for (attrs.transactions) |tx| {
            const tx_rlp = try tx.serialize(self.allocator);
            const tx_hex = try self.hashToHex(tx_rlp);
            // String is stored in JSON array - will be freed in deinitJsonRpc
            self.allocator.free(tx_rlp); // Free RLP bytes immediately
            try tx_array.append(std.json.Value{ .string = tx_hex });
        }
        try obj.put("transactions", std.json.Value{ .array = tx_array });

        // Withdrawals (empty for now)
        const withdrawals_array = std.json.Array.init(self.allocator);
        // Array is stored in JSON object - will be freed in deinitJsonRpc
        try obj.put("withdrawals", std.json.Value{ .array = withdrawals_array });

        // ParentBeaconBlockRoot (required for V3/Cancun)
        if (attrs.parent_beacon_block_root) |beacon_root| {
            const beacon_root_bytes = types.hashToBytes(beacon_root);
            const beacon_root_hex = try self.hashToHex(&beacon_root_bytes);
            // String is stored in JSON object - will be freed in deinitJsonRpc
            try obj.put("parentBeaconBlockRoot", std.json.Value{ .string = beacon_root_hex });
        } else {
            // For V3, we still need to provide it (use zero hash as default)
            const zero_hash_hex = try self.hashToHex(&([_]u8{0} ** 32));
            try obj.put("parentBeaconBlockRoot", std.json.Value{ .string = zero_hash_hex });
        }

        return obj;
    }

    /// Properly deinitialize a JSON-RPC object map created by toJsonRpc
    /// Frees all string values stored in the map
    pub fn deinitJsonRpc(allocator: std.mem.Allocator, obj: *std.json.ObjectMap) void {
        var it = obj.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .string => |s| {
                    allocator.free(s);
                },
                .array => |arr| {
                    // Free strings in array
                    for (arr.items) |item| {
                        switch (item) {
                            .string => |str| allocator.free(str),
                            else => {},
                        }
                    }
                    arr.deinit();
                },
                else => {},
            }
        }
        obj.deinit();
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
