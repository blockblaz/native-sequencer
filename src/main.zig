const std = @import("std");
const lib = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    var cfg = try lib.config.Config.fromEnv(allocator);
    defer {
        if (!std.mem.eql(u8, cfg.api_host, "0.0.0.0")) allocator.free(cfg.api_host);
        if (!std.mem.eql(u8, cfg.l1_rpc_url, "http://localhost:8545")) allocator.free(cfg.l1_rpc_url);
    }

    // Check emergency halt
    if (cfg.emergency_halt) {
        std.log.err("Sequencer is in emergency halt mode", .{});
        return;
    }

    // Initialize components
    var state_manager = lib.state.StateManager.init(allocator);
    defer state_manager.deinit();

    var mp = try lib.mempool.Mempool.init(allocator, &cfg);
    defer mp.deinit();

    var batch_builder = lib.batch.Builder.init(allocator, &cfg);
    defer batch_builder.deinit();

    var ingress_handler = lib.validation.ingress.Ingress.init(allocator, &mp, &state_manager);

    var seq = lib.sequencer.Sequencer.init(allocator, &cfg, &mp, &state_manager, &batch_builder);

    var l1_client = lib.l1.Client.init(allocator, &cfg);
    defer l1_client.deinit();

    var m = lib.metrics.Metrics.init(allocator);

    // Start API server
    const api_address = try std.net.Address.parseIp(cfg.api_host, cfg.api_port);
    var api_server = lib.api.server.JsonRpcServer.init(allocator, api_address, &ingress_handler, &m);

    // Start sequencing loop in background
    var sequencing_thread = try std.Thread.spawn(.{}, sequencingLoop, .{ &seq, &batch_builder, &l1_client, &m, &cfg });
    sequencing_thread.detach();

    // Start metrics server (simplified)
    var metrics_thread = try std.Thread.spawn(.{}, metricsLoop, .{ &m, cfg.metrics_port });
    metrics_thread.detach();

    // Start API server (blocking)
    try api_server.start();
}

fn sequencingLoop(seq: *lib.sequencer.Sequencer, batch_builder: *lib.batch.Builder, l1_client: *lib.l1.Client, m: *lib.metrics.Metrics, cfg: *const lib.config.Config) void {
    while (true) {
        std.Thread.sleep(cfg.batch_interval_ms * std.time.ns_per_ms);

        // Build block
        const block = seq.buildBlock() catch |err| {
            std.log.err("Error building block: {any}", .{err});
            continue;
        };
        m.incrementBlocksCreated();

        // Add to batch
        batch_builder.addBlock(block) catch |err| {
            std.log.err("Error adding block to batch: {any}", .{err});
            continue;
        };

        // Flush batch if needed
        if (batch_builder.shouldFlush()) {
            const batch_data = batch_builder.buildBatch() catch |err| {
                std.log.err("Error building batch: {any}", .{err});
                continue;
            };

            // Submit to L1
            _ = l1_client.submitBatch(batch_data) catch |err| {
                std.log.err("Error submitting batch to L1: {any}", .{err});
                m.incrementL1SubmissionErrors();
                continue;
            };

            m.incrementBatchesSubmitted();
            batch_builder.clear();
        }
    }
}

fn metricsLoop(m: *lib.metrics.Metrics, port: u16) void {
    // Simplified metrics server - in production use proper async networking
    std.log.info("Metrics server would listen on port {d}", .{port});
    std.log.warn("Metrics server implementation incomplete - networking API needs proper Zig 0.15 implementation", .{});
    // TODO: Implement proper metrics server using Zig 0.15 networking APIs
    // For now, just sleep to keep thread alive
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        _ = m;
    }
}
