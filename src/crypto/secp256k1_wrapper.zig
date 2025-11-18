const std = @import("std");
const types = @import("../core/types.zig");
const keccak = @import("keccak.zig");
const secp = @import("secp256k1");

/// Private key (32 bytes)
pub const PrivateKey = struct {
    bytes: [32]u8,

    /// Create from bytes
    pub fn fromBytes(bytes: [32]u8) !PrivateKey {
        // Basic validation - check not all zeros
        if (std.mem.allEqual(u8, &bytes, 0)) {
            return error.InvalidPrivateKey;
        }
        return .{ .bytes = bytes };
    }
};

/// Public key (uncompressed: 64 bytes)
pub const PublicKey = struct {
    /// X coordinate (32 bytes)
    x: [32]u8,
    /// Y coordinate (32 bytes)
    y: [32]u8,

    /// Create from uncompressed bytes (64 bytes)
    pub fn fromUncompressed(bytes: []const u8) !PublicKey {
        if (bytes.len != 64) {
            return error.InvalidPublicKeyLength;
        }

        var pk: PublicKey = undefined;
        @memcpy(&pk.x, bytes[0..32]);
        @memcpy(&pk.y, bytes[32..64]);

        return pk;
    }

    /// Derive Ethereum address from public key
    pub fn toAddress(self: PublicKey) types.Address {
        // Ethereum address is the last 20 bytes of Keccak-256(public_key)
        var pub_bytes: [64]u8 = undefined;
        @memcpy(pub_bytes[0..32], &self.x);
        @memcpy(pub_bytes[32..64], &self.y);

        const hash_result = keccak.hash(&pub_bytes);

        const hash_bytes = types.hashToBytes(hash_result);
        var addr_bytes: [20]u8 = undefined;
        @memcpy(&addr_bytes, hash_bytes[12..32]);

        return types.addressFromBytes(addr_bytes);
    }
};

/// Derive public key from private key
pub fn derivePublicKey(private_key: PrivateKey) !PublicKey {
    var ctx = try secp.Secp256k1.init();

    // Use a workaround: sign a dummy message and recover the pubkey
    // This gives us the public key corresponding to the private key
    const dummy_msg: [32]u8 = [_]u8{1} ** 32;
    const dummy_sig = try ctx.sign(dummy_msg, private_key.bytes);
    const pubkey_65 = try ctx.recoverPubkey(dummy_msg, dummy_sig);

    // Convert from 65-byte (0x04 prefix + x + y) to our format (x + y)
    return try PublicKey.fromUncompressed(pubkey_65[1..65]);
}

/// Signature type (r, s, v format)
pub const Signature = types.Signature;

/// Sign a message hash with a private key
pub fn sign(message_hash: types.Hash, private_key: PrivateKey) !Signature {
    var ctx = try secp.Secp256k1.init();
    
    const hash_bytes = types.hashToBytes(message_hash);
    const sig_bytes = try ctx.sign(hash_bytes, private_key.bytes);

    // sig_bytes is [65]u8: [r (32) | s (32) | v (1)]
    var sig: Signature = undefined;
    @memcpy(&sig.r, sig_bytes[0..32]);
    @memcpy(&sig.s, sig_bytes[32..64]);
    // Convert recovery ID (0-3) to Ethereum v (27-30)
    sig.v = sig_bytes[64] + 27;

    return sig;
}

/// Recover public key from signature and message hash
pub fn recoverPublicKey(message_hash: types.Hash, signature: Signature) !PublicKey {
    var ctx = try secp.Secp256k1.init();

    // Convert our signature format to library format
    var sig_bytes: [65]u8 = undefined;
    @memcpy(sig_bytes[0..32], &signature.r);
    @memcpy(sig_bytes[32..64], &signature.s);
    // Convert Ethereum v (27-30) back to recovery ID (0-3)
    sig_bytes[64] = signature.v - 27;

    const hash_bytes = types.hashToBytes(message_hash);
    const pubkey_65 = try ctx.recoverPubkey(hash_bytes, sig_bytes);

    // Convert from 65-byte (0x04 prefix + x + y) to our format (x + y)
    return try PublicKey.fromUncompressed(pubkey_65[1..65]);
}

/// Verify a signature
pub fn verify(message_hash: types.Hash, signature: Signature, public_key: PublicKey) !bool {
    // For verification, we can recover the public key and compare
    const recovered_pubkey = try recoverPublicKey(message_hash, signature);

    return std.mem.eql(u8, &public_key.x, &recovered_pubkey.x) and
        std.mem.eql(u8, &public_key.y, &recovered_pubkey.y);
}

