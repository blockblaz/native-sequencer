const std = @import("std");
const types = @import("types.zig");
const transaction = @import("transaction.zig");

pub const MempoolEntry = struct {
    tx: transaction.Transaction,
    hash: types.Hash,
    priority: u256,
    received_at: u64,

    pub fn compare(_: void, a: MempoolEntry, b: MempoolEntry) std.math.Order {
        if (a.priority > b.priority) return .gt;
        if (a.priority < b.priority) return .lt;
        if (a.received_at < b.received_at) return .lt;
        if (a.received_at > b.received_at) return .gt;
        return .eq;
    }
};
