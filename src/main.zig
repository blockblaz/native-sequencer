const std = @import("std");
const lib = @import("root.zig");

pub fn main() !void {
    std.log.info("Starting Native Sequencer...", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load configuration
    std.log.info("Loading configuration from environment variables...", .{});
    var cfg = try lib.config.Config.fromEnv(allocator);
    defer {
        if (!std.mem.eql(u8, cfg.api_host, "0.0.0.0")) allocator.free(cfg.api_host);
        if (!std.mem.eql(u8, cfg.l1_rpc_url, "http://localhost:8545")) allocator.free(cfg.l1_rpc_url);
    }

    std.log.info("Configuration loaded: API={s}:{d}, L1_RPC={s}, Metrics={d}, BatchInterval={d}ms", .{
        cfg.api_host,
        cfg.api_port,
        cfg.l1_rpc_url,
        cfg.metrics_port,
        cfg.batch_interval_ms,
    });

    // Check emergency halt
    if (cfg.emergency_halt) {
        std.log.err("Sequencer is in emergency halt mode - exiting", .{});
        return;
    }

    // Initialize components
    std.log.info("Initializing sequencer components...", .{});

    // Initialize RocksDB if state_db_path is configured
    var state_db: ?lib.persistence.rocksdb.Database = null;
    var state_manager: lib.state.StateManager = undefined;

    // Check if STATE_DB_PATH is set or if default path should be used
    const use_persistence = blk: {
        if (std.process.getEnvVarOwned(allocator, "STATE_DB_PATH")) |env_path| {
            defer allocator.free(env_path);
            break :blk true;
        } else |_| {
            // Use default path
            break :blk true;
        }
    };

    if (use_persistence) {
        // Open RocksDB database (not supported on Windows)
        const db_result = lib.persistence.rocksdb.Database.open(allocator, cfg.state_db_path);
        if (db_result) |db| {
            state_db = db;
            std.log.info("Initializing state manager with RocksDB persistence at {s}", .{cfg.state_db_path});
            state_manager = try lib.state.StateManager.initWithPersistence(allocator, &state_db.?);
        } else |err| {
            if (err == error.UnsupportedPlatform) {
                std.log.warn("RocksDB persistence not supported on Windows, falling back to in-memory state", .{});
                state_db = null;
                state_manager = lib.state.StateManager.init(allocator);
            } else {
                return err;
            }
        }
    } else {
        // Use in-memory state manager
        state_manager = lib.state.StateManager.init(allocator);
    }
    defer state_manager.deinit();
    if (state_db) |*db| {
        defer db.close();
    }

    var mp = try lib.mempool.Mempool.init(allocator, &cfg);
    defer mp.deinit();
    std.log.info("Mempool initialized (max_size={d}, wal_path={s})", .{ cfg.mempool_max_size, cfg.mempool_wal_path });

    var batch_builder = lib.batch.Builder.init(allocator, &cfg);
    defer batch_builder.deinit();
    std.log.info("Batch builder initialized (size_limit={d}, gas_limit={d})", .{ cfg.batch_size_limit, cfg.block_gas_limit });

    var ingress_handler = lib.validation.ingress.Ingress.init(allocator, &mp, &state_manager);

    var seq = lib.sequencer.Sequencer.init(allocator, &cfg, &mp, &state_manager, &batch_builder);

    var l1_client = lib.l1.Client.init(allocator, &cfg);
    defer l1_client.deinit();
    std.log.info("L1 client initialized (rpc_url={s}, chain_id={d})", .{ cfg.l1_rpc_url, cfg.l1_chain_id });

    var m = lib.metrics.Metrics.init(allocator);

    // Start API server
    std.log.info("Starting API server...", .{});
    const api_address = try std.net.Address.parseIp(cfg.api_host, cfg.api_port);
    var api_server = lib.api.server.JsonRpcServer.init(allocator, api_address, cfg.api_host, cfg.api_port, &ingress_handler, &m);

    // Start sequencing loop in background
    std.log.info("Starting sequencing loop (interval={d}ms)...", .{cfg.batch_interval_ms});
    var sequencing_thread = try std.Thread.spawn(.{}, sequencingLoop, .{ &seq, &batch_builder, &l1_client, &m, &cfg });
    sequencing_thread.detach();

    // Start metrics server
    std.log.info("Starting metrics server...", .{});
    const metrics_host = "0.0.0.0";
    const metrics_address = try std.net.Address.parseIp(metrics_host, cfg.metrics_port);
    var metrics_server = lib.metrics.server.MetricsServer.init(allocator, metrics_address, metrics_host, cfg.metrics_port, &m);
    var metrics_thread = try std.Thread.spawn(.{}, metricsServerLoop, .{&metrics_server});
    metrics_thread.detach();

    std.log.info("Native Sequencer started successfully", .{});
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
        std.log.info("Block #{d} created: {d} transactions, {d} gas used", .{ block.number, block.transactions.len, block.gas_used });

        // Add to batch
        batch_builder.addBlock(block) catch |err| {
            std.log.err("Error adding block #{d} to batch: {any}", .{ block.number, err });
            continue;
        };

        // Flush batch if needed
        if (batch_builder.shouldFlush()) {
            const batch_data = batch_builder.buildBatch() catch |err| {
                std.log.err("Error building batch: {any}", .{err});
                continue;
            };

            std.log.info("Submitting batch to L1 ({d} blocks)...", .{batch_data.blocks.len});

            // Submit to L1
            const batch_hash = l1_client.submitBatch(batch_data) catch |err| {
                std.log.err("Error submitting batch to L1: {any}", .{err});
                m.incrementL1SubmissionErrors();
                continue;
            };

            m.incrementBatchesSubmitted();
            std.log.info("Batch submitted successfully to L1 (hash={s})", .{formatHash(batch_hash)});
            batch_builder.clear();
        }
    }
}

fn formatHash(hash: lib.core.types.Hash) []const u8 {
    // Format hash as hex string for logging
    const bytes = hash.toBytes();
    var buffer: [66]u8 = undefined; // "0x" + 64 hex chars
    buffer[0] = '0';
    buffer[1] = 'x';
    // Format each byte as hex
    for (bytes, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        buffer[2 + i * 2] = hex_chars[byte >> 4];
        buffer[2 + i * 2 + 1] = hex_chars[byte & 0xf];
    }
    return buffer[0..66];
}

fn metricsServerLoop(server: *lib.metrics.server.MetricsServer) void {
    server.start() catch |err| {
        std.log.err("Metrics server error: {any}", .{err});
    };
}
