const std = @import("std");
const core = @import("../core/root.zig");

pub const StateManager = struct {
    allocator: std.mem.Allocator,
    nonces: std.HashMap(core.types.Address, u64, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage),
    balances: std.HashMap(core.types.Address, u256, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage),
    receipts: std.HashMap(core.types.Hash, core.receipt.Receipt, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage),
    current_block_number: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) StateManager {
        return .{
            .allocator = allocator,
            .nonces = std.HashMap(core.types.Address, u64, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage).init(allocator),
            .balances = std.HashMap(core.types.Address, u256, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage).init(allocator),
            .receipts = std.HashMap(core.types.Hash, core.receipt.Receipt, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *StateManager) void {
        self.nonces.deinit();
        self.balances.deinit();
        var receipt_iter = self.receipts.iterator();
        while (receipt_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.logs);
            for (entry.value_ptr.logs) |log| {
                self.allocator.free(log.topics);
                self.allocator.free(log.data);
            }
        }
        self.receipts.deinit();
    }

    pub fn getNonce(self: *const StateManager, address: core.types.Address) !u64 {
        return self.nonces.get(address) orelse 0;
    }

    pub fn getBalance(self: *const StateManager, address: core.types.Address) !u256 {
        return self.balances.get(address) orelse 0;
    }

    pub fn setBalance(self: *StateManager, address: core.types.Address, balance: u256) !void {
        try self.balances.put(address, balance);
    }

    pub fn incrementNonce(self: *StateManager, address: core.types.Address) !void {
        const current = self.getNonce(address) catch 0;
        try self.nonces.put(address, current + 1);
    }

    pub fn applyTransaction(self: *StateManager, tx: core.transaction.Transaction, gas_used: u64) !core.receipt.Receipt {
        const sender = try tx.sender();
        const gas_cost = tx.gas_price * gas_used;

        // Update balance
        const current_balance = try self.getBalance(sender);
        const new_balance = if (current_balance >= (tx.value + gas_cost)) current_balance - tx.value - gas_cost else 0;
        try self.setBalance(sender, new_balance);

        // Update recipient balance if transfer
        if (tx.to) |to| {
            const recipient_balance = try self.getBalance(to);
            try self.setBalance(to, recipient_balance + tx.value);
        }

        // Increment nonce
        try self.incrementNonce(sender);

        // Create receipt
        // Note: tx.hash() returns Hash ([32]u8), not an allocated slice, so no need to free
        const tx_hash = try tx.hash(self.allocator);

        const receipt = core.receipt.Receipt{
            .transaction_hash = tx_hash,
            .block_number = self.current_block_number,
            .block_hash = [_]u8{0} ** 32, // Will be set when block is finalized
            .transaction_index = 0, // Will be set properly
            .gas_used = gas_used,
            .status = true,
            .logs = &[_]core.receipt.Receipt.Log{},
        };

        try self.receipts.put(tx_hash, receipt);

        return receipt;
    }

    pub fn getReceipt(self: *const StateManager, tx_hash: core.types.Hash) ?core.receipt.Receipt {
        return self.receipts.get(tx_hash);
    }

    pub fn finalizeBlock(self: *StateManager, block: core.block.Block) !void {
        self.current_block_number = block.number;
        // In production, update state root, receipts root, etc.
    }
};

