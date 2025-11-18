const std = @import("std");
const types = @import("../core/types.zig");
const transaction = @import("../core/transaction.zig");
const crypto_root = @import("root.zig");
const zigeth = crypto_root.zigeth;
const hash = @import("hash.zig");

/// Recover Ethereum address from transaction signature
pub fn recoverAddress(tx: *const transaction.Transaction) !types.Address {
    // Get the transaction hash (unsigned)
    const tx_hash_bytes = try tx.hash(std.heap.page_allocator);
    defer std.heap.page_allocator.free(tx_hash_bytes);
    
    const tx_hash = zigeth.primitives.Hash.fromBytes(tx_hash_bytes);
    
    // Create signature from transaction fields
    const sig = zigeth.primitives.Signature.init(tx.r, tx.s, tx.v);
    
    // Recover address using zigeth
    const recovered_address = try zigeth.crypto.ecdsa.recoverAddress(tx_hash, sig);
    
    return recovered_address.bytes;
}

/// Verify transaction signature
pub fn verifySignature(tx: *const transaction.Transaction) !bool {
    // Get the transaction hash
    const tx_hash_bytes = try tx.hash(std.heap.page_allocator);
    defer std.heap.page_allocator.free(tx_hash_bytes);
    
    const tx_hash = zigeth.primitives.Hash.fromBytes(tx_hash_bytes);
    
    // Create signature from transaction fields
    const sig = zigeth.primitives.Signature.init(tx.r, tx.s, tx.v);
    
    // Recover public key
    const pub_key = zigeth.crypto.ecdsa.recoverPublicKey(tx_hash, sig) catch return false;
    
    // Derive address from public key
    const recovered_address = pub_key.toAddress();
    
    // Get expected sender
    const expected_sender = try tx.sender();
    
    // Compare addresses
    return std.mem.eql(u8, &recovered_address.bytes, &expected_sender);
}

/// Sign data with a private key
pub fn sign(data: []const u8, private_key_bytes: [32]u8) !types.Signature {
    // Create private key from bytes
    const private_key = try zigeth.crypto.PrivateKey.fromBytes(private_key_bytes);
    
    // Hash the data
    const data_hash = zigeth.crypto.keccak.hash(data);
    
    // Sign with zigeth
    const sig = try zigeth.crypto.ecdsa.Signer.init(private_key).signHash(data_hash);
    
    return .{
        .r = sig.r,
        .s = sig.s,
        .v = sig.v,
    };
}

