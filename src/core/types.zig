// Core type definitions used throughout the sequencer

const std = @import("std");

// Use native u256 types for Hash and Address
pub const Hash = u256; // 32 bytes
pub const Address = u256; // 20 bytes (stored as u256, but only 20 bytes are used)

/// Convert 32-byte array to Hash (u256)
pub fn hashFromBytes(bytes: [32]u8) Hash {
    var result: u256 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        result = (result << 8) | bytes[i];
    }
    return result;
}

/// Convert Hash (u256) to 32-byte array
pub fn hashToBytes(hash: Hash) [32]u8 {
    var result: [32]u8 = undefined;
    var temp = hash;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        result[i] = @as(u8, @truncate(temp & 0xff));
        temp >>= 8;
    }
    return result;
}

/// Convert 32-byte array to u256 (for general u256 values, not just hashes)
pub fn u256FromBytes(bytes: [32]u8) u256 {
    return hashFromBytes(bytes);
}

/// Convert u256 to 32-byte array (for general u256 values, not just hashes)
pub fn u256ToBytes(value: u256) [32]u8 {
    return hashToBytes(value);
}

/// Convert 20-byte address to Address (u256)
pub fn addressFromBytes(bytes: [20]u8) Address {
    var result: u256 = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        result = (result << 8) | bytes[i];
    }
    return result;
}

/// Convert Address (u256) to 20-byte array
pub fn addressToBytes(addr: Address) [20]u8 {
    var result: [20]u8 = undefined;
    var temp = addr;
    var i: usize = 20;
    while (i > 0) {
        i -= 1;
        result[i] = @as(u8, @truncate(temp & 0xff));
        temp >>= 8;
    }
    return result;
}

/// ECDSA signature (r, s, v format)
pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};
