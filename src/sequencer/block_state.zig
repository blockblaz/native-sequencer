// Block State Management (Safe/Unsafe blocks)
// Tracks safe blocks (derived from L1) and unsafe blocks (sequencer-proposed)

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");

pub const BlockState = struct {
    allocator: std.mem.Allocator,
    safe_block: ?core.block.Block = null,
    unsafe_block: ?core.block.Block = null,
    finalized_block: ?core.block.Block = null,
    head_block: ?core.block.Block = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .safe_block = null,
            .unsafe_block = null,
            .finalized_block = null,
            .head_block = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.safe_block) |*block| {
            self.allocator.free(block.transactions);
        }
        if (self.unsafe_block) |*block| {
            self.allocator.free(block.transactions);
        }
        if (self.finalized_block) |*block| {
            self.allocator.free(block.transactions);
        }
        if (self.head_block) |*block| {
            self.allocator.free(block.transactions);
        }
    }

    /// Set safe block (derived from L1)
    pub fn setSafeBlock(self: *Self, block: core.block.Block) !void {
        // Free old safe block
        if (self.safe_block) |*old_block| {
            self.allocator.free(old_block.transactions);
        }

        // Clone block
        const transactions = try self.allocator.dupe(core.transaction.Transaction, block.transactions);
        var safe_block = block;
        safe_block.transactions = transactions;

        self.safe_block = safe_block;
        std.log.info("[BlockState] Safe block updated to #{d}", .{block.number});
    }

    /// Set unsafe block (sequencer-proposed)
    pub fn setUnsafeBlock(self: *Self, block: core.block.Block) !void {
        // Free old unsafe block
        if (self.unsafe_block) |*old_block| {
            self.allocator.free(old_block.transactions);
        }

        // Clone block
        const transactions = try self.allocator.dupe(core.transaction.Transaction, block.transactions);
        var unsafe_block = block;
        unsafe_block.transactions = transactions;

        self.unsafe_block = unsafe_block;
        std.log.info("[BlockState] Unsafe block updated to #{d}", .{block.number});
    }

    /// Set finalized block
    pub fn setFinalizedBlock(self: *Self, block: core.block.Block) !void {
        // Free old finalized block
        if (self.finalized_block) |*old_block| {
            self.allocator.free(old_block.transactions);
        }

        // Clone block
        const transactions = try self.allocator.dupe(core.transaction.Transaction, block.transactions);
        var finalized_block = block;
        finalized_block.transactions = transactions;

        self.finalized_block = finalized_block;
        std.log.info("[BlockState] Finalized block updated to #{d}", .{block.number});
    }

    /// Set head block
    pub fn setHeadBlock(self: *Self, block: core.block.Block) !void {
        // Free old head block
        if (self.head_block) |*old_block| {
            self.allocator.free(old_block.transactions);
        }

        // Clone block
        const transactions = try self.allocator.dupe(core.transaction.Transaction, block.transactions);
        var head_block = block;
        head_block.transactions = transactions;

        self.head_block = head_block;
        std.log.info("[BlockState] Head block updated to #{d}", .{block.number});
    }

    /// Get safe block
    pub fn getSafeBlock(self: *const Self) ?core.block.Block {
        return self.safe_block;
    }

    /// Get unsafe block
    pub fn getUnsafeBlock(self: *const Self) ?core.block.Block {
        return self.unsafe_block;
    }

    /// Get finalized block
    pub fn getFinalizedBlock(self: *const Self) ?core.block.Block {
        return self.finalized_block;
    }

    /// Get head block
    pub fn getHeadBlock(self: *const Self) ?core.block.Block {
        return self.head_block;
    }

    /// Get safe block hash
    pub fn getSafeBlockHash(self: *const Self) ?types.Hash {
        if (self.safe_block) |block| {
            return block.hash();
        }
        return null;
    }

    /// Get unsafe block hash
    pub fn getUnsafeBlockHash(self: *const Self) ?types.Hash {
        if (self.unsafe_block) |block| {
            return block.hash();
        }
        return null;
    }

    /// Get finalized block hash
    pub fn getFinalizedBlockHash(self: *const Self) ?types.Hash {
        if (self.finalized_block) |block| {
            return block.hash();
        }
        return null;
    }

    /// Get head block hash
    pub fn getHeadBlockHash(self: *const Self) ?types.Hash {
        if (self.head_block) |block| {
            return block.hash();
        }
        return null;
    }
};
