const std = @import("std");

pub const Config = struct {
    // API Server
    api_host: []const u8 = "0.0.0.0",
    api_port: u16 = 6197,

    // L1 Connection
    l1_rpc_url: []const u8 = "http://localhost:8545",
    l1_chain_id: u64 = 1,

    // L2 Connection
    l2_rpc_url: []const u8 = "http://localhost:8545",
    l2_engine_api_port: u16 = 8551,
    l2_chain_id: u64 = 1337,

    // Sequencer
    sequencer_private_key: ?[32]u8 = null,
    batch_size_limit: u64 = 1000,
    block_gas_limit: u64 = 30_000_000,
    batch_interval_ms: u64 = 2000,

    // Mempool
    mempool_max_size: u64 = 100_000,
    mempool_wal_path: []const u8 = "./mempool.wal",

    // State
    state_db_path: []const u8 = "./state.db",

    // Observability
    metrics_port: u16 = 9090,
    enable_tracing: bool = false,

    // Operator Controls
    emergency_halt: bool = false,
    rate_limit_per_second: u64 = 1000,

    pub fn fromEnv(allocator: std.mem.Allocator) !Config {
        var config = Config{};

        if (std.process.getEnvVarOwned(allocator, "API_HOST")) |host| {
            config.api_host = host;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "API_PORT")) |port_str| {
            config.api_port = try std.fmt.parseInt(u16, port_str, 10);
            allocator.free(port_str);
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "L1_RPC_URL")) |url| {
            config.l1_rpc_url = url;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "L2_RPC_URL")) |url| {
            config.l2_rpc_url = url;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "L2_ENGINE_API_PORT")) |port_str| {
            config.l2_engine_api_port = try std.fmt.parseInt(u16, port_str, 10);
            allocator.free(port_str);
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "SEQUENCER_KEY")) |key_hex| {
            defer allocator.free(key_hex);
            // Parse hex key (remove 0x prefix if present)
            const hex_start: usize = if (std.mem.startsWith(u8, key_hex, "0x")) 2 else 0;
            const hex_data = key_hex[hex_start..];

            if (hex_data.len != 64) {
                return error.InvalidSequencerKey;
            }

            var key_bytes: [32]u8 = undefined;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                const high = try std.fmt.parseInt(u8, hex_data[i * 2 .. i * 2 + 1], 16);
                const low = try std.fmt.parseInt(u8, hex_data[i * 2 + 1 .. i * 2 + 2], 16);
                key_bytes[i] = (high << 4) | low;
            }

            config.sequencer_private_key = key_bytes;
        } else |_| {}

        return config;
    }
};
