const std = @import("std");

/// Convert bytes to hex string with 0x prefix
pub fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, 2 + bytes.len * 2);

    result[0] = '0';
    result[1] = 'x';

    for (bytes, 0..) |byte, i| {
        result[2 + i * 2] = hex_chars[byte >> 4];
        result[2 + i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return result;
}

/// Convert hex string to bytes (handles with or without 0x prefix)
pub fn hexToBytes(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    var start: usize = 0;

    // Skip 0x prefix if present
    if (hex_str.len >= 2 and hex_str[0] == '0' and (hex_str[1] == 'x' or hex_str[1] == 'X')) {
        start = 2;
    }

    const hex_len = hex_str.len - start;
    if (hex_len % 2 != 0) {
        return error.InvalidHexLength;
    }

    const result = try allocator.alloc(u8, hex_len / 2);
    errdefer allocator.free(result);

    for (0..result.len) |i| {
        const high = try hexCharToNibble(hex_str[start + i * 2]);
        const low = try hexCharToNibble(hex_str[start + i * 2 + 1]);
        result[i] = (high << 4) | low;
    }

    return result;
}

/// Convert a single hex character to its nibble value
fn hexCharToNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexCharacter,
    };
}

