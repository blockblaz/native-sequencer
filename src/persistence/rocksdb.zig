// RocksDB persistence layer for Native Sequencer
// Note: RocksDB is currently disabled
// Implementation mirrors zeam's RocksDB pattern exactly

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");

// RocksDB is disabled for now - use stub implementation
const rocksdb = struct {
    pub const DB = struct {};
    pub const ColumnFamilyHandle = struct {};
    pub const Data = struct {
        data: []const u8,
        pub fn deinit(_: *@This()) void {}
    };
    pub const DBOptions = struct {
        create_if_missing: bool = true,
        create_missing_column_families: bool = true,
    };
    pub const ColumnFamilyDescription = struct {
        name: []const u8,
        options: struct {},
    };
    pub const ColumnFamily = struct {
        handle: ColumnFamilyHandle,
    };
};

pub const RocksDBError = error{
    DatabaseOpenFailed,
    DatabaseOperationFailed,
    SerializationFailed,
    DeserializationFailed,
    KeyNotFound,
    UnsupportedPlatform, // Windows is not supported
} || std.mem.Allocator.Error;

pub const Database = struct {
    db: rocksdb.DB,
    allocator: std.mem.Allocator,
    cf_handles: []const rocksdb.ColumnFamilyHandle,
    cfs: []const rocksdb.ColumnFamily,
    // Keep this as a null terminated string to avoid issues with the RocksDB API
    // As the path gets converted to ptr before being passed to the C API binding
    path: [:0]const u8,

    const Self = @This();

    const OpenError = RocksDBError || std.posix.MakeDirError || std.fs.Dir.StatFileError || error{RocksDBOpen};

    /// Open or create a RocksDB database
    /// Note: RocksDB is disabled - returns error.UnsupportedPlatform
    /// Returns Database by value (like zeam), not a pointer
    pub fn open(allocator: std.mem.Allocator, path: []const u8) OpenError!Self {
        _ = allocator;
        _ = path;
        return error.UnsupportedPlatform;
    }

    /// Close the database
    pub fn deinit(self: *Self) void {
        // RocksDB is disabled - just free the path
        self.allocator.free(self.path);
    }

    /// Put a key-value pair
    /// Note: Takes self by value (like zeam), not by pointer
    /// Database is stored on disk via RocksDB, not in-memory
    pub fn put(self: Self, key: []const u8, value: []const u8) !void {
        _ = self;
        _ = key;
        _ = value;
        return error.UnsupportedPlatform;
    }

    /// Get a value by key
    pub fn get(self: *Self, key: []const u8) !?rocksdb.Data {
        _ = self;
        _ = key;
        return error.UnsupportedPlatform;
    }

    /// Delete a key-value pair
    pub fn delete(self: *Self, key: []const u8) !void {
        _ = self;
        _ = key;
        return error.UnsupportedPlatform;
    }

    /// Check if a key exists
    pub fn exists(self: *Self, key: []const u8) !bool {
        _ = self;
        _ = key;
        return error.UnsupportedPlatform;
    }

    /// Store an address -> u64 mapping (for nonces)
    pub fn putNonce(self: Self, address: core.types.Address, nonce: u64) !void {
        _ = self;
        _ = address;
        _ = nonce;
        return error.UnsupportedPlatform;
    }

    /// Get a nonce for an address
    pub fn getNonce(self: *Self, address: core.types.Address) !?u64 {
        _ = self;
        _ = address;
        return error.UnsupportedPlatform;
    }

    /// Store an address -> u256 mapping (for balances)
    pub fn putBalance(self: Self, address: core.types.Address, balance: u256) !void {
        _ = self;
        _ = address;
        _ = balance;
        return error.UnsupportedPlatform;
    }

    /// Get a balance for an address
    pub fn getBalance(self: *Self, address: core.types.Address) !?u256 {
        _ = self;
        _ = address;
        return error.UnsupportedPlatform;
    }

    /// Store a receipt by transaction hash
    pub fn putReceipt(self: Self, tx_hash: core.types.Hash, receipt: core.receipt.Receipt) !void {
        _ = self;
        _ = tx_hash;
        _ = receipt;
        return error.UnsupportedPlatform;
    }

    /// Get a receipt by transaction hash
    pub fn getReceipt(self: *Self, tx_hash: core.types.Hash) !?core.receipt.Receipt {
        _ = self;
        _ = tx_hash;
        return error.UnsupportedPlatform;
    }

    /// Store current block number
    pub fn putBlockNumber(self: Self, block_number: u64) !void {
        _ = self;
        _ = block_number;
        return error.UnsupportedPlatform;
    }

    /// Get current block number
    pub fn getBlockNumber(self: *Self) !?u64 {
        _ = self;
        return error.UnsupportedPlatform;
    }

    /// Helper: Convert address to database key
    fn addressToKey(self: Self, prefix: []const u8, address: core.types.Address) ![]u8 {
        const addr_bytes = core.types.addressToBytes(address);
        const prefix_len = prefix.len;
        const key = try self.allocator.alloc(u8, prefix_len + 32);
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
    fn serializeReceipt(self: Self, _: core.receipt.Receipt) ![]u8 {
        // TODO: Implement proper RLP or protobuf serialization
        // For now, return empty slice as placeholder
        return try self.allocator.alloc(u8, 0);
    }

    /// Deserialize receipt (simplified implementation)
    fn deserializeReceipt(_: *Self, _: []const u8) !core.receipt.Receipt {
        // TODO: Implement proper deserialization
        return error.DeserializationFailed;
    }
};

/// Helper function to get return type (like zeam's interface.ReturnType)
fn ReturnType(comptime FnPtr: type) type {
    return switch (@typeInfo(FnPtr)) {
        .@"fn" => |fun| fun.return_type.?,
        .pointer => |ptr| @typeInfo(ptr.child).@"fn".return_type.?,
        else => @compileError("not a function or function pointer"),
    };
}

/// Wrapper function for RocksDB calls (like zeam's callRocksDB)
/// Handles error strings automatically
fn callRocksDB(func: anytype, args: anytype) ReturnType(@TypeOf(func)) {
    var err_str: ?rocksdb.Data = null;
    return @call(.auto, func, args ++ .{&err_str}) catch |e| {
        const func_name = @typeName(@TypeOf(func));
        const err_msg = if (err_str) |es| blk: {
            const msg = es.data;
            es.deinit();
            break :blk msg;
        } else "unknown";
        std.log.err("Failed to call RocksDB function: '{s}', error: {} - {s}", .{ func_name, e, err_msg });
        return e;
    };
}
