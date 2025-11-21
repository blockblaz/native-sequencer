const std = @import("std");
const core = @import("../core/root.zig");
const crypto = @import("../crypto/root.zig");
const state = @import("../state/root.zig");
const l2_state = @import("../l2/state_provider.zig");

pub const ValidationResult = enum {
    valid,
    invalid_signature,
    invalid_nonce,
    insufficient_gas,
    insufficient_balance,
    invalid_gas_price,
    duplicate,
    invalid_execute_tx,
};

pub const TransactionValidator = struct {
    allocator: std.mem.Allocator,
    state_manager: ?*state.StateManager, // Optional - kept for witness generation
    state_provider: ?*l2_state.StateProvider, // Optional - used for validation queries (op-node style)

    pub fn init(allocator: std.mem.Allocator, sm: ?*state.StateManager, sp: ?*l2_state.StateProvider) TransactionValidator {
        return .{
            .allocator = allocator,
            .state_manager = sm,
            .state_provider = sp,
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

        // 3. Check nonce - prefer state provider (L2 geth) over local state manager
        const expected_nonce: u64 = if (self.state_provider) |sp| blk: {
            // Query L2 geth for nonce (op-node style)
            break :blk sp.getNonce(sender, "latest") catch |err| {
                std.log.warn("[Validator] Failed to get nonce from L2 geth: {any}, falling back to local state", .{err});
                // Fallback to local state manager if available
                if (self.state_manager) |sm| {
                    break :blk try sm.getNonce(sender);
                } else {
                    return .invalid_nonce;
                }
            };
        } else if (self.state_manager) |sm| blk: {
            // Use local state manager as fallback
            break :blk try sm.getNonce(sender);
        } else {
            return error.NoStateSource;
        };

        if (tx.nonce < expected_nonce) {
            return .invalid_nonce;
        }

        // 4. Check balance (for value transfer) - prefer state provider (L2 geth)
        if (tx.value > 0) {
            const balance: u256 = if (self.state_provider) |sp| blk: {
                // Query L2 geth for balance (op-node style)
                break :blk sp.getBalance(sender, "latest") catch |err| {
                    std.log.warn("[Validator] Failed to get balance from L2 geth: {any}, falling back to local state", .{err});
                    // Fallback to local state manager if available
                    if (self.state_manager) |sm| {
                        break :blk try sm.getBalance(sender);
                    } else {
                        return .insufficient_balance;
                    }
                };
            } else if (self.state_manager) |sm| blk: {
                // Use local state manager as fallback
                break :blk try sm.getBalance(sender);
            } else {
                return error.NoStateSource;
            };

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

    // Note: ExecuteTx transactions are stateless and should be forwarded to L1 geth
    // We don't do full validation here - L1 geth will validate them when executed
    // Only minimal validation (signature check for deduplication) is done in acceptExecuteTx
};
