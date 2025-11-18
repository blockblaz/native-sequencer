const std = @import("std");
const core = @import("../core/root.zig");
const mempool = @import("../mempool/root.zig");
const batch = @import("../batch/root.zig");
const state = @import("../state/root.zig");
const config = @import("../config/root.zig");
const mev = @import("mev.zig");

pub const Sequencer = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    mempool: *mempool.Mempool,
    state_manager: *state.StateManager,
    batch_builder: *batch.Builder,
    mev_orderer: mev.MEVOrderer,
    current_block_number: u64 = 0,
    parent_hash: core.types.Hash = core.types.hashFromBytes([_]u8{0} ** 32),

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config, mp: *mempool.Mempool, sm: *state.StateManager, bb: *batch.Builder) Sequencer {
        return .{
            .allocator = allocator,
            .config = cfg,
            .mempool = mp,
            .state_manager = sm,
            .batch_builder = bb,
            .mev_orderer = mev.MEVOrderer.init(allocator),
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
        var valid_txs = std.array_list.Managed(core.transaction.Transaction).init(self.allocator);
        defer valid_txs.deinit();

        for (mev_txs) |tx| {
            // Light simulation check
            const expected_nonce = try self.state_manager.getNonce(try tx.sender());
            if (tx.nonce != expected_nonce) continue;

            if (gas_used + tx.gas_limit > self.config.block_gas_limit) break;

            // Apply transaction (simplified - in production run full execution)
            _ = try self.state_manager.applyTransaction(tx, tx.gas_limit);
            gas_used += tx.gas_limit;
            try valid_txs.append(tx);

            // Remove from mempool
            const tx_hash = try tx.hash(self.allocator);
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
