// Storage trie support for contract storage slots
// Each contract has its own storage trie for tracking storage values

const std = @import("std");
const types = @import("types.zig");
const trie_module = @import("trie.zig");
const crypto_hash = @import("../crypto/hash.zig");

pub const StorageTrie = struct {
    allocator: std.mem.Allocator,
    contract_address: types.Address,
    trie: trie_module.MerklePatriciaTrie,
    /// Track accessed storage slots for witness generation
    accessed_slots: std.ArrayList(u256),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, contract_address: types.Address) Self {
        return .{
            .allocator = allocator,
            .contract_address = contract_address,
            .trie = trie_module.MerklePatriciaTrie.init(allocator),
            .accessed_slots = std.ArrayList(u256).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.trie.deinit();
        self.accessed_slots.deinit();
    }

    /// Put storage value at slot
    pub fn put(self: *Self, slot: u256, value: u256) !void {
        // Track slot access
        try self.trackSlotAccess(slot);

        // Convert slot to bytes
        const slot_bytes = types.u256ToBytes(slot);
        const value_bytes = types.u256ToBytes(value);

        // Store in trie
        try self.trie.put(&slot_bytes, &value_bytes);
    }

    /// Get storage value at slot
    pub fn get(self: *Self, slot: u256) !?u256 {
        // Track slot access
        try self.trackSlotAccess(slot);

        // Convert slot to bytes
        const slot_bytes = types.u256ToBytes(slot);

        // Get from trie
        const value_bytes = self.trie.get(&slot_bytes) catch return null;
        if (value_bytes == null) {
            return null;
        }

        // Convert bytes to u256
        if (value_bytes.?.len != 32) {
            return error.InvalidStorageValue;
        }

        var value_bytes_array: [32]u8 = undefined;
        @memcpy(&value_bytes_array, value_bytes.?[0..32]);

        return types.u256FromBytes(value_bytes_array);
    }

    /// Compute storage root hash
    pub fn rootHash(self: *Self) !types.Hash {
        return try self.trie.rootHash();
    }

    /// Generate storage trie nodes for witness
    pub fn generateWitnessNodes(self: *Self, slots: []const u256) !std.ArrayList(*trie_module.Node) {
        var result = std.ArrayList(*trie_module.Node).init(self.allocator);

        for (slots) |slot| {
            const slot_bytes = types.u256ToBytes(slot);
            const nodes = try self.trie.generateWitnessNodes(&slot_bytes);
            defer nodes.deinit();

            for (nodes.items) |node| {
                try result.append(node);
            }
        }

        return result;
    }

    /// Handle storage slot access tracking
    pub fn trackSlotAccess(self: *Self, slot: u256) !void {
        // Avoid duplicates
        for (self.accessed_slots.items) |accessed_slot| {
            if (accessed_slot == slot) {
                return;
            }
        }
        try self.accessed_slots.append(slot);
    }

    /// Get all accessed storage slots
    pub fn getAccessedSlots(self: *const Self) []const u256 {
        return self.accessed_slots.items;
    }

    /// Clear accessed slots tracking
    pub fn clearAccessedSlots(self: *Self) void {
        self.accessed_slots.clearAndFree();
    }
};

/// Storage trie manager for multiple contracts
pub const StorageTrieManager = struct {
    allocator: std.mem.Allocator,
    /// Map contract address to its storage trie
    storage_tries: std.HashMap(types.Address, *StorageTrie, std.hash_map.AutoContext(types.Address), std.hash_map.default_max_load_percentage),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .storage_tries = std.HashMap(types.Address, *StorageTrie, std.hash_map.AutoContext(types.Address), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.storage_tries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.storage_tries.deinit();
    }

    /// Get or create storage trie for contract
    pub fn getStorageTrie(self: *Self, contract_address: types.Address) !*StorageTrie {
        if (self.storage_tries.get(contract_address)) |trie| {
            return trie;
        }

        // Create new storage trie
        const trie = try self.allocator.create(StorageTrie);
        trie.* = StorageTrie.init(self.allocator, contract_address);
        try self.storage_tries.put(contract_address, trie);

        return trie;
    }

    /// Put storage value for contract
    pub fn put(self: *Self, contract_address: types.Address, slot: u256, value: u256) !void {
        const trie = try self.getStorageTrie(contract_address);
        try trie.put(slot, value);
    }

    /// Get storage value for contract
    pub fn get(self: *Self, contract_address: types.Address, slot: u256) !?u256 {
        const trie = self.storage_tries.get(contract_address) orelse return null;
        return try trie.get(slot);
    }

    /// Get storage root for contract
    pub fn getStorageRoot(self: *Self, contract_address: types.Address) !?types.Hash {
        const trie = self.storage_tries.get(contract_address) orelse return null;
        return try trie.rootHash();
    }

    /// Generate witness nodes for all accessed storage slots
    pub fn generateWitnessNodes(self: *Self, contract_address: types.Address) !std.ArrayList(*trie_module.Node) {
        const trie = self.storage_tries.get(contract_address) orelse {
            return std.ArrayList(*trie_module.Node).init(self.allocator);
        };

        const accessed_slots = trie.getAccessedSlots();
        return try trie.generateWitnessNodes(accessed_slots);
    }
};
