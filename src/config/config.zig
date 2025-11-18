const std = @import("std");

pub const Config = struct {
    // API Server
    api_host: []const u8 = "0.0.0.0",
    api_port: u16 = 8545,

    // L1 Connection
    l1_rpc_url: []const u8 = "http://localhost:8545",
    l1_chain_id: u64 = 1,

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

        if (std.posix.getenv("API_HOST")) |host| {
            config.api_host = try allocator.dupe(u8, host);
        }
        if (std.posix.getenv("API_PORT")) |port_str| {
            config.api_port = try std.fmt.parseInt(u16, port_str, 10);
        }
        if (std.posix.getenv("L1_RPC_URL")) |url| {
            config.l1_rpc_url = try allocator.dupe(u8, url);
        }
        if (std.posix.getenv("SEQUENCER_KEY")) |key_hex| {
            // Parse hex key
            _ = key_hex;
        }

        return config;
    }
};

