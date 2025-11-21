// Reorg Handler
// Handles chain reorganizations for L1 and L2 chains (op-node style)

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const block_state = @import("block_state.zig");

pub const ReorgHandler = struct {
    allocator: std.mem.Allocator,
    block_state: *block_state.BlockState,
    // Store recent L1 block hashes for reorg detection
    l1_block_hashes: std.HashMap(u64, types.Hash, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    max_stored_blocks: u64 = 100, // Store last 100 blocks for reorg detection

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, bs: *block_state.BlockState) Self {
        return .{
            .allocator = allocator,
            .block_state = bs,
            .l1_block_hashes = std.HashMap(u64, types.Hash, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.l1_block_hashes.deinit();
    }

    /// Store L1 block hash for reorg detection
    pub fn storeL1BlockHash(self: *Self, block_number: u64, block_hash: types.Hash) !void {
        try self.l1_block_hashes.put(block_number, block_hash);

        // Clean up old blocks (keep only last max_stored_blocks)
        if (self.l1_block_hashes.count() > self.max_stored_blocks) {
            var to_remove = std.ArrayList(u64).init(self.allocator);
            defer to_remove.deinit();

            var it = self.l1_block_hashes.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* < block_number - self.max_stored_blocks) {
                    try to_remove.append(entry.key_ptr.*);
                }
            }

            for (to_remove.items) |block_num| {
                _ = self.l1_block_hashes.remove(block_num);
            }
        }
    }

    /// Detect L1 reorg by comparing block hashes
    /// Returns common ancestor block number if reorg detected, null otherwise
    pub fn detectL1Reorg(self: *Self, expected_block_number: u64, actual_block_hash: types.Hash) !?u64 {
        // Check if we have stored hash for this block
        if (self.l1_block_hashes.get(expected_block_number)) |expected_hash| {
            // Compare hashes
            if (!std.mem.eql(u8, &types.hashToBytes(expected_hash), &types.hashToBytes(actual_block_hash))) {
                std.log.warn("[ReorgHandler] L1 reorg detected at block #{d}", .{expected_block_number});

                // Find common ancestor by checking previous blocks
                var check_block = expected_block_number;
                while (check_block > 0) : (check_block -= 1) {
                    if (self.l1_block_hashes.get(check_block)) |_| {
                        // Found a stored block, assume it's the common ancestor
                        return check_block;
                    }
                }

                // No common ancestor found, return genesis
                return 0;
            }
        }

        // Store this block hash for future reorg detection
        try self.storeL1BlockHash(expected_block_number, actual_block_hash);

        return null; // No reorg detected
    }

    /// Detect L2 reorg by comparing block hashes
    /// Returns common ancestor block number if reorg detected, null otherwise
    pub fn detectL2Reorg(self: *Self, expected_block_number: u64, actual_block_hash: types.Hash) !?u64 {
        // Get current head block
        const head_hash = self.block_state.getHeadBlockHash();

        if (head_hash) |current_hash| {
            // Compare with expected hash
            if (!std.mem.eql(u8, &types.hashToBytes(current_hash), &types.hashToBytes(actual_block_hash))) {
                std.log.warn("[ReorgHandler] L2 reorg detected at block #{d}", .{expected_block_number});

                // For now, return previous block as common ancestor
                // In production, would traverse chain to find actual common ancestor
                if (expected_block_number > 0) {
                    return expected_block_number - 1;
                }
                return 0; // Genesis
            }
        }

        return null; // No reorg detected
    }

    /// Handle L2 reorg by resetting block state
    pub fn handleL2Reorg(self: *Self, common_ancestor: u64) !void {
        std.log.warn("[ReorgHandler] L2 reorg detected, resetting to block #{d}", .{common_ancestor});

        // Reset head block to common ancestor
        // In production, would:
        // 1. Fetch block at common ancestor from storage
        // 2. Reset head block to that block
        // 3. Reset safe/unsafe blocks if they're after common ancestor
        // 4. Clear blocks after common ancestor

        // For now, just log the reorg
        // Full implementation would require block storage/retrieval
        _ = self;
    }
};
