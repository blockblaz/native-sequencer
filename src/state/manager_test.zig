// Thread safety tests for StateManager

const std = @import("std");
const testing = std.testing;
const StateManager = @import("manager.zig").StateManager;
const persistence = @import("../persistence/root.zig");
const core = @import("../core/root.zig");

test "StateManager concurrent getNonce" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state_manager = StateManager.init(allocator);
    defer state_manager.deinit();

    // Create a test address
    const test_address = core.types.addressFromBytes([_]u8{1} ** 20);

    // Set initial nonce
    try state_manager.setNonce(test_address, 100);

    // Spawn multiple threads reading nonce concurrently
    const num_threads = 20;
    const num_reads_per_thread = 100;
    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = [_]?anyerror{null} ** num_threads;
    var results: [num_threads]u64 = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn readNonceLoop(sm: *StateManager, addr: core.types.Address, thread_id: usize, result_ptr: *u64, err_ptr: *?anyerror) void {
                err_ptr.* = readNonceLoopImpl(sm, addr, thread_id, result_ptr) catch |err| err;
            }
            fn readNonceLoopImpl(sm: *StateManager, addr: core.types.Address, thread_id: usize, result_ptr: *u64) !void {
                var sum: u64 = 0;
                for (0..num_reads_per_thread) |_| {
                    const nonce = try sm.getNonce(addr);
                    sum += nonce;
                }
                result_ptr.* = sum;
            }
        }.readNonceLoop, .{ &state_manager, test_address, i, &results[i], &errors[i] });
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

    // Verify all threads read the same nonce value
    const expected_sum = 100 * num_reads_per_thread;
    for (results) |sum| {
        try testing.expect(sum == expected_sum);
    }
}

test "StateManager concurrent setNonce" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state_manager = StateManager.init(allocator);
    defer state_manager.deinit();

    // Create test addresses (one per thread to avoid races)
    const num_threads = 10;
    var addresses: [num_threads]core.types.Address = undefined;
    for (0..num_threads) |i| {
        var addr_bytes: [20]u8 = undefined;
        @memset(&addr_bytes, @as(u8, @intCast(i)));
        addresses[i] = core.types.addressFromBytes(addr_bytes);
    }

    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = [_]?anyerror{null} ** num_threads;

    // Spawn threads writing to different addresses
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn writeNonceLoop(sm: *StateManager, addr: core.types.Address, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = writeNonceLoopImpl(sm, addr, thread_id) catch |err| err;
            }
            fn writeNonceLoopImpl(sm: *StateManager, addr: core.types.Address, thread_id: usize) !void {
                for (0..100) |j| {
                    const nonce = @as(u64, thread_id * 100 + j);
                    try sm.setNonce(addr, nonce);
                }
            }
        }.writeNonceLoop, .{ &state_manager, addresses[i], i, &errors[i] });
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

    // Verify each address has the correct final nonce
    for (addresses, 0..) |addr, i| {
        const final_nonce = try state_manager.getNonce(addr);
        const expected_nonce = @as(u64, i * 100 + 99);
        try testing.expect(final_nonce == expected_nonce);
    }
}

test "StateManager concurrent getBalance and setBalance" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var state_manager = StateManager.init(allocator);
    defer state_manager.deinit();

    // Create test addresses
    const num_threads = 10;
    var addresses: [num_threads]core.types.Address = undefined;
    for (0..num_threads) |i| {
        var addr_bytes: [20]u8 = undefined;
        @memset(&addr_bytes, @as(u8, @intCast(i)));
        addresses[i] = core.types.addressFromBytes(addr_bytes);
    }

    // Set initial balances
    for (addresses) |addr| {
        try state_manager.setBalance(addr, 1000);
    }

    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = [_]?anyerror{null} ** num_threads;

    // Spawn threads reading and writing balances
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn balanceLoop(sm: *StateManager, addr: core.types.Address, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = balanceLoopImpl(sm, addr, thread_id) catch |err| err;
            }
            fn balanceLoopImpl(sm: *StateManager, addr: core.types.Address, thread_id: usize) !void {
                for (0..50) |_| {
                    const balance = try sm.getBalance(addr);
                    try testing.expect(balance >= 0);
                    // Write back the same balance (should be safe)
                    try sm.setBalance(addr, balance);
                }
            }
        }.balanceLoop, .{ &state_manager, addresses[i], i, &errors[i] });
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

test "StateManager with LMDB persistence concurrent access" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create temporary database
    const test_dir = "test_state_manager_persistence";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var db = try persistence.lmdb.Database.open(allocator, test_dir);
    defer db.deinit();

    var state_manager = StateManager.initWithPersistence(allocator, &db) catch |err| {
        std.log.err("Failed to initialize state manager with persistence: {any}", .{err});
        return err;
    };
    defer state_manager.deinit();

    // Create test address
    const test_address = core.types.addressFromBytes([_]u8{1} ** 20);

    // Set initial values
    try state_manager.setNonce(test_address, 50);
    try state_manager.setBalance(test_address, 1000);

    const num_threads = 10;
    const num_ops_per_thread = 50;
    var threads: [num_threads]std.Thread = undefined;
    var errors: [num_threads]?anyerror = [_]?anyerror{null} ** num_threads;

    // Spawn threads doing mixed operations
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn mixedOpsLoop(sm: *StateManager, addr: core.types.Address, thread_id: usize, err_ptr: *?anyerror) void {
                err_ptr.* = mixedOpsLoopImpl(sm, addr, thread_id) catch |err| err;
            }
            fn mixedOpsLoopImpl(sm: *StateManager, addr: core.types.Address, thread_id: usize) !void {
                for (0..num_ops_per_thread) |_| {
                    // Read operations
                    _ = try sm.getNonce(addr);
                    _ = try sm.getBalance(addr);

                    // Write operations (to different addresses to avoid races)
                    var addr_bytes: [20]u8 = undefined;
                    @memset(&addr_bytes, @as(u8, @intCast(thread_id)));
                    const thread_addr = core.types.addressFromBytes(addr_bytes);
                    try sm.setNonce(thread_addr, @as(u64, thread_id));
                    try sm.setBalance(thread_addr, @as(u256, thread_id * 100));
                }
            }
        }.mixedOpsLoop, .{ &state_manager, test_address, i, &errors[i] });
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

    // Verify final state
    const final_nonce = try state_manager.getNonce(test_address);
    try testing.expect(final_nonce >= 50); // Should be at least initial value

    const final_balance = try state_manager.getBalance(test_address);
    try testing.expect(final_balance >= 0);
}
