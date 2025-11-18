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
        var result = std.array_list.Managed(u8).init(allocator);
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
    
    var result = std.array_list.Managed(u8).init(allocator);
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
    var result = std.array_list.Managed(u8).init(std.heap.page_allocator);
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
    var result = std.array_list.Managed(u8).init(allocator);
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
    
    var result = std.array_list.Managed(u8).init(allocator);
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
    var items = std.array_list.Managed([]const u8).init(allocator);
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

pub fn decodeTransaction(allocator: std.mem.Allocator, data: []const u8) !@import("transaction.zig").Transaction {
    // Simplified - in production implement full RLP list decoding
    _ = allocator;
    _ = data;
    return error.NotImplemented;
}

