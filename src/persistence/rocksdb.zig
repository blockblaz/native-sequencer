// RocksDB persistence layer for Native Sequencer
//
// This module provides a high-level interface to RocksDB for:
// - State persistence (nonces, balances, receipts)
// - Mempool checkpoints
// - Block metadata storage

const std = @import("std");
const rocksdb = @import("rocksdb");
const core = @import("../core/root.zig");

pub const RocksDBError = error{
    DatabaseOpenFailed,
    DatabaseOperationFailed,
    SerializationFailed,
    DeserializationFailed,
    KeyNotFound,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    db: rocksdb.DB,
    path: []const u8,
    default_cf_handle: rocksdb.ColumnFamilyHandle, // Store default column family handle

    /// Open or create a RocksDB database
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const path_owned = try allocator.dupe(u8, path);
        defer allocator.free(path_owned);

        // Convert path to null-terminated string (like zeam does)
        // In Zig 0.15.2, use allocSentinel instead of allocPrintZ
        const path_null = try allocator.allocSentinel(u8, path.len, 0);
        @memcpy(path_null[0..path.len], path);
        defer allocator.free(path_null);

        // Create directory if it doesn't exist
        std.fs.cwd().makePath(path) catch |err| {
            std.log.err("Failed to create RocksDB directory at {s}: {any}", .{ path, err });
            return error.DatabaseOpenFailed;
        };

        // Create options using DBOptions (like zeam does)
        const options = rocksdb.DBOptions{
            .create_if_missing = true,
            .create_missing_column_families = true,
        };

        // Create default column family description
        const column_family_descriptions = try allocator.alloc(rocksdb.ColumnFamilyDescription, 1);
        defer allocator.free(column_family_descriptions);
        column_family_descriptions[0] = .{ .name = "default", .options = .{} };

        // Open database - rocksdb.DB.open requires 5 arguments including error pointer
        var err_str: ?rocksdb.Data = null;
        const db: rocksdb.DB, const cfs: []const rocksdb.ColumnFamily = try rocksdb.DB.open(
            allocator,
            path_null,
            options,
            column_family_descriptions,
            &err_str,
        );
        defer allocator.free(cfs);

        std.log.info("Opened RocksDB database at {s}", .{path});

        const path_stored = try allocator.dupe(u8, path);

        // Store the default column family handle (index 0)
        const default_cf_handle = cfs[0].handle;

        return Database{
            .allocator = allocator,
            .db = db,
            .path = path_stored,
            .default_cf_handle = default_cf_handle,
        };
    }

    /// Close the database
    pub fn close(self: *Database) void {
        self.db.deinit();
        self.allocator.free(self.path);
    }

    /// Put a key-value pair
    pub fn put(self: *Database, key: []const u8, value: []const u8) !void {
        var err_str: ?rocksdb.Data = null;
        self.db.put(self.default_cf_handle, key, value, &err_str) catch |err| {
            std.log.err("Failed to put key-value pair: {any}", .{err});
            return error.DatabaseOperationFailed;
        };
    }

    /// Get a value by key
    pub fn get(self: *Database, key: []const u8) !?rocksdb.Data {
        var err_str: ?rocksdb.Data = null;
        const value = self.db.get(self.default_cf_handle, key, &err_str) catch |err| {
            std.log.err("Failed to get value for key: {any}", .{err});
            return error.DatabaseOperationFailed;
        };
        return value;
    }

    /// Delete a key-value pair
    pub fn delete(self: *Database, key: []const u8) !void {
        var err_str: ?rocksdb.Data = null;
        self.db.delete(self.default_cf_handle, key, &err_str) catch |err| {
            std.log.err("Failed to delete key: {any}", .{err});
            return error.DatabaseOperationFailed;
        };
    }

    /// Check if a key exists
    pub fn exists(self: *Database, key: []const u8) !bool {
        const value = try self.get(key);
        if (value) |v| {
            v.deinit();
            return true;
        }
        return false;
    }

    /// Store an address -> u64 mapping (for nonces)
    pub fn putNonce(self: *Database, address: core.types.Address, nonce: u64) !void {
        const key = try self.addressToKey("nonce:", address);
        defer self.allocator.free(key);

        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, nonce, .big);
        try self.put(key, &value_buf);
    }

    /// Get a nonce for an address
    pub fn getNonce(self: *Database, address: core.types.Address) !?u64 {
        const key = try self.addressToKey("nonce:", address);
        defer self.allocator.free(key);

        const value_opt = try self.get(key);
        defer if (value_opt) |v| v.deinit();

        const value = value_opt orelse return null;

        if (value.data.len != 8) {
            return error.DeserializationFailed;
        }

        var value_buf: [8]u8 = undefined;
        @memcpy(&value_buf, value.data[0..8]);
        return std.mem.readInt(u64, &value_buf, .big);
    }

    /// Store an address -> u256 mapping (for balances)
    pub fn putBalance(self: *Database, address: core.types.Address, balance: u256) !void {
        const key = try self.addressToKey("balance:", address);
        defer self.allocator.free(key);

        var value_buf: [32]u8 = undefined;
        std.mem.writeInt(u256, &value_buf, balance, .big);
        try self.put(key, &value_buf);
    }

    /// Get a balance for an address
    pub fn getBalance(self: *Database, address: core.types.Address) !?u256 {
        const key = try self.addressToKey("balance:", address);
        defer self.allocator.free(key);

        const value_opt = try self.get(key);
        defer if (value_opt) |v| v.deinit();

        const value = value_opt orelse return null;

        if (value.data.len != 32) {
            return error.DeserializationFailed;
        }

        var value_buf: [32]u8 = undefined;
        @memcpy(&value_buf, value.data[0..32]);
        return std.mem.readInt(u256, &value_buf, .big);
    }

    /// Store a receipt by transaction hash
    pub fn putReceipt(self: *Database, tx_hash: core.types.Hash, receipt: core.receipt.Receipt) !void {
        const key = try self.hashToKey("receipt:", tx_hash);
        defer self.allocator.free(key);

        // Serialize receipt (simplified - in production use proper serialization)
        const serialized = try self.serializeReceipt(receipt);
        defer self.allocator.free(serialized);

        try self.put(key, serialized);
    }

    /// Get a receipt by transaction hash
    pub fn getReceipt(self: *Database, tx_hash: core.types.Hash) !?core.receipt.Receipt {
        const key = try self.hashToKey("receipt:", tx_hash);
        defer self.allocator.free(key);

        const value_opt = try self.get(key);
        defer if (value_opt) |v| v.deinit();

        const value = value_opt orelse return null;

        return try self.deserializeReceipt(value.data);
    }

    /// Store current block number
    pub fn putBlockNumber(self: *Database, block_number: u64) !void {
        const key = "block_number";
        var value_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_buf, block_number, .big);
        try self.put(key, &value_buf);
    }

    /// Get current block number
    pub fn getBlockNumber(self: *Database) !?u64 {
        const key = "block_number";
        const value_opt = try self.get(key);
        defer if (value_opt) |v| v.deinit();

        const value = value_opt orelse return null;

        if (value.data.len != 8) {
            return error.DeserializationFailed;
        }

        var value_buf: [8]u8 = undefined;
        @memcpy(&value_buf, value.data[0..8]);
        return std.mem.readInt(u64, &value_buf, .big);
    }

    /// Helper: Convert address to database key
    fn addressToKey(self: *Database, prefix: []const u8, address: core.types.Address) ![]u8 {
        const addr_bytes = address.toBytes();
        const prefix_len = prefix.len;
        const key = try self.allocator.alloc(u8, prefix_len + 32);
        @memcpy(key[0..prefix_len], prefix);
        @memcpy(key[prefix_len..], &addr_bytes);
        return key;
    }

    /// Helper: Convert hash to database key
    fn hashToKey(self: *Database, prefix: []const u8, hash: core.types.Hash) ![]u8 {
        const hash_bytes = hash.toBytes();
        const prefix_len = prefix.len;
        const key = try self.allocator.alloc(u8, prefix_len + 32);
        @memcpy(key[0..prefix_len], prefix);
        @memcpy(key[prefix_len..], &hash_bytes);
        return key;
    }

    /// Serialize receipt (simplified implementation)
    fn serializeReceipt(self: *Database, _: core.receipt.Receipt) ![]u8 {
        // TODO: Implement proper RLP or protobuf serialization
        // For now, return empty slice as placeholder
        return try self.allocator.alloc(u8, 0);
    }

    /// Deserialize receipt (simplified implementation)
    fn deserializeReceipt(_: *Database, _: []const u8) !core.receipt.Receipt {
        // TODO: Implement proper deserialization
        return error.DeserializationFailed;
    }
};
