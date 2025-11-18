const std = @import("std");
const types = @import("../core/types.zig");
const transaction = @import("../core/transaction.zig");
const hash = @import("hash.zig");
const keccak = @import("keccak.zig");
const secp256k1 = @import("secp256k1_wrapper.zig");

/// Recover Ethereum address from transaction signature
pub fn recoverAddress(tx: *const transaction.Transaction) !types.Address {
    // Get the transaction hash (unsigned)
    const tx_hash = try tx.hash(std.heap.page_allocator);
    
    // Create signature struct from transaction fields
    const sig = types.Signature{
        .r = tx.r,
        .s = tx.s,
        .v = tx.v,
    };
    
    // Recover public key
    const pub_key = try secp256k1.recoverPublicKey(tx_hash, sig);
    
    // Derive address from public key
    return pub_key.toAddress();
}

/// Verify transaction signature
pub fn verifySignature(tx: *const transaction.Transaction) !bool {
    // Get the transaction hash
    const tx_hash = try tx.hash(std.heap.page_allocator);
    
    // Create signature struct from transaction fields
    const sig = types.Signature{
        .r = tx.r,
        .s = tx.s,
        .v = tx.v,
    };
    
    // Recover public key
    const pub_key = secp256k1.recoverPublicKey(tx_hash, sig) catch return false;
    
    // Derive address from public key
    const recovered_address = pub_key.toAddress();
    
    // Get expected sender
    const expected_sender = try tx.sender();
    
    // Compare addresses (U256 comparison)
    return recovered_address.eql(expected_sender);
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

