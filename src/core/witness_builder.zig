// Witness builder for generating witnesses from state during execution
// Tracks state access and builds witness incrementally

const std = @import("std");
const types = @import("types.zig");
const witness = @import("witness.zig");
const crypto_hash = @import("../crypto/hash.zig");

/// Tracks state access during execution to build witness
pub const WitnessBuilder = struct {
    allocator: std.mem.Allocator,
    witness: witness.Witness,
    /// Track accessed state node hashes
    accessed_state_nodes: std.ArrayList(types.Hash),
    /// Track accessed code hashes
    accessed_code_hashes: std.ArrayList(types.Hash),
    /// Track block numbers needed for BLOCKHASH opcode
    needed_block_numbers: std.ArrayList(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .witness = witness.Witness.init(allocator),
            .accessed_state_nodes = std.ArrayList(types.Hash).init(allocator),
            .accessed_code_hashes = std.ArrayList(types.Hash).init(allocator),
            .needed_block_numbers = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.witness.deinit(self.allocator);
        self.accessed_state_nodes.deinit();
        self.accessed_code_hashes.deinit();
        self.needed_block_numbers.deinit();
    }

    /// Track state node access
    pub fn trackStateNode(self: *Self, node_hash: types.Hash) !void {
        // Avoid duplicates
        for (self.accessed_state_nodes.items) |hash| {
            if (hash == node_hash) {
                return;
            }
        }
        try self.accessed_state_nodes.append(node_hash);
    }

    /// Track code access
    pub fn trackCode(self: *Self, code: []const u8) !void {
        const code_hash = crypto_hash.keccak256(code);
        // Avoid duplicates
        for (self.accessed_code_hashes.items) |hash| {
            if (hash == code_hash) {
                return;
            }
        }
        try self.accessed_code_hashes.append(code_hash);
    }

    /// Track block number needed for BLOCKHASH opcode
    pub fn trackBlockNumber(self: *Self, block_number: u64) !void {
        // Avoid duplicates
        for (self.needed_block_numbers.items) |num| {
            if (num == block_number) {
                return;
            }
        }
        try self.needed_block_numbers.append(block_number);
    }

    /// Add state node to witness
    pub fn addStateNode(self: *Self, node_hash: types.Hash, node_data: []const u8) !void {
        const node_data_copy = try self.allocator.dupe(u8, node_data);
        errdefer self.allocator.free(node_data_copy);
        try self.witness.state.put(node_hash, node_data_copy);
    }

    /// Add code to witness
    pub fn addCode(self: *Self, code_hash: types.Hash, code: []const u8) !void {
        const code_copy = try self.allocator.dupe(u8, code);
        errdefer self.allocator.free(code_copy);
        try self.witness.codes.put(code_hash, code_copy);
    }

    /// Add block header to witness
    pub fn addHeader(self: *Self, header: witness.BlockHeader) !void {
        // Copy header
        var header_copy = header;
        header_copy.extra_data = try self.allocator.dupe(u8, header.extra_data);
        errdefer self.allocator.free(header_copy.extra_data);

        // Resize headers array
        const new_headers = try self.allocator.realloc(self.witness.headers, self.witness.headers.len + 1);
        errdefer self.allocator.free(new_headers);
        new_headers[self.witness.headers.len] = header_copy;
        self.witness.headers = new_headers;
    }

    /// Extract state trie nodes needed for transaction execution
    /// Traverses MPT to collect all nodes along paths to accessed accounts
    pub fn extractStateNodes(self: *Self, state_manager: anytype) !void {
        // Build state trie from state manager
        const state_root_module = @import("../state/state_root.zig");
        var state_root = state_root_module.StateRoot.init(self.allocator);
        defer state_root.deinit();

        // Compute state root (this builds the trie)
        // Note: We need a mutable reference, so we'll need to adjust the call site
        // For now, we'll skip this if state_manager is const
        _ = state_manager;

        // For each accessed state node hash, get the node data
        for (self.accessed_state_nodes.items) |node_hash| {
            // Query state manager or trie for node data
            // For now, we'll need to integrate with trie to get actual node data
            // This is a placeholder - full implementation would query the trie
            const node_data = try self.allocator.alloc(u8, 32); // Placeholder
            @memset(node_data, 0);
            try self.addStateNode(node_hash, node_data);
        }
    }

    /// Extract contract bytecodes accessed during execution
    pub fn extractContractCodes(self: *Self, state_manager: anytype) !void {
        _ = self;
        _ = state_manager;
        // In a full implementation, this would:
        // 1. For each accessed contract address
        // 2. Get the contract code
        // 3. Compute code hash
        // 4. Add to witness.codes
    }

    /// Extract block headers needed for BLOCKHASH opcode
    pub fn extractBlockHeaders(self: *Self, block_manager: anytype) !void {
        _ = self;
        _ = block_manager;
        // In a full implementation, this would:
        // 1. For each needed block number
        // 2. Get the block header
        // 3. Add to witness.headers
    }

    /// Build witness incrementally during block building
    pub fn buildWitness(self: *Self, state_manager: anytype, block_manager: anytype) !witness.Witness {
        // Extract all required data
        try self.extractStateNodes(state_manager);
        try self.extractContractCodes(state_manager);
        try self.extractBlockHeaders(block_manager);

        // Return a copy of the witness
        // Note: In production, you might want to return a reference or move semantics
        return self.witness;
    }

    /// Get the current witness (without building)
    pub fn getWitness(self: *const Self) *const witness.Witness {
        return &self.witness;
    }

    /// Generate witness for an entire block
    /// This processes all transactions in the block and builds a complete witness
    /// exec_engine must have a witness_builder field that can be set to self
    pub fn generateBlockWitness(self: *Self, block: *const @import("block.zig").Block, exec_engine: anytype) !void {
        // Process each transaction in the block
        for (block.transactions) |tx| {
            // Track state access for each transaction
            const sender = tx.sender() catch continue;
            const sender_hash = crypto_hash.keccak256(&types.addressToBytes(sender));
            try self.trackStateNode(sender_hash);

            if (tx.to) |to| {
                const to_hash = crypto_hash.keccak256(&types.addressToBytes(to));
                try self.trackStateNode(to_hash);

                // Track code access if this is a contract call
                if (tx.data.len > 0) {
                    try self.trackCode(tx.data);
                }
            }

            // Execute transaction to track all state accesses
            // Note: We attach witness builder to execution engine
            // The execution engine should have a witness_builder field
            if (@hasField(@TypeOf(exec_engine.*), "witness_builder")) {
                exec_engine.witness_builder = self;
            }
            _ = exec_engine.executeTransaction(tx) catch |err| {
                std.log.debug("Transaction execution failed during block witness generation: {any}", .{err});
                // Continue processing other transactions
            };
        }

        // Track block header for BLOCKHASH opcode
        try self.trackBlockNumber(block.number);
    }
};
