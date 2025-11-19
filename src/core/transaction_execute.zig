// ExecuteTx transaction type (type 0x05) for EXECUTE precompile
// Matches go-ethereum's ExecuteTx structure

const std = @import("std");
const types = @import("types.zig");
const crypto_hash = @import("../crypto/hash.zig");
const signature = @import("../crypto/signature.zig");
const rlp_module = @import("rlp.zig");

pub const ExecuteTxType: u8 = 0x05;

pub const ExecuteTx = struct {
    // Standard EIP-1559 fields
    chain_id: u256,
    nonce: u64,
    gas_tip_cap: u256, // maxPriorityFeePerGas
    gas_fee_cap: u256, // maxFeePerGas
    gas: u64,

    // Execution target
    to: ?types.Address,
    value: u256,
    data: []const u8,

    // EXECUTE-specific fields
    pre_state_hash: types.Hash,
    witness_size: u32,
    withdrawals_size: u32,
    coinbase: types.Address,
    block_number: u64,
    timestamp: u64,
    witness: []const u8,
    withdrawals: []const u8,
    blob_hashes: []types.Hash,

    // Signature
    v: u256,
    r: u256,
    s: u256,

    const Self = @This();

    /// Compute transaction hash for signing (EIP-2718 typed transaction)
    /// Uses prefixed RLP hash with transaction type 0x05
    pub fn hash(self: *const Self, allocator: std.mem.Allocator) !types.Hash {
        // EIP-2718: typed transaction hash = keccak256(transaction_type || rlp(tx_data))
        const rlp_data = try self.encodeRLP(allocator);
        defer allocator.free(rlp_data);

        // Prepend transaction type byte
        var prefixed = std.ArrayList(u8).init(allocator);
        defer prefixed.deinit();
        try prefixed.append(ExecuteTxType);
        try prefixed.appendSlice(rlp_data);

        // keccak256 returns Hash (u256), which is what we need
        return crypto_hash.keccak256(prefixed.items);
    }

    /// Serialize ExecuteTx to RLP format (without transaction type prefix)
    pub fn encodeRLP(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (items.items) |item| {
                allocator.free(item);
            }
            items.deinit();
        }

        // ChainID
        const chain_id_bytes = types.u256ToBytes(self.chain_id);
        const chain_id_encoded = try rlp_module.encodeBytes(allocator, &chain_id_bytes);
        try items.append(chain_id_encoded);

        // Nonce
        const nonce_encoded = try rlp_module.encodeUint(allocator, self.nonce);
        try items.append(nonce_encoded);

        // GasTipCap
        const gas_tip_cap_bytes = types.u256ToBytes(self.gas_tip_cap);
        const gas_tip_cap_encoded = try rlp_module.encodeBytes(allocator, &gas_tip_cap_bytes);
        try items.append(gas_tip_cap_encoded);

        // GasFeeCap
        const gas_fee_cap_bytes = types.u256ToBytes(self.gas_fee_cap);
        const gas_fee_cap_encoded = try rlp_module.encodeBytes(allocator, &gas_fee_cap_bytes);
        try items.append(gas_fee_cap_encoded);

        // Gas
        const gas_encoded = try rlp_module.encodeUint(allocator, self.gas);
        try items.append(gas_encoded);

        // To (address or empty)
        if (self.to) |to| {
            const to_bytes_array = types.addressToBytes(to);
            const to_encoded = try rlp_module.encodeBytes(allocator, &to_bytes_array);
            try items.append(to_encoded);
        } else {
            const empty = try rlp_module.encodeBytes(allocator, &[_]u8{});
            try items.append(empty);
        }

        // Value
        const value_bytes = types.u256ToBytes(self.value);
        const value_encoded = try rlp_module.encodeBytes(allocator, &value_bytes);
        try items.append(value_encoded);

        // Data
        const data_encoded = try rlp_module.encodeBytes(allocator, self.data);
        try items.append(data_encoded);

        // PreStateHash
        const pre_state_hash_bytes = types.hashToBytes(self.pre_state_hash);
        const pre_state_hash_encoded = try rlp_module.encodeBytes(allocator, &pre_state_hash_bytes);
        try items.append(pre_state_hash_encoded);

        // WitnessSize (as u64 in RLP, converted from u32)
        const witness_size_u64: u64 = self.witness_size;
        const witness_size_encoded = try rlp_module.encodeUint(allocator, witness_size_u64);
        try items.append(witness_size_encoded);

        // WithdrawalsSize (as u64 in RLP, converted from u32)
        const withdrawals_size_u64: u64 = self.withdrawals_size;
        const withdrawals_size_encoded = try rlp_module.encodeUint(allocator, withdrawals_size_u64);
        try items.append(withdrawals_size_encoded);

        // Coinbase
        const coinbase_bytes_array = types.addressToBytes(self.coinbase);
        const coinbase_encoded = try rlp_module.encodeBytes(allocator, &coinbase_bytes_array);
        try items.append(coinbase_encoded);

        // BlockNumber
        const block_number_encoded = try rlp_module.encodeUint(allocator, self.block_number);
        try items.append(block_number_encoded);

        // Timestamp
        const timestamp_encoded = try rlp_module.encodeUint(allocator, self.timestamp);
        try items.append(timestamp_encoded);

        // Witness
        const witness_encoded = try rlp_module.encodeBytes(allocator, self.witness);
        try items.append(witness_encoded);

        // Withdrawals
        const withdrawals_encoded = try rlp_module.encodeBytes(allocator, self.withdrawals);
        try items.append(withdrawals_encoded);

        // BlobHashes (list of hashes)
        var blob_hashes_items = std.ArrayList([]const u8).init(allocator);
        defer {
            for (blob_hashes_items.items) |item| {
                allocator.free(item);
            }
            blob_hashes_items.deinit();
        }
        for (self.blob_hashes) |blob_hash| {
            const blob_hash_bytes = types.hashToBytes(blob_hash);
            const blob_hash_encoded = try rlp_module.encodeBytes(allocator, &blob_hash_bytes);
            try blob_hashes_items.append(blob_hash_encoded);
        }
        const blob_hashes_list = try rlp_module.encodeList(allocator, blob_hashes_items.items);
        defer allocator.free(blob_hashes_list);
        try items.append(blob_hashes_list);

        // V
        const v_bytes = types.u256ToBytes(self.v);
        const v_encoded = try rlp_module.encodeBytes(allocator, &v_bytes);
        try items.append(v_encoded);

        // R
        const r_bytes = types.u256ToBytes(self.r);
        const r_encoded = try rlp_module.encodeBytes(allocator, &r_bytes);
        try items.append(r_encoded);

        // S
        const s_bytes = types.u256ToBytes(self.s);
        const s_encoded = try rlp_module.encodeBytes(allocator, &s_bytes);
        try items.append(s_encoded);

        const rlp_result = try rlp_module.encodeList(allocator, items.items);

        // Clean up intermediate items
        for (items.items) |item| {
            allocator.free(item);
        }

        return rlp_result;
    }

    /// Decode ExecuteTx from RLP bytes (without transaction type prefix)
    pub fn decodeRLP(allocator: std.mem.Allocator, data: []const u8) !Self {
        const decoded_list = try rlp_module.decodeList(allocator, data);
        defer {
            for (decoded_list.items) |item| {
                allocator.free(item);
            }
            allocator.free(decoded_list.items);
        }

        if (decoded_list.items.len < 22) {
            return error.InvalidRLP;
        }

        var idx: usize = 0;

        // ChainID
        const chain_id_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(chain_id_result.value);
        if (chain_id_result.value.len != 32) return error.InvalidRLP;
        var chain_id_bytes: [32]u8 = undefined;
        @memcpy(&chain_id_bytes, chain_id_result.value);
        const chain_id = types.u256FromBytes(chain_id_bytes);
        idx += 1;

        // Nonce
        const nonce_result = try rlp_module.decodeUint(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        const nonce = @as(u64, @intCast(nonce_result.value));
        idx += 1;

        // GasTipCap
        const gas_tip_cap_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(gas_tip_cap_result.value);
        if (gas_tip_cap_result.value.len != 32) return error.InvalidRLP;
        var gas_tip_cap_bytes: [32]u8 = undefined;
        @memcpy(&gas_tip_cap_bytes, gas_tip_cap_result.value);
        const gas_tip_cap = types.u256FromBytes(gas_tip_cap_bytes);
        idx += 1;

        // GasFeeCap
        const gas_fee_cap_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(gas_fee_cap_result.value);
        if (gas_fee_cap_result.value.len != 32) return error.InvalidRLP;
        var gas_fee_cap_bytes: [32]u8 = undefined;
        @memcpy(&gas_fee_cap_bytes, gas_fee_cap_result.value);
        const gas_fee_cap = types.u256FromBytes(gas_fee_cap_bytes);
        idx += 1;

        // Gas
        const gas_result = try rlp_module.decodeUint(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        const gas = @as(u64, @intCast(gas_result.value));
        idx += 1;

        // To
        defer allocator.free(decoded_list.items[idx]);
        const to_address: ?types.Address = if (decoded_list.items[idx].len == 0) null else blk: {
            if (decoded_list.items[idx].len != 20) {
                return error.InvalidRLP;
            }
            var addr_bytes: [20]u8 = undefined;
            @memcpy(&addr_bytes, decoded_list.items[idx]);
            break :blk types.addressFromBytes(addr_bytes);
        };
        idx += 1;

        // Value
        const value_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(value_result.value);
        if (value_result.value.len != 32) return error.InvalidRLP;
        var value_bytes: [32]u8 = undefined;
        @memcpy(&value_bytes, value_result.value);
        const value = types.u256FromBytes(value_bytes);
        idx += 1;

        // Data
        defer allocator.free(decoded_list.items[idx]);
        const data_bytes = try allocator.dupe(u8, decoded_list.items[idx]);
        idx += 1;

        // PreStateHash
        const pre_state_hash_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(pre_state_hash_result.value);
        if (pre_state_hash_result.value.len != 32) return error.InvalidRLP;
        var pre_state_hash_bytes: [32]u8 = undefined;
        @memcpy(&pre_state_hash_bytes, pre_state_hash_result.value);
        const pre_state_hash = types.hashFromBytes(pre_state_hash_bytes);
        idx += 1;

        // WitnessSize
        const witness_size_result = try rlp_module.decodeUint(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        const witness_size = @as(u32, @intCast(witness_size_result.value));
        idx += 1;

        // WithdrawalsSize
        const withdrawals_size_result = try rlp_module.decodeUint(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        const withdrawals_size = @as(u32, @intCast(withdrawals_size_result.value));
        idx += 1;

        // Coinbase
        defer allocator.free(decoded_list.items[idx]);
        if (decoded_list.items[idx].len != 20) {
            allocator.free(data_bytes);
            return error.InvalidRLP;
        }
        var coinbase_bytes: [20]u8 = undefined;
        @memcpy(&coinbase_bytes, decoded_list.items[idx]);
        const coinbase = types.addressFromBytes(coinbase_bytes);
        idx += 1;

        // BlockNumber
        const block_number_result = try rlp_module.decodeUint(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        const block_number = @as(u64, @intCast(block_number_result.value));
        idx += 1;

        // Timestamp
        const timestamp_result = try rlp_module.decodeUint(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        const timestamp = @as(u64, @intCast(timestamp_result.value));
        idx += 1;

        // Witness
        defer allocator.free(decoded_list.items[idx]);
        const witness_bytes = try allocator.dupe(u8, decoded_list.items[idx]);
        idx += 1;

        // Withdrawals
        defer allocator.free(decoded_list.items[idx]);
        const withdrawals_bytes = try allocator.dupe(u8, decoded_list.items[idx]);
        idx += 1;

        // BlobHashes
        defer allocator.free(decoded_list.items[idx]);
        const blob_hashes_list = try rlp_module.decodeList(allocator, decoded_list.items[idx]);
        defer {
            for (blob_hashes_list.items) |item| {
                allocator.free(item);
            }
            allocator.free(blob_hashes_list.items);
        }
        var blob_hashes = std.ArrayList(types.Hash).init(allocator);
        errdefer blob_hashes.deinit();
        for (blob_hashes_list.items) |blob_hash_item| {
            defer allocator.free(blob_hash_item);
            const blob_hash_bytes_result = try rlp_module.decodeBytes(allocator, blob_hash_item);
            defer allocator.free(blob_hash_bytes_result.value);
            if (blob_hash_bytes_result.value.len != 32) {
                blob_hashes.deinit();
                allocator.free(data_bytes);
                allocator.free(witness_bytes);
                allocator.free(withdrawals_bytes);
                return error.InvalidRLP;
            }
            var blob_hash_bytes: [32]u8 = undefined;
            @memcpy(&blob_hash_bytes, blob_hash_bytes_result.value);
            try blob_hashes.append(types.hashFromBytes(blob_hash_bytes));
        }
        idx += 1;

        // V
        const v_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(v_result.value);
        if (v_result.value.len != 32) {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.InvalidRLP;
        }
        var v_bytes: [32]u8 = undefined;
        @memcpy(&v_bytes, v_result.value);
        const v = types.u256FromBytes(v_bytes);
        idx += 1;

        // R
        const r_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(r_result.value);
        if (r_result.value.len != 32) {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.InvalidRLP;
        }
        var r_bytes: [32]u8 = undefined;
        @memcpy(&r_bytes, r_result.value);
        const r = types.u256FromBytes(r_bytes);
        idx += 1;

        // S
        const s_result = try rlp_module.decodeBytes(allocator, decoded_list.items[idx]);
        defer allocator.free(decoded_list.items[idx]);
        defer allocator.free(s_result.value);
        if (s_result.value.len != 32) {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.InvalidRLP;
        }
        var s_bytes: [32]u8 = undefined;
        @memcpy(&s_bytes, s_result.value);
        const s = types.u256FromBytes(s_bytes);

        // Validate witness and withdrawals sizes
        if (witness_bytes.len != witness_size) {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.InvalidRLP;
        }
        if (withdrawals_bytes.len != withdrawals_size) {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.InvalidRLP;
        }

        return Self{
            .chain_id = chain_id,
            .nonce = nonce,
            .gas_tip_cap = gas_tip_cap,
            .gas_fee_cap = gas_fee_cap,
            .gas = gas,
            .to = to_address,
            .value = value,
            .data = data_bytes,
            .pre_state_hash = pre_state_hash,
            .witness_size = witness_size,
            .withdrawals_size = withdrawals_size,
            .coinbase = coinbase,
            .block_number = block_number,
            .timestamp = timestamp,
            .witness = witness_bytes,
            .withdrawals = withdrawals_bytes,
            .blob_hashes = try blob_hashes.toOwnedSlice(),
            .v = v,
            .r = r,
            .s = s,
        };
    }

    /// Decode ExecuteTx from raw transaction bytes (with EIP-2718 type prefix)
    pub fn fromRaw(allocator: std.mem.Allocator, raw: []const u8) !Self {
        if (raw.len == 0) return error.InvalidRLP;
        if (raw[0] != ExecuteTxType) return error.InvalidRLP;

        // Skip transaction type byte and decode RLP
        return decodeRLP(allocator, raw[1..]);
    }

    /// Serialize ExecuteTx to raw transaction bytes (with EIP-2718 type prefix)
    pub fn serialize(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        const rlp_data = try self.encodeRLP(allocator);
        defer allocator.free(rlp_data);

        // Prepend transaction type byte
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        try result.append(ExecuteTxType);
        try result.appendSlice(rlp_data);

        return try result.toOwnedSlice();
    }

    /// Recover sender address from signature
    pub fn sender(self: *const Self, allocator: std.mem.Allocator) !types.Address {
        // For EIP-2718 typed transactions, we need to hash the transaction data
        // and recover the address from the signature
        const tx_hash = try self.hash(allocator);

        // Extract r, s, v from u256 fields
        const r_bytes = types.u256ToBytes(self.r);
        const s_bytes = types.u256ToBytes(self.s);
        const v_byte = @as(u8, @intCast(self.v & 0xff));

        // Create signature struct
        const sig = types.Signature{
            .r = r_bytes,
            .s = s_bytes,
            .v = v_byte,
        };

        // Use secp256k1 to recover public key from signature
        const secp256k1_mod = @import("../crypto/secp256k1_wrapper.zig");
        const pubkey = try secp256k1_mod.recoverPublicKey(tx_hash, sig);

        // Derive address from public key
        return pubkey.toAddress();
    }

    /// Get priority for mempool ordering (gas fee cap)
    pub fn priority(self: *const Self) u256 {
        return self.gas_fee_cap;
    }

    /// Serialize ExecuteTx to JSON format matching go-ethereum
    pub fn toJson(self: *const Self, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer obj.deinit();

        // Transaction type
        try obj.put("type", std.json.Value{ .string = try std.fmt.allocPrint(allocator, "0x{d:0>2}", .{ExecuteTxType}) });

        // ChainID
        const chain_id_hex = try u256ToHex(allocator, self.chain_id);
        try obj.put("chainId", std.json.Value{ .string = chain_id_hex });

        // Nonce
        const nonce_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.nonce});
        try obj.put("nonce", std.json.Value{ .string = nonce_hex });

        // Gas
        const gas_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.gas});
        try obj.put("gas", std.json.Value{ .string = gas_hex });

        // To
        if (self.to) |to| {
            const to_bytes = types.addressToBytes(to);
            const to_hex = try bytesToHex(allocator, &to_bytes);
            try obj.put("to", std.json.Value{ .string = to_hex });
        } else {
            try obj.put("to", std.json.Value{ .null = {} });
        }

        // MaxPriorityFeePerGas
        const gas_tip_cap_hex = try u256ToHex(allocator, self.gas_tip_cap);
        try obj.put("maxPriorityFeePerGas", std.json.Value{ .string = gas_tip_cap_hex });

        // MaxFeePerGas
        const gas_fee_cap_hex = try u256ToHex(allocator, self.gas_fee_cap);
        try obj.put("maxFeePerGas", std.json.Value{ .string = gas_fee_cap_hex });

        // Value
        const value_hex = try u256ToHex(allocator, self.value);
        try obj.put("value", std.json.Value{ .string = value_hex });

        // Input (data)
        const input_hex = try bytesToHex(allocator, self.data);
        try obj.put("input", std.json.Value{ .string = input_hex });

        // PreStateHash
        const pre_state_hash_bytes = types.hashToBytes(self.pre_state_hash);
        const pre_state_hash_hex = try bytesToHex(allocator, &pre_state_hash_bytes);
        try obj.put("preStateHash", std.json.Value{ .string = pre_state_hash_hex });

        // Coinbase
        const coinbase_bytes = types.addressToBytes(self.coinbase);
        const coinbase_hex = try bytesToHex(allocator, &coinbase_bytes);
        try obj.put("coinbase", std.json.Value{ .string = coinbase_hex });

        // BlockNumber
        const block_number_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.block_number});
        try obj.put("blockNumber", std.json.Value{ .string = block_number_hex });

        // Timestamp
        const timestamp_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.timestamp});
        try obj.put("timestamp", std.json.Value{ .string = timestamp_hex });

        // Witness
        const witness_hex = try bytesToHex(allocator, self.witness);
        try obj.put("witness", std.json.Value{ .string = witness_hex });

        // WitnessSize
        const witness_size_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.witness_size});
        try obj.put("witnessSize", std.json.Value{ .string = witness_size_hex });

        // Withdrawals
        const withdrawals_hex = try bytesToHex(allocator, self.withdrawals);
        try obj.put("withdrawals", std.json.Value{ .string = withdrawals_hex });

        // WithdrawalsSize
        const withdrawals_size_hex = try std.fmt.allocPrint(allocator, "0x{x}", .{self.withdrawals_size});
        try obj.put("withdrawalsSize", std.json.Value{ .string = withdrawals_size_hex });

        // BlobVersionedHashes
        if (self.blob_hashes.len > 0) {
            var blob_array = std.ArrayList(std.json.Value).init(allocator);
            errdefer blob_array.deinit();
            for (self.blob_hashes) |blob_hash| {
                const blob_hash_bytes = types.hashToBytes(blob_hash);
                const blob_hash_hex = try bytesToHex(allocator, &blob_hash_bytes);
                try blob_array.append(std.json.Value{ .string = blob_hash_hex });
            }
            try obj.put("blobVersionedHashes", std.json.Value{ .array = .{ .items = try blob_array.toOwnedSlice(), .capacity = blob_array.items.len } });
        }

        // V
        const v_hex = try u256ToHex(allocator, self.v);
        try obj.put("v", std.json.Value{ .string = v_hex });

        // R
        const r_hex = try u256ToHex(allocator, self.r);
        try obj.put("r", std.json.Value{ .string = r_hex });

        // S
        const s_hex = try u256ToHex(allocator, self.s);
        try obj.put("s", std.json.Value{ .string = s_hex });

        return std.json.Value{ .object = obj };
    }

    /// Deserialize ExecuteTx from JSON format matching go-ethereum
    pub fn fromJson(allocator: std.mem.Allocator, json_value: std.json.Value) !Self {
        const obj = switch (json_value) {
            .object => |o| o,
            else => return error.InvalidJson,
        };

        // ChainID (required)
        const chain_id_val = obj.get("chainId") orelse return error.MissingField;
        const chain_id_hex = switch (chain_id_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const chain_id = try hexToU256(chain_id_hex);

        // Nonce (required)
        const nonce_val = obj.get("nonce") orelse return error.MissingField;
        const nonce_hex = switch (nonce_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const nonce = try hexToU64(nonce_hex);

        // Gas (required)
        const gas_val = obj.get("gas") orelse return error.MissingField;
        const gas_hex = switch (gas_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const gas = try hexToU64(gas_hex);

        // To (optional)
        const to_address: ?types.Address = if (obj.get("to")) |to_val| blk: {
            const to_hex = switch (to_val) {
                .string => |s| s,
                .null => break :blk null,
                else => return error.InvalidField,
            };
            if (to_hex.len == 0) break :blk null;
            const to_bytes = try hexToBytes(allocator, to_hex);
            defer allocator.free(to_bytes);
            if (to_bytes.len != 20) return error.InvalidAddress;
            var addr_bytes: [20]u8 = undefined;
            @memcpy(&addr_bytes, to_bytes);
            break :blk types.addressFromBytes(addr_bytes);
        } else null;

        // MaxPriorityFeePerGas (required)
        const gas_tip_cap_val = obj.get("maxPriorityFeePerGas") orelse return error.MissingField;
        const gas_tip_cap_hex = switch (gas_tip_cap_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const gas_tip_cap = try hexToU256(gas_tip_cap_hex);

        // MaxFeePerGas (required)
        const gas_fee_cap_val = obj.get("maxFeePerGas") orelse return error.MissingField;
        const gas_fee_cap_hex = switch (gas_fee_cap_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const gas_fee_cap = try hexToU256(gas_fee_cap_hex);

        // Value (required)
        const value_val = obj.get("value") orelse return error.MissingField;
        const value_hex = switch (value_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const value = try hexToU256(value_hex);

        // Input/Data (required)
        const input_val = obj.get("input") orelse return error.MissingField;
        const input_hex = switch (input_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const data_bytes = try hexToBytes(allocator, input_hex);

        // PreStateHash (required)
        const pre_state_hash_val = obj.get("preStateHash") orelse return error.MissingField;
        const pre_state_hash_hex = switch (pre_state_hash_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const pre_state_hash_bytes = try hexToBytes(allocator, pre_state_hash_hex);
        defer allocator.free(pre_state_hash_bytes);
        if (pre_state_hash_bytes.len != 32) {
            allocator.free(data_bytes);
            return error.InvalidHash;
        }
        var pre_state_hash_array: [32]u8 = undefined;
        @memcpy(&pre_state_hash_array, pre_state_hash_bytes);
        const pre_state_hash = types.hashFromBytes(pre_state_hash_array);

        // Coinbase (required)
        const coinbase_val = obj.get("coinbase") orelse return error.MissingField;
        const coinbase_hex = switch (coinbase_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const coinbase_bytes = try hexToBytes(allocator, coinbase_hex);
        defer allocator.free(coinbase_bytes);
        if (coinbase_bytes.len != 20) {
            allocator.free(data_bytes);
            return error.InvalidAddress;
        }
        var coinbase_array: [20]u8 = undefined;
        @memcpy(&coinbase_array, coinbase_bytes);
        const coinbase = types.addressFromBytes(coinbase_array);

        // BlockNumber (required)
        const block_number_val = obj.get("blockNumber") orelse return error.MissingField;
        const block_number_hex = switch (block_number_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const block_number = try hexToU64(block_number_hex);

        // Timestamp (required)
        const timestamp_val = obj.get("timestamp") orelse return error.MissingField;
        const timestamp_hex = switch (timestamp_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const timestamp = try hexToU64(timestamp_hex);

        // Witness (required)
        const witness_val = obj.get("witness") orelse return error.MissingField;
        const witness_hex = switch (witness_val) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        const witness_bytes = try hexToBytes(allocator, witness_hex);

        // WitnessSize (optional, derived from witness length if not provided)
        var witness_size: u32 = @intCast(witness_bytes.len);
        if (obj.get("witnessSize")) |witness_size_val| {
            const witness_size_hex = switch (witness_size_val) {
                .string => |s| s,
                else => {
                    allocator.free(data_bytes);
                    allocator.free(witness_bytes);
                    return error.InvalidField;
                },
            };
            witness_size = @intCast(try hexToU64(witness_size_hex));
            if (witness_size != witness_bytes.len) {
                allocator.free(data_bytes);
                allocator.free(witness_bytes);
                return error.InvalidWitnessSize;
            }
        }

        // Withdrawals (required)
        const withdrawals_val = obj.get("withdrawals") orelse {
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            return error.MissingField;
        };
        const withdrawals_hex = switch (withdrawals_val) {
            .string => |s| s,
            else => {
                allocator.free(data_bytes);
                allocator.free(witness_bytes);
                return error.InvalidField;
            },
        };
        const withdrawals_bytes = try hexToBytes(allocator, withdrawals_hex);

        // WithdrawalsSize (optional, derived from withdrawals length if not provided)
        var withdrawals_size: u32 = @intCast(withdrawals_bytes.len);
        if (obj.get("withdrawalsSize")) |withdrawals_size_val| {
            const withdrawals_size_hex = switch (withdrawals_size_val) {
                .string => |s| s,
                else => {
                    allocator.free(data_bytes);
                    allocator.free(witness_bytes);
                    allocator.free(withdrawals_bytes);
                    return error.InvalidField;
                },
            };
            withdrawals_size = @intCast(try hexToU64(withdrawals_size_hex));
            if (withdrawals_size != withdrawals_bytes.len) {
                allocator.free(data_bytes);
                allocator.free(witness_bytes);
                allocator.free(withdrawals_bytes);
                return error.InvalidWithdrawalsSize;
            }
        }

        // BlobVersionedHashes (optional)
        var blob_hashes = std.ArrayList(types.Hash).init(allocator);
        errdefer blob_hashes.deinit();
        if (obj.get("blobVersionedHashes")) |blob_hashes_val| {
            const blob_array = switch (blob_hashes_val) {
                .array => |arr| arr,
                else => {
                    allocator.free(data_bytes);
                    allocator.free(witness_bytes);
                    allocator.free(withdrawals_bytes);
                    return error.InvalidField;
                },
            };
            for (blob_array.items) |blob_hash_val| {
                const blob_hash_hex = switch (blob_hash_val) {
                    .string => |s| s,
                    else => {
                        blob_hashes.deinit();
                        allocator.free(data_bytes);
                        allocator.free(witness_bytes);
                        allocator.free(withdrawals_bytes);
                        return error.InvalidField;
                    },
                };
                const blob_hash_bytes = try hexToBytes(allocator, blob_hash_hex);
                defer allocator.free(blob_hash_bytes);
                if (blob_hash_bytes.len != 32) {
                    blob_hashes.deinit();
                    allocator.free(data_bytes);
                    allocator.free(witness_bytes);
                    allocator.free(withdrawals_bytes);
                    return error.InvalidHash;
                }
                var blob_hash_array: [32]u8 = undefined;
                @memcpy(&blob_hash_array, blob_hash_bytes);
                try blob_hashes.append(types.hashFromBytes(blob_hash_array));
            }
        }

        // R (required)
        const r_val = obj.get("r") orelse {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.MissingField;
        };
        const r_hex = switch (r_val) {
            .string => |s| s,
            else => {
                blob_hashes.deinit();
                allocator.free(data_bytes);
                allocator.free(witness_bytes);
                allocator.free(withdrawals_bytes);
                return error.InvalidField;
            },
        };
        const r = try hexToU256(r_hex);

        // S (required)
        const s_val = obj.get("s") orelse {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.MissingField;
        };
        const s_hex = switch (s_val) {
            .string => |s_str| s_str,
            else => {
                blob_hashes.deinit();
                allocator.free(data_bytes);
                allocator.free(witness_bytes);
                allocator.free(withdrawals_bytes);
                return error.InvalidField;
            },
        };
        const s = try hexToU256(s_hex);

        // V (required, can be from v or yParity)
        var v: u256 = undefined;
        if (obj.get("v")) |v_val| {
            const v_hex = switch (v_val) {
                .string => |v_str| v_str,
                else => {
                    blob_hashes.deinit();
                    allocator.free(data_bytes);
                    allocator.free(witness_bytes);
                    allocator.free(withdrawals_bytes);
                    return error.InvalidField;
                },
            };
            v = try hexToU256(v_hex);
        } else if (obj.get("yParity")) |yparity_val| {
            const yparity_hex = switch (yparity_val) {
                .string => |yp_str| yp_str,
                else => {
                    blob_hashes.deinit();
                    allocator.free(data_bytes);
                    allocator.free(witness_bytes);
                    allocator.free(withdrawals_bytes);
                    return error.InvalidField;
                },
            };
            const yparity = try hexToU64(yparity_hex);
            // Convert yParity to v (for EIP-155, v = chain_id * 2 + 35 + yParity)
            const v_value = (chain_id * 2) + 35 + yparity;
            v = v_value;
        } else {
            blob_hashes.deinit();
            allocator.free(data_bytes);
            allocator.free(witness_bytes);
            allocator.free(withdrawals_bytes);
            return error.MissingField;
        }

        return Self{
            .chain_id = chain_id,
            .nonce = nonce,
            .gas_tip_cap = gas_tip_cap,
            .gas_fee_cap = gas_fee_cap,
            .gas = gas,
            .to = to_address,
            .value = value,
            .data = data_bytes,
            .pre_state_hash = pre_state_hash,
            .witness_size = witness_size,
            .withdrawals_size = withdrawals_size,
            .coinbase = coinbase,
            .block_number = block_number,
            .timestamp = timestamp,
            .witness = witness_bytes,
            .withdrawals = withdrawals_bytes,
            .blob_hashes = try blob_hashes.toOwnedSlice(),
            .v = v,
            .r = r,
            .s = s,
        };
    }

    /// Free allocated memory
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.witness);
        allocator.free(self.withdrawals);
        allocator.free(self.blob_hashes);
    }
};

// Helper functions for JSON serialization

fn u256ToHex(allocator: std.mem.Allocator, value: u256) ![]u8 {
    const bytes = types.u256ToBytes(value);
    return bytesToHex(allocator, &bytes);
}

fn hexToU256(hex_str: []const u8) !u256 {
    const bytes = try hexToBytesNoAlloc(hex_str);
    return types.u256FromBytes(bytes);
}

fn hexToU64(hex_str: []const u8) !u64 {
    const hex_start: usize = if (std.mem.startsWith(u8, hex_str, "0x")) 2 else 0;
    const hex_data = hex_str[hex_start..];
    if (hex_data.len == 0) return 0;
    return try std.fmt.parseInt(u64, hex_data, 16);
}

fn bytesToHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    try result.appendSlice("0x");
    for (bytes) |byte| {
        try result.writer().print("{x:0>2}", .{byte});
    }
    return try result.toOwnedSlice();
}

fn hexToBytes(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const hex_start: usize = if (std.mem.startsWith(u8, hex_str, "0x")) 2 else 0;
    const hex_data = hex_str[hex_start..];

    var bytes = std.ArrayList(u8).init(allocator);
    errdefer bytes.deinit();

    var i: usize = 0;
    while (i < hex_data.len) : (i += 2) {
        if (i + 1 >= hex_data.len) break;
        const byte = try std.fmt.parseInt(u8, hex_data[i .. i + 2], 16);
        try bytes.append(byte);
    }

    return try bytes.toOwnedSlice();
}

fn hexToBytesNoAlloc(hex_str: []const u8) ![32]u8 {
    const hex_start: usize = if (std.mem.startsWith(u8, hex_str, "0x")) 2 else 0;
    const hex_data = hex_str[hex_start..];

    var result: [32]u8 = undefined;
    @memset(&result, 0);

    // Parse hex string and store in big-endian format (left-padded)
    var result_idx: usize = 32;
    var hex_idx: usize = hex_data.len;

    // Process from right to left to maintain big-endian order
    while (hex_idx > 0 and result_idx > 0) {
        hex_idx -= 2;
        if (hex_idx + 1 >= hex_data.len) break;
        result_idx -= 1;
        result[result_idx] = try std.fmt.parseInt(u8, hex_data[hex_idx .. hex_idx + 2], 16);
    }

    return result;
}

const ExecuteTxError = error{
    InvalidJson,
    MissingField,
    InvalidField,
    InvalidAddress,
    InvalidHash,
    InvalidWitnessSize,
    InvalidWithdrawalsSize,
};
