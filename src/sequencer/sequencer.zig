// Sequencer refactored for op-node style architecture
// Requests payloads from L2 geth instead of building blocks directly

const std = @import("std");
const core = @import("../core/root.zig");
const mempool = @import("../mempool/root.zig");
const batch = @import("../batch/root.zig");
const state = @import("../state/root.zig");
const config = @import("../config/root.zig");
const mev = @import("mev.zig");
const block_state = @import("block_state.zig");
const l1_derivation = @import("../l1/derivation.zig");
const l2_engine = @import("../l2/engine_api_client.zig");
const l2_payload = @import("../l2/payload_attrs.zig");
const types = @import("../core/types.zig");

pub const Sequencer = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    mempool: *mempool.Mempool,
    state_manager: *state.StateManager,
    batch_builder: *batch.Builder,
    mev_orderer: mev.MEVOrderer,
    current_block_number: u64 = 0,
    parent_hash: core.types.Hash = core.types.hashFromBytes([_]u8{0} ** 32),

    // op-node style components
    block_state: block_state.BlockState,
    l1_derivation: *l1_derivation.L1Derivation,
    engine_client: *l2_engine.EngineApiClient,
    payload_builder: l2_payload.PayloadAttributesBuilder,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *const config.Config,
        mp: *mempool.Mempool,
        sm: *state.StateManager,
        bb: *batch.Builder,
        derivation: *l1_derivation.L1Derivation,
        engine: *l2_engine.EngineApiClient,
    ) Sequencer {
        return .{
            .allocator = allocator,
            .config = cfg,
            .mempool = mp,
            .state_manager = sm,
            .batch_builder = bb,
            .mev_orderer = mev.MEVOrderer.init(allocator),
            .block_state = block_state.BlockState.init(allocator),
            .l1_derivation = derivation,
            .engine_client = engine,
            .payload_builder = l2_payload.PayloadAttributesBuilder.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.block_state.deinit();
    }

    /// Request payload from L2 geth (op-node style)
    /// Returns payload_id if successful
    pub fn requestPayload(self: *Self) !?[]const u8 {
        // Get transactions from mempool (check conditional transaction conditions)
        const current_block = if (self.block_state.head_block) |head| head.number else self.current_block_number;
        const current_timestamp = @as(u64, @intCast(std.time.timestamp()));
        const txs = try self.mempool.getTopN(self.config.block_gas_limit, self.config.batch_size_limit, current_block, current_timestamp);
        defer self.allocator.free(txs);

        // Apply MEV ordering
        const mev_txs = try self.mev_orderer.order(txs);
        defer self.allocator.free(mev_txs);

        // Build payload attributes
        const fee_recipient = types.addressFromBytes([_]u8{0} ** 20); // Default coinbase
        var payload_attrs = try self.payload_builder.build(mev_txs, fee_recipient);
        defer payload_attrs.deinit(self.allocator);

        // Convert to JSON-RPC format
        const payload_attrs_json = try self.payload_builder.toJsonRpc(payload_attrs);
        // Note: payload_attrs_json ownership is transferred to forkchoiceUpdated
        // It will be deinitialized in forkchoiceUpdated's defer block

        // Get fork choice state
        const head_hash = self.block_state.getHeadBlockHash() orelse self.parent_hash;
        const safe_hash = self.block_state.getSafeBlockHash() orelse self.parent_hash;
        const finalized_hash = self.block_state.getFinalizedBlockHash() orelse self.parent_hash;

        // Request payload via engine_forkchoiceUpdatedV3
        // payload_attrs_json is moved into params array and will be deinitialized there
        const response = try self.engine_client.forkchoiceUpdated(head_hash, safe_hash, finalized_hash, payload_attrs_json);

        if (response.payload_id) |payload_id| {
            std.log.info("[Sequencer] Payload requested, payload_id: {s}", .{payload_id});
            return payload_id;
        }

        return null;
    }

    /// Get built payload from L2 geth
    pub fn getPayload(self: *Self, payload_id: []const u8) !l2_engine.EngineApiClient.ExecutionPayload {
        return try self.engine_client.getPayload(payload_id);
    }

    /// Convert execution payload to block
    pub fn payloadToBlock(self: *Self, payload: l2_engine.EngineApiClient.ExecutionPayload) !core.block.Block {
        // Parse transactions from RLP hex
        var transactions = std.ArrayList(core.transaction.Transaction).init(self.allocator);
        errdefer {
            for (transactions.items) |*tx| {
                self.allocator.free(tx.data);
            }
            transactions.deinit();
        }

        // Parse each transaction from RLP hex string
        for (payload.transactions) |tx_hex| {
            // Convert hex string to bytes
            const tx_bytes = try self.hexToBytes(tx_hex);
            defer self.allocator.free(tx_bytes);

            // Decode transaction from RLP
            const tx = core.transaction.Transaction.fromRaw(self.allocator, tx_bytes) catch |err| {
                std.log.warn("[Sequencer] Failed to parse transaction from payload: {any}, skipping", .{err});
                continue; // Skip invalid transactions
            };

            try transactions.append(tx);
        }

        const block = core.block.Block{
            .number = payload.block_number,
            .parent_hash = payload.parent_hash,
            .timestamp = payload.timestamp,
            .transactions = try transactions.toOwnedSlice(),
            .gas_used = payload.gas_used,
            .gas_limit = payload.gas_limit,
            .state_root = payload.state_root,
            .receipts_root = payload.receipts_root,
            .logs_bloom = payload.logs_bloom,
        };

        return block;
    }

    /// Update safe block from L1 derivation
    pub fn updateSafeBlock(self: *Self, l1_block_number: u64) !void {
        // Derive L2 from L1
        if (try self.l1_derivation.deriveL2FromL1(l1_block_number)) |derived| {
            // Create block from derived data
            const block = core.block.Block{
                .number = derived.block_number,
                .parent_hash = self.parent_hash,
                .timestamp = derived.timestamp,
                .transactions = derived.transactions,
                .gas_used = 0,
                .gas_limit = self.config.block_gas_limit,
                .state_root = core.types.hashFromBytes([_]u8{0} ** 32),
                .receipts_root = core.types.hashFromBytes([_]u8{0} ** 32),
                .logs_bloom = [_]u8{0} ** 256,
            };

            try self.block_state.setSafeBlock(block);
            self.l1_derivation.updateSafeBlock(derived.block_number);
        }
    }

    /// Build unsafe block (sequencer-proposed, not yet on L1) - op-node style
    /// Requests payload from L2 geth instead of building directly
    pub fn buildBlock(self: *Self) !core.block.Block {
        // Request payload from L2 geth
        const payload_id_opt = self.requestPayload() catch |err| {
            // Log connection errors with more context
            if (err == error.ConnectionRefused) {
                std.log.warn("[Sequencer] L2 geth Engine API not available at {s}:{d}. Is L2 geth running?", .{ self.config.l2_rpc_url, self.config.l2_engine_api_port });
            }
            return err;
        };
        if (payload_id_opt) |payload_id| {
            // Get built payload
            var payload = try self.getPayload(payload_id);
            defer payload.deinit(self.allocator);

            // Convert to block
            const block = try self.payloadToBlock(payload);

            // Update unsafe block
            try self.block_state.setUnsafeBlock(block);

            // Update head
            try self.block_state.setHeadBlock(block);

            self.parent_hash = block.hash();
            self.current_block_number = block.number;

            // Remove transactions from mempool (they're now in the block)
            for (block.transactions) |tx| {
                const tx_hash = tx.hash(self.allocator) catch continue;
                _ = self.mempool.remove(tx_hash) catch {};
            }

            return block;
        }

        // Fallback: create empty block if payload request fails
        const block = core.block.Block{
            .number = self.current_block_number,
            .parent_hash = self.parent_hash,
            .timestamp = @intCast(std.time.timestamp()),
            .transactions = try self.allocator.alloc(core.transaction.Transaction, 0),
            .gas_used = 0,
            .gas_limit = self.config.block_gas_limit,
            .state_root = core.types.hashFromBytes([_]u8{0} ** 32),
            .receipts_root = core.types.hashFromBytes([_]u8{0} ** 32),
            .logs_bloom = [_]u8{0} ** 256,
        };

        self.parent_hash = block.hash();
        self.current_block_number += 1;

        return block;
    }

    fn hexToBytes(self: *Self, hex: []const u8) ![]u8 {
        const hex_start: usize = if (std.mem.startsWith(u8, hex, "0x")) 2 else 0;
        const hex_data = hex[hex_start..];

        if (hex_data.len % 2 != 0) {
            return error.InvalidHexLength;
        }

        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < hex_data.len) : (i += 2) {
            const high = try std.fmt.parseInt(u8, hex_data[i .. i + 1], 16);
            const low = try std.fmt.parseInt(u8, hex_data[i + 1 .. i + 2], 16);
            try result.append((high << 4) | low);
        }

        return result.toOwnedSlice();
    }
};
