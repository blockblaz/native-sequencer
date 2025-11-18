const std = @import("std");
const core = @import("../core/root.zig");
const mempool = @import("../mempool/root.zig");
const batch = @import("../batch/root.zig");
const state = @import("../state/root.zig");
const config = @import("../config/root.zig");
const mev = @import("mev.zig");
const execution = @import("execution.zig");

fn formatHash(hash: core.types.Hash) []const u8 {
    // Format hash as hex string for logging
    const bytes = hash.toBytes();
    var buffer: [66]u8 = undefined; // "0x" + 64 hex chars
    buffer[0] = '0';
    buffer[1] = 'x';
    // Format each byte as hex
    for (bytes, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        buffer[2 + i * 2] = hex_chars[byte >> 4];
        buffer[2 + i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return buffer[0..66];
}

pub const Sequencer = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    mempool: *mempool.Mempool,
    state_manager: *state.StateManager,
    batch_builder: *batch.Builder,
    mev_orderer: mev.MEVOrderer,
    current_block_number: u64 = 0,
    parent_hash: core.types.Hash = core.types.hashFromBytes([_]u8{0} ** 32),

    execution_engine: execution.ExecutionEngine,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config, mp: *mempool.Mempool, sm: *state.StateManager, bb: *batch.Builder) Sequencer {
        return .{
            .allocator = allocator,
            .config = cfg,
            .mempool = mp,
            .state_manager = sm,
            .batch_builder = bb,
            .mev_orderer = mev.MEVOrderer.init(allocator),
            .execution_engine = execution.ExecutionEngine.init(allocator, sm),
        };
    }

    pub fn buildBlock(self: *Sequencer) !core.block.Block {
        // Get top transactions from mempool
        const txs = try self.mempool.getTopN(self.config.block_gas_limit, self.config.batch_size_limit);
        defer self.allocator.free(txs);

        // Apply MEV ordering
        const mev_txs = try self.mev_orderer.order(txs);
        defer self.allocator.free(mev_txs);

        // Build block
        var gas_used: u64 = 0;
        var valid_txs = std.ArrayList(core.transaction.Transaction).init(self.allocator);
        defer valid_txs.deinit();

        for (mev_txs) |tx| {
            // Check if transaction fits in block gas limit
            const estimated_gas = tx.gas_limit;
            if (gas_used + estimated_gas > self.config.block_gas_limit) break;

            // Execute transaction
            const exec_result = self.execution_engine.executeTransaction(tx) catch |err| {
                std.log.warn("Transaction execution error: {any}", .{err});
                continue;
            };

            // Skip failed transactions
            if (!exec_result.success) {
                const tx_hash = tx.hash(self.allocator) catch continue;
                std.log.warn("Transaction execution failed (hash={s}, gas_used={d})", .{ formatHash(tx_hash), exec_result.gas_used });
                continue;
            }

            // Check if execution fits in block gas limit
            if (gas_used + exec_result.gas_used > self.config.block_gas_limit) break;

            // Apply state changes (execution engine already updated state)
            // Create receipt
            const tx_hash = try tx.hash(self.allocator);
            _ = try self.state_manager.applyTransaction(tx, exec_result.gas_used);

            gas_used += exec_result.gas_used;
            try valid_txs.append(tx);

            // Remove from mempool
            // tx_hash is U256 struct (not allocated), no need to free
            _ = try self.mempool.remove(tx_hash);
        }

        const block = core.block.Block{
            .number = self.current_block_number,
            .parent_hash = self.parent_hash,
            .timestamp = @intCast(std.time.timestamp()),
            .transactions = try valid_txs.toOwnedSlice(),
            .gas_used = gas_used,
            .gas_limit = self.config.block_gas_limit,
            .state_root = core.types.hashFromBytes([_]u8{0} ** 32), // In production, compute from state
            .receipts_root = core.types.hashFromBytes([_]u8{0} ** 32), // In production, compute from receipts
            .logs_bloom = [_]u8{0} ** 256,
        };

        try self.state_manager.finalizeBlock(block);
        self.parent_hash = block.hash();
        self.current_block_number += 1;

        return block;
    }
};
