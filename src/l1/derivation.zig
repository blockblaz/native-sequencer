// L1 Derivation Pipeline
// Derives L2 blocks from L1 blocks and receipts (op-node style)

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const client = @import("client.zig");
const batch_parser = @import("batch_parser.zig");

pub const DerivedL2Data = struct {
    block_number: u64,
    transactions: []core.transaction.Transaction,
    timestamp: u64,
    l1_block_number: u64,
    l1_block_hash: types.Hash,
};

pub const L1Derivation = struct {
    allocator: std.mem.Allocator,
    l1_client: *client.Client,
    batch_parser: batch_parser.BatchParser,
    current_l1_block: u64 = 0,
    safe_l2_block: u64 = 0,
    last_derived_l1_block: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, l1_cli: *client.Client) Self {
        return .{
            .allocator = allocator,
            .l1_client = l1_cli,
            .batch_parser = batch_parser.BatchParser.init(allocator, null), // TODO: Set batch inbox address
            .current_l1_block = 0,
            .safe_l2_block = 0,
            .last_derived_l1_block = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed
    }

    /// Get current L1 block number
    pub fn getCurrentL1Block(self: *Self) !u64 {
        // Use L1 client's getLatestBlockNumber method
        const block_number = try self.l1_client.getLatestBlockNumber();
        self.current_l1_block = block_number;
        return block_number;
    }

    /// Derive L2 data from L1 block
    /// Parses batches from L1 transactions and extracts L2 transactions
    pub fn deriveL2FromL1(self: *Self, l1_block_number: u64) !?DerivedL2Data {
        // Skip if already derived this block
        if (l1_block_number <= self.last_derived_l1_block) {
            return null;
        }

        // Get L1 block with transactions
        const l1_block = self.l1_client.getBlockByNumber(l1_block_number, true) catch |err| {
            std.log.warn("[L1Derivation] Failed to get L1 block #{d}: {any}, using simplified derivation", .{ l1_block_number, err });
            // Fallback to simplified derivation
            return self.deriveL2FromL1Simplified(l1_block_number);
        };
        defer {
            // Free transaction data
            for (l1_block.transactions) |tx| {
                if (tx.to) |to| self.allocator.free(to);
                self.allocator.free(tx.data);
            }
            self.allocator.free(l1_block.transactions);
        }

        // Derive L2 block number (1:1 with L1 for now, can be adjusted)
        const l2_block_number = l1_block_number;

        // Parse batches from L1 transactions
        var all_l2_txs = std.ArrayList(core.transaction.Transaction).init(self.allocator);
        defer {
            for (all_l2_txs.items) |*tx| {
                self.allocator.free(tx.data);
            }
            all_l2_txs.deinit();
        }

        // Filter transactions to batch inbox address (if configured)
        // For now, parse all transactions as potential batches
        for (l1_block.transactions) |l1_tx| {
            // Parse batch from transaction calldata
            const batch_data_opt = self.batch_parser.parseBatchFromL1Tx(l1_tx.data) catch |err| {
                // Failed to parse batch, skip this transaction
                std.log.debug("[L1Derivation] Failed to parse batch from L1 tx: {any}", .{err});
                continue;
            };

            if (batch_data_opt) |bd| {
                var batch_data = bd; // Make mutable copy
                defer batch_data.deinit();

                // Extract L2 transactions from batch
                const l2_txs = self.batch_parser.extractL2Transactions(batch_data) catch continue;
                defer {
                    for (l2_txs) |*tx| {
                        self.allocator.free(tx.data);
                    }
                    self.allocator.free(l2_txs);
                }

                // Add to aggregated list
                for (l2_txs) |tx| {
                    const data_copy = try self.allocator.dupe(u8, tx.data);
                    try all_l2_txs.append(core.transaction.Transaction{
                        .nonce = tx.nonce,
                        .gas_price = tx.gas_price,
                        .gas_limit = tx.gas_limit,
                        .to = tx.to,
                        .value = tx.value,
                        .data = data_copy,
                        .v = tx.v,
                        .r = tx.r,
                        .s = tx.s,
                    });
                }
            } else {
                // No batch data, skip this transaction
                continue;
            }
        }

        self.last_derived_l1_block = l1_block_number;

        return DerivedL2Data{
            .block_number = l2_block_number,
            .transactions = try all_l2_txs.toOwnedSlice(),
            .timestamp = l1_block.timestamp,
            .l1_block_number = l1_block_number,
            .l1_block_hash = l1_block.hash,
        };
    }

    /// Simplified derivation (fallback when block fetching fails)
    fn deriveL2FromL1Simplified(self: *Self, l1_block_number: u64) !?DerivedL2Data {
        const l2_block_number = l1_block_number;
        const transactions = try self.allocator.alloc(core.transaction.Transaction, 0);
        const l1_hash = types.hashFromBytes([_]u8{0} ** 32);

        self.last_derived_l1_block = l1_block_number;

        return DerivedL2Data{
            .block_number = l2_block_number,
            .transactions = transactions,
            .timestamp = @intCast(std.time.timestamp()),
            .l1_block_number = l1_block_number,
            .l1_block_hash = l1_hash,
        };
    }

    /// Handle L1 reorg (chain reorganization)
    /// Resets derivation state to common ancestor
    pub fn handleReorg(self: *Self, new_l1_block: u64, common_ancestor: u64) !void {
        std.log.warn("[L1Derivation] L1 reorg detected: new_block={d}, common_ancestor={d}", .{ new_l1_block, common_ancestor });

        // Reset derivation state to common ancestor
        if (common_ancestor < self.last_derived_l1_block) {
            self.last_derived_l1_block = common_ancestor;
            self.current_l1_block = common_ancestor;

            // Reset safe L2 block to match common ancestor
            if (common_ancestor < self.safe_l2_block) {
                self.safe_l2_block = common_ancestor;
            }
        }
    }

    /// Update safe block (fully derived from L1)
    pub fn updateSafeBlock(self: *Self, l2_block_number: u64) void {
        if (l2_block_number > self.safe_l2_block) {
            self.safe_l2_block = l2_block_number;
        }
    }

    /// Get safe L2 block number
    pub fn getSafeBlock(self: *Self) u64 {
        return self.safe_l2_block;
    }

    fn hexToHash(self: *Self, hex: []const u8) !types.Hash {
        _ = self;
        const hex_start: usize = if (std.mem.startsWith(u8, hex, "0x")) 2 else 0;
        const hex_data = hex[hex_start..];

        if (hex_data.len != 64) {
            return error.InvalidHashLength;
        }

        var result: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const high = try std.fmt.parseInt(u8, hex_data[i * 2 .. i * 2 + 1], 16);
            const low = try std.fmt.parseInt(u8, hex_data[i * 2 + 1 .. i * 2 + 2], 16);
            result[i] = (high << 4) | low;
        }

        return types.hashFromBytes(result);
    }
};
