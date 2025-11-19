// Transaction execution engine

const std = @import("std");
const core = @import("../core/root.zig");
const state = @import("../state/root.zig");
const types = @import("../core/types.zig");
const crypto_hash = @import("../crypto/hash.zig");

pub const ExecutionResult = struct {
    success: bool,
    gas_used: u64,
    return_data: []const u8,
    logs: []core.receipt.Receipt.Log,
};

pub const ExecutionEngine = struct {
    allocator: std.mem.Allocator,
    state_manager: *state.StateManager,
    /// Optional witness builder for tracking state access
    witness_builder: ?*core.witness_builder.WitnessBuilder = null,

    pub fn init(allocator: std.mem.Allocator, sm: *state.StateManager) ExecutionEngine {
        return .{
            .allocator = allocator,
            .state_manager = sm,
            .witness_builder = null,
        };
    }

    /// Initialize with witness builder for state tracking
    pub fn initWithWitnessBuilder(allocator: std.mem.Allocator, sm: *state.StateManager, wb: *core.witness_builder.WitnessBuilder) ExecutionEngine {
        return .{
            .allocator = allocator,
            .state_manager = sm,
            .witness_builder = wb,
        };
    }

    pub fn executeTransaction(self: *ExecutionEngine, tx: core.transaction.Transaction) !ExecutionResult {
        const sender = try tx.sender();

        // Track state access for witness generation
        if (self.witness_builder) |wb| {
            // Track sender account access (simplified - would track actual trie nodes)
            const sender_hash = crypto_hash.keccak256(&types.addressToBytes(sender));
            try wb.trackStateNode(sender_hash);
        }

        // Get current state
        const sender_nonce = try self.state_manager.getNonce(sender);
        const sender_balance = try self.state_manager.getBalance(sender);

        // Validate nonce
        if (tx.nonce != sender_nonce) {
            return ExecutionResult{
                .success = false,
                .gas_used = 0,
                .return_data = "",
                .logs = &[_]core.receipt.Receipt.Log{},
            };
        }

        // Calculate base gas cost
        const base_gas: u64 = 21000; // Base transaction cost
        var gas_used: u64 = base_gas;

        // Add gas for data (4 gas per zero byte, 16 gas per non-zero byte)
        for (tx.data) |byte| {
            if (byte == 0) {
                gas_used += 4;
            } else {
                gas_used += 16;
            }
        }

        // Add gas for contract creation (32000 gas)
        if (tx.to == null) {
            gas_used += 32000;
        }

        // Calculate total cost
        // gas_price and value are already u256 types
        const gas_cost = tx.gas_price * @as(u256, gas_used);
        const total_cost = tx.value + gas_cost;

        // Check balance
        if (sender_balance < total_cost) {
            return ExecutionResult{
                .success = false,
                .gas_used = 0,
                .return_data = "",
                .logs = &[_]core.receipt.Receipt.Log{},
            };
        }

        // Check gas limit
        if (gas_used > tx.gas_limit) {
            return ExecutionResult{
                .success = false,
                .gas_used = tx.gas_limit, // Consume all gas on failure
                .return_data = "",
                .logs = &[_]core.receipt.Receipt.Log{},
            };
        }

        // Track recipient state access
        if (tx.to) |to| {
            if (self.witness_builder) |wb| {
                const to_hash = crypto_hash.keccak256(&types.addressToBytes(to));
                try wb.trackStateNode(to_hash);
            }
        }

        // Execute transaction
        if (tx.to) |to| {
            // Contract call or transfer
            return try self.executeCall(tx, sender, to, gas_used, gas_cost);
        } else {
            // Contract creation
            return try self.executeCreate(tx, sender, gas_used, gas_cost);
        }
    }

    fn executeCall(self: *ExecutionEngine, tx: core.transaction.Transaction, sender: core.types.Address, to: core.types.Address, gas_used: u64, gas_cost: u256) !ExecutionResult {
        // Track code access if this is a contract call
        if (self.witness_builder) |wb| {
            // In a full implementation, we would:
            // 1. Check if 'to' is a contract (has code)
            // 2. Get the contract code
            // 3. Track it in witness builder
            // For now, simplified tracking
            if (tx.data.len > 0) {
                // Likely a contract call, track code access
                try wb.trackCode(tx.data);
            }
        }
        // Update sender balance
        const sender_balance = try self.state_manager.getBalance(sender);
        const total_cost = tx.value + gas_cost;
        const new_sender_balance = if (sender_balance >= total_cost) sender_balance - total_cost else 0;
        try self.state_manager.setBalance(sender, new_sender_balance);

        // Update recipient balance (only if transaction succeeded)
        if (sender_balance >= total_cost) {
            const recipient_balance = try self.state_manager.getBalance(to);
            const new_recipient_balance = recipient_balance + tx.value;
            try self.state_manager.setBalance(to, new_recipient_balance);
        }

        // Increment nonce
        try self.state_manager.incrementNonce(sender);

        // For now, contract calls are simplified - just return success
        // In production, this would execute EVM bytecode
        const return_data = if (tx.data.len > 0) "" else "";

        return ExecutionResult{
            .success = true,
            .gas_used = gas_used,
            .return_data = return_data,
            .logs = &[_]core.receipt.Receipt.Log{},
        };
    }

    fn executeCreate(self: *ExecutionEngine, tx: core.transaction.Transaction, sender: core.types.Address, gas_used: u64, gas_cost: u256) !ExecutionResult {
        // Update sender balance
        const sender_balance = try self.state_manager.getBalance(sender);
        const total_cost = tx.value + gas_cost;
        const new_sender_balance = if (sender_balance >= total_cost) sender_balance - total_cost else 0;
        try self.state_manager.setBalance(sender, new_sender_balance);

        // Increment nonce
        try self.state_manager.incrementNonce(sender);

        // For contract creation, we would:
        // 1. Execute init code
        // 2. Create new contract account
        // 3. Set contract code
        // For now, simplified implementation

        return ExecutionResult{
            .success = true,
            .gas_used = gas_used,
            .return_data = "",
            .logs = &[_]core.receipt.Receipt.Log{},
        };
    }
};
