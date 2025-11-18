// Metrics HTTP server implementation using Zig 0.15 networking

const std = @import("std");
const http = @import("../api/http.zig");
const Metrics = @import("metrics.zig").Metrics;

pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    metrics: *Metrics,
    http_server: http.HttpServer,
    host: []const u8,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address, host: []const u8, port: u16, metrics: *Metrics) MetricsServer {
        return .{
            .allocator = allocator,
            .address = address,
            .metrics = metrics,
            .http_server = http.HttpServer.init(allocator, address, host, port),
            .host = host,
            .port = port,
        };
    }

    pub fn start(self: *MetricsServer) !void {
        try self.http_server.listen();
        std.log.info("Metrics server listening on {s}:{d}", .{ self.host, self.port });

        while (true) {
            var conn = self.http_server.accept() catch |err| {
                std.log.err("Error accepting metrics connection: {any}", .{err});
                continue;
            };
            defer conn.close();

            // Handle connection in current thread (simple implementation)
            self.handleConnection(&conn) catch |err| {
                std.log.err("Error handling metrics connection: {any}", .{err});
            };
        }
    }

    fn handleConnection(self: *MetricsServer, conn: *http.Connection) !void {
        var request = conn.readRequest() catch |err| {
            // Send error response if request parsing fails
            const error_response = try self.createErrorResponse(400, "Bad Request");
            defer self.allocator.free(error_response);
            try conn.writeResponse(error_response);
            return err;
        };
        defer request.deinit();

        // Only handle GET requests to /metrics
        if (!std.mem.eql(u8, request.method, "GET")) {
            const error_response = try self.createErrorResponse(405, "Method Not Allowed");
            defer self.allocator.free(error_response);
            try conn.writeResponse(error_response);
            return;
        }

        if (!std.mem.eql(u8, request.path, "/metrics")) {
            const error_response = try self.createErrorResponse(404, "Not Found");
            defer self.allocator.free(error_response);
            try conn.writeResponse(error_response);
            return;
        }

        // Generate metrics response
        const response = try self.createMetricsResponse();
        defer self.allocator.free(response);
        try conn.writeResponse(response);
    }

    fn createMetricsResponse(self: *MetricsServer) ![]u8 {
        var response = http.HttpResponse.init(self.allocator);
        defer response.deinit();

        response.status_code = 200;
        try response.headers.put("Content-Type", "text/plain; version=0.0.4; charset=utf-8");

        // Format metrics in Prometheus format
        var metrics_buffer = std.ArrayList(u8).init(self.allocator);
        defer metrics_buffer.deinit();

        try metrics_buffer.writer().print(
            \\# HELP sequencer_transactions_received Total number of transactions received
            \\# TYPE sequencer_transactions_received counter
            \\sequencer_transactions_received {d}
            \\
            \\# HELP sequencer_transactions_accepted Total number of transactions accepted
            \\# TYPE sequencer_transactions_accepted counter
            \\sequencer_transactions_accepted {d}
            \\
            \\# HELP sequencer_transactions_rejected Total number of transactions rejected
            \\# TYPE sequencer_transactions_rejected counter
            \\sequencer_transactions_rejected {d}
            \\
            \\# HELP sequencer_blocks_created Total number of blocks created
            \\# TYPE sequencer_blocks_created counter
            \\sequencer_blocks_created {d}
            \\
            \\# HELP sequencer_batches_submitted Total number of batches submitted to L1
            \\# TYPE sequencer_batches_submitted counter
            \\sequencer_batches_submitted {d}
            \\
            \\# HELP sequencer_mempool_size Current mempool size
            \\# TYPE sequencer_mempool_size gauge
            \\sequencer_mempool_size {d}
            \\
            \\# HELP sequencer_l1_submission_errors Total number of L1 submission errors
            \\# TYPE sequencer_l1_submission_errors counter
            \\sequencer_l1_submission_errors {d}
            \\
        , .{
            self.metrics.transactions_received.load(.monotonic),
            self.metrics.transactions_accepted.load(.monotonic),
            self.metrics.transactions_rejected.load(.monotonic),
            self.metrics.blocks_created.load(.monotonic),
            self.metrics.batches_submitted.load(.monotonic),
            self.metrics.mempool_size.load(.monotonic),
            self.metrics.l1_submission_errors.load(.monotonic),
        });

        response.body = try metrics_buffer.toOwnedSlice();
        defer self.allocator.free(response.body);

        return try response.format(self.allocator);
    }

    fn createErrorResponse(self: *MetricsServer, status_code: u16, message: []const u8) ![]u8 {
        var response = http.HttpResponse.init(self.allocator);
        defer response.deinit();

        response.status_code = status_code;
        try response.headers.put("Content-Type", "text/plain");

        const body = try std.fmt.allocPrint(self.allocator, "{s}\r\n", .{message});
        defer self.allocator.free(body);
        response.body = body;

        return try response.format(self.allocator);
    }

    pub fn deinit(self: *MetricsServer) void {
        self.http_server.deinit();
    }
};
