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

    // Initialize LMDB database - stored on disk at cfg.state_db_path
    // Database is returned by value (like zeam), not a pointer
    var state_db: ?lib.persistence.lmdb.Database = null;
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
        // Open LMDB database (stored on disk, not in-memory)
        // Open database - returns Database by value (like zeam), not a pointer
        const db_result = lib.persistence.lmdb.Database.open(allocator, cfg.state_db_path);
        if (db_result) |db| {
            state_db = db;
            std.log.info("Initializing state manager with LMDB persistence at {s}", .{cfg.state_db_path});
            state_manager = try lib.state.StateManager.initWithPersistence(allocator, &state_db.?);
        } else |err| {
            std.log.warn("LMDB persistence failed: {any}, falling back to in-memory state", .{err});
            state_db = null;
            state_manager = lib.state.StateManager.init(allocator);
        }
    } else {
        // Use in-memory state manager (no persistence)
        state_manager = lib.state.StateManager.init(allocator);
    }
    // Cleanup: state manager first, then database (defer executes in reverse order)
    defer state_manager.deinit();
    if (state_db) |*db| {
        defer db.deinit(); // Close database (like zeam uses deinit, not close)
    }

    var mp = try lib.mempool.Mempool.init(allocator, &cfg);
    defer mp.deinit();
    std.log.info("Mempool initialized (max_size={d}, wal_path={s})", .{ cfg.mempool_max_size, cfg.mempool_wal_path });

    var batch_builder = lib.batch.Builder.init(allocator, &cfg);
    defer batch_builder.deinit();
    std.log.info("Batch builder initialized (size_limit={d}, gas_limit={d})", .{ cfg.batch_size_limit, cfg.block_gas_limit });

    // Initialize L2 state provider for validation queries (op-node style)
    var state_provider = lib.l2.StateProvider.init(allocator, cfg.l2_rpc_url);
    std.log.info("L2 state provider initialized (rpc_url={s})", .{cfg.l2_rpc_url});

    // Initialize ingress with state manager (for witness generation) and state provider (for validation)
    var ingress_handler = lib.validation.ingress.Ingress.init(allocator, &mp, &state_manager, &state_provider);

    // Initialize L1 client for derivation
    var l1_client = lib.l1.Client.init(allocator, &cfg);
    defer l1_client.deinit();
    std.log.info("L1 client initialized (rpc_url={s}, chain_id={d})", .{ cfg.l1_rpc_url, cfg.l1_chain_id });

    // Initialize L1 derivation pipeline
    var l1_derivation = lib.l1.derivation.L1Derivation.init(allocator, &l1_client);
    std.log.info("L1 derivation pipeline initialized", .{});

    // Initialize L2 Engine API client
    var engine_client = lib.l2.EngineApiClient.init(allocator, cfg.l2_rpc_url, cfg.l2_engine_api_port, cfg.l2_jwt_secret);
    if (cfg.l2_jwt_secret) |_| {
        std.log.info("L2 Engine API client initialized (rpc_url={s}, engine_port={d}, jwt_auth=enabled)", .{ cfg.l2_rpc_url, cfg.l2_engine_api_port });
    } else {
        std.log.warn("L2 Engine API client initialized without JWT authentication - Engine API calls may fail", .{});
        std.log.info("L2 Engine API client initialized (rpc_url={s}, engine_port={d}, jwt_auth=disabled)", .{ cfg.l2_rpc_url, cfg.l2_engine_api_port });
    }

    // Initialize sequencer with op-node style components
    var seq = lib.sequencer.Sequencer.init(allocator, &cfg, &mp, &state_manager, &batch_builder, &l1_derivation, &engine_client);
    defer seq.deinit();

    var m = lib.metrics.Metrics.init(allocator);

    // Start API server
    std.log.info("Starting API server...", .{});
    const api_address = try std.net.Address.parseIp(cfg.api_host, cfg.api_port);
    var api_server = lib.api.server.JsonRpcServer.initWithSequencer(allocator, api_address, cfg.api_host, cfg.api_port, &ingress_handler, &m, &l1_client, &seq);

    // Start sequencing loop in background
    std.log.info("Starting sequencing loop (interval={d}ms)...", .{cfg.batch_interval_ms});
    var sequencing_thread = try std.Thread.spawn(.{}, sequencingLoop, .{ &seq, &batch_builder, &l1_client, &m, &cfg, &state_manager }); // state_manager is mutable for database access
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

fn sequencingLoop(seq: *lib.sequencer.Sequencer, batch_builder: *lib.batch.Builder, l1_client: *lib.l1.Client, m: *lib.metrics.Metrics, cfg: *const lib.config.Config, state_manager: *lib.state.StateManager) void {
    while (true) {
        std.Thread.sleep(cfg.batch_interval_ms * std.time.ns_per_ms);

        // Update safe blocks from L1 derivation (op-node style)
        if (l1_client.getLatestBlockNumber()) |block_num| {
            seq.updateSafeBlock(block_num) catch |err| {
                std.log.warn("Failed to update safe block from L1: {any}", .{err});
            };
        } else |err| {
            std.log.warn("Failed to get L1 block number: {any}", .{err});
        }

        // Build unsafe block (sequencer-proposed) via payload request to L2 geth (op-node style)
        // This requests L2 geth to build a block with transactions from mempool
        const block = seq.buildBlock() catch |err| {
            std.log.err("Error building block (payload request failed): {any}", .{err});
            continue;
        };
        m.incrementBlocksCreated();
        std.log.info("Block #{d} created via L2 geth payload: {d} transactions, {d} gas used", .{ block.number, block.transactions.len, block.gas_used });

        // Only add blocks with transactions to batch (empty blocks advance L2 state but aren't submitted to L1)
        if (block.transactions.len > 0) {
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

                // Only submit if batch has blocks with transactions
                var has_transactions = false;
                for (batch_data.blocks) |batch_block| {
                    if (batch_block.transactions.len > 0) {
                        has_transactions = true;
                        break;
                    }
                }

                if (has_transactions) {
                    std.log.info("Submitting batch to L1 ({d} blocks)...", .{batch_data.blocks.len});

                    // Submit to L1 (with ExecuteTx support)
                    const batch_hash = l1_client.submitBatch(batch_data, state_manager, seq) catch |err| {
                        std.log.err("Error submitting batch to L1: {any}", .{err});
                        m.incrementL1SubmissionErrors();
                        continue;
                    };

                    m.incrementBatchesSubmitted();
                    std.log.info("Batch submitted successfully to L1 (hash={s})", .{formatHash(batch_hash)});
                } else {
                    std.log.debug("Skipping batch submission - no transactions in batch", .{});
                }
                batch_builder.clear();
            }
        } else {
            // Empty block: L2 state updated (block number incremented, parent hash updated)
            // but not submitted to L1 to save gas costs
            std.log.debug("Empty block #{d} - L2 state updated, skipping L1 submission", .{block.number});
        }
    }
}

fn formatHash(hash: lib.core.types.Hash) []const u8 {
    // Format hash as hex string for logging
    const bytes = lib.core.types.hashToBytes(hash);
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
