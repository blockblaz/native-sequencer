const std = @import("std");
const core = @import("../core/root.zig");
const mempool = @import("../mempool/root.zig");
const state = @import("../state/root.zig");
const validator = @import("transaction.zig");

pub const Ingress = struct {
    allocator: std.mem.Allocator,
    mempool: *mempool.Mempool,
    validator: validator.TransactionValidator,

    pub fn init(allocator: std.mem.Allocator, mp: *mempool.Mempool, sm: *state.StateManager) Ingress {
        return .{
            .allocator = allocator,
            .mempool = mp,
            .validator = validator.TransactionValidator.init(allocator, sm),
        };
    }

    pub fn acceptTransaction(self: *Ingress, tx: core.transaction.Transaction) !validator.ValidationResult {
        // Validate transaction
        const result = try self.validator.validate(&tx);
        if (result != .valid) {
            return result;
        }

        // Check if duplicate in mempool
        const tx_hash = try tx.hash(self.allocator);
        // tx_hash is u256 (not allocated), no need to free
        if (self.mempool.contains(tx_hash)) {
            return .duplicate;
        }

        // Insert into mempool
        const inserted = try self.mempool.insert(tx);
        if (!inserted) {
            return .duplicate;
        }

        return .valid;
    }

    /// Accept ExecuteTx transaction
    /// ExecuteTx transactions are stateless and should be forwarded to L1 geth
    /// We only do minimal validation (signature check for deduplication)
    /// Full validation will be done by L1 geth when the transaction is executed
    pub fn acceptExecuteTx(self: *Ingress, execute_tx: *core.transaction_execute.ExecuteTx) !validator.ValidationResult {
        // Minimal validation: check signature for deduplication purposes
        // We don't validate nonce/balance since ExecuteTx is stateless and L1 geth will validate it
        _ = execute_tx.sender(self.allocator) catch {
            return .invalid_signature;
        };

        // Check if duplicate in mempool (by hash)
        const tx_hash = try execute_tx.hash(self.allocator);
        if (self.mempool.contains(tx_hash)) {
            return .duplicate;
        }

        // ExecuteTx transactions are forwarded to L1 geth, not stored in mempool
        // They will be sent directly to L1 via eth_sendRawTransaction

        return .valid;
    }

    pub fn validateBatch(self: *Ingress, txs: []core.transaction.Transaction) ![]validator.ValidationResult {
        // Use ArrayList to avoid allocator issues
        var results = std.ArrayList(validator.ValidationResult).init(self.allocator);
        defer results.deinit();
        errdefer results.deinit();

        for (txs) |tx| {
            const result = self.acceptTransaction(tx) catch |err| {
                _ = err;
                try results.append(.invalid_signature); // Default error
                continue;
            };
            try results.append(result);
        }
        return results.toOwnedSlice();
    }
};
