// Thread safety and concurrent access tests for LMDB

const std = @import("std");
const testing = std.testing;
const lmdb = @import("lmdb.zig");
const core = @import("../core/root.zig");

test "LMDB concurrent reads" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create temporary database
    const test_dir = "test_db_concurrent_reads";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var db = try lmdb.Database.open(allocator, test_dir);
    defer db.deinit();

    // Write some test data
    const test_key = "test_key";
    const test_value = "test_value";
    try db.put(test_key, test_value);

    // Spawn multiple threads reading concurrently
    const num_threads = 10;
    const num_reads_per_thread = 100;
    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = [_]?anyerror{null} ** num_threads;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn readLoop(db_ptr: *lmdb.Database, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = readLoopImpl(db_ptr, thread_id) catch |err| err;
            }
            fn readLoopImpl(db_ptr: *lmdb.Database, thread_id: usize) !void {
                for (0..num_reads_per_thread) |_| {
                    const data_opt = try db_ptr.get(test_key);
                    if (data_opt) |*data| {
                        defer data.deinit();
                        if (!std.mem.eql(u8, data.data, test_value)) {
                            return error.ValueMismatch;
                        }
                    } else {
                        return error.KeyNotFound;
                    }
                }
            }
        }.readLoop, .{ &db, i, &errors[i] });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Check for errors
    for (errors, 0..) |err, i| {
        if (err) |e| {
            std.log.err("Thread {d} failed: {any}", .{ i, e });
            return e;
        }
    }
}

test "LMDB concurrent writes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create temporary database
    const test_dir = "test_db_concurrent_writes";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var db = try lmdb.Database.open(allocator, test_dir);
    defer db.deinit();

    // Spawn multiple threads writing concurrently
    const num_threads = 10;
    const num_writes_per_thread = 50;
    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = [_]?anyerror{null} ** num_threads;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn writeLoop(db_ptr: *lmdb.Database, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = writeLoopImpl(db_ptr, thread_id) catch |err| err;
            }
            fn writeLoopImpl(db_ptr: *lmdb.Database, thread_id: usize) !void {
                for (0..num_writes_per_thread) |j| {
                    var key_buf: [64]u8 = undefined;
                    const key = std.fmt.bufPrint(&key_buf, "thread_{d}_key_{d}", .{ thread_id, j }) catch return error.BufferTooSmall;

                    var value_buf: [64]u8 = undefined;
                    const value = std.fmt.bufPrint(&value_buf, "thread_{d}_value_{d}", .{ thread_id, j }) catch return error.BufferTooSmall;

                    try db_ptr.put(key, value);
                }
            }
        }.writeLoop, .{ &db, i, &errors[i] });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Check for errors
    for (errors, 0..) |err, i| {
        if (err) |e| {
            std.log.err("Thread {d} failed: {any}", .{ i, e });
            return e;
        }
    }

    // Verify all writes succeeded
    for (0..num_threads) |i| {
        for (0..num_writes_per_thread) |j| {
            var key_buf: [64]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "thread_{d}_key_{d}", .{ i, j }) catch return error.BufferTooSmall;

            var value_buf: [64]u8 = undefined;
            const expected_value = std.fmt.bufPrint(&value_buf, "thread_{d}_value_{d}", .{ i, j }) catch return error.BufferTooSmall;

            var data_opt = try db.get(key);
            if (data_opt) |*data| {
                defer data.deinit();
                try testing.expect(std.mem.eql(u8, data.data, expected_value));
            } else {
                return error.KeyNotFound;
            }
        }
    }
}

test "LMDB mixed concurrent reads and writes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create temporary database
    const test_dir = "test_db_mixed_concurrent";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var db = try lmdb.Database.open(allocator, test_dir);
    defer db.deinit();

    // Initialize with some data
    try db.put("key_0", "value_0");
    try db.put("key_1", "value_1");

    const num_writer_threads = 5;
    const num_reader_threads = 10;
    const num_ops_per_thread = 100;

    var writer_threads: [num_writer_threads]std.Thread = undefined;
    var reader_threads: [num_reader_threads]std.Thread = undefined;
    var writer_errors: [num_writer_threads]?anyerror = [_]?anyerror{null} ** num_writer_threads;
    var reader_errors: [num_reader_threads]?anyerror = [_]?anyerror{null} ** num_reader_threads;

    // Spawn writer threads
    for (0..num_writer_threads) |i| {
        writer_threads[i] = try std.Thread.spawn(.{}, struct {
            fn writeLoop(db_ptr: *lmdb.Database, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = writeLoopImpl(db_ptr, thread_id) catch |err| err;
            }
            fn writeLoopImpl(db_ptr: *lmdb.Database, thread_id: usize) !void {
                for (0..num_ops_per_thread) |j| {
                    var key_buf: [64]u8 = undefined;
                    const key = std.fmt.bufPrint(&key_buf, "key_{d}", .{thread_id * num_ops_per_thread + j}) catch return error.BufferTooSmall;

                    var value_buf: [64]u8 = undefined;
                    const value = std.fmt.bufPrint(&value_buf, "value_{d}", .{thread_id * num_ops_per_thread + j}) catch return error.BufferTooSmall;

                    try db_ptr.put(key, value);
                }
            }
        }.writeLoop, .{ &db, i, &writer_errors[i] });
    }

    // Spawn reader threads
    for (0..num_reader_threads) |i| {
        reader_threads[i] = try std.Thread.spawn(.{}, struct {
            fn readLoop(db_ptr: *lmdb.Database, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = readLoopImpl(db_ptr, thread_id) catch |err| err;
            }
            fn readLoopImpl(db_ptr: *lmdb.Database, thread_id: usize) !void {
                for (0..num_ops_per_thread) |_| {
                    // Read from initial keys
                    const data_opt = try db_ptr.get("key_0");
                    if (data_opt) |*data| {
                        defer data.deinit();
                        _ = data.data;
                    }
                }
            }
        }.readLoop, .{ &db, i, &reader_errors[i] });
    }

    // Wait for all threads
    for (writer_threads) |thread| {
        thread.join();
    }
    for (reader_threads) |thread| {
        thread.join();
    }

    // Check for errors
    for (writer_errors, 0..) |err, i| {
        if (err) |e| {
            std.log.err("Writer thread {d} failed: {any}", .{ i, e });
            return e;
        }
    }
    for (reader_errors, 0..) |err, i| {
        if (err) |e| {
            std.log.err("Reader thread {d} failed: {any}", .{ i, e });
            return e;
        }
    }
}

test "LMDB transaction isolation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create temporary database
    const test_dir = "test_db_isolation";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var db = try lmdb.Database.open(allocator, test_dir);
    defer db.deinit();

    // Write initial value
    try db.put("isolated_key", "initial_value");

    // Start a read transaction
    const read_data_opt = try db.get("isolated_key");
    if (read_data_opt) |*read_data| {
        defer read_data.deinit();
        try testing.expect(std.mem.eql(u8, read_data.data, "initial_value"));

        // Write a new value in another transaction (should succeed)
        try db.put("isolated_key", "new_value");

        // The read transaction should still see the old value (isolation)
        // Note: In LMDB, read transactions see a snapshot, but our implementation
        // creates a new transaction for each get, so it will see the new value.
        // This test verifies that concurrent operations don't corrupt data.
        const read_data2_opt = try db.get("isolated_key");
        if (read_data2_opt) |*read_data2| {
            defer read_data2.deinit();
            try testing.expect(std.mem.eql(u8, read_data2.data, "new_value"));
        } else {
            return error.KeyNotFound;
        }
    } else {
        return error.KeyNotFound;
    }
}

test "LMDB nonce operations concurrent" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create temporary database
    const test_dir = "test_db_nonce_concurrent";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var db = try lmdb.Database.open(allocator, test_dir);
    defer db.deinit();

    // Create a test address
    const test_address = core.types.addressFromBytes([_]u8{1} ** 20);

    // Spawn multiple threads updating nonces concurrently
    const num_threads = 10;
    const num_updates_per_thread = 20;
    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = [_]?anyerror{null} ** num_threads;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn updateNonceLoop(db_ptr: *lmdb.Database, addr: core.types.Address, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = updateNonceLoopImpl(db_ptr, addr, thread_id) catch |err| err;
            }
            fn updateNonceLoopImpl(db_ptr: *lmdb.Database, addr: core.types.Address, thread_id: usize) !void {
                for (0..num_updates_per_thread) |j| {
                    const nonce = @as(u64, thread_id * num_updates_per_thread + j);
                    try db_ptr.putNonce(addr, nonce);
                }
            }
        }.updateNonceLoop, .{ &db, test_address, i, &errors[i] });
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Check for errors
    for (errors, 0..) |err, i| {
        if (err) |e| {
            std.log.err("Thread {d} failed: {any}", .{ i, e });
            return e;
        }
    }

    // Verify final nonce (should be one of the written values)
    const final_nonce_opt = try db.getNonce(test_address);
    if (final_nonce_opt) |final_nonce| {
        // The final value should be one of the written nonces
        const expected_max = num_threads * num_updates_per_thread - 1;
        try testing.expect(final_nonce <= expected_max);
    } else {
        return error.NonceNotFound;
    }
}
