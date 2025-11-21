// L1 Batch Parser
// Parses L2 batch data from L1 transaction calldata (op-node style)

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const rlp = @import("../core/rlp.zig");

pub const BatchData = struct {
    l2_transactions: []core.transaction.Transaction,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchData) void {
        for (self.l2_transactions) |*tx| {
            self.allocator.free(tx.data);
        }
        self.allocator.free(self.l2_transactions);
    }
};

pub const BatchParser = struct {
    allocator: std.mem.Allocator,
    batch_inbox_address: ?types.Address,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, batch_inbox_address: ?types.Address) Self {
        return .{
            .allocator = allocator,
            .batch_inbox_address = batch_inbox_address,
        };
    }

    /// Parse batch from L1 transaction calldata
    /// In Optimism, batches are submitted to a batch inbox contract
    /// The calldata contains RLP-encoded L2 transactions
    pub fn parseBatchFromL1Tx(self: *Self, l1_tx_calldata: []const u8) !?BatchData {
        // TODO: Implement full batch parsing
        // For now, return empty batch
        // In production, would:
        // 1. Decode RLP batch structure
        // 2. Extract L2 transactions from batch
        // 3. Validate batch structure
        // 4. Return parsed batch data

        _ = l1_tx_calldata; // Unused for now

        // Return empty batch for now
        return BatchData{
            .l2_transactions = try self.allocator.alloc(core.transaction.Transaction, 0),
            .allocator = self.allocator,
        };
    }

    /// Extract L2 transactions from batch data
    pub fn extractL2Transactions(self: *Self, batch: BatchData) ![]core.transaction.Transaction {
        // Clone transactions
        const txs = try self.allocator.alloc(core.transaction.Transaction, batch.l2_transactions.len);
        for (batch.l2_transactions, 0..) |tx, i| {
            const data_copy = try self.allocator.dupe(u8, tx.data);
            txs[i] = core.transaction.Transaction{
                .nonce = tx.nonce,
                .gas_price = tx.gas_price,
                .gas_limit = tx.gas_limit,
                .to = tx.to,
                .value = tx.value,
                .data = data_copy,
                .v = tx.v,
                .r = tx.r,
                .s = tx.s,
            };
        }
        return txs;
    }

    /// Validate batch structure
    pub fn validateBatch(self: *Self, batch: BatchData) bool {
        _ = self;
        // Basic validation: check that transactions are valid
        for (batch.l2_transactions) |tx| {
            // Validate transaction fields
            if (tx.gas_limit == 0) {
                return false;
            }
        }
        return true;
    }
};
