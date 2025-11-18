const std = @import("std");
const core = @import("../core/root.zig");
const config = @import("../config/root.zig");
const crypto = @import("../crypto/root.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    l1_chain_id: u64,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) Client {
        return .{
            .allocator = allocator,
            .config = cfg,
            .l1_chain_id = cfg.l1_chain_id,
        };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
        // No cleanup needed for simplified implementation
    }

    pub fn submitBatch(self: *Client, batch: core.batch.Batch) !core.types.Hash {
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

        const result = try self.callRpc("eth_blockNumber", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result - should be hex string
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
        const address = try std.net.Address.parseIp(host, port);
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

        // Build JSON-RPC request
        var request_json = std.array_list.Managed(u8).init(self.allocator);
        defer request_json.deinit();

        try request_json.writer().print(
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s},"id":1}}
        , .{ method, try self.jsonValueToString(params) });

        const request_body = try request_json.toOwnedSlice();
        defer self.allocator.free(request_body);

        // Build HTTP request
        var http_request = std.array_list.Managed(u8).init(self.allocator);
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
        try stream.writeAll(http_request_bytes);

        // Read response
        var response_buffer: [8192]u8 = undefined;
        const bytes_read = try stream.read(&response_buffer);
        const response = response_buffer[0..bytes_read];

        // Parse HTTP response
        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.InvalidResponse;
        const json_body = response[body_start + 4 ..];

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
                var result = std.array_list.Managed(u8).init(self.allocator);
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
                var result = std.array_list.Managed(u8).init(self.allocator);
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
        var result = std.array_list.Managed(u8).init(self.allocator);
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
