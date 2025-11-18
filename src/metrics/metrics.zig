const std = @import("std");

pub const Metrics = struct {
    allocator: std.mem.Allocator,
    transactions_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    transactions_accepted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    transactions_rejected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    blocks_created: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    batches_submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    mempool_size: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    l1_submission_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator) Metrics {
        return Metrics{ .allocator = allocator };
    }

    pub fn incrementTransactionsReceived(self: *Metrics) void {
        _ = self.transactions_received.fetchAdd(1, .monotonic);
    }

    pub fn incrementTransactionsAccepted(self: *Metrics) void {
        _ = self.transactions_accepted.fetchAdd(1, .monotonic);
    }

    pub fn incrementTransactionsRejected(self: *Metrics) void {
        _ = self.transactions_rejected.fetchAdd(1, .monotonic);
    }

    pub fn incrementBlocksCreated(self: *Metrics) void {
        _ = self.blocks_created.fetchAdd(1, .monotonic);
    }

    pub fn incrementBatchesSubmitted(self: *Metrics) void {
        _ = self.batches_submitted.fetchAdd(1, .monotonic);
    }

    pub fn setMempoolSize(self: *Metrics, size: u64) void {
        _ = self.mempool_size.store(size, .monotonic);
    }

    pub fn incrementL1SubmissionErrors(self: *Metrics) void {
        _ = self.l1_submission_errors.fetchAdd(1, .monotonic);
    }

    pub fn format(self: *const Metrics, writer: anytype) !void {
        try writer.print(
            \\# Sequencer Metrics
            \\transactions_received: {d}
            \\transactions_accepted: {d}
            \\transactions_rejected: {d}
            \\blocks_created: {d}
            \\batches_submitted: {d}
            \\mempool_size: {d}
            \\l1_submission_errors: {d}
            \\
        , .{
            self.transactions_received.load(.monotonic),
            self.transactions_accepted.load(.monotonic),
            self.transactions_rejected.load(.monotonic),
            self.blocks_created.load(.monotonic),
            self.batches_submitted.load(.monotonic),
            self.mempool_size.load(.monotonic),
            self.l1_submission_errors.load(.monotonic),
        });
    }
};
