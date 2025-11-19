// Witness storage in RocksDB for efficient witness data management

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const witness = @import("../core/witness.zig");
const rocksdb_module = @import("rocksdb.zig");

pub const WitnessStorage = struct {
    allocator: std.mem.Allocator,
    db: *rocksdb_module.Database,

    const Self = @This();

    // Key prefixes for different witness data types
    const WITNESS_PREFIX: []const u8 = "witness:";
    const STATE_NODE_PREFIX: []const u8 = "state_node:";
    const CODE_PREFIX: []const u8 = "code:";
    const HEADER_PREFIX: []const u8 = "header:";

    pub fn init(allocator: std.mem.Allocator, db: *rocksdb_module.Database) Self {
        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed - db is managed externally
    }

    /// Store witness data in RocksDB
    pub fn storeWitness(self: *Self, witness_data: *const witness.Witness, witness_id: types.Hash) !void {
        // Serialize witness to RLP
        const witness_rlp = try witness_data.encodeRLP(self.allocator);
        defer self.allocator.free(witness_rlp);

        // Store witness RLP data
        const key = try self.witnessKey(witness_id);
        defer self.allocator.free(key);

        try self.db.put(key, witness_rlp);
    }

    /// Retrieve witness data from RocksDB
    pub fn getWitness(self: *Self, witness_id: types.Hash) !?witness.Witness {
        const key = try self.witnessKey(witness_id);
        defer self.allocator.free(key);

        const witness_data_opt = self.db.get(key) catch |err| {
            if (err == rocksdb_module.RocksDBError.KeyNotFound) {
                return null;
            }
            return err;
        };
        defer if (witness_data_opt) |d| d.deinit();

        const witness_data = witness_data_opt orelse return null;

        // Decode witness from RLP
        const decoded = try witness.Witness.decodeRLP(self.allocator, witness_data.data);
        return decoded.witness;
    }

    /// Store state trie node in RocksDB
    pub fn storeStateNode(self: *Self, node_hash: types.Hash, node_data: []const u8) !void {
        const key = try self.stateNodeKey(node_hash);
        defer self.allocator.free(key);

        const node_data_copy = try self.allocator.dupe(u8, node_data);
        defer self.allocator.free(node_data_copy);

        try self.db.put(key, node_data_copy);
    }

    /// Retrieve state trie node from RocksDB
    pub fn getStateNode(self: *Self, node_hash: types.Hash) !?[]const u8 {
        const key = try self.stateNodeKey(node_hash);
        defer self.allocator.free(key);

        const node_data_opt = self.db.get(key) catch |err| {
            if (err == rocksdb_module.RocksDBError.KeyNotFound) {
                return null;
            }
            return err;
        };
        defer if (node_data_opt) |d| d.deinit();

        const node_data = node_data_opt orelse return null;

        // Return a copy of the data
        return try self.allocator.dupe(u8, node_data.data);
    }

    /// Store contract code in RocksDB
    pub fn storeCode(self: *Self, code_hash: types.Hash, code: []const u8) !void {
        const key = try self.codeKey(code_hash);
        defer self.allocator.free(key);

        const code_copy = try self.allocator.dupe(u8, code);
        defer self.allocator.free(code_copy);

        try self.db.put(key, code_copy);
    }

    /// Retrieve contract code from RocksDB
    pub fn getCode(self: *Self, code_hash: types.Hash) !?[]const u8 {
        const key = try self.codeKey(code_hash);
        defer self.allocator.free(key);

        const code_data_opt = self.db.get(key) catch |err| {
            if (err == rocksdb_module.RocksDBError.KeyNotFound) {
                return null;
            }
            return err;
        };
        defer if (code_data_opt) |d| d.deinit();

        const code_data = code_data_opt orelse return null;

        // Return a copy of the data
        return try self.allocator.dupe(u8, code_data.data);
    }

    /// Store block header in RocksDB
    pub fn storeHeader(self: *Self, block_number: u64, header: *const witness.BlockHeader) !void {
        const key = try self.headerKey(block_number);
        defer self.allocator.free(key);

        // Serialize header to RLP
        const header_rlp = try header.encodeRLP(self.allocator);
        defer self.allocator.free(header_rlp);

        try self.db.put(key, header_rlp);
    }

    /// Retrieve block header from RocksDB
    pub fn getHeader(self: *Self, block_number: u64) !?witness.BlockHeader {
        const key = try self.headerKey(block_number);
        defer self.allocator.free(key);

        const header_data_opt = self.db.get(key) catch |err| {
            if (err == rocksdb_module.RocksDBError.KeyNotFound) {
                return null;
            }
            return err;
        };
        defer if (header_data_opt) |d| d.deinit();

        const header_data = header_data_opt orelse return null;

        // Decode header from RLP
        const decoded = try witness.BlockHeader.decodeRLP(self.allocator, header_data.data);
        return decoded.header;
    }

    /// Cache frequently accessed state data
    /// This maintains an in-memory cache for hot data
    pub fn cacheStateNode(self: *Self, node_hash: types.Hash, node_data: []const u8) !void {
        // Store in RocksDB (which acts as persistent cache)
        try self.storeStateNode(node_hash, node_data);
    }

    /// Query RocksDB for state trie nodes
    /// Returns all state nodes matching the given prefix (for trie traversal)
    pub fn queryStateNodes(self: *Self, prefix_hash: types.Hash) !std.ArrayList([]const u8) {
        _ = prefix_hash; // TODO: Use prefix_hash for prefix matching
        // TODO: Implement iterator-based query for prefix matching
        // For now, return empty list
        return std.ArrayList([]const u8).init(self.allocator);
    }

    /// Generate key for witness storage
    fn witnessKey(self: *Self, witness_id: types.Hash) ![]u8 {
        const hash_bytes = types.hashToBytes(witness_id);
        var key = std.ArrayList(u8).init(self.allocator);
        errdefer key.deinit();
        try key.writer().print("{s}", .{WITNESS_PREFIX});
        try key.writer().print("{s}", .{try self.bytesToHex(&hash_bytes)});
        return try key.toOwnedSlice();
    }

    /// Generate key for state node storage
    fn stateNodeKey(self: *Self, node_hash: types.Hash) ![]u8 {
        const hash_bytes = types.hashToBytes(node_hash);
        var key = std.ArrayList(u8).init(self.allocator);
        errdefer key.deinit();
        try key.writer().print("{s}", .{STATE_NODE_PREFIX});
        try key.writer().print("{s}", .{try self.bytesToHex(&hash_bytes)});
        return try key.toOwnedSlice();
    }

    /// Generate key for code storage
    fn codeKey(self: *Self, code_hash: types.Hash) ![]u8 {
        const hash_bytes = types.hashToBytes(code_hash);
        var key = std.ArrayList(u8).init(self.allocator);
        errdefer key.deinit();
        try key.writer().print("{s}", .{CODE_PREFIX});
        try key.writer().print("{s}", .{try self.bytesToHex(&hash_bytes)});
        return try key.toOwnedSlice();
    }

    /// Generate key for header storage
    fn headerKey(self: *Self, block_number: u64) ![]u8 {
        var key = std.ArrayList(u8).init(self.allocator);
        errdefer key.deinit();
        try key.writer().print("{s}", .{HEADER_PREFIX});
        try key.writer().print("{x}", .{block_number});
        return try key.toOwnedSlice();
    }

    /// Convert bytes to hex string
    fn bytesToHex(self: *Self, bytes: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        const hex_digits = "0123456789abcdef";
        for (bytes) |byte| {
            try result.append(hex_digits[byte >> 4]);
            try result.append(hex_digits[byte & 0xf]);
        }

        return try result.toOwnedSlice();
    }
};
