const std = @import("std");
const core = @import("../core/root.zig");
const config = @import("../config/root.zig");

pub const Builder = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    blocks: std.ArrayList(core.block.Block),

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) Builder {
        return .{
            .allocator = allocator,
            .config = cfg,
            .blocks = std.ArrayList(core.block.Block).init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block.transactions);
        }
        self.blocks.deinit();
    }

    pub fn addBlock(self: *Builder, block: core.block.Block) !void {
        try self.blocks.append(block);
    }

    pub fn buildBatch(self: *Builder) !core.batch.Batch {
        const blocks = try self.blocks.toOwnedSlice();
        return core.batch.Batch{
            .blocks = blocks,
            .l1_tx_hash = null,
            .l1_block_number = null,
            .created_at = @intCast(std.time.timestamp()),
        };
    }

    pub fn clear(self: *Builder) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block.transactions);
        }
        self.blocks.clearAndFree();
    }

    pub fn shouldFlush(self: *const Builder) bool {
        return self.blocks.items.len >= self.config.batch_size_limit;
    }
};

