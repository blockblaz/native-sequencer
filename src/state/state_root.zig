// State root computation for Ethereum state trie

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const crypto_hash = @import("../crypto/hash.zig");
const trie_module = @import("../core/trie.zig");

pub const StateRoot = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed
    }

    /// Compute state root from state manager
    /// This builds a Merkle Patricia Trie from all accounts in the state manager
    pub fn computeStateRoot(self: *Self, state_manager: *@import("manager.zig").StateManager) !types.Hash {
        // Build state trie from all accounts
        var trie = trie_module.MerklePatriciaTrie.init(self.allocator);
        defer trie.deinit();

        // Iterate over all accounts in state manager
        var nonce_iter = state_manager.nonces.iterator();
        while (nonce_iter.next()) |entry| {
            const address = entry.key_ptr.*;
            const nonce = entry.value_ptr.*;

            // Get balance for this address
            const balance = state_manager.getBalance(address) catch 0;

            // Encode account data (nonce, balance, storage_root, code_hash)
            const account_data = try self.encodeAccount(address, nonce, balance, state_manager);
            defer self.allocator.free(account_data);

            // Insert into trie
            const addr_bytes = types.addressToBytes(address);
            try trie.put(&addr_bytes, account_data);
        }

        // Compute root hash
        return try trie.rootHash();
    }

    /// Update state root after each block
    pub fn updateStateRoot(self: *Self, state_manager: *@import("manager.zig").StateManager) !types.Hash {
        return try self.computeStateRoot(state_manager);
    }

    /// Verify state root matches witness root
    pub fn verifyStateRoot(_: *Self, computed_root: types.Hash, witness_root: types.Hash) bool {
        return computed_root == witness_root;
    }

    /// Encode account data for state trie
    fn encodeAccount(self: *Self, _: types.Address, nonce: u64, balance: u256, _: *@import("manager.zig").StateManager) ![]u8 {

        // RLP encode account: [nonce, balance, storage_root, code_hash]
        const rlp_module = @import("../core/rlp.zig");

        var items = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (items.items) |item| {
                self.allocator.free(item);
            }
            items.deinit();
        }

        // Nonce
        try items.append(try rlp_module.encodeUint(self.allocator, nonce));

        // Balance
        const balance_bytes = types.u256ToBytes(balance);
        try items.append(try rlp_module.encodeBytes(self.allocator, &balance_bytes));

        // Storage root (empty for now - would be computed from storage trie)
        const empty_storage_root = types.hashFromBytes([_]u8{0} ** 32);
        const storage_root_bytes = types.hashToBytes(empty_storage_root);
        try items.append(try rlp_module.encodeBytes(self.allocator, &storage_root_bytes));

        // Code hash (empty for EOAs - would be keccak256(code) for contracts)
        const empty_code_hash = types.hashFromBytes([_]u8{0} ** 32);
        const code_hash_bytes = types.hashToBytes(empty_code_hash);
        try items.append(try rlp_module.encodeBytes(self.allocator, &code_hash_bytes));

        return try rlp_module.encodeList(self.allocator, items.items);
    }
};
