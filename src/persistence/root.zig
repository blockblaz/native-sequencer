pub const rocksdb = @import("rocksdb.zig");

// Note: RocksDB types (Options, ReadOptions, WriteOptions) are not available on Windows
// They are only exported when rocksdb module is available (non-Windows platforms)
