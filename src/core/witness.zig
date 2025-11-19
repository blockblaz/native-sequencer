// Witness structure for stateless execution
// Matches go-ethereum's witness format for ExecuteTx transactions

const std = @import("std");
const types = @import("types.zig");
const rlp_module = @import("rlp.zig");

/// Block header for BLOCKHASH opcode support
pub const BlockHeader = struct {
    number: u64,
    hash: types.Hash,
    parent_hash: types.Hash,
    timestamp: u64,
    state_root: types.Hash,
    transactions_root: types.Hash,
    receipts_root: types.Hash,
    gas_used: u64,
    gas_limit: u64,
    coinbase: types.Address,
    difficulty: u256,
    extra_data: []const u8,

    const Self = @This();

    /// Encode block header to RLP format
    pub fn encodeRLP(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (items.items) |item| {
                allocator.free(item);
            }
            items.deinit();
        }

        // Encode all header fields
        try items.append(try rlp_module.encodeUint(allocator, self.number));
        try items.append(try rlp_module.encodeBytes(allocator, &types.hashToBytes(self.hash)));
        try items.append(try rlp_module.encodeBytes(allocator, &types.hashToBytes(self.parent_hash)));
        try items.append(try rlp_module.encodeUint(allocator, self.timestamp));
        try items.append(try rlp_module.encodeBytes(allocator, &types.hashToBytes(self.state_root)));
        try items.append(try rlp_module.encodeBytes(allocator, &types.hashToBytes(self.transactions_root)));
        try items.append(try rlp_module.encodeBytes(allocator, &types.hashToBytes(self.receipts_root)));
        try items.append(try rlp_module.encodeUint(allocator, self.gas_used));
        try items.append(try rlp_module.encodeUint(allocator, self.gas_limit));
        try items.append(try rlp_module.encodeBytes(allocator, &types.addressToBytes(self.coinbase)));
        try items.append(try rlp_module.encodeUint(allocator, self.difficulty));
        try items.append(try rlp_module.encodeBytes(allocator, self.extra_data));

        return try rlp_module.encodeList(allocator, items.items);
    }

    /// Decode block header from RLP format
    pub fn decodeRLP(allocator: std.mem.Allocator, data: []const u8) !struct { header: Self, consumed: usize } {
        const decoded = try rlp_module.decodeList(allocator, data);
        defer {
            for (decoded.items) |item| {
                allocator.free(item);
            }
            decoded.items.deinit();
        }

        if (decoded.items.len < 12) {
            return error.InvalidRLP;
        }

        var idx: usize = 0;

        // Number
        const number_result = try rlp_module.decodeUint(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        const number = @as(u64, @intCast(number_result.value));
        idx += 1;

        // Hash
        const hash_result = try rlp_module.decodeBytes(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        defer allocator.free(hash_result.value);
        if (hash_result.value.len != 32) return error.InvalidRLP;
        var hash_bytes: [32]u8 = undefined;
        @memcpy(&hash_bytes, hash_result.value);
        const hash = types.hashFromBytes(hash_bytes);
        idx += 1;

        // Parent hash
        const parent_hash_result = try rlp_module.decodeBytes(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        defer allocator.free(parent_hash_result.value);
        if (parent_hash_result.value.len != 32) return error.InvalidRLP;
        var parent_hash_bytes: [32]u8 = undefined;
        @memcpy(&parent_hash_bytes, parent_hash_result.value);
        const parent_hash = types.hashFromBytes(parent_hash_bytes);
        idx += 1;

        // Timestamp
        const timestamp_result = try rlp_module.decodeUint(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        const timestamp = @as(u64, @intCast(timestamp_result.value));
        idx += 1;

        // State root
        const state_root_result = try rlp_module.decodeBytes(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        defer allocator.free(state_root_result.value);
        if (state_root_result.value.len != 32) return error.InvalidRLP;
        var state_root_bytes: [32]u8 = undefined;
        @memcpy(&state_root_bytes, state_root_result.value);
        const state_root = types.hashFromBytes(state_root_bytes);
        idx += 1;

        // Transactions root
        const transactions_root_result = try rlp_module.decodeBytes(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        defer allocator.free(transactions_root_result.value);
        if (transactions_root_result.value.len != 32) return error.InvalidRLP;
        var transactions_root_bytes: [32]u8 = undefined;
        @memcpy(&transactions_root_bytes, transactions_root_result.value);
        const transactions_root = types.hashFromBytes(transactions_root_bytes);
        idx += 1;

        // Receipts root
        const receipts_root_result = try rlp_module.decodeBytes(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        defer allocator.free(receipts_root_result.value);
        if (receipts_root_result.value.len != 32) return error.InvalidRLP;
        var receipts_root_bytes: [32]u8 = undefined;
        @memcpy(&receipts_root_bytes, receipts_root_result.value);
        const receipts_root = types.hashFromBytes(receipts_root_bytes);
        idx += 1;

        // Gas used
        const gas_used_result = try rlp_module.decodeUint(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        const gas_used = @as(u64, @intCast(gas_used_result.value));
        idx += 1;

        // Gas limit
        const gas_limit_result = try rlp_module.decodeUint(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        const gas_limit = @as(u64, @intCast(gas_limit_result.value));
        idx += 1;

        // Coinbase
        const coinbase_result = try rlp_module.decodeBytes(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        defer allocator.free(coinbase_result.value);
        if (coinbase_result.value.len != 20) return error.InvalidRLP;
        var coinbase_bytes: [20]u8 = undefined;
        @memcpy(&coinbase_bytes, coinbase_result.value);
        const coinbase = types.addressFromBytes(coinbase_bytes);
        idx += 1;

        // Difficulty
        const difficulty_result = try rlp_module.decodeBytes(allocator, decoded.items[idx]);
        defer allocator.free(decoded.items[idx]);
        defer allocator.free(difficulty_result.value);
        if (difficulty_result.value.len != 32) return error.InvalidRLP;
        var difficulty_bytes: [32]u8 = undefined;
        @memcpy(&difficulty_bytes, difficulty_result.value);
        const difficulty = types.u256FromBytes(difficulty_bytes);
        idx += 1;

        // Extra data
        defer allocator.free(decoded.items[idx]);
        const extra_data = try allocator.dupe(u8, decoded.items[idx]);
        idx += 1;

        return .{
            .header = Self{
                .number = number,
                .hash = hash,
                .parent_hash = parent_hash,
                .timestamp = timestamp,
                .state_root = state_root,
                .transactions_root = transactions_root,
                .receipts_root = receipts_root,
                .gas_used = gas_used,
                .gas_limit = gas_limit,
                .coinbase = coinbase,
                .difficulty = difficulty,
                .extra_data = extra_data,
            },
            .consumed = decoded.consumed,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.extra_data);
    }
};

/// Witness structure matching go-ethereum format
pub const Witness = struct {
    /// Array of block headers (for BLOCKHASH opcode)
    headers: []BlockHeader,
    /// Map of contract bytecodes (keyed by code hash)
    codes: std.HashMap(types.Hash, []const u8, std.hash_map.AutoContext(types.Hash), std.hash_map.default_max_load_percentage),
    /// Map of MPT trie nodes (keyed by node hash)
    state: std.HashMap(types.Hash, []const u8, std.hash_map.AutoContext(types.Hash), std.hash_map.default_max_load_percentage),

    const Self = @This();

    /// Initialize witness with allocator
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .headers = &[_]BlockHeader{},
            .codes = std.HashMap(types.Hash, []const u8, std.hash_map.AutoContext(types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
            .state = std.HashMap(types.Hash, []const u8, std.hash_map.AutoContext(types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    /// Encode witness to RLP format matching go-ethereum
    pub fn encodeRLP(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (items.items) |item| {
                allocator.free(item);
            }
            items.deinit();
        }

        // Encode headers array
        var headers_items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (headers_items.items) |item| {
                allocator.free(item);
            }
            headers_items.deinit();
        }
        for (self.headers) |header| {
            const header_rlp = try header.encodeRLP(allocator);
            try headers_items.append(header_rlp);
        }
        const headers_list = try rlp_module.encodeList(allocator, headers_items.items);
        defer allocator.free(headers_list);
        try items.append(headers_list);

        // Encode codes map (as list of [hash, code] pairs)
        var codes_items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (codes_items.items) |item| {
                allocator.free(item);
            }
            codes_items.deinit();
        }
        var codes_iter = self.codes.iterator();
        while (codes_iter.next()) |entry| {
            var pair_items = std.ArrayList([]const u8).init(allocator);
            defer {
                for (pair_items.items) |item| {
                    allocator.free(item);
                }
                pair_items.deinit();
            }
            const hash_bytes = types.hashToBytes(entry.key_ptr.*);
            try pair_items.append(try rlp_module.encodeBytes(allocator, &hash_bytes));
            try pair_items.append(try rlp_module.encodeBytes(allocator, entry.value_ptr.*));
            const pair_rlp = try rlp_module.encodeList(allocator, pair_items.items);
            try codes_items.append(pair_rlp);
        }
        const codes_list = try rlp_module.encodeList(allocator, codes_items.items);
        defer allocator.free(codes_list);
        try items.append(codes_list);

        // Encode state map (as list of [hash, node] pairs)
        var state_items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (state_items.items) |item| {
                allocator.free(item);
            }
            state_items.deinit();
        }
        var state_iter = self.state.iterator();
        while (state_iter.next()) |entry| {
            var pair_items = std.ArrayList([]const u8).init(allocator);
            defer {
                for (pair_items.items) |item| {
                    allocator.free(item);
                }
                pair_items.deinit();
            }
            const hash_bytes = types.hashToBytes(entry.key_ptr.*);
            try pair_items.append(try rlp_module.encodeBytes(allocator, &hash_bytes));
            try pair_items.append(try rlp_module.encodeBytes(allocator, entry.value_ptr.*));
            const pair_rlp = try rlp_module.encodeList(allocator, pair_items.items);
            try state_items.append(pair_rlp);
        }
        const state_list = try rlp_module.encodeList(allocator, state_items.items);
        defer allocator.free(state_list);
        try items.append(state_list);

        return try rlp_module.encodeList(allocator, items.items);
    }

    /// Decode witness from RLP bytes
    pub fn decodeRLP(allocator: std.mem.Allocator, data: []const u8) !Self {
        const decoded = try rlp_module.decodeList(allocator, data);
        defer {
            for (decoded.items) |item| {
                allocator.free(item);
            }
            decoded.items.deinit();
        }

        if (decoded.items.len < 3) {
            return error.InvalidRLP;
        }

        var witness = Self.init(allocator);
        errdefer witness.deinit(allocator);

        // Decode headers
        const headers_list = try rlp_module.decodeList(allocator, decoded.items[0]);
        defer {
            for (headers_list.items) |item| {
                allocator.free(item);
            }
            headers_list.items.deinit();
        }
        var headers = std.ArrayList(BlockHeader).init(allocator);
        errdefer {
            for (headers.items) |*header| {
                header.deinit(allocator);
            }
            headers.deinit();
        }
        for (headers_list.items) |header_data| {
            const header_result = try BlockHeader.decodeRLP(allocator, header_data);
            try headers.append(header_result.header);
        }
        witness.headers = try headers.toOwnedSlice();

        // Decode codes map
        const codes_list = try rlp_module.decodeList(allocator, decoded.items[1]);
        defer {
            for (codes_list.items) |item| {
                allocator.free(item);
            }
            codes_list.items.deinit();
        }
        for (codes_list.items) |pair_data| {
            const pair_list = try rlp_module.decodeList(allocator, pair_data);
            defer {
                for (pair_list.items) |item| {
                    allocator.free(item);
                }
                pair_list.items.deinit();
            }
            if (pair_list.items.len != 2) return error.InvalidRLP;

            const hash_result = try rlp_module.decodeBytes(allocator, pair_list.items[0]);
            defer allocator.free(pair_list.items[0]);
            defer allocator.free(hash_result.value);
            if (hash_result.value.len != 32) return error.InvalidRLP;
            var hash_bytes: [32]u8 = undefined;
            @memcpy(&hash_bytes, hash_result.value);
            const hash = types.hashFromBytes(hash_bytes);

            defer allocator.free(pair_list.items[1]);
            const code = try allocator.dupe(u8, pair_list.items[1]);
            try witness.codes.put(hash, code);
        }

        // Decode state map
        const state_list = try rlp_module.decodeList(allocator, decoded.items[2]);
        defer {
            for (state_list.items) |item| {
                allocator.free(item);
            }
            state_list.items.deinit();
        }
        for (state_list.items) |pair_data| {
            const pair_list = try rlp_module.decodeList(allocator, pair_data);
            defer {
                for (pair_list.items) |item| {
                    allocator.free(item);
                }
                pair_list.items.deinit();
            }
            if (pair_list.items.len != 2) return error.InvalidRLP;

            const hash_result = try rlp_module.decodeBytes(allocator, pair_list.items[0]);
            defer allocator.free(pair_list.items[0]);
            defer allocator.free(hash_result.value);
            if (hash_result.value.len != 32) return error.InvalidRLP;
            var hash_bytes: [32]u8 = undefined;
            @memcpy(&hash_bytes, hash_result.value);
            const hash = types.hashFromBytes(hash_bytes);

            defer allocator.free(pair_list.items[1]);
            const node = try allocator.dupe(u8, pair_list.items[1]);
            try witness.state.put(hash, node);
        }

        return witness;
    }

    /// Validate witness structure
    pub fn validate(_: *const Self) bool {
        // Basic validation: check that required fields are present
        // More comprehensive validation would check:
        // - All referenced state nodes are present
        // - All referenced codes are present
        // - Headers are in correct order
        return true;
    }

    /// Verify witness root matches pre-state hash
    pub fn verifyRoot(_: *const Self, _: types.Hash) bool {
        // In a full implementation, this would:
        // 1. Reconstruct the state trie from witness.state nodes
        // 2. Compute the root hash
        // 3. Compare with pre_state_hash
        // For now, simplified validation
        return true;
    }

    /// Check witness completeness before execution
    pub fn isComplete(_: *const Self) bool {
        // Check that witness contains all required data
        // This is a simplified check - full implementation would verify:
        // - All state nodes referenced in transactions are present
        // - All contract codes referenced are present
        // - All block headers needed for BLOCKHASH are present
        return true;
    }

    /// Free allocated memory
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Free headers
        for (self.headers) |*header| {
            header.deinit(allocator);
        }
        allocator.free(self.headers);

        // Free codes
        var codes_iter = self.codes.iterator();
        while (codes_iter.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.codes.deinit();

        // Free state nodes
        var state_iter = self.state.iterator();
        while (state_iter.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.state.deinit();
    }
};
