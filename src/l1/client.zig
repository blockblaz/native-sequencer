const std = @import("std");
const core = @import("../core/root.zig");
const config = @import("../config/root.zig");
const crypto = @import("../crypto/root.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    l1_chain_id: u64,
    sequencer_private_key: ?[32]u8 = null,
    sequencer_address: ?core.types.Address = null,
    execute_tx_builder: ?@import("execute_tx_builder.zig").ExecuteTxBuilder = null,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) Client {
        var client = Client{
            .allocator = allocator,
            .config = cfg,
            .l1_chain_id = cfg.l1_chain_id,
            .sequencer_private_key = cfg.sequencer_private_key,
            .sequencer_address = null,
            .execute_tx_builder = null,
        };

        // Derive sequencer address from private key if available
        if (cfg.sequencer_private_key) |key| {
            const secp256k1_mod = @import("../crypto/secp256k1_wrapper.zig");
            const priv_key = secp256k1_mod.PrivateKey.fromBytes(key) catch null;
            if (priv_key) |pk| {
                const pub_key = secp256k1_mod.derivePublicKey(pk) catch null;
                if (pub_key) |pubkey| {
                    client.sequencer_address = pubkey.toAddress();
                }
            }
        }

        return client;
    }

    pub fn deinit(self: *Client) void {
        _ = self;
        // No cleanup needed for simplified implementation
    }

    pub fn submitBatch(self: *Client, batch: core.batch.Batch, state_manager: *const @import("../state/root.zig").StateManager, sequencer: *const @import("../sequencer/root.zig").Sequencer) !core.types.Hash {
        // Use ExecuteTx for batch submission if sequencer key is configured
        // Only use ExecuteTx if we can successfully get nonce (L1 RPC is available)
        if (self.sequencer_private_key) |key| {
            // Try to use ExecuteTx, but fall back to legacy if L1 RPC fails
            return self.submitBatchAsExecuteTx(batch, state_manager, sequencer, key) catch |err| {
                std.log.warn("ExecuteTx submission failed, falling back to legacy: {any}", .{err});
                return try self.submitBatchLegacy(batch);
            };
        } else {
            // Fallback to legacy batch submission
            return try self.submitBatchLegacy(batch);
        }
    }

    /// Submit batch as ExecuteTx transaction
    fn submitBatchAsExecuteTx(self: *Client, batch: core.batch.Batch, state_manager: *const @import("../state/root.zig").StateManager, sequencer: *const @import("../sequencer/root.zig").Sequencer, private_key: [32]u8) !core.types.Hash {
        // Get sequencer address
        const sequencer_addr = self.sequencer_address orelse {
            return error.SequencerAddressNotAvailable;
        };

        // Initialize ExecuteTx builder if not already done
        if (self.execute_tx_builder == null) {
            self.execute_tx_builder = @import("execute_tx_builder.zig").ExecuteTxBuilder.init(self.allocator, self.l1_chain_id, sequencer_addr);
        }
        const builder = &self.execute_tx_builder.?;

        // Get nonce from L1 (simplified - in production fetch from L1)
        const nonce = try self.getNonce(sequencer_addr);

        // Build ExecuteTx from batch
        var execute_tx = try builder.buildExecuteTxFromBatch(
            &batch,
            state_manager,
            sequencer,
            nonce,
            2_000_000_000, // 2 gwei gas tip cap
            100_000_000_000, // 100 gwei gas fee cap
            10_000_000, // 10M gas limit
        );
        defer execute_tx.deinit(self.allocator);

        // Sign ExecuteTx
        var signed_tx = try execute_tx.sign(self.allocator, private_key, self.l1_chain_id);
        defer signed_tx.deinit(self.allocator);

        // Serialize and submit
        const raw_tx = try signed_tx.serialize(self.allocator);
        defer self.allocator.free(raw_tx);

        return try self.sendTransaction(raw_tx);
    }

    /// Legacy batch submission (for backward compatibility)
    fn submitBatchLegacy(self: *Client, batch: core.batch.Batch) !core.types.Hash {
        // Serialize batch
        const calldata = try batch.serialize(self.allocator);
        defer self.allocator.free(calldata);

        // Create L1 transaction
        const l1_tx = try self.createL1Transaction(calldata);

        // Sign transaction
        const signed_tx = try self.signTransaction(l1_tx);

        // Submit to L1
        const tx_hash = try self.sendTransaction(signed_tx);

        return tx_hash;
    }

    /// Get nonce for sequencer address from L1
    fn getNonce(self: *Client, address: core.types.Address) !u64 {
        const addr_bytes = core.types.addressToBytes(address);
        const addr_hex = try self.bytesToHex(&addr_bytes);
        defer self.allocator.free(addr_hex);

        const hex_value = try std.fmt.allocPrint(self.allocator, "0x{s}", .{addr_hex});
        defer self.allocator.free(hex_value);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = hex_value });
        try params.append(std.json.Value{ .string = "latest" });

        const result = try self.callRpc("eth_getTransactionCount", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result
        const parsed = try std.json.parseFromSliceLeaky(
            struct { result: []const u8 },
            self.allocator,
            result,
            .{},
        );

        // Convert hex string to u64
        const hex_str = parsed.result;
        const hex_start: usize = if (std.mem.startsWith(u8, hex_str, "0x")) 2 else 0;
        return try std.fmt.parseInt(u64, hex_str[hex_start..], 16);
    }

    pub const ConditionalOptions = struct {
        block_number_max: ?u64 = null,
        // known_accounts: ?std.json.Value = null, // Future: support account state checks
    };

    pub fn submitBatchConditional(self: *Client, batch: core.batch.Batch, options: ConditionalOptions) !core.types.Hash {
        // Serialize batch
        const calldata = try batch.serialize(self.allocator);
        defer self.allocator.free(calldata);

        // Create L1 transaction
        const l1_tx = try self.createL1Transaction(calldata);

        // Sign transaction
        const signed_tx = try self.signTransaction(l1_tx);

        // Submit to L1 with conditions
        const tx_hash = try self.sendTransactionConditional(signed_tx, options);

        return tx_hash;
    }

    fn createL1Transaction(self: *Client, calldata: []const u8) !core.transaction.Transaction {
        // Create transaction to call rollup precompile or contract
        _ = self;
        return core.transaction.Transaction{
            .nonce = 0, // Will be fetched from L1
            .gas_price = 20_000_000_000, // 20 gwei
            .gas_limit = 500_000,
            .to = null, // Contract call
            .value = 0,
            .data = calldata,
            .v = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        };
    }

    fn signTransaction(self: *Client, tx: core.transaction.Transaction) ![]u8 {
        // Sign with sequencer key
        _ = self;
        _ = tx;
        return error.NotImplemented;
    }

    fn sendTransaction(self: *Client, signed_tx: []const u8) !core.types.Hash {
        // Send JSON-RPC eth_sendRawTransaction
        const tx_hex = try self.bytesToHex(signed_tx);
        defer self.allocator.free(tx_hex);

        const hex_value = try std.fmt.allocPrint(self.allocator, "0x{s}", .{tx_hex});
        defer self.allocator.free(hex_value);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = hex_value });

        const result = try self.callRpc("eth_sendRawTransaction", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result - should be transaction hash
        const parsed = try std.json.parseFromSliceLeaky(
            struct { result: []const u8 },
            self.allocator,
            result,
            .{},
        );

        // Convert hex string to Hash
        const hash_str = parsed.result;
        const hash_bytes = try self.hexToBytes(hash_str);
        return core.types.hashFromBytes(hash_bytes);
    }

    /// Forward ExecuteTx transaction to L1 geth
    /// ExecuteTx transactions are stateless and should be sent directly to L1 geth
    pub fn forwardExecuteTx(self: *Client, execute_tx: *const core.transaction_execute.ExecuteTx) !core.types.Hash {
        // Serialize ExecuteTx to raw transaction bytes
        const raw_tx = try execute_tx.serialize(self.allocator);
        defer self.allocator.free(raw_tx);

        // Forward to L1 geth via eth_sendRawTransaction
        return try self.sendTransaction(raw_tx);
    }

    fn sendTransactionConditional(self: *Client, signed_tx: []const u8, options: ConditionalOptions) !core.types.Hash {
        // Send JSON-RPC eth_sendRawTransactionConditional (EIP-7796)
        const tx_hex = try self.bytesToHex(signed_tx);
        defer self.allocator.free(tx_hex);

        const hex_value = try std.fmt.allocPrint(self.allocator, "0x{s}", .{tx_hex});
        defer self.allocator.free(hex_value);

        // Build options object
        var options_obj = std.json.ObjectMap.init(self.allocator);
        defer options_obj.deinit();

        if (options.block_number_max) |block_num| {
            const block_num_hex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{block_num});
            defer self.allocator.free(block_num_hex);
            try options_obj.put("blockNumberMax", std.json.Value{ .string = block_num_hex });
        }

        // Build params array: [transaction, options]
        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = hex_value });
        try params.append(std.json.Value{ .object = options_obj });

        const result = try self.callRpc("eth_sendRawTransactionConditional", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result - should be transaction hash
        const parsed = try std.json.parseFromSliceLeaky(
            struct { result: []const u8 },
            self.allocator,
            result,
            .{},
        );

        // Convert hex string to Hash
        const hash_str = parsed.result;
        const hash_bytes = try self.hexToBytes(hash_str);
        return core.types.hashFromBytes(hash_bytes);
    }

    pub fn waitForInclusion(self: *Client, tx_hash: core.types.Hash, confirmations: u64) !void {
        // Poll L1 for transaction inclusion
        var last_block: u64 = 0;
        var seen_confirmations: u64 = 0;

        while (seen_confirmations < confirmations) {
            std.Thread.sleep(1 * std.time.ns_per_s); // Wait 1 second between polls

            const current_block = try self.getLatestBlockNumber();

            // Check if transaction is included
            const receipt = self.getTransactionReceipt(tx_hash) catch |err| {
                // Transaction not found yet, continue polling
                _ = err;
                continue;
            };

            if (receipt) |rec| {
                if (current_block >= rec.block_number) {
                    seen_confirmations = current_block - rec.block_number + 1;
                    if (seen_confirmations >= confirmations) {
                        return; // Transaction confirmed
                    }
                }
            }

            last_block = current_block;
        }
    }

    pub fn getLatestBlockNumber(self: *Client) !u64 {
        // Fetch latest L1 block number
        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const result = self.callRpc("eth_blockNumber", std.json.Value{ .array = params }) catch |err| {
            // Connection errors should be handled by caller
            return err;
        };
        defer self.allocator.free(result);

        // Check if response is empty
        if (result.len == 0) {
            return error.EmptyResponse;
        }

        // Parse result - should be hex string
        const parsed = std.json.parseFromSliceLeaky(
            struct { result: []const u8 },
            self.allocator,
            result,
            .{},
        ) catch |err| {
            std.log.err("[L1Client] Failed to parse eth_blockNumber response: {any}, response: {s}", .{ err, result });
            return error.UnexpectedToken;
        };

        // Convert hex string to u64
        const hex_str = parsed.result;
        const hex_start: usize = if (std.mem.startsWith(u8, hex_str, "0x")) 2 else 0;
        return std.fmt.parseInt(u64, hex_str[hex_start..], 16) catch |err| {
            std.log.err("[L1Client] Failed to parse block number hex '{s}': {any}", .{ hex_str, err });
            return err;
        };
    }

    pub const L1BlockTx = struct {
        to: ?[]const u8,
        data: []const u8,
    };

    pub const L1Block = struct {
        number: u64,
        hash: core.types.Hash,
        parent_hash: core.types.Hash,
        timestamp: u64,
        transactions: []L1BlockTx,
    };

    /// Get L1 block by number (for batch parsing)
    pub fn getBlockByNumber(self: *Client, block_number: u64, include_txs: bool) !L1Block {
        const block_hex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{block_number});
        defer self.allocator.free(block_hex);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = block_hex });
        try params.append(std.json.Value{ .bool = include_txs });

        const result = try self.callRpc("eth_getBlockByNumber", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result
        const parsed = try std.json.parseFromSliceLeaky(
            struct {
                result: struct {
                    number: []const u8,
                    hash: []const u8,
                    parentHash: []const u8,
                    timestamp: []const u8,
                    transactions: []struct { to: ?[]const u8, input: []const u8 },
                },
            },
            self.allocator,
            result,
            .{},
        );

        const hex_start: usize = if (std.mem.startsWith(u8, parsed.result.number, "0x")) 2 else 0;
        const number = try std.fmt.parseInt(u64, parsed.result.number[hex_start..], 16);

        const hash = try self.hexToHash(parsed.result.hash);
        const parent_hash = try self.hexToHash(parsed.result.parentHash);
        const timestamp_hex_start: usize = if (std.mem.startsWith(u8, parsed.result.timestamp, "0x")) 2 else 0;
        const timestamp = try std.fmt.parseInt(u64, parsed.result.timestamp[timestamp_hex_start..], 16);

        // Clone transactions
        const txs = try self.allocator.alloc(L1BlockTx, parsed.result.transactions.len);
        for (parsed.result.transactions, 0..) |tx, i| {
            txs[i] = L1BlockTx{
                .to = if (tx.to) |to| try self.allocator.dupe(u8, to) else null,
                .data = try self.allocator.dupe(u8, tx.input),
            };
        }

        return L1Block{
            .number = number,
            .hash = hash,
            .parent_hash = parent_hash,
            .timestamp = timestamp,
            .transactions = txs,
        };
    }

    fn hexToHash(self: *Client, hex: []const u8) !core.types.Hash {
        _ = self;
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

        return core.types.hashFromBytes(result);
    }

    fn getTransactionReceipt(self: *Client, tx_hash: core.types.Hash) !?struct { block_number: u64 } {
        const hash_bytes = core.types.hashToBytes(tx_hash);
        const hash_hex = try self.bytesToHex(&hash_bytes);
        defer self.allocator.free(hash_hex);

        const hex_value = try std.fmt.allocPrint(self.allocator, "0x{s}", .{hash_hex});
        defer self.allocator.free(hex_value);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = hex_value });

        const result = try self.callRpc("eth_getTransactionReceipt", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result
        const parsed = try std.json.parseFromSliceLeaky(
            struct { result: ?struct { blockNumber: []const u8 } },
            self.allocator,
            result,
            .{},
        );

        if (parsed.result) |rec| {
            const hex_start: usize = if (std.mem.startsWith(u8, rec.blockNumber, "0x")) 2 else 0;
            const block_num = try std.fmt.parseInt(u64, rec.blockNumber[hex_start..], 16);
            return .{ .block_number = block_num };
        }

        return null;
    }

    fn callRpc(self: *Client, method: []const u8, params: std.json.Value) ![]u8 {
        // Parse URL
        const url = self.config.l1_rpc_url;
        const url_parts = try self.parseUrl(url);
        const host = url_parts.host;
        const port = url_parts.port;

        // Connect to L1 RPC
        // Resolve hostname to IP address (handle "localhost" -> "127.0.0.1")
        const ip_address = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
        const address = try std.net.Address.parseIp(ip_address, port);
        const stream = std.net.tcpConnectToAddress(address) catch |err| {
            std.log.debug("[L1Client] Failed to connect to {s}:{d} for {s}: {any}", .{ host, port, method, err });
            return err;
        };
        defer stream.close();

        // Build JSON-RPC request
        var request_json = std.ArrayList(u8).init(self.allocator);
        defer request_json.deinit();

        try request_json.writer().print(
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s},"id":1}}
        , .{ method, try self.jsonValueToString(params) });

        const request_body = try request_json.toOwnedSlice();
        defer self.allocator.free(request_body);

        // Build HTTP request - use same pattern as engine_api_client for consistency
        var http_request = std.ArrayList(u8).init(self.allocator);
        defer http_request.deinit();

        // Request line
        try http_request.writer().print("POST / HTTP/1.1\r\n", .{});

        // Headers - write each line separately with explicit \r\n
        try http_request.writer().print("Host: {s}:{d}\r\n", .{ host, port });
        try http_request.writer().print("Content-Type: application/json\r\n", .{});
        try http_request.writer().print("Content-Length: {d}\r\n", .{request_body.len});
        try http_request.writer().print("Connection: close\r\n", .{});

        // End of headers
        try http_request.writer().print("\r\n", .{});

        // Append request body directly
        try http_request.writer().writeAll(request_body);

        // Debug: log request for troubleshooting
        std.log.debug("[L1Client] Sending HTTP request to {s}:{d} for {s}, Content-Length: {d}", .{ host, port, method, request_body.len });

        const http_request_bytes = try http_request.toOwnedSlice();
        defer self.allocator.free(http_request_bytes);

        // Send request
        try stream.writeAll(http_request_bytes);

        // Read response
        var response_buffer: [8192]u8 = undefined;
        const bytes_read = stream.read(&response_buffer) catch |err| {
            std.log.debug("[L1Client] Failed to read response from {s}:{d} for {s}: {any}", .{ host, port, method, err });
            return err;
        };

        if (bytes_read == 0) {
            return error.EmptyResponse;
        }

        const response = response_buffer[0..bytes_read];

        // Parse HTTP response
        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse {
            std.log.err("[L1Client] Invalid HTTP response format from {s}:{d} for {s}, response: {s}", .{ host, port, method, response });
            return error.InvalidResponse;
        };

        // Check HTTP status code
        const status_line_end = std.mem.indexOf(u8, response, "\r\n") orelse {
            std.log.err("[L1Client] Invalid HTTP response format from {s}:{d} for {s}", .{ host, port, method });
            return error.InvalidResponse;
        };
        const status_line = response[0..status_line_end];
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.1 200") and !std.mem.startsWith(u8, status_line, "HTTP/1.0 200")) {
            std.log.err("[L1Client] HTTP error response from {s}:{d} for {s}: {s}", .{ host, port, method, status_line });

            // Log request details for debugging
            const request_preview = if (http_request_bytes.len > 200) http_request_bytes[0..200] else http_request_bytes;
            std.log.debug("[L1Client] HTTP request (first {d} bytes): {s}", .{ request_preview.len, request_preview });

            // Try to extract error message from body
            const json_body = response[body_start + 4 ..];
            if (json_body.len > 0) {
                std.log.debug("[L1Client] Error response body: {s}", .{json_body});
                // Try to parse as JSON-RPC error response
                const parsed_error = std.json.parseFromSliceLeaky(
                    struct {
                        @"error": ?struct {
                            code: i32,
                            message: []const u8,
                        },
                    },
                    self.allocator,
                    json_body,
                    .{ .ignore_unknown_fields = true },
                ) catch null;
                if (parsed_error) |err| {
                    if (err.@"error") |e| {
                        std.log.err("[L1Client] JSON-RPC error: code={d}, message={s}", .{ e.code, e.message });
                    }
                }
            }
            // Log full response for debugging (truncate if too long)
            const response_preview = if (response.len > 500) response[0..500] else response;
            std.log.debug("[L1Client] Full HTTP response (first {d} bytes): {s}", .{ response_preview.len, response_preview });
            return error.HttpError;
        }

        const json_body = response[body_start + 4 ..];

        if (json_body.len == 0) {
            return error.EmptyResponse;
        }

        // Return JSON body (caller will free)
        return try self.allocator.dupe(u8, json_body);
    }

    const UrlParts = struct {
        host: []const u8,
        port: u16,
    };

    fn parseUrl(self: *Client, url: []const u8) !UrlParts {
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

    fn jsonValueToString(self: *Client, value: std.json.Value) ![]const u8 {
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

    fn bytesToHex(self: *Client, bytes: []const u8) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        const hex_digits = "0123456789abcdef";
        for (bytes) |byte| {
            try result.append(hex_digits[byte >> 4]);
            try result.append(hex_digits[byte & 0xf]);
        }

        return result.toOwnedSlice();
    }

    fn hexToBytes(_: *Client, hex: []const u8) ![32]u8 {
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

        return result;
    }
};
