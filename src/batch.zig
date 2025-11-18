const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");

pub const BatchBuilder = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    blocks: std.ArrayList(types.Block),

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) BatchBuilder {
        return .{
            .allocator = allocator,
            .config = cfg,
            .blocks = std.ArrayList(types.Block).init(allocator),
        };
    }

    pub fn deinit(self: *BatchBuilder) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block.transactions);
        }
        self.blocks.deinit();
    }

    pub fn addBlock(self: *BatchBuilder, block: types.Block) !void {
        try self.blocks.append(block);
    }

    pub fn buildBatch(self: *BatchBuilder) !types.Batch {
        const blocks = try self.blocks.toOwnedSlice();
        return types.Batch{
            .blocks = blocks,
            .l1_tx_hash = null,
            .l1_block_number = null,
            .created_at = @intCast(std.time.timestamp()),
        };
    }

    pub fn clear(self: *BatchBuilder) void {
        for (self.blocks.items) |block| {
            self.allocator.free(block.transactions);
        }
        self.blocks.clearAndFree();
    }

    pub fn shouldFlush(self: *const BatchBuilder) bool {
        return self.blocks.items.len >= self.config.batch_size_limit;
    }
};

