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
        // tx_hash is U256 struct (not allocated), no need to free
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

    pub fn validateBatch(self: *Ingress, txs: []core.transaction.Transaction) ![]validator.ValidationResult {
        // Use ArrayList to avoid allocator issues
        var results = std.array_list.Managed(validator.ValidationResult).init(self.allocator);
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

