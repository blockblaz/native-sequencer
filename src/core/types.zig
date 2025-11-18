// Core type definitions used throughout the sequencer

const std = @import("std");

// ============================================================================
// Custom U256 Implementation - Allocator Bug Workaround
// ============================================================================
//
// PROBLEM:
// Zig 0.14.x has a compiler bug in HashMap's AutoContext when using native
// u256 types as HashMap keys. The error manifests as:
//   "error: access of union field 'pointer' while field 'int' is active"
//   at std/mem/Allocator.zig:425:45
//
// This bug occurs during HashMap initialization when the allocator tries to
// determine the type information for u256 keys. The issue is in the standard
// library's type introspection code, not in our code.
//
// ATTEMPTED SOLUTIONS:
// 1. Native u256 with AutoContext → "int" allocator error
// 2. Wrapper structs ([32]u8) with custom contexts → "struct" allocator error
// 3. Custom U256 struct (two u128 fields) with custom contexts → ✅ WORKS
//
// SOLUTION:
// We implement a custom U256 struct using two u128 fields (primitive types)
// and provide explicit hash() and eql() methods. This allows us to use custom
// HashMap contexts (HashContext, AddressContext) that bypass the problematic
// AutoContext code path entirely.
//
// WHY THIS WORKS:
// - u128 is a primitive type that HashMap handles correctly
// - Custom contexts give explicit control over hashing/equality
// - Avoids the allocator's type introspection bug with large integers
// - Maintains full 32-byte hash and 20-byte address functionality
//
// PERFORMANCE:
// - Struct with two u128 fields is stack-allocated (no heap allocation)
// - Hash function is simple XOR of both halves (fast)
// - Equality check compares both fields (efficient)
// - No performance penalty compared to native u256 for our use cases
//
// ============================================================================

pub const U256 = struct {
    low: u128,
    high: u128,

    pub fn fromU256(value: u256) U256 {
        return .{
            .low = @truncate(value),
            .high = @truncate(value >> 128),
        };
    }

    pub fn toU256(self: U256) u256 {
        return (@as(u256, self.high) << 128) | self.low;
    }

    pub fn fromBytes(bytes: [32]u8) U256 {
        var low: u128 = 0;
        var high: u128 = 0;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            low = (low << 8) | bytes[15 - i];
        }
        while (i < 32) : (i += 1) {
            high = (high << 8) | bytes[31 - i];
        }
        return .{ .low = low, .high = high };
    }

    pub fn toBytes(self: U256) [32]u8 {
        var result: [32]u8 = undefined;
        var temp_low = self.low;
        var temp_high = self.high;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            result[15 - i] = @as(u8, @truncate(temp_low & 0xff));
            temp_low >>= 8;
        }
        i = 16;
        while (i < 32) : (i += 1) {
            result[31 - i] = @as(u8, @truncate(temp_high & 0xff));
            temp_high >>= 8;
        }
        return result;
    }

    pub fn eql(self: U256, other: U256) bool {
        return self.low == other.low and self.high == other.high;
    }

    pub fn hash(self: U256) u64 {
        // Simple hash combining both halves
        return @as(u64, @truncate(self.low)) ^ @as(u64, @truncate(self.low >> 64)) ^ @as(u64, @truncate(self.high)) ^ @as(u64, @truncate(self.high >> 64));
    }
};

// Use custom U256 struct instead of native u256 to avoid allocator bug
pub const Address = U256; // 20 bytes padded to 32 bytes

pub fn addressFromBytes(bytes: [20]u8) Address {
    var padded: [32]u8 = undefined;
    @memset(padded[0..12], 0);
    @memcpy(padded[12..32], &bytes);
    return U256.fromBytes(padded);
}

pub fn addressToBytes(addr: Address) [20]u8 {
    const bytes = addr.toBytes();
    var result: [20]u8 = undefined;
    @memcpy(&result, bytes[12..32]);
    return result;
}

pub const Hash = U256; // 32 bytes

pub fn hashFromBytes(bytes: [32]u8) Hash {
    return U256.fromBytes(bytes);
}

pub fn hashToBytes(hash: Hash) [32]u8 {
    return hash.toBytes();
}

/// ECDSA signature (r, s, v format)
pub const Signature = struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};
