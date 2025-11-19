// Engine API client for L2 geth communication
// Implements Engine API endpoints: engine_newPayload, engine_getPayload, engine_forkchoiceUpdated

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const block_module = @import("../core/block.zig");

pub const EngineApiClient = struct {
    allocator: std.mem.Allocator,
    l2_rpc_url: []const u8,
    l2_engine_api_port: u16,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, l2_rpc_url: []const u8, l2_engine_api_port: u16) Self {
        return .{
            .allocator = allocator,
            .l2_rpc_url = l2_rpc_url,
            .l2_engine_api_port = l2_engine_api_port,
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

    /// Get payload from L2 geth via engine_getPayload
    pub fn getPayload(self: *Self, payload_id: []const u8) !struct { block_hash: types.Hash, block_number: u64 } {
        std.log.info("[EngineAPI] Calling engine_getPayload with payload_id: {s}", .{payload_id});

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        var payload_id_obj = std.json.ObjectMap.init(self.allocator);
        defer payload_id_obj.deinit();
        try payload_id_obj.put("payloadId", std.json.Value{ .string = payload_id });

        try params.append(std.json.Value{ .object = payload_id_obj });

        const result = try self.callRpc("engine_getPayload", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse response
        const parsed = try std.json.parseFromSliceLeaky(
            struct {
                result: struct {
                    blockHash: []const u8,
                    blockNumber: []const u8,
                },
            },
            self.allocator,
            result,
            .{},
        );

        const block_hash = try self.hexToHash(parsed.result.blockHash);
        const hex_start: usize = if (std.mem.startsWith(u8, parsed.result.blockNumber, "0x")) 2 else 0;
        const block_number = try std.fmt.parseInt(u64, parsed.result.blockNumber[hex_start..], 16);

        const block_hash_hex = try self.hashToHex(block_hash);
        defer self.allocator.free(block_hash_hex);

        std.log.info("[EngineAPI] engine_getPayload response: block_hash={s}, block_number={d}", .{
            block_hash_hex,
            block_number,
        });

        return .{
            .block_hash = block_hash,
            .block_number = block_number,
        };
    }

    /// Update fork choice state via engine_forkchoiceUpdated
    pub fn forkchoiceUpdated(self: *Self, head_block_hash: types.Hash, safe_block_hash: types.Hash, finalized_block_hash: types.Hash) !ForkChoiceUpdateResponse {
        const head_hex = try self.hashToHex(head_block_hash);
        defer self.allocator.free(head_hex);
        const safe_hex = try self.hashToHex(safe_block_hash);
        defer self.allocator.free(safe_hex);
        const finalized_hex = try self.hashToHex(finalized_block_hash);
        defer self.allocator.free(finalized_hex);

        std.log.info("[EngineAPI] Calling engine_forkchoiceUpdated: head={s}, safe={s}, finalized={s}", .{
            head_hex,
            safe_hex,
            finalized_hex,
        });

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        // Fork choice state
        var fork_choice_obj = std.json.ObjectMap.init(self.allocator);
        defer fork_choice_obj.deinit();
        try fork_choice_obj.put("headBlockHash", std.json.Value{ .string = head_hex });
        try fork_choice_obj.put("safeBlockHash", std.json.Value{ .string = safe_hex });
        try fork_choice_obj.put("finalizedBlockHash", std.json.Value{ .string = finalized_hex });

        // Payload attributes (optional)
        var payload_attrs_obj = std.json.ObjectMap.init(self.allocator);
        defer payload_attrs_obj.deinit();
        const timestamp = @as(u64, @intCast(std.time.timestamp()));
        try payload_attrs_obj.put("timestamp", std.json.Value{ .string = try std.fmt.allocPrint(self.allocator, "0x{x}", .{timestamp}) });
        try payload_attrs_obj.put("prevRandao", std.json.Value{ .string = try self.hashToHex(types.hashFromBytes([_]u8{0} ** 32)) });
        try payload_attrs_obj.put("suggestedFeeRecipient", std.json.Value{ .string = try self.addressToHex(types.addressFromBytes([_]u8{0} ** 20)) });

        try params.append(std.json.Value{ .object = fork_choice_obj });
        try params.append(std.json.Value{ .object = payload_attrs_obj });

        const result = try self.callRpc("engine_forkchoiceUpdated", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse response
        const parsed = try std.json.parseFromSliceLeaky(
            struct {
                result: struct {
                    payloadStatus: struct {
                        status: []const u8,
                        latestValidHash: ?[]const u8,
                        validationError: ?[]const u8,
                    },
                    payloadId: ?[]const u8,
                },
            },
            self.allocator,
            result,
            .{},
        );

        const response = ForkChoiceUpdateResponse{
            .payload_status = PayloadStatus{
                .status = parsed.result.payloadStatus.status,
                .latest_valid_hash = parsed.result.payloadStatus.latestValidHash,
                .validation_error = parsed.result.payloadStatus.validationError,
            },
            .payload_id = parsed.result.payloadId,
        };

        std.log.info("[EngineAPI] engine_forkchoiceUpdated response: status={s}", .{
            response.payload_status.status,
        });

        if (response.payload_id) |pid| {
            std.log.info("[EngineAPI] Payload ID: {s}", .{pid});
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

    /// Call JSON-RPC endpoint
    fn callRpc(self: *Self, method: []const u8, params: std.json.Value) ![]u8 {
        const start_time = std.time.nanoTimestamp();

        // Parse URL
        const url_parts = try self.parseUrl(self.l2_rpc_url);
        const host = url_parts.host;
        const port = if (std.mem.eql(u8, method[0..7], "engine_")) self.l2_engine_api_port else url_parts.port;

        std.log.debug("[EngineAPI] Connecting to {s}:{d} for method {s}", .{ host, port, method });

        // Connect to L2 RPC
        const address = try std.net.Address.parseIp(host, port);
        const stream = std.net.tcpConnectToAddress(address) catch |err| {
            std.log.err("[EngineAPI] Failed to connect to {s}:{d} for {s}: {any}", .{ host, port, method, err });
            return err;
        };
        defer stream.close();

        std.log.debug("[EngineAPI] Connected to {s}:{d}", .{ host, port });

        // Build JSON-RPC request
        var request_json = std.ArrayList(u8).init(self.allocator);
        defer request_json.deinit();

        try request_json.writer().print(
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s},"id":1}}
        , .{ method, try self.jsonValueToString(params) });

        const request_body = try request_json.toOwnedSlice();
        defer self.allocator.free(request_body);

        // Build HTTP request
        var http_request = std.ArrayList(u8).init(self.allocator);
        defer http_request.deinit();

        try http_request.writer().print(
            \\POST / HTTP/1.1\r
            \\Host: {s}:{d}\r
            \\Content-Type: application/json\r
            \\Content-Length: {d}\r
            \\\r
            \\{s}
        , .{ host, port, request_body.len, request_body });

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
            std.log.err("[EngineAPI] Invalid HTTP response format for {s}", .{method});
            return error.InvalidResponse;
        };
        const json_body = response[body_start + 4 ..];

        const elapsed_ms = (@as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1_000_000.0);
        std.log.debug("[EngineAPI] {s} completed in {d:.2}ms, response size: {d} bytes", .{
            method,
            elapsed_ms,
            json_body.len,
        });

        // Return JSON body (caller will free)
        return try self.allocator.dupe(u8, json_body);
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
                return try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{s});
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
};
