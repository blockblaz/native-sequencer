// Comprehensive tests for ECDSA signature verification

const std = @import("std");
const testing = std.testing;
const types = @import("../core/types.zig");
const transaction = @import("../core/transaction.zig");
const signature = @import("signature.zig");
const secp256k1 = @import("secp256k1_wrapper.zig");
const keccak = @import("keccak.zig");

test "validateSignatureComponents - valid signature" {
    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    @memset(&r, 0);
    @memset(&s, 0);
    r[31] = 1; // Non-zero r
    s[31] = 1; // Non-zero s

    try testing.expectError(error.InvalidRValue, signature.validateSignatureComponents(r, s, 0)); // v < 27
    try testing.expectError(error.InvalidVValue, signature.validateSignatureComponents(r, s, 26)); // v < 27
    try testing.expectError(error.InvalidVValue, signature.validateSignatureComponents(r, s, 29)); // 28 < v < 35
    try testing.expectError(error.InvalidVValue, signature.validateSignatureComponents(r, s, 34)); // 28 < v < 35

    // Valid v values
    try signature.validateSignatureComponents(r, s, 27); // Legacy
    try signature.validateSignatureComponents(r, s, 28); // Legacy
    try signature.validateSignatureComponents(r, s, 35); // EIP-155 chain_id=0
    try signature.validateSignatureComponents(r, s, 36); // EIP-155 chain_id=0
    try signature.validateSignatureComponents(r, s, 37); // EIP-155 chain_id=1
}

test "validateSignatureComponents - zero r" {
    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    @memset(&r, 0);
    @memset(&s, 0);
    s[31] = 1; // Non-zero s

    try testing.expectError(error.InvalidRValue, signature.validateSignatureComponents(r, s, 27));
}

test "validateSignatureComponents - zero s" {
    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    @memset(&r, 0);
    @memset(&s, 0);
    r[31] = 1; // Non-zero r

    try testing.expectError(error.InvalidSValue, signature.validateSignatureComponents(r, s, 27));
}

test "extractRecoveryId - legacy signatures" {
    const info_27 = signature.extractRecoveryId(27);
    try testing.expectEqual(@as(u8, 0), info_27.recovery_id);
    try testing.expect(info_27.chain_id == null);

    const info_28 = signature.extractRecoveryId(28);
    try testing.expectEqual(@as(u8, 1), info_28.recovery_id);
    try testing.expect(info_28.chain_id == null);
}

test "extractRecoveryId - EIP-155 signatures" {
    // v = 35 = chain_id * 2 + 35, recovery_id = 0
    const info_35 = signature.extractRecoveryId(35);
    try testing.expectEqual(@as(u8, 0), info_35.recovery_id);
    try testing.expectEqual(@as(u64, 0), info_35.chain_id.?);

    // v = 36 = chain_id * 2 + 36, recovery_id = 1
    const info_36 = signature.extractRecoveryId(36);
    try testing.expectEqual(@as(u8, 1), info_36.recovery_id);
    try testing.expectEqual(@as(u64, 0), info_36.chain_id.?);

    // v = 37 = chain_id * 2 + 35, recovery_id = 0, chain_id = 1
    const info_37 = signature.extractRecoveryId(37);
    try testing.expectEqual(@as(u8, 0), info_37.recovery_id);
    try testing.expectEqual(@as(u64, 1), info_37.chain_id.?);

    // v = 38 = chain_id * 2 + 36, recovery_id = 1, chain_id = 1
    const info_38 = signature.extractRecoveryId(38);
    try testing.expectEqual(@as(u8, 1), info_38.recovery_id);
    try testing.expectEqual(@as(u64, 1), info_38.chain_id.?);
}

test "signature verification - roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a test private key
    var private_key_bytes: [32]u8 = undefined;
    @memset(&private_key_bytes, 0);
    private_key_bytes[31] = 1; // Non-zero private key

    const private_key = try secp256k1.PrivateKey.fromBytes(private_key_bytes);

    // Create a test transaction
    const tx = transaction.Transaction{
        .nonce = 1,
        .gas_price = 1000000000,
        .gas_limit = 21000,
        .to = types.addressFromBytes([_]u8{
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00,
            0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x12, 0x34, 0x56, 0x78,
        }),
        .value = 1000000000000000000,
        .data = &[_]u8{},
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    // Hash the transaction
    const tx_hash = try tx.hash(allocator);
    // Note: hashToBytes returns a stack-allocated array, no need to free

    // Sign the transaction
    const sig = try secp256k1.sign(tx_hash, private_key);

    // Create signed transaction
    var signed_tx = tx;
    signed_tx.r = sig.r;
    signed_tx.s = sig.s;
    signed_tx.v = sig.v;

    // Verify signature
    const is_valid = try signature.verifySignature(&signed_tx);
    try testing.expect(is_valid);

    // Test recovery
    const recovered_address = try signature.recoverAddress(&signed_tx);
    const expected_address = try signed_tx.sender();
    try testing.expect(recovered_address == expected_address);

    // Clean up transaction data
    allocator.free(tx.data);
}

test "signature verification - invalid signature" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a transaction with invalid signature (zero r)
    var tx = transaction.Transaction{
        .nonce = 1,
        .gas_price = 1000000000,
        .gas_limit = 21000,
        .to = null,
        .value = 0,
        .data = &[_]u8{},
        .v = 27,
        .r = [_]u8{0} ** 32, // Invalid: zero r
        .s = [_]u8{1} ** 32,
    };

    // Verification should fail
    const is_valid = try signature.verifySignature(&tx);
    try testing.expect(!is_valid);
}

test "signature verification - invalid v value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Create a transaction with invalid v value
    var tx = transaction.Transaction{
        .nonce = 1,
        .gas_price = 1000000000,
        .gas_limit = 21000,
        .to = null,
        .value = 0,
        .data = &[_]u8{},
        .v = 26, // Invalid: < 27
        .r = [_]u8{1} ** 32,
        .s = [_]u8{1} ** 32,
    };

    // Verification should fail
    const is_valid = try signature.verifySignature(&tx);
    try testing.expect(!is_valid);
}

test "signature verification - signature too large" {
    // Create signature with r >= secp256k1 curve order
    var r: [32]u8 = undefined;
    @memset(&r, 0xff);
    r[0] = 0xff;
    r[1] = 0xff;
    r[2] = 0xff;
    r[3] = 0xff;
    r[4] = 0xff;
    r[5] = 0xff;
    r[6] = 0xff;
    r[7] = 0xff;
    r[8] = 0xff;
    r[9] = 0xff;
    r[10] = 0xff;
    r[11] = 0xff;
    r[12] = 0xff;
    r[13] = 0xff;
    r[14] = 0xff;
    r[15] = 0xff;
    r[16] = 0xff;
    r[17] = 0xff;
    r[18] = 0xff;
    r[19] = 0xff;
    r[20] = 0xff;
    r[21] = 0xff;
    r[22] = 0xff;
    r[23] = 0xff;
    r[24] = 0xff;
    r[25] = 0xff;
    r[26] = 0xff;
    r[27] = 0xff;
    r[28] = 0xff;
    r[29] = 0xff;
    r[30] = 0xff;
    r[31] = 0xff; // This makes r >= curve order

    var s: [32]u8 = undefined;
    @memset(&s, 1);

    try testing.expectError(error.SignatureTooLarge, signature.validateSignatureComponents(r, s, 27));
}
