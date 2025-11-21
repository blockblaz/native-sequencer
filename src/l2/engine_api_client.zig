// Engine API client for L2 geth communication
// Implements Engine API endpoints: engine_newPayload, engine_getPayload, engine_forkchoiceUpdatedV3

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const block_module = @import("../core/block.zig");
const crypto = @import("../crypto/root.zig");

pub const EngineApiClient = struct {
    allocator: std.mem.Allocator,
    l2_rpc_url: []const u8,
    l2_engine_api_port: u16,
    jwt_secret: ?[32]u8 = null, // JWT secret for Engine API authentication

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, l2_rpc_url: []const u8, l2_engine_api_port: u16, jwt_secret: ?[32]u8) Self {
        return .{
            .allocator = allocator,
            .l2_rpc_url = l2_rpc_url,
            .l2_engine_api_port = l2_engine_api_port,
            .jwt_secret = jwt_secret,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed
    }

    /// Payload status response
    pub const PayloadStatus = struct {
        status: []const u8, // "VALID", "INVALID", "SYNCING", "ACCEPTED"
        latest_valid_hash: ?[]const u8,
        validation_error: ?[]const u8,
    };

    /// Fork choice update response
    pub const ForkChoiceUpdateResponse = struct {
        payload_status: PayloadStatus,
        payload_id: ?[]const u8,
    };

    /// Submit block to L2 geth via engine_newPayload
    pub fn newPayload(self: *Self, block: *const block_module.Block) !PayloadStatus {
        const block_hash = block.hash();
        const block_hash_hex = try self.hashToHex(block_hash);
        defer self.allocator.free(block_hash_hex);

        std.log.info("[EngineAPI] Calling engine_newPayload for block #{d} (hash: {s}, {d} txs, {d} gas used)", .{
            block.number,
            block_hash_hex,
            block.transactions.len,
            block.gas_used,
        });

        // Convert block to Engine API payload format
        const payload = try self.blockToPayload(block);
        defer self.allocator.free(payload.transactions);
        defer self.allocator.free(payload.block_hash);

        // Build JSON-RPC request
        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        var payload_obj = std.json.ObjectMap.init(self.allocator);
        defer payload_obj.deinit();

        try payload_obj.put("parentHash", std.json.Value{ .string = try self.hashToHex(payload.parent_hash) });
        try payload_obj.put("feeRecipient", std.json.Value{ .string = try self.addressToHex(payload.fee_recipient) });
        try payload_obj.put("stateRoot", std.json.Value{ .string = try self.hashToHex(payload.state_root) });
        try payload_obj.put("receiptsRoot", std.json.Value{ .string = try self.hashToHex(payload.receipts_root) });
        try payload_obj.put("logsBloom", std.json.Value{ .string = try self.bytesToHex(&payload.logs_bloom) });
        try payload_obj.put("prevRandao", std.json.Value{ .string = try self.hashToHex(payload.prev_randao) });
        try payload_obj.put("blockNumber", std.json.Value{ .string = try std.fmt.allocPrint(self.allocator, "0x{x}", .{payload.block_number}) });
        try payload_obj.put("gasLimit", std.json.Value{ .string = try std.fmt.allocPrint(self.allocator, "0x{x}", .{payload.gas_limit}) });
        try payload_obj.put("gasUsed", std.json.Value{ .string = try std.fmt.allocPrint(self.allocator, "0x{x}", .{payload.gas_used}) });
        try payload_obj.put("timestamp", std.json.Value{ .string = try std.fmt.allocPrint(self.allocator, "0x{x}", .{payload.timestamp}) });
        try payload_obj.put("extraData", std.json.Value{ .string = "0x" });
        try payload_obj.put("baseFeePerGas", std.json.Value{ .string = try std.fmt.allocPrint(self.allocator, "0x{x}", .{payload.base_fee_per_gas}) });
        try payload_obj.put("blockHash", std.json.Value{ .string = try self.hashToHex(payload.block_hash) });

        // Add transactions
        var tx_array = std.json.Array.init(self.allocator);
        defer tx_array.deinit();
        for (payload.transactions) |tx_hex| {
            try tx_array.append(std.json.Value{ .string = tx_hex });
        }
        try payload_obj.put("transactions", std.json.Value{ .array = tx_array });

        // Add withdrawals (empty for now)
        var withdrawals_array = std.json.Array.init(self.allocator);
        defer withdrawals_array.deinit();
        try payload_obj.put("withdrawals", std.json.Value{ .array = withdrawals_array });

        try params.append(std.json.Value{ .object = payload_obj });

        const result = try self.callRpc("engine_newPayload", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse response
        const parsed = try std.json.parseFromSliceLeaky(
            struct {
                result: struct {
                    status: []const u8,
                    latestValidHash: ?[]const u8,
                    validationError: ?[]const u8,
                },
            },
            self.allocator,
            result,
            .{},
        );

        const status = PayloadStatus{
            .status = parsed.result.status,
            .latest_valid_hash = parsed.result.latestValidHash,
            .validation_error = parsed.result.validationError,
        };

        std.log.info("[EngineAPI] engine_newPayload response for block #{d}: status={s}", .{
            block.number,
            status.status,
        });

        if (status.latest_valid_hash) |hash| {
            std.log.info("[EngineAPI] Latest valid hash: {s}", .{hash});
        }

        if (status.validation_error) |err| {
            std.log.err("[EngineAPI] Validation error for block #{d}: {s}", .{ block.number, err });
        }

        return status;
    }

    /// Withdrawal represents a validator withdrawal (EIP-4895)
    pub const Withdrawal = struct {
        index: u64,
        validator_index: u64,
        address: types.Address,
        amount: u64, // Amount in Gwei

        pub fn deinit(self: *Withdrawal, allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
            // No dynamic memory to free
        }
    };

    /// Execution payload returned from engine_getPayload
    pub const ExecutionPayload = struct {
        block_hash: types.Hash,
        block_number: u64,
        parent_hash: types.Hash,
        timestamp: u64,
        fee_recipient: types.Address,
        state_root: types.Hash,
        receipts_root: types.Hash,
        logs_bloom: [256]u8,
        prev_randao: types.Hash,
        gas_limit: u64,
        gas_used: u64,
        transactions: [][]const u8, // RLP-encoded transactions
        extra_data: []const u8, // Block extra data
        base_fee_per_gas: ?u256, // Base fee per gas (EIP-1559), null if not present
        withdrawals: []Withdrawal, // Withdrawals array (Shanghai/Cancun), empty if not present
        blob_gas_used: ?u64, // Blob gas used (Cancun), null if not present
        excess_blob_gas: ?u64, // Excess blob gas (Cancun), null if not present

        pub fn deinit(self: *ExecutionPayload, allocator: std.mem.Allocator) void {
            for (self.transactions) |tx| {
                allocator.free(tx);
            }
            allocator.free(self.transactions);
            allocator.free(self.extra_data);
            for (self.withdrawals) |*w| {
                w.deinit(allocator);
            }
            allocator.free(self.withdrawals);
        }
    };

    /// Get payload from L2 geth via engine_getPayload
    pub fn getPayload(self: *Self, payload_id: []const u8) !ExecutionPayload {
        std.log.info("[EngineAPI] Calling engine_getPayload with payload_id: {s}", .{payload_id});

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        var payload_id_obj = std.json.ObjectMap.init(self.allocator);
        defer payload_id_obj.deinit();
        try payload_id_obj.put("payloadId", std.json.Value{ .string = payload_id });

        try params.append(std.json.Value{ .object = payload_id_obj });

        const result = try self.callRpc("engine_getPayload", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Debug: log raw response for troubleshooting
        std.log.debug("[EngineAPI] Raw engine_getPayload response: {s}", .{result});

        // Parse full execution payload response - parse all fields including extra ones
        const parsed = std.json.parseFromSliceLeaky(
            struct {
                result: ?struct {
                    blockHash: []const u8,
                    blockNumber: []const u8,
                    parentHash: []const u8,
                    timestamp: []const u8,
                    feeRecipient: []const u8,
                    stateRoot: []const u8,
                    receiptsRoot: []const u8,
                    logsBloom: []const u8,
                    prevRandao: []const u8,
                    gasLimit: []const u8,
                    gasUsed: []const u8,
                    transactions: [][]const u8,
                    extraData: ?[]const u8, // Optional - may not be present in older versions
                    baseFeePerGas: ?[]const u8, // Optional - EIP-1559, null for pre-London blocks
                    withdrawals: ?[]struct {
                        index: []const u8,
                        validatorIndex: []const u8,
                        address: []const u8,
                        amount: []const u8,
                    }, // Optional - Shanghai/Cancun upgrade
                    blobGasUsed: ?[]const u8, // Optional - Cancun upgrade
                    excessBlobGas: ?[]const u8, // Optional - Cancun upgrade
                },
                @"error": ?struct {
                    code: i32,
                    message: []const u8,
                },
            },
            self.allocator,
            result,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.log.err("[EngineAPI] Failed to parse engine_getPayload response: {any}, response: {s}", .{ err, result });
            return err;
        };

        // Check for error response
        if (parsed.@"error") |err| {
            std.log.err("[EngineAPI] engine_getPayload error response: code={d}, message={s}", .{ err.code, err.message });
            return error.EngineApiError;
        }

        // Check if result is present
        const result_data = parsed.result orelse {
            std.log.err("[EngineAPI] engine_getPayload response missing 'result' field, response: {s}", .{result});
            return error.MissingField;
        };

        const block_hash = try self.hexToHash(result_data.blockHash);
        const parent_hash = try self.hexToHash(result_data.parentHash);
        const state_root = try self.hexToHash(result_data.stateRoot);
        const receipts_root = try self.hexToHash(result_data.receiptsRoot);
        const prev_randao = try self.hexToHash(result_data.prevRandao);
        const fee_recipient = try self.hexToAddress(result_data.feeRecipient);

        const hex_start: usize = if (std.mem.startsWith(u8, result_data.blockNumber, "0x")) 2 else 0;
        const block_number = try std.fmt.parseInt(u64, result_data.blockNumber[hex_start..], 16);

        const timestamp_start: usize = if (std.mem.startsWith(u8, result_data.timestamp, "0x")) 2 else 0;
        const timestamp = try std.fmt.parseInt(u64, result_data.timestamp[timestamp_start..], 16);

        const gas_limit_start: usize = if (std.mem.startsWith(u8, result_data.gasLimit, "0x")) 2 else 0;
        const gas_limit = try std.fmt.parseInt(u64, result_data.gasLimit[gas_limit_start..], 16);

        const gas_used_start: usize = if (std.mem.startsWith(u8, result_data.gasUsed, "0x")) 2 else 0;
        const gas_used = try std.fmt.parseInt(u64, result_data.gasUsed[gas_used_start..], 16);

        // Parse logs bloom
        var logs_bloom: [256]u8 = undefined;
        const bloom_hex_start: usize = if (std.mem.startsWith(u8, result_data.logsBloom, "0x")) 2 else 0;
        const bloom_hex = result_data.logsBloom[bloom_hex_start..];
        if (bloom_hex.len != 512) {
            return error.InvalidLogsBloomLength;
        }
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const high = try std.fmt.parseInt(u8, bloom_hex[i * 2 .. i * 2 + 1], 16);
            const low = try std.fmt.parseInt(u8, bloom_hex[i * 2 + 1 .. i * 2 + 2], 16);
            logs_bloom[i] = (high << 4) | low;
        }

        // Clone transactions
        const transactions = try self.allocator.alloc([]const u8, result_data.transactions.len);
        for (result_data.transactions, 0..) |tx_hex, idx| {
            transactions[idx] = try self.allocator.dupe(u8, tx_hex);
        }

        // Parse extraData (optional)
        const extra_data = if (result_data.extraData) |ed| try self.hexToBytes(ed) else try self.allocator.alloc(u8, 0);

        // Parse baseFeePerGas (optional, EIP-1559)
        const base_fee_per_gas: ?u256 = if (result_data.baseFeePerGas) |bfpg| blk: {
            const bfpg_bytes = try self.hexToBytes(bfpg);
            defer self.allocator.free(bfpg_bytes);
            // Convert bytes to u256 (big-endian)
            var value: u256 = 0;
            for (bfpg_bytes) |byte| {
                value = (value << 8) | byte;
            }
            break :blk value;
        } else null;

        // Parse withdrawals (optional, Shanghai/Cancun)
        const withdrawals = if (result_data.withdrawals) |wds| blk: {
            const withdrawals_array = try self.allocator.alloc(Withdrawal, wds.len);
            for (wds, 0..) |wd, idx| {
                const index_hex_start: usize = if (std.mem.startsWith(u8, wd.index, "0x")) 2 else 0;
                const index = try std.fmt.parseInt(u64, wd.index[index_hex_start..], 16);

                const validator_index_hex_start: usize = if (std.mem.startsWith(u8, wd.validatorIndex, "0x")) 2 else 0;
                const validator_index = try std.fmt.parseInt(u64, wd.validatorIndex[validator_index_hex_start..], 16);

                const address = try self.hexToAddress(wd.address);

                const amount_hex_start: usize = if (std.mem.startsWith(u8, wd.amount, "0x")) 2 else 0;
                const amount = try std.fmt.parseInt(u64, wd.amount[amount_hex_start..], 16);

                withdrawals_array[idx] = Withdrawal{
                    .index = index,
                    .validator_index = validator_index,
                    .address = address,
                    .amount = amount,
                };
            }
            break :blk withdrawals_array;
        } else try self.allocator.alloc(Withdrawal, 0);

        // Parse blobGasUsed (optional, Cancun)
        const blob_gas_used: ?u64 = if (result_data.blobGasUsed) |bgu| blk: {
            const bgu_hex_start: usize = if (std.mem.startsWith(u8, bgu, "0x")) 2 else 0;
            break :blk try std.fmt.parseInt(u64, bgu[bgu_hex_start..], 16);
        } else null;

        // Parse excessBlobGas (optional, Cancun)
        const excess_blob_gas: ?u64 = if (result_data.excessBlobGas) |ebg| blk: {
            const ebg_hex_start: usize = if (std.mem.startsWith(u8, ebg, "0x")) 2 else 0;
            break :blk try std.fmt.parseInt(u64, ebg[ebg_hex_start..], 16);
        } else null;

        const block_hash_hex = try self.hashToHex(block_hash);
        defer self.allocator.free(block_hash_hex);

        std.log.info("[EngineAPI] engine_getPayload response: block_hash={s}, block_number={d}, {d} txs, {d} withdrawals", .{
            block_hash_hex,
            block_number,
            transactions.len,
            withdrawals.len,
        });

        return ExecutionPayload{
            .block_hash = block_hash,
            .block_number = block_number,
            .parent_hash = parent_hash,
            .timestamp = timestamp,
            .fee_recipient = fee_recipient,
            .state_root = state_root,
            .receipts_root = receipts_root,
            .logs_bloom = logs_bloom,
            .prev_randao = prev_randao,
            .gas_limit = gas_limit,
            .gas_used = gas_used,
            .transactions = transactions,
            .extra_data = extra_data,
            .base_fee_per_gas = base_fee_per_gas,
            .withdrawals = withdrawals,
            .blob_gas_used = blob_gas_used,
            .excess_blob_gas = excess_blob_gas,
        };
    }

    /// Update fork choice state via engine_forkchoiceUpdatedV3 (with optional payload attributes)
    /// If payload_attrs is provided, requests L2 geth to build a payload
    /// Note: payload_attrs ownership is NOT transferred - caller must manage its memory
    pub fn forkchoiceUpdated(self: *Self, head_block_hash: types.Hash, safe_block_hash: types.Hash, finalized_block_hash: types.Hash, payload_attrs: ?std.json.ObjectMap) !ForkChoiceUpdateResponse {
        const head_hex = try self.hashToHex(head_block_hash);
        defer self.allocator.free(head_hex);
        const safe_hex = try self.hashToHex(safe_block_hash);
        defer self.allocator.free(safe_hex);
        const finalized_hex = try self.hashToHex(finalized_block_hash);
        defer self.allocator.free(finalized_hex);

        std.log.info("[EngineAPI] Calling engine_forkchoiceUpdatedV3: head={s}, safe={s}, finalized={s}", .{
            head_hex,
            safe_hex,
            finalized_hex,
        });

        // Serialize params to JSON string before building HTTP request
        // This ensures all string references are valid during serialization
        var params_json_str = std.ArrayList(u8).init(self.allocator);
        defer params_json_str.deinit();

        try params_json_str.append('[');

        // Fork choice state object
        try params_json_str.append('{');
        try params_json_str.writer().print("\"headBlockHash\":\"{s}\"", .{head_hex});
        try params_json_str.append(',');
        try params_json_str.writer().print("\"safeBlockHash\":\"{s}\"", .{safe_hex});
        try params_json_str.append(',');
        try params_json_str.writer().print("\"finalizedBlockHash\":\"{s}\"", .{finalized_hex});
        try params_json_str.append('}');

        // Payload attributes (optional)
        if (payload_attrs) |attrs| {
            try params_json_str.append(',');
            const attrs_str = try self.jsonValueToString(std.json.Value{ .object = attrs });
            defer self.allocator.free(attrs_str);
            try params_json_str.writer().print("{s}", .{attrs_str});
        } else {
            try params_json_str.append(',');
            try params_json_str.appendSlice("{}");
        }

        try params_json_str.append(']');
        const params_json = try params_json_str.toOwnedSlice();
        defer self.allocator.free(params_json);

        // Build JSON-RPC request directly with serialized params
        var request_json = std.ArrayList(u8).init(self.allocator);
        defer request_json.deinit();

        try request_json.writer().print(
            \\{{"jsonrpc":"2.0","method":"engine_forkchoiceUpdatedV3","params":{s},"id":1}}
        , .{params_json});

        const request_body = try request_json.toOwnedSlice();
        defer self.allocator.free(request_body);

        // Now make the HTTP call
        const result = try self.callRpcWithBody("engine_forkchoiceUpdatedV3", request_body);
        defer self.allocator.free(result);

        // Debug: log raw response for troubleshooting
        std.log.debug("[EngineAPI] Raw engine_forkchoiceUpdatedV3 response: {s}", .{result});

        // Parse response - handle both success and error responses
        // Use a two-step approach: first parse as generic JSON, then extract fields
        var parsed_generic = try std.json.parseFromSlice(std.json.Value, self.allocator, result, .{});
        defer parsed_generic.deinit();

        // Check for error response first
        if (parsed_generic.value.object.get("error")) |err_val| {
            const err_obj = err_val.object;
            const err_code = if (err_obj.get("code")) |c| switch (c) {
                .integer => |i| @as(i32, @intCast(i)),
                else => return error.InvalidErrorCode,
            } else return error.MissingErrorCode;

            const err_msg = if (err_obj.get("message")) |m| switch (m) {
                .string => |s| s,
                else => return error.InvalidErrorMessage,
            } else return error.MissingErrorMessage;

            std.log.err("[EngineAPI] engine_forkchoiceUpdatedV3 error response: code={d}, message={s}", .{ err_code, err_msg });

            // Log error data if present
            if (err_obj.get("data")) |data_val| {
                if (data_val == .object) {
                    if (data_val.object.get("err")) |err_data| {
                        if (err_data == .string) {
                            std.log.err("[EngineAPI] Error details: {s}", .{err_data.string});
                        }
                    }
                }
            }

            // Provide helpful error messages for common issues
            if (err_code == -32601) {
                std.log.err("[EngineAPI] Method not found - ensure L2 geth has Engine API enabled (--authrpc.addr, --authrpc.port, --authrpc.jwtsecret)", .{});
            } else if (err_code == -38003) {
                std.log.err("[EngineAPI] Invalid payload attributes - check that all required fields are present (timestamp, prevRandao, suggestedFeeRecipient, parentBeaconBlockRoot)", .{});
            }

            return error.EngineApiError;
        }

        // Parse success response
        const result_val = parsed_generic.value.object.get("result") orelse {
            std.log.err("[EngineAPI] engine_forkchoiceUpdatedV3 response missing both 'result' and 'error' fields, response: {s}", .{result});
            return error.MissingField;
        };

        const result_obj = switch (result_val) {
            .object => |o| o,
            else => {
                std.log.err("[EngineAPI] engine_forkchoiceUpdatedV3 result is not an object, response: {s}", .{result});
                return error.InvalidResponse;
            },
        };

        // Extract payloadStatus
        const payload_status_val = result_obj.get("payloadStatus") orelse {
            std.log.err("[EngineAPI] engine_forkchoiceUpdatedV3 result missing 'payloadStatus' field, response: {s}", .{result});
            return error.MissingField;
        };

        const payload_status_obj = switch (payload_status_val) {
            .object => |o| o,
            else => {
                std.log.err("[EngineAPI] engine_forkchoiceUpdatedV3 payloadStatus is not an object, response: {s}", .{result});
                return error.InvalidResponse;
            },
        };

        const status_str = if (payload_status_obj.get("status")) |s| switch (s) {
            .string => |str| str,
            else => return error.InvalidStatus,
        } else return error.MissingField;

        const latest_valid_hash = if (payload_status_obj.get("latestValidHash")) |h| switch (h) {
            .string => |str| str,
            .null => null,
            else => null,
        } else null;

        const validation_error = if (payload_status_obj.get("validationError")) |e| switch (e) {
            .string => |str| str,
            .null => null,
            else => null,
        } else null;

        const payload_id = if (result_obj.get("payloadId")) |pid| switch (pid) {
            .string => |str| str,
            .null => null,
            else => null,
        } else null;

        // Create response directly
        const response = ForkChoiceUpdateResponse{
            .payload_status = PayloadStatus{
                .status = status_str,
                .latest_valid_hash = latest_valid_hash,
                .validation_error = validation_error,
            },
            .payload_id = payload_id,
        };

        std.log.info("[EngineAPI] engine_forkchoiceUpdatedV3 response: status={s}", .{
            response.payload_status.status,
        });

        // Log warning if status is INVALID
        if (std.mem.eql(u8, response.payload_status.status, "INVALID")) {
            std.log.warn("[EngineAPI] Fork choice update returned INVALID status - fork choice state may be invalid", .{});
            if (response.payload_status.validation_error) |err| {
                std.log.err("[EngineAPI] Validation error: {s}", .{err});
            }
        }

        if (response.payload_id) |pid| {
            std.log.info("[EngineAPI] Payload ID: {s}", .{pid});
        } else {
            std.log.warn("[EngineAPI] No payload ID returned - payload attributes may have been invalid or missing", .{});
        }

        if (response.payload_status.latest_valid_hash) |hash| {
            std.log.info("[EngineAPI] Latest valid hash: {s}", .{hash});
        }

        if (response.payload_status.validation_error) |err| {
            std.log.err("[EngineAPI] Fork choice validation error: {s}", .{err});
        }

        return response;
    }

    /// Convert block to Engine API payload format
    fn blockToPayload(self: *Self, block: *const block_module.Block) !struct {
        parent_hash: types.Hash,
        fee_recipient: types.Address,
        state_root: types.Hash,
        receipts_root: types.Hash,
        logs_bloom: [256]u8,
        prev_randao: types.Hash,
        block_number: u64,
        gas_limit: u64,
        gas_used: u64,
        timestamp: u64,
        base_fee_per_gas: u256,
        block_hash: types.Hash,
        transactions: [][]const u8,
    } {
        // Serialize transactions to hex
        var transactions = std.ArrayList([]const u8).init(self.allocator);
        defer transactions.deinit();

        for (block.transactions) |tx| {
            const tx_rlp = try tx.serialize(self.allocator);
            defer self.allocator.free(tx_rlp);
            const tx_hex = try self.bytesToHex(tx_rlp);
            try transactions.append(tx_hex);
        }

        const block_hash = block.hash();

        return .{
            .parent_hash = block.parent_hash,
            .fee_recipient = types.addressFromBytes([_]u8{0} ** 20), // Default coinbase
            .state_root = block.state_root,
            .receipts_root = block.receipts_root,
            .logs_bloom = block.logs_bloom,
            .prev_randao = types.hashFromBytes([_]u8{0} ** 32), // Placeholder
            .block_number = block.number,
            .gas_limit = block.gas_limit,
            .gas_used = block.gas_used,
            .timestamp = block.timestamp,
            .base_fee_per_gas = 0, // Placeholder
            .block_hash = block_hash,
            .transactions = try transactions.toOwnedSlice(),
        };
    }

    /// Call JSON-RPC endpoint with pre-serialized request body
    fn callRpcWithBody(self: *Self, method: []const u8, request_body: []const u8) ![]u8 {
        const start_time = std.time.nanoTimestamp();

        // Parse URL
        const url_parts = try self.parseUrl(self.l2_rpc_url);
        const host = url_parts.host;
        const port = if (std.mem.startsWith(u8, method, "engine_")) self.l2_engine_api_port else url_parts.port;

        std.log.debug("[EngineAPI] Connecting to {s}:{d} for method {s}", .{ host, port, method });

        // Connect to L2 RPC
        // Resolve hostname to IP address (handle "localhost" -> "127.0.0.1")
        const ip_address = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
        const address = try std.net.Address.parseIp(ip_address, port);
        const stream = std.net.tcpConnectToAddress(address) catch |err| {
            if (err == error.ConnectionRefused) {
                std.log.debug("[EngineAPI] Connection refused to {s}:{d} for {s} - L2 geth may not be running", .{ host, port, method });
            } else {
                std.log.err("[EngineAPI] Failed to connect to {s}:{d} for {s}: {any}", .{ host, port, method, err });
            }
            return err;
        };
        defer stream.close();

        std.log.debug("[EngineAPI] Connected to {s}:{d}", .{ host, port });

        // Generate JWT token if JWT secret is configured (required for Engine API)
        var jwt_token: []const u8 = "";
        defer if (jwt_token.len > 0) self.allocator.free(jwt_token);

        if (self.jwt_secret) |secret| {
            jwt_token = try crypto.jwt.generateEngineAPIToken(self.allocator, secret);
        }

        // Build HTTP request - append directly to avoid format string issues
        var http_request = std.ArrayList(u8).init(self.allocator);
        defer http_request.deinit();

        // Write HTTP headers
        try http_request.writer().print("POST / HTTP/1.1\r\n", .{});
        try http_request.writer().print("Host: {s}:{d}\r\n", .{ host, port });
        try http_request.writer().print("Content-Type: application/json\r\n", .{});
        try http_request.writer().print("Content-Length: {d}\r\n", .{request_body.len});
        try http_request.writer().print("Connection: close\r\n", .{});

        // Add Authorization header if JWT is configured
        if (jwt_token.len > 0) {
            try http_request.writer().print("Authorization: Bearer {s}\r\n", .{jwt_token});
        }

        // End of headers
        try http_request.writer().print("\r\n", .{});

        // Append request body directly (not via format string to avoid segfault)
        try http_request.writer().writeAll(request_body);

        const http_request_bytes = try http_request.toOwnedSlice();
        defer self.allocator.free(http_request_bytes);

        // Send request
        std.log.debug("[EngineAPI] Sending {s} request ({d} bytes)", .{ method, http_request_bytes.len });
        stream.writeAll(http_request_bytes) catch |err| {
            std.log.err("[EngineAPI] Failed to send {s} request: {any}", .{ method, err });
            return err;
        };

        // Read response
        var response_buffer: [8192]u8 = undefined;
        const bytes_read = stream.read(&response_buffer) catch |err| {
            std.log.err("[EngineAPI] Failed to read {s} response: {any}", .{ method, err });
            return err;
        };
        const response = response_buffer[0..bytes_read];

        // Parse HTTP response
        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse {
            std.log.err("[EngineAPI] Invalid HTTP response format for {s}, response: {s}", .{ method, response });
            return error.InvalidResponse;
        };

        // Check HTTP status code
        const status_line_end = std.mem.indexOf(u8, response, "\r\n") orelse {
            std.log.err("[EngineAPI] Invalid HTTP response format for {s}", .{method});
            return error.InvalidResponse;
        };
        const status_line = response[0..status_line_end];
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200")) {
            std.log.err("[EngineAPI] HTTP error response for {s}: {s}", .{ method, status_line });
            return error.HttpError;
        }

        const json_body = response[body_start + 4 ..];

        if (json_body.len == 0) {
            std.log.err("[EngineAPI] Empty JSON body in response for {s}", .{method});
            return error.EmptyResponse;
        }

        const elapsed_ms = (@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1_000_000.0);
        std.log.debug("[EngineAPI] {s} completed in {d:.2}ms, response size: {d} bytes", .{
            method,
            elapsed_ms,
            json_body.len,
        });

        // Return JSON body (caller will free)
        return try self.allocator.dupe(u8, json_body);
    }

    /// Call JSON-RPC endpoint (legacy method - kept for compatibility)
    fn callRpc(self: *Self, method: []const u8, params: std.json.Value) ![]u8 {
        // Serialize params first
        const params_str = try self.jsonValueToString(params);
        defer self.allocator.free(params_str);

        // Build request body
        var request_json = std.ArrayList(u8).init(self.allocator);
        defer request_json.deinit();

        try request_json.writer().print(
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s},"id":1}}
        , .{ method, params_str });

        const request_body = try request_json.toOwnedSlice();
        defer self.allocator.free(request_body);

        return self.callRpcWithBody(method, request_body);
    }

    const UrlParts = struct {
        host: []const u8,
        port: u16,
    };

    fn parseUrl(self: *Self, url: []const u8) !UrlParts {
        _ = self;
        // Simple URL parsing - assumes http://host:port format
        if (!std.mem.startsWith(u8, url, "http://")) {
            return error.InvalidUrl;
        }

        const host_start = 7; // Skip "http://"
        const colon_idx = std.mem.indexOfScalar(u8, url[host_start..], ':') orelse {
            // No port specified, use default 8545
            return UrlParts{ .host = url[host_start..], .port = 8545 };
        };

        const host = url[host_start .. host_start + colon_idx];
        const port_str = url[host_start + colon_idx + 1 ..];
        const port = try std.fmt.parseInt(u16, port_str, 10);

        return UrlParts{ .host = host, .port = port };
    }

    fn jsonValueToString(self: *Self, value: std.json.Value) ![]const u8 {
        // Simple JSON serialization for params
        switch (value) {
            .array => |arr| {
                var result = std.ArrayList(u8).init(self.allocator);
                defer result.deinit();
                try result.append('[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try result.append(',');
                    const item_str = try self.jsonValueToString(item);
                    defer self.allocator.free(item_str);
                    try result.writer().print("{s}", .{item_str});
                }
                try result.append(']');
                return result.toOwnedSlice();
            },
            .object => |obj| {
                var result = std.ArrayList(u8).init(self.allocator);
                defer result.deinit();
                try result.append('{');
                var first = true;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (!first) try result.append(',');
                    first = false;
                    const key_str = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{entry.key_ptr.*});
                    defer self.allocator.free(key_str);
                    const val_str = try self.jsonValueToString(entry.value_ptr.*);
                    defer self.allocator.free(val_str);
                    try result.writer().print("{s}:{s}", .{ key_str, val_str });
                }
                try result.append('}');
                return result.toOwnedSlice();
            },
            .string => |s| {
                // Escape special characters in JSON strings
                var result = std.ArrayList(u8).init(self.allocator);
                defer result.deinit();
                try result.append('"');
                for (s) |char| {
                    switch (char) {
                        '"' => try result.appendSlice("\\\""),
                        '\\' => try result.appendSlice("\\\\"),
                        '\n' => try result.appendSlice("\\n"),
                        '\r' => try result.appendSlice("\\r"),
                        '\t' => try result.appendSlice("\\t"),
                        else => try result.append(char),
                    }
                }
                try result.append('"');
                return result.toOwnedSlice();
            },
            else => return error.UnsupportedJsonType,
        }
    }

    fn bytesToHex(self: *Self, bytes: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        try result.appendSlice("0x");
        const hex_digits = "0123456789abcdef";
        for (bytes) |byte| {
            try result.append(hex_digits[byte >> 4]);
            try result.append(hex_digits[byte & 0xf]);
        }

        return result.toOwnedSlice();
    }

    fn hashToHex(self: *Self, hash: types.Hash) ![]u8 {
        const bytes = types.hashToBytes(hash);
        return self.bytesToHex(&bytes);
    }

    fn addressToHex(self: *Self, addr: types.Address) ![]u8 {
        const bytes = types.addressToBytes(addr);
        return self.bytesToHex(&bytes);
    }

    fn hexToHash(_: *Self, hex: []const u8) !types.Hash {
        const hex_start: usize = if (std.mem.startsWith(u8, hex, "0x")) 2 else 0;
        const hex_data = hex[hex_start..];

        if (hex_data.len != 64) {
            return error.InvalidHashLength;
        }

        var result: [32]u8 = undefined;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const high = try std.fmt.parseInt(u8, hex_data[i * 2 .. i * 2 + 1], 16);
            const low = try std.fmt.parseInt(u8, hex_data[i * 2 + 1 .. i * 2 + 2], 16);
            result[i] = (high << 4) | low;
        }

        return types.hashFromBytes(result);
    }

    fn hexToAddress(_: *Self, hex: []const u8) !types.Address {
        const hex_start: usize = if (std.mem.startsWith(u8, hex, "0x")) 2 else 0;
        const hex_data = hex[hex_start..];

        if (hex_data.len != 40) {
            return error.InvalidAddressLength;
        }

        var result: [20]u8 = undefined;
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            const high = try std.fmt.parseInt(u8, hex_data[i * 2 .. i * 2 + 1], 16);
            const low = try std.fmt.parseInt(u8, hex_data[i * 2 + 1 .. i * 2 + 2], 16);
            result[i] = (high << 4) | low;
        }

        return types.addressFromBytes(result);
    }

    /// Convert hex string to bytes (variable length)
    fn hexToBytes(self: *Self, hex: []const u8) ![]u8 {
        const hex_start: usize = if (std.mem.startsWith(u8, hex, "0x")) 2 else 0;
        const hex_data = hex[hex_start..];

        if (hex_data.len % 2 != 0) {
            return error.InvalidHexLength;
        }

        const result = try self.allocator.alloc(u8, hex_data.len / 2);
        var i: usize = 0;
        while (i < hex_data.len) : (i += 2) {
            const high = try std.fmt.parseInt(u8, hex_data[i .. i + 1], 16);
            const low = try std.fmt.parseInt(u8, hex_data[i + 1 .. i + 2], 16);
            result[i / 2] = (high << 4) | low;
        }

        return result;
    }
};
