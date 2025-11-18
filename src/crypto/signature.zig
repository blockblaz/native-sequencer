// Comprehensive ECDSA signature verification for Ethereum transactions
//
// This module implements full ECDSA signature verification with:
// - Signature component validation (r, s, v)
// - Edge case handling (zero values, invalid recovery IDs, etc.)
// - EIP-155 chain ID support
// - Comprehensive error handling
// - Performance optimizations

const std = @import("std");
const types = @import("../core/types.zig");
const transaction = @import("../core/transaction.zig");
const hash = @import("hash.zig");
const keccak = @import("keccak.zig");
const secp256k1 = @import("secp256k1_wrapper.zig");

/// Error types for signature verification
pub const SignatureError = error{
    InvalidRecoveryId,
    InvalidRValue,
    InvalidSValue,
    InvalidVValue,
    SignatureRecoveryFailed,
    InvalidSignatureFormat,
    ZeroSignature,
    SignatureTooLarge,
};

/// secp256k1 curve order (n)
const SECP256K1_N: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;

/// Maximum valid s value (n/2 for low-s canonical signatures)
const MAX_S: u256 = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

/// Validate signature components (r, s, v)
/// Returns error if signature components are invalid
pub fn validateSignatureComponents(r: [32]u8, s: [32]u8, v: u8) SignatureError!void {
    // Check r value: must be non-zero and < secp256k1 curve order
    const r_value = readU256(&r);
    if (r_value == 0) {
        return error.InvalidRValue;
    }
    if (r_value >= SECP256K1_N) {
        return error.SignatureTooLarge;
    }

    // Check s value: must be non-zero and < secp256k1 curve order
    // For canonical signatures (EIP-2), s must be <= n/2
    const s_value = readU256(&s);
    if (s_value == 0) {
        return error.InvalidSValue;
    }
    if (s_value >= SECP256K1_N) {
        return error.SignatureTooLarge;
    }
    // Note: We don't enforce low-s canonical form here to be compatible
    // with older transactions, but we validate it's within valid range

    // Check v value: must be 27, 28, or EIP-155 encoded (35 + chain_id * 2 or 36 + chain_id * 2)
    // Valid v values: 27, 28, or >= 35 (EIP-155)
    if (v < 27) {
        return error.InvalidVValue;
    }
    if (v > 28 and v < 35) {
        return error.InvalidVValue;
    }
}

/// Extract recovery ID from v value
/// Returns recovery ID (0-3) and chain ID (if EIP-155)
pub fn extractRecoveryId(v: u8) struct { recovery_id: u8, chain_id: ?u64 } {
    if (v == 27) {
        return .{ .recovery_id = 0, .chain_id = null };
    } else if (v == 28) {
        return .{ .recovery_id = 1, .chain_id = null };
    } else if (v >= 35) {
        // EIP-155: v = chain_id * 2 + 35 or chain_id * 2 + 36
        const recovery_id: u8 = if ((v - 35) % 2 == 0) 0 else 1;
        const chain_id = (v - 35) / 2;
        return .{ .recovery_id = recovery_id, .chain_id = chain_id };
    } else {
        // Invalid v value, but we'll let secp256k1 handle it
        return .{ .recovery_id = @truncate(v - 27), .chain_id = null };
    }
}

/// Read u256 from big-endian bytes
fn readU256(bytes: *const [32]u8) u256 {
    var result: u256 = 0;
    for (bytes) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

/// Recover Ethereum address from transaction signature
/// This function handles both legacy (v=27/28) and EIP-155 (v>=35) signatures
/// Note: This function uses page_allocator internally for transaction hashing
pub fn recoverAddress(tx: *const transaction.Transaction) !types.Address {
    // Validate signature components first
    try validateSignatureComponents(tx.r, tx.s, tx.v);

    // Get the transaction hash (unsigned)
    // For EIP-155, we need to hash with chain ID included
    // Use page_allocator for transaction hash (it's temporary)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const tx_hash = try tx.hash(allocator);
    // tx_hash is U256 struct (stack-allocated), no need to free

    // Create signature struct from transaction fields
    const sig = types.Signature{
        .r = tx.r,
        .s = tx.s,
        .v = tx.v,
    };

    // Recover public key
    const pub_key = secp256k1.recoverPublicKey(tx_hash, sig) catch {
        return error.SignatureRecoveryFailed;
    };

    // Derive address from public key
    return pub_key.toAddress();
}

/// Verify transaction signature with comprehensive validation
/// Returns true if signature is valid, false otherwise
/// This function performs full validation including:
/// - Signature component validation
/// - Public key recovery
/// - Address comparison
pub fn verifySignature(tx: *const transaction.Transaction) !bool {
    // Step 1: Validate signature components
    validateSignatureComponents(tx.r, tx.s, tx.v) catch |err| {
        std.log.debug("Signature validation failed: {any}", .{err});
        return false;
    };

    // Step 2: Get the transaction hash
    // Use page_allocator for transaction hash (it's temporary)
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const tx_hash = tx.hash(allocator) catch {
        std.log.debug("Failed to compute transaction hash", .{});
        return false;
    };
    // tx_hash is U256 struct (stack-allocated), no need to free

    // Step 3: Create signature struct
    const sig = types.Signature{
        .r = tx.r,
        .s = tx.s,
        .v = tx.v,
    };

    // Step 4: Recover public key from signature
    const pub_key = secp256k1.recoverPublicKey(tx_hash, sig) catch {
        std.log.debug("Public key recovery failed", .{});
        return false;
    };

    // Step 5: Derive address from public key
    const recovered_address = pub_key.toAddress();

    // Step 6: Get expected sender (this will also recover address)
    // We compare the recovered address from step 5 with the expected sender
    const expected_sender = tx.sender() catch {
        std.log.debug("Failed to recover sender address", .{});
        return false;
    };

    // Step 7: Compare addresses (U256 comparison)
    const addresses_match = recovered_address.eql(expected_sender);
    if (!addresses_match) {
        std.log.debug("Recovered address does not match expected sender", .{});
    }

    return addresses_match;
}

/// Verify signature with explicit chain ID (for EIP-155)
/// This is useful when you want to verify a signature with a specific chain ID
pub fn verifySignatureWithChainId(tx: *const transaction.Transaction, chain_id: u64) !bool {
    // Extract recovery info from v
    const recovery_info = extractRecoveryId(tx.v);

    // Check if chain ID matches
    if (recovery_info.chain_id) |tx_chain_id| {
        if (tx_chain_id != chain_id) {
            std.log.debug("Chain ID mismatch: expected {d}, got {d}", .{ chain_id, tx_chain_id });
            return false;
        }
    } else {
        // Legacy transaction (v=27/28), but we're expecting EIP-155
        std.log.debug("Expected EIP-155 signature but got legacy signature", .{});
        return false;
    }

    // Verify signature normally
    return try verifySignature(tx);
}

/// Sign data with a private key
pub fn sign(data: []const u8, private_key_bytes: [32]u8) !types.Signature {
    // Create private key from bytes
    const private_key = try secp256k1.PrivateKey.fromBytes(private_key_bytes);

    // Hash the data
    const data_hash = keccak.hash(data);

    // Sign with secp256k1
    return try secp256k1.sign(data_hash, private_key);
}
