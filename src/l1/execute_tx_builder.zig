// ExecuteTx builder for creating ExecuteTx transactions from batches
// Converts batches to ExecuteTx format for L1 submission

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const batch_module = @import("../core/batch.zig");
const witness_builder_module = @import("../core/witness_builder.zig");
const state = @import("../state/root.zig");
const sequencer_module = @import("../sequencer/root.zig");

pub const ExecuteTxBuilder = struct {
    allocator: std.mem.Allocator,
    chain_id: u64,
    sequencer_address: types.Address,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, chain_id: u64, sequencer_address: types.Address) Self {
        return .{
            .allocator = allocator,
            .chain_id = chain_id,
            .sequencer_address = sequencer_address,
        };
    }

    /// Build ExecuteTx from batch
    /// This creates an ExecuteTx transaction that includes:
    /// - Pre-state hash (from state manager)
    /// - Witness data (generated from batch execution)
    /// - Block context (coinbase, block number, timestamp)
    /// - Batch data as transaction data
    pub fn buildExecuteTxFromBatch(
        self: *Self,
        batch: *const batch_module.Batch,
        state_manager: *const state.StateManager,
        sequencer: *const sequencer_module.Sequencer,
        nonce: u64,
        gas_tip_cap: u256,
        gas_fee_cap: u256,
        gas_limit: u64,
    ) !core.transaction_execute.ExecuteTx {
        // Get pre-state hash from state manager
        const pre_state_hash = try self.getPreStateHash(state_manager);

        // Generate witness for the batch
        var witness_builder = witness_builder_module.WitnessBuilder.init(self.allocator);
        defer witness_builder.deinit();

        // Process all blocks in batch to build witness
        // Note: We need a mutable reference to execution_engine for witness tracking
        // Create a temporary mutable copy of the execution engine
        if (batch.blocks.len > 0) {
            var temp_exec_engine = sequencer.execution_engine;
            temp_exec_engine.witness_builder = &witness_builder;
            for (batch.blocks) |block| {
                try witness_builder.generateBlockWitness(&block, &temp_exec_engine);
            }
        }

        // Build witness
        _ = try witness_builder.buildWitness(state_manager, null);
        const witness_rlp = try witness_builder.witness.encodeRLP(self.allocator);
        defer self.allocator.free(witness_rlp);

        // Serialize batch data
        const batch_data = try batch.serialize(self.allocator);
        defer self.allocator.free(batch_data);

        // Get block context from first block (or use defaults)
        const BlockContext = struct {
            coinbase: types.Address,
            block_number: u64,
            timestamp: u64,
        };
        const block_context: BlockContext = if (batch.blocks.len > 0) BlockContext{
            .coinbase = self.sequencer_address,
            .block_number = batch.blocks[0].number,
            .timestamp = batch.blocks[0].timestamp,
        } else BlockContext{
            .coinbase = self.sequencer_address,
            .block_number = 0,
            .timestamp = @as(u64, @intCast(std.time.timestamp())),
        };

        // Create ExecuteTx
        const execute_tx = core.transaction_execute.ExecuteTx{
            .chain_id = self.chain_id,
            .nonce = nonce,
            .gas_tip_cap = gas_tip_cap,
            .gas_fee_cap = gas_fee_cap,
            .gas = gas_limit,
            .to = null, // ExecuteTx targets the EXECUTE precompile
            .value = 0,
            .data = batch_data,
            .pre_state_hash = pre_state_hash,
            .witness_size = @intCast(witness_rlp.len),
            .withdrawals_size = 0, // No withdrawals for now
            .coinbase = block_context.coinbase,
            .block_number = block_context.block_number,
            .timestamp = block_context.timestamp,
            .witness = try self.allocator.dupe(u8, witness_rlp),
            .withdrawals = &[_]u8{},
            .blob_hashes = &[_]types.Hash{},
            .v = 0,
            .r = 0,
            .s = 0,
        };

        return execute_tx;
    }

    /// Get pre-state hash from state manager
    fn getPreStateHash(_: *Self, _: *const state.StateManager) !types.Hash {
        // In a full implementation, this would compute the state root hash
        // For now, return a placeholder (in production, compute from state trie)
        return types.hashFromBytes([_]u8{0} ** 32);
    }
};
