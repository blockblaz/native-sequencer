const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");
const state = @import("../state/root.zig");

pub const ValidationResult = enum {
    valid,
    invalid_signature,
    invalid_nonce,
    insufficient_gas,
    insufficient_balance,
    invalid_gas_price,
    duplicate,
};

pub const TransactionValidator = struct {
    allocator: std.mem.Allocator,
    state_manager: *state.StateManager,

    pub fn init(allocator: std.mem.Allocator, sm: *state.StateManager) TransactionValidator {
        return .{
            .allocator = allocator,
            .state_manager = sm,
        };
    }

    pub fn validate(self: *TransactionValidator, tx: *const core.transaction.Transaction) !ValidationResult {
        // 1. Validate signature
        const sig_valid = crypto.signature.verifySignature(tx) catch false;
        if (!sig_valid) {
            return .invalid_signature;
        }

        // 2. Get sender
        const sender = try tx.sender();

        // 3. Check nonce
        const expected_nonce = try self.state_manager.getNonce(sender);
        if (tx.nonce < expected_nonce) {
            return .invalid_nonce;
        }

        // 4. Check balance (for value transfer)
        if (tx.value > 0) {
            const balance = try self.state_manager.getBalance(sender);
            const total_cost = tx.value + (tx.gas_price * tx.gas_limit);
            if (balance < total_cost) {
                return .insufficient_balance;
            }
        }

        // 5. Check gas price (minimum threshold)
        if (tx.gas_price == 0) {
            return .invalid_gas_price;
        }

        return .valid;
    }
};

