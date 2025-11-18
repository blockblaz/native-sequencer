const std = @import("std");
const testing = std.testing;
const rlp = @import("rlp.zig");

test "RLP encode single byte < 0x80" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeBytes(allocator, &[_]u8{0x42});
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x42), encoded[0]);
}

test "RLP encode empty bytes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeBytes(allocator, &[_]u8{});
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x80), encoded[0]);
}

test "RLP encode short string (< 56 bytes)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = "hello";
    const encoded = try rlp.encodeBytes(allocator, data);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 6), encoded.len);
    try testing.expectEqual(@as(u8, 0x85), encoded[0]); // 0x80 + 5
    try testing.expectEqualSlices(u8, data, encoded[1..]);
}

test "RLP encode uint zero" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeUint(allocator, 0);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x80), encoded[0]);
}

test "RLP encode uint small" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeUint(allocator, 42);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 42), encoded[0]);
}

test "RLP encode uint large" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeUint(allocator, 1000);
    defer allocator.free(encoded);

    try testing.expect(encoded.len >= 2);
    try testing.expectEqual(@as(u8, 0x82), encoded[0]); // 0x80 + 2
    try testing.expectEqual(@as(u8, 0x03), encoded[1]);
    try testing.expectEqual(@as(u8, 0xe8), encoded[2]);
}

test "RLP encode list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const item1 = try rlp.encodeBytes(allocator, "hello");
    defer allocator.free(item1);
    const item2 = try rlp.encodeBytes(allocator, "world");
    defer allocator.free(item2);

    const items = [_][]const u8{ item1, item2 };
    const encoded = try rlp.encodeList(allocator, &items);
    defer allocator.free(encoded);

    try testing.expect(encoded.len > 0);
    try testing.expect(encoded[0] >= 0xc0); // List marker
}

test "RLP decode single byte < 0x80" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = [_]u8{0x42};
    const decoded = try rlp.decodeBytes(allocator, &data);
    defer allocator.free(decoded.value);

    try testing.expectEqual(@as(usize, 1), decoded.value.len);
    try testing.expectEqual(@as(u8, 0x42), decoded.value[0]);
    try testing.expectEqual(@as(usize, 1), decoded.consumed);
}

test "RLP decode empty bytes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const data = [_]u8{0x80};
    const decoded = try rlp.decodeBytes(allocator, &data);
    defer allocator.free(decoded.value);

    try testing.expectEqual(@as(usize, 0), decoded.value.len);
    try testing.expectEqual(@as(usize, 1), decoded.consumed);
}

test "RLP decode short string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original = "hello";
    const encoded = try rlp.encodeBytes(allocator, original);
    defer allocator.free(encoded);

    const decoded = try rlp.decodeBytes(allocator, encoded);
    defer allocator.free(decoded.value);

    try testing.expectEqualSlices(u8, original, decoded.value);
}

test "RLP decode uint zero" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeUint(allocator, 0);
    defer allocator.free(encoded);

    const decoded = try rlp.decodeUint(allocator, encoded);
    try testing.expectEqual(@as(u256, 0), decoded.value);
}

test "RLP decode uint small" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeUint(allocator, 42);
    defer allocator.free(encoded);

    const decoded = try rlp.decodeUint(allocator, encoded);
    try testing.expectEqual(@as(u256, 42), decoded.value);
}

test "RLP decode uint large" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const encoded = try rlp.encodeUint(allocator, 1000);
    defer allocator.free(encoded);

    const decoded = try rlp.decodeUint(allocator, encoded);
    try testing.expectEqual(@as(u256, 1000), decoded.value);
}

test "RLP decode list" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const item1 = try rlp.encodeBytes(allocator, "hello");
    defer allocator.free(item1);
    const item2 = try rlp.encodeBytes(allocator, "world");
    defer allocator.free(item2);

    const items = [_][]const u8{ item1, item2 };
    const encoded = try rlp.encodeList(allocator, &items);
    defer allocator.free(encoded);

    const decoded = try rlp.decodeList(allocator, encoded);
    defer {
        for (decoded.items) |item| {
            allocator.free(item);
        }
        allocator.free(decoded.items);
    }

    try testing.expectEqual(@as(usize, 2), decoded.items.len);
    try testing.expectEqualSlices(u8, "hello", decoded.items[0]);
    try testing.expectEqualSlices(u8, "world", decoded.items[1]);
}

test "RLP encode and decode transaction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const transaction = @import("transaction.zig").Transaction{
        .nonce = 42,
        .gas_price = 1000000000,
        .gas_limit = 21000,
        .to = null,
        .value = 1000000000000000000,
        .data = &[_]u8{0x12, 0x34, 0x56},
        .v = 27,
        .r = [_]u8{0x01} ** 32,
        .s = [_]u8{0x02} ** 32,
    };

    const encoded = try rlp.encodeTransaction(allocator, &transaction);
    defer allocator.free(encoded);

    const decoded = try rlp.decodeTransaction(allocator, encoded);
    defer allocator.free(decoded.data);

    try testing.expectEqual(transaction.nonce, decoded.nonce);
    try testing.expectEqual(transaction.gas_price, decoded.gas_price);
    try testing.expectEqual(transaction.gas_limit, decoded.gas_limit);
    try testing.expectEqual(transaction.to, decoded.to);
    try testing.expectEqual(transaction.value, decoded.value);
    try testing.expectEqualSlices(u8, transaction.data, decoded.data);
    try testing.expectEqual(transaction.v, decoded.v);
    try testing.expectEqualSlices(u8, &transaction.r, &decoded.r);
    try testing.expectEqualSlices(u8, &transaction.s, &decoded.s);
}

test "RLP encode and decode transaction with address" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const types_mod = @import("types.zig");
    const addr_bytes = [_]u8{0x01} ** 20;
    const address = types_mod.addressFromBytes(addr_bytes);

    const transaction = @import("transaction.zig").Transaction{
        .nonce = 1,
        .gas_price = 20000000000,
        .gas_limit = 21000,
        .to = address,
        .value = 500000000000000000,
        .data = &[_]u8{},
        .v = 28,
        .r = [_]u8{0x03} ** 32,
        .s = [_]u8{0x04} ** 32,
    };

    const encoded = try rlp.encodeTransaction(allocator, &transaction);
    defer allocator.free(encoded);

    const decoded = try rlp.decodeTransaction(allocator, encoded);
    defer allocator.free(decoded.data);

    try testing.expectEqual(transaction.nonce, decoded.nonce);
    try testing.expectEqual(transaction.gas_price, decoded.gas_price);
    try testing.expectEqual(transaction.gas_limit, decoded.gas_limit);
    try testing.expect(decoded.to != null);
    if (decoded.to) |to| {
        const decoded_bytes = types_mod.addressToBytes(to);
        try testing.expectEqualSlices(u8, &addr_bytes, &decoded_bytes);
    }
    try testing.expectEqual(transaction.value, decoded.value);
    try testing.expectEqualSlices(u8, transaction.data, decoded.data);
    try testing.expectEqual(transaction.v, decoded.v);
    try testing.expectEqualSlices(u8, &transaction.r, &decoded.r);
    try testing.expectEqualSlices(u8, &transaction.s, &decoded.s);
}

test "RLP Transaction.fromRaw roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original = @import("transaction.zig").Transaction{
        .nonce = 100,
        .gas_price = 50000000000,
        .gas_limit = 30000,
        .to = null,
        .value = 2000000000000000000,
        .data = "test data",
        .v = 27,
        .r = [_]u8{0x05} ** 32,
        .s = [_]u8{0x06} ** 32,
    };

    const serialized = try original.serialize(allocator);
    defer allocator.free(serialized);

    const decoded = try @import("transaction.zig").Transaction.fromRaw(allocator, serialized);
    defer allocator.free(decoded.data);

    try testing.expectEqual(original.nonce, decoded.nonce);
    try testing.expectEqual(original.gas_price, decoded.gas_price);
    try testing.expectEqual(original.gas_limit, decoded.gas_limit);
    try testing.expectEqual(original.to, decoded.to);
    try testing.expectEqual(original.value, decoded.value);
    try testing.expectEqualSlices(u8, original.data, decoded.data);
    try testing.expectEqual(original.v, decoded.v);
    try testing.expectEqualSlices(u8, &original.r, &decoded.r);
    try testing.expectEqualSlices(u8, &original.s, &decoded.s);
}

test "RLP decode invalid data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Empty data
    try testing.expectError(error.InvalidRLP, rlp.decodeBytes(allocator, &[_]u8{}));

    // Invalid list marker
    try testing.expectError(error.InvalidRLP, rlp.decodeList(allocator, &[_]u8{0x42}));

    // Truncated data
    try testing.expectError(error.InvalidRLP, rlp.decodeBytes(allocator, &[_]u8{0x85})); // Says 5 bytes but only 1 byte
}

