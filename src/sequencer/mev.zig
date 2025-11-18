const std = @import("std");
const core = @import("../core/root.zig");

pub const MEVOrderer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MEVOrderer {
        return .{ .allocator = allocator };
    }

    pub fn order(self: *MEVOrderer, txs: []core.transaction.Transaction) ![]core.transaction.Transaction {
        // Simplified MEV - in production implement bundle detection, backrunning, etc.
        // For now, just return sorted by priority
        // Use ArrayList to avoid allocator issues with Transaction slices
        var sorted = std.ArrayList(core.transaction.Transaction).init(self.allocator);
        errdefer sorted.deinit();
        try sorted.appendSlice(txs);

        // Sort by priority (gas price) descending
        std.mem.sort(core.transaction.Transaction, sorted.items, {}, struct {
            fn compare(_: void, a: core.transaction.Transaction, b: core.transaction.Transaction) bool {
                return a.priority() > b.priority();
            }
        }.compare);

        return sorted.toOwnedSlice();
    }
};
