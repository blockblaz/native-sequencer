// LMDB persistence layer for Native Sequencer

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");

// LMDB C bindings - conditional compilation for Windows and cross-compilation
// On Windows or when cross-compiling without headers, use stub implementation
const c = if (builtin.target.os.tag == .windows) struct {
    pub const MDB_env = struct {};
    pub const MDB_txn = struct {};
    pub const MDB_dbi = u32;
    pub const MDB_val = struct {
        mv_size: usize,
        mv_data: ?*anyopaque,
    };
    pub const MDB_SUCCESS = 0;
    pub const MDB_NOTFOUND = 1;
    pub const MDB_NOSUBDIR = 0x4000;
    pub const MDB_RDONLY = 0x20000;
    pub const MDB_CREATE = 0x40000;
    pub fn mdb_env_create(_: *?*MDB_env) c_int {
        return 1; // Error
    }
    pub fn mdb_env_set_mapsize(_: ?*MDB_env, _: c_ulong) c_int {
        return 1; // Error
    }
    pub fn mdb_env_open(_: ?*MDB_env, _: [*c]const u8, _: c_uint, _: c_uint) c_int {
        return 1; // Error
    }
    pub fn mdb_env_close(_: ?*MDB_env) void {}
    pub fn mdb_txn_begin(_: ?*MDB_env, _: ?*MDB_txn, _: c_uint, _: *?*MDB_txn) c_int {
        return 1; // Error
    }
    pub fn mdb_txn_commit(_: ?*MDB_txn) c_int {
        return 1; // Error
    }
    pub fn mdb_txn_abort(_: ?*MDB_txn) void {}
    pub fn mdb_dbi_open(_: ?*MDB_txn, _: ?[*c]const u8, _: c_uint, _: *MDB_dbi) c_int {
        return 1; // Error
    }
    pub fn mdb_put(_: ?*MDB_txn, _: MDB_dbi, _: *MDB_val, _: *MDB_val, _: c_uint) c_int {
        return 1; // Error
    }
    pub fn mdb_get(_: ?*MDB_txn, _: MDB_dbi, _: *MDB_val, _: *MDB_val) c_int {
        return 1; // Error
    }
    pub fn mdb_del(_: ?*MDB_txn, _: MDB_dbi, _: *MDB_val, _: ?*MDB_val) c_int {
        return 1; // Error
    }
} else @cImport({
    @cInclude("lmdb.h");
});

pub const LMDBError = error{
    DatabaseOpenFailed,
    DatabaseOperationFailed,
    SerializationFailed,
    DeserializationFailed,
    KeyNotFound,
    TransactionFailed,
    EnvironmentFailed,
    UnsupportedPlatform, // Windows is not supported
} || std.mem.Allocator.Error;

pub const Data = struct {
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.data);
    }
};

pub const Database = struct {
    env: ?*c.MDB_env = null,
    dbi: c.MDB_dbi = 0,
    allocator: std.mem.Allocator,
    path: [:0]const u8,

    const Self = @This();

    const OpenError = LMDBError || std.posix.MakeDirError || std.fs.Dir.StatFileError || error{UnsupportedPlatform};

    /// Open or create an LMDB database
    /// Returns Database by value (like zeam), not a pointer
    /// Note: On Windows, this will return error.UnsupportedPlatform
    pub fn open(allocator: std.mem.Allocator, path: []const u8) OpenError!Self {
        // LMDB is not supported on Windows
        if (builtin.target.os.tag == .windows) {
            return error.UnsupportedPlatform;
        }

        // Create directory if it doesn't exist
        std.fs.cwd().makePath(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };

        // Allocate null-terminated path string
        const path_z = try allocator.dupeZ(u8, path);

        // Create LMDB environment
        var env: ?*c.MDB_env = null;
        const env_result = c.mdb_env_create(&env);
        if (env_result != c.MDB_SUCCESS) {
            allocator.free(path_z);
            return error.EnvironmentFailed;
        }

        // Set map size (default 10MB, can be increased)
        const map_size: c_ulong = 10 * 1024 * 1024; // 10MB
        _ = c.mdb_env_set_mapsize(env, map_size);

        // Open environment
        const open_result = c.mdb_env_open(env, path_z.ptr, c.MDB_NOSUBDIR, 0o644);
        if (open_result != c.MDB_SUCCESS) {
            c.mdb_env_close(env);
            allocator.free(path_z);
            return error.DatabaseOpenFailed;
        }

        // Open database in a transaction
        var txn: ?*c.MDB_txn = null;
        const txn_result = c.mdb_txn_begin(env, null, 0, &txn);
        if (txn_result != c.MDB_SUCCESS) {
            c.mdb_env_close(env);
            allocator.free(path_z);
            return error.TransactionFailed;
        }

        var dbi: c.MDB_dbi = undefined;
        const dbi_result = c.mdb_dbi_open(txn, null, c.MDB_CREATE, &dbi);
        if (dbi_result != c.MDB_SUCCESS) {
            _ = c.mdb_txn_abort(txn);
            c.mdb_env_close(env);
            allocator.free(path_z);
            return error.DatabaseOpenFailed;
        }

        const commit_result = c.mdb_txn_commit(txn);
        if (commit_result != c.MDB_SUCCESS) {
            c.mdb_env_close(env);
            allocator.free(path_z);
            return error.TransactionFailed;
        }

        return Self{
            .env = env,
            .dbi = dbi,
            .allocator = allocator,
            .path = path_z,
        };
    }

    /// Close the database
    pub fn deinit(self: *Self) void {
        if (self.env) |env| {
            c.mdb_env_close(env);
        }
        self.allocator.free(self.path);
    }

    /// Put a key-value pair
    /// Note: Takes self by value (like zeam), not by pointer
    pub fn put(self: Self, key: []const u8, value: []const u8) !void {
        if (self.env == null) return error.DatabaseOperationFailed;

        var txn: ?*c.MDB_txn = null;
        const txn_result = c.mdb_txn_begin(self.env, null, 0, &txn);
        if (txn_result != c.MDB_SUCCESS) {
            return error.TransactionFailed;
        }
        errdefer _ = c.mdb_txn_abort(txn);

        var key_val: c.MDB_val = undefined;
        key_val.mv_size = key.len;
        key_val.mv_data = @constCast(key.ptr);

        var data_val: c.MDB_val = undefined;
        data_val.mv_size = value.len;
        data_val.mv_data = @constCast(value.ptr);

        const put_result = c.mdb_put(txn, self.dbi, &key_val, &data_val, 0);
        if (put_result != c.MDB_SUCCESS) {
            return error.DatabaseOperationFailed;
        }

        const commit_result = c.mdb_txn_commit(txn);
        if (commit_result != c.MDB_SUCCESS) {
            return error.TransactionFailed;
        }
    }

    /// Get a value by key
    pub fn get(self: *Self, key: []const u8) !?Data {
        if (self.env == null) return error.DatabaseOperationFailed;

        var txn: ?*c.MDB_txn = null;
        const txn_result = c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn);
        if (txn_result != c.MDB_SUCCESS) {
            return error.TransactionFailed;
        }
        defer _ = c.mdb_txn_abort(txn);

        var key_val: c.MDB_val = undefined;
        key_val.mv_size = key.len;
        key_val.mv_data = @constCast(key.ptr);

        var data_val: c.MDB_val = undefined;
        const get_result = c.mdb_get(txn, self.dbi, &key_val, &data_val);
        if (get_result == c.MDB_NOTFOUND) {
            return null;
        }
        if (get_result != c.MDB_SUCCESS) {
            return error.DatabaseOperationFailed;
        }

        // Copy the data
        const data = try self.allocator.dupe(u8, @as([*]const u8, @ptrCast(data_val.mv_data))[0..data_val.mv_size]);
        return Data{
            .data = data,
            .allocator = self.allocator,
        };
    }

    /// Delete a key-value pair
    pub fn delete(self: *Self, key: []const u8) !void {
        if (self.env == null) return error.DatabaseOperationFailed;

        var txn: ?*c.MDB_txn = null;
        const txn_result = c.mdb_txn_begin(self.env, null, 0, &txn);
        if (txn_result != c.MDB_SUCCESS) {
            return error.TransactionFailed;
        }
        errdefer _ = c.mdb_txn_abort(txn);

        var key_val: c.MDB_val = undefined;
        key_val.mv_size = key.len;
        key_val.mv_data = @constCast(key.ptr);

        const del_result = c.mdb_del(txn, self.dbi, &key_val, null);
        if (del_result == c.MDB_NOTFOUND) {
            _ = c.mdb_txn_abort(txn);
            return error.KeyNotFound;
        }
        if (del_result != c.MDB_SUCCESS) {
            return error.DatabaseOperationFailed;
        }

        const commit_result = c.mdb_txn_commit(txn);
        if (commit_result != c.MDB_SUCCESS) {
            return error.TransactionFailed;
        }
    }

    /// Check if a key exists
    pub fn exists(self: *Self, key: []const u8) !bool {
        var result = try self.get(key);
        if (result) |*data| {
            data.deinit();
            return true;
        }
        return false;
    }

    /// Store an address -> u64 mapping (for nonces)
    pub fn putNonce(self: Self, address: core.types.Address, nonce: u64) !void {
        const key = try self.addressToKey("nonce:", address);
        defer self.allocator.free(key);

        var nonce_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce_bytes, nonce, .big);

        try self.put(key, &nonce_bytes);
    }

    /// Get a nonce for an address
    pub fn getNonce(self: *Self, address: core.types.Address) !?u64 {
        const key = try self.addressToKey("nonce:", address);
        defer self.allocator.free(key);

        var data_opt = try self.get(key);
        if (data_opt) |*data| {
            defer data.deinit();
            if (data.data.len != 8) return error.DeserializationFailed;
            return std.mem.readInt(u64, data.data[0..8], .big);
        }
        return null;
    }

    /// Store an address -> u256 mapping (for balances)
    pub fn putBalance(self: Self, address: core.types.Address, balance: u256) !void {
        const key = try self.addressToKey("balance:", address);
        defer self.allocator.free(key);

        const balance_bytes = core.types.u256ToBytes(balance);
        try self.put(key, &balance_bytes);
    }

    /// Get a balance for an address
    pub fn getBalance(self: *Self, address: core.types.Address) !?u256 {
        const key = try self.addressToKey("balance:", address);
        defer self.allocator.free(key);

        var data_opt = try self.get(key);
        if (data_opt) |*data| {
            defer data.deinit();
            if (data.data.len != 32) return error.DeserializationFailed;
            const bytes: [32]u8 = data.data[0..32].*;
            return core.types.u256FromBytes(bytes);
        }
        return null;
    }

    /// Store a receipt by transaction hash
    pub fn putReceipt(self: Self, tx_hash: core.types.Hash, receipt: core.receipt.Receipt) !void {
        const key = try self.hashToKey("receipt:", tx_hash);
        defer self.allocator.free(key);

        const serialized = try self.serializeReceipt(receipt);
        defer self.allocator.free(serialized);

        try self.put(key, serialized);
    }

    /// Get a receipt by transaction hash
    pub fn getReceipt(self: *Self, tx_hash: core.types.Hash) !?core.receipt.Receipt {
        const key = try self.hashToKey("receipt:", tx_hash);
        defer self.allocator.free(key);

        var data_opt = try self.get(key);
        if (data_opt) |*data| {
            defer data.deinit();
            return try self.deserializeReceipt(data.data);
        }
        return null;
    }

    /// Store current block number
    pub fn putBlockNumber(self: Self, block_number: u64) !void {
        const key = "block_number";
        var block_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &block_bytes, block_number, .big);
        try self.put(key, &block_bytes);
    }

    /// Get current block number
    pub fn getBlockNumber(self: *Self) !?u64 {
        const key = "block_number";
        var data_opt = try self.get(key);
        if (data_opt) |*data| {
            defer data.deinit();
            if (data.data.len != 8) return error.DeserializationFailed;
            return std.mem.readInt(u64, data.data[0..8], .big);
        }
        return null;
    }

    /// Helper: Convert address to database key
    fn addressToKey(self: Self, prefix: []const u8, address: core.types.Address) ![]u8 {
        const addr_bytes = core.types.addressToBytes(address);
        const prefix_len = prefix.len;
        const key = try self.allocator.alloc(u8, prefix_len + 20);
        @memcpy(key[0..prefix_len], prefix);
        @memcpy(key[prefix_len..], &addr_bytes);
        return key;
    }

    /// Helper: Convert hash to database key
    fn hashToKey(self: Self, prefix: []const u8, hash: core.types.Hash) ![]u8 {
        const hash_bytes = core.types.hashToBytes(hash);
        const prefix_len = prefix.len;
        const key = try self.allocator.alloc(u8, prefix_len + 32);
        @memcpy(key[0..prefix_len], prefix);
        @memcpy(key[prefix_len..], &hash_bytes);
        return key;
    }

    /// Serialize receipt (simplified implementation)
    fn serializeReceipt(self: Self, receipt: core.receipt.Receipt) ![]u8 {
        // TODO: Implement proper RLP or protobuf serialization
        // For now, return empty slice as placeholder
        _ = receipt;
        return try self.allocator.alloc(u8, 0);
    }

    /// Deserialize receipt (simplified implementation)
    fn deserializeReceipt(_: *Self, _: []const u8) !core.receipt.Receipt {
        // TODO: Implement proper deserialization
        return error.DeserializationFailed;
    }
};
