// RLP (Recursive Length Prefix) encoding/decoding for Ethereum
// Simplified implementation - in production use a more complete RLP library

const std = @import("std");
const types = @import("types.zig");

pub const RLPError = error{
    InvalidRLP,
    InvalidLength,
    InvalidData,
};

pub fn encodeUint(allocator: std.mem.Allocator, value: u256) ![]u8 {
    if (value == 0) {
        // Use ArrayList instead of direct alloc to avoid allocator issues
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        try result.append(0x80);
        return result.toOwnedSlice();
    }

    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, value, .big);

    // Find first non-zero byte
    var start: usize = 0;
    while (start < buf.len and buf[start] == 0) start += 1;
    const significant_bytes = buf.len - start;

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (significant_bytes == 1 and buf[start] < 0x80) {
        // Single byte, encode directly
        try result.append(buf[start]);
    } else {
        // Encode length prefix
        if (significant_bytes < 56) {
            try result.append(@intCast(0x80 + significant_bytes));
        } else {
            const len_bytes = try encodeLength(significant_bytes);
            try result.append(@intCast(0xb7 + len_bytes.len));
            try result.appendSlice(len_bytes);
        }
        try result.appendSlice(buf[start..]);
    }

    return result.toOwnedSlice();
}

fn encodeLength(len: usize) ![]u8 {
    var result = std.ArrayList(u8).init(std.heap.page_allocator);
    errdefer result.deinit();

    var n = len;
    while (n > 0) {
        try result.append(@intCast(n & 0xff));
        n >>= 8;
    }

    // Reverse to get big-endian
    const bytes = result.items;
    var i: usize = 0;
    var j = bytes.len - 1;
    while (i < j) {
        const temp = bytes[i];
        bytes[i] = bytes[j];
        bytes[j] = temp;
        i += 1;
        j -= 1;
    }

    return result.toOwnedSlice();
}

pub fn encodeBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (data.len == 1 and data[0] < 0x80) {
        try result.append(data[0]);
    } else {
        if (data.len < 56) {
            try result.append(@intCast(0x80 + data.len));
        } else {
            const len_bytes = try encodeLength(data.len);
            try result.append(@intCast(0xb7 + len_bytes.len));
            try result.appendSlice(len_bytes);
        }
        try result.appendSlice(data);
    }

    return result.toOwnedSlice();
}

pub fn encodeList(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (items) |item| {
        total_len += item.len;
    }

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (total_len < 56) {
        try result.append(@intCast(0xc0 + total_len));
    } else {
        const len_bytes = try encodeLength(total_len);
        try result.append(@intCast(0xf7 + len_bytes.len));
        try result.appendSlice(len_bytes);
    }

    for (items) |item| {
        try result.appendSlice(item);
    }

    return result.toOwnedSlice();
}

pub fn encodeTransaction(allocator: std.mem.Allocator, tx: *const @import("transaction.zig").Transaction) ![]u8 {
    var items = std.ArrayList([]const u8).init(allocator);
    defer {
        for (items.items) |item| {
            allocator.free(item);
        }
        items.deinit();
    }

    const nonce = try encodeUint(allocator, tx.nonce);
    try items.append(nonce);

    const gas_price = try encodeUint(allocator, tx.gas_price);
    try items.append(gas_price);

    const gas_limit = try encodeUint(allocator, tx.gas_limit);
    try items.append(gas_limit);

    if (tx.to) |to| {
        const types_mod = @import("types.zig");
        const to_bytes_array = types_mod.addressToBytes(to);
        const to_bytes = try encodeBytes(allocator, &to_bytes_array);
        try items.append(to_bytes);
    } else {
        const empty = try encodeBytes(allocator, &[_]u8{});
        try items.append(empty);
    }

    const value = try encodeUint(allocator, tx.value);
    try items.append(value);

    const data = try encodeBytes(allocator, tx.data);
    try items.append(data);

    const v = try encodeUint(allocator, tx.v);
    try items.append(v);

    const r = try encodeBytes(allocator, &tx.r);
    try items.append(r);

    const s = try encodeBytes(allocator, &tx.s);
    try items.append(s);

    const list = try encodeList(allocator, items.items);

    // Clean up intermediate items
    for (items.items) |item| {
        allocator.free(item);
    }

    return list;
}

pub fn decodeUint(_: std.mem.Allocator, data: []const u8) !struct { value: u256, consumed: usize } {
    if (data.len == 0) return error.InvalidRLP;

    if (data[0] < 0x80) {
        // Single byte
        return .{ .value = data[0], .consumed = 1 };
    }

    var len: usize = 0;
    var offset: usize = 1;

    if (data[0] < 0xb8) {
        // Short string (0x80-0xb7)
        len = data[0] - 0x80;
    } else if (data[0] < 0xc0) {
        // Long string (0xb8-0xbf)
        const len_len = data[0] - 0xb7;
        if (data.len < 1 + len_len) return error.InvalidRLP;

        len = 0;
        var i: usize = 0;
        while (i < len_len) : (i += 1) {
            len = (len << 8) | data[1 + i];
        }
        offset = 1 + len_len;
    } else {
        return error.InvalidRLP;
    }

    if (data.len < offset + len) return error.InvalidRLP;

    var value: u256 = 0;
    const start = offset;
    const end = offset + len;
    var i = start;
    while (i < end) : (i += 1) {
        value = (value << 8) | data[i];
    }

    return .{ .value = value, .consumed = offset + len };
}

pub fn decodeBytes(allocator: std.mem.Allocator, data: []const u8) !struct { value: []u8, consumed: usize } {
    if (data.len == 0) return error.InvalidRLP;

    if (data[0] < 0x80) {
        // Single byte
        const result = try allocator.alloc(u8, 1);
        result[0] = data[0];
        return .{ .value = result, .consumed = 1 };
    }

    var len: usize = 0;
    var offset: usize = 1;

    if (data[0] < 0xb8) {
        // Short string (0x80-0xb7)
        len = data[0] - 0x80;
    } else if (data[0] < 0xc0) {
        // Long string (0xb8-0xbf)
        const len_len = data[0] - 0xb7;
        if (data.len < 1 + len_len) return error.InvalidRLP;

        len = 0;
        var i: usize = 0;
        while (i < len_len) : (i += 1) {
            len = (len << 8) | data[1 + i];
        }
        offset = 1 + len_len;
    } else {
        return error.InvalidRLP;
    }

    if (data.len < offset + len) return error.InvalidRLP;

    const result = try allocator.dupe(u8, data[offset .. offset + len]);
    return .{ .value = result, .consumed = offset + len };
}

fn getItemLength(data: []const u8) !usize {
    if (data.len == 0) return error.InvalidRLP;

    if (data[0] < 0x80) {
        // Single byte
        return 1;
    } else if (data[0] < 0xb8) {
        // Short string (0x80-0xb7)
        const len = data[0] - 0x80;
        if (data.len < 1 + len) return error.InvalidRLP;
        return 1 + len;
    } else if (data[0] < 0xc0) {
        // Long string (0xb8-0xbf)
        const len_len = data[0] - 0xb7;
        if (data.len < 1 + len_len) return error.InvalidRLP;

        var len: usize = 0;
        var i: usize = 0;
        while (i < len_len) : (i += 1) {
            len = (len << 8) | data[1 + i];
        }
        if (data.len < 1 + len_len + len) return error.InvalidRLP;
        return 1 + len_len + len;
    } else if (data[0] < 0xf8) {
        // Short list (0xc0-0xf7) - need to recursively calculate consumed bytes
        const payload_len = data[0] - 0xc0;
        if (data.len < 1 + payload_len) return error.InvalidRLP;

        var consumed: usize = 1; // header byte
        var pos: usize = 1;
        while (pos < 1 + payload_len) {
            const item_len = try getItemLength(data[pos..]);
            consumed += item_len;
            pos += item_len;
        }
        return consumed;
    } else {
        // Long list (0xf8-0xff) - need to recursively calculate consumed bytes
        const len_len = data[0] - 0xf7;
        if (data.len < 1 + len_len) return error.InvalidRLP;

        var payload_len: usize = 0;
        var i: usize = 0;
        while (i < len_len) : (i += 1) {
            payload_len = (payload_len << 8) | data[1 + i];
        }

        var consumed: usize = 1 + len_len; // header + length bytes
        var pos: usize = 1 + len_len;
        while (pos < 1 + len_len + payload_len) {
            const item_len = try getItemLength(data[pos..]);
            consumed += item_len;
            pos += item_len;
        }
        return consumed;
    }
}

pub fn decodeList(allocator: std.mem.Allocator, data: []const u8) !struct { items: [][]u8, consumed: usize } {
    if (data.len == 0) return error.InvalidRLP;

    if (data[0] < 0xc0) {
        return error.InvalidRLP; // Not a list
    }

    var total_len: usize = 0;
    var offset: usize = 1;

    if (data[0] < 0xf8) {
        // Short list (0xc0-0xf7)
        total_len = data[0] - 0xc0;
    } else {
        // Long list (0xf8-0xff)
        const len_len = data[0] - 0xf7;
        if (data.len < 1 + len_len) return error.InvalidRLP;

        total_len = 0;
        var i: usize = 0;
        while (i < len_len) : (i += 1) {
            total_len = (total_len << 8) | data[1 + i];
        }
        offset = 1 + len_len;
    }

    if (data.len < offset + total_len) return error.InvalidRLP;

    var items = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (items.items) |item| {
            allocator.free(item);
        }
        items.deinit();
    }

    var pos: usize = offset;
    while (pos < offset + total_len) {
        const remaining = data[pos..];
        // Decode the next RLP item (could be bytes or nested list)
        const item_len = try getItemLength(remaining);
        if (item_len == 0) {
            break;
        }
        const item_data = try allocator.dupe(u8, remaining[0..item_len]);
        try items.append(item_data);
        pos += item_len;
    }

    if (pos != offset + total_len) {
        // Clean up on error
        for (items.items) |item| {
            allocator.free(item);
        }
        items.deinit();
        return error.InvalidRLP;
    }

    return .{ .items = try items.toOwnedSlice(), .consumed = offset + total_len };
}

pub fn decodeTransaction(allocator: std.mem.Allocator, data: []const u8) !@import("transaction.zig").Transaction {
    const decoded_list = try decodeList(allocator, data);
    defer {
        for (decoded_list.items) |item| {
            allocator.free(item);
        }
        allocator.free(decoded_list.items);
    }

    if (decoded_list.items.len < 9) {
        return error.InvalidRLP;
    }

    // Decode nonce
    const nonce_result = try decodeUint(allocator, decoded_list.items[0]);
    defer allocator.free(decoded_list.items[0]);
    const nonce = @as(u64, @intCast(nonce_result.value));

    // Decode gas_price
    const gas_price_result = try decodeUint(allocator, decoded_list.items[1]);
    defer allocator.free(decoded_list.items[1]);
    const gas_price = gas_price_result.value;

    // Decode gas_limit
    const gas_limit_result = try decodeUint(allocator, decoded_list.items[2]);
    defer allocator.free(decoded_list.items[2]);
    const gas_limit = @as(u64, @intCast(gas_limit_result.value));

    // Decode to (address or empty)
    defer allocator.free(decoded_list.items[3]);
    const to_address: ?types.Address = if (decoded_list.items[3].len == 0) null else blk: {
        if (decoded_list.items[3].len != 20) {
            return error.InvalidRLP;
        }
        var addr_bytes: [20]u8 = undefined;
        @memcpy(&addr_bytes, decoded_list.items[3]);
        break :blk types.addressFromBytes(addr_bytes);
    };

    // Decode value
    const value_result = try decodeUint(allocator, decoded_list.items[4]);
    defer allocator.free(decoded_list.items[4]);
    const value = value_result.value;

    // Decode data
    defer allocator.free(decoded_list.items[5]);
    const data_bytes = try allocator.dupe(u8, decoded_list.items[5]);

    // Decode v
    const v_result = try decodeUint(allocator, decoded_list.items[6]);
    defer allocator.free(decoded_list.items[6]);
    const v = @as(u8, @intCast(v_result.value));

    // Decode r
    defer allocator.free(decoded_list.items[7]);
    if (decoded_list.items[7].len != 32) {
        allocator.free(data_bytes);
        return error.InvalidRLP;
    }
    var r_bytes: [32]u8 = undefined;
    @memcpy(&r_bytes, decoded_list.items[7]);

    // Decode s
    defer allocator.free(decoded_list.items[8]);
    if (decoded_list.items[8].len != 32) {
        allocator.free(data_bytes);
        return error.InvalidRLP;
    }
    var s_bytes: [32]u8 = undefined;
    @memcpy(&s_bytes, decoded_list.items[8]);

    return @import("transaction.zig").Transaction{
        .nonce = nonce,
        .gas_price = gas_price,
        .gas_limit = gas_limit,
        .to = to_address,
        .value = value,
        .data = data_bytes,
        .v = v,
        .r = r_bytes,
        .s = s_bytes,
    };
}
