const std = @import("std");
const types = @import("types.zig");
const block = @import("block.zig");

pub const Batch = struct {
    blocks: []block.Block,
    l1_tx_hash: ?types.Hash,
    l1_block_number: ?u64,
    created_at: u64,

    pub fn serialize(self: *const Batch, allocator: std.mem.Allocator) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        const created_at_bytes = std.mem.asBytes(&self.created_at);
        try list.appendSlice(created_at_bytes);
        for (self.blocks) |blk| {
            const block_bytes = std.mem.asBytes(&blk.number);
            try list.appendSlice(block_bytes);
            const block_hash = blk.hash();
            const block_hash_bytes = types.hashToBytes(block_hash);
            try list.appendSlice(&block_hash_bytes);
        }

        return list.toOwnedSlice();
    }
};
