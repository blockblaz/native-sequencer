// State provider for querying L2 geth node state via JSON-RPC

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");

pub const StateProvider = struct {
    allocator: std.mem.Allocator,
    l2_rpc_url: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, l2_rpc_url: []const u8) Self {
        return .{
            .allocator = allocator,
            .l2_rpc_url = l2_rpc_url,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed
    }

    /// Get account balance via eth_getBalance
    pub fn getBalance(self: *Self, address: types.Address, block: []const u8) !u256 {
        const addr_bytes = types.addressToBytes(address);
        const addr_hex = try self.bytesToHex(&addr_bytes);
        defer self.allocator.free(addr_hex);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = addr_hex });
        try params.append(std.json.Value{ .string = block });

        const result = try self.callRpc("eth_getBalance", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result
        const parsed = try std.json.parseFromSliceLeaky(
            struct { result: []const u8 },
            self.allocator,
            result,
            .{},
        );

        // Convert hex string to u256
        const hex_str = parsed.result;
        const hex_start: usize = if (std.mem.startsWith(u8, hex_str, "0x")) 2 else 0;
        return try self.hexToU256(hex_str[hex_start..]);
    }

    /// Get account nonce via eth_getTransactionCount
    pub fn getNonce(self: *Self, address: types.Address, block: []const u8) !u64 {
        const addr_bytes = types.addressToBytes(address);
        const addr_hex = try self.bytesToHex(&addr_bytes);
        defer self.allocator.free(addr_hex);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = addr_hex });
        try params.append(std.json.Value{ .string = block });

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

    /// Get contract bytecode via eth_getCode
    pub fn getCode(self: *Self, address: types.Address, block: []const u8) ![]const u8 {
        const addr_bytes = types.addressToBytes(address);
        const addr_hex = try self.bytesToHex(&addr_bytes);
        defer self.allocator.free(addr_hex);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = addr_hex });
        try params.append(std.json.Value{ .string = block });

        const result = try self.callRpc("eth_getCode", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result
        const parsed = try std.json.parseFromSliceLeaky(
            struct { result: []const u8 },
            self.allocator,
            result,
            .{},
        );

        // Convert hex string to bytes
        const hex_str = parsed.result;
        return try self.hexToBytes(hex_str);
    }

    /// Get storage value via eth_getStorageAt
    pub fn getStorageAt(self: *Self, address: types.Address, position: u256, block: []const u8) ![32]u8 {
        const addr_bytes = types.addressToBytes(address);
        const addr_hex = try self.bytesToHex(&addr_bytes);
        defer self.allocator.free(addr_hex);

        const pos_bytes = types.u256ToBytes(position);
        const pos_hex = try self.bytesToHex(&pos_bytes);
        defer self.allocator.free(pos_hex);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();
        try params.append(std.json.Value{ .string = addr_hex });
        try params.append(std.json.Value{ .string = pos_hex });
        try params.append(std.json.Value{ .string = block });

        const result = try self.callRpc("eth_getStorageAt", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        // Parse result
        const parsed = try std.json.parseFromSliceLeaky(
            struct { result: []const u8 },
            self.allocator,
            result,
            .{},
        );

        // Convert hex string to 32-byte array
        const hex_str = parsed.result;
        return try self.hexToBytes32(hex_str);
    }

    /// Get block by number via eth_getBlockByNumber
    pub fn getBlockByNumber(self: *Self, block_number: u64, include_txs: bool) !struct {
        number: u64,
        hash: types.Hash,
        parent_hash: types.Hash,
        timestamp: u64,
        gas_limit: u64,
        gas_used: u64,
        state_root: types.Hash,
    } {
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
                    gasLimit: []const u8,
                    gasUsed: []const u8,
                    stateRoot: []const u8,
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
        const gas_limit_hex_start: usize = if (std.mem.startsWith(u8, parsed.result.gasLimit, "0x")) 2 else 0;
        const gas_limit = try std.fmt.parseInt(u64, parsed.result.gasLimit[gas_limit_hex_start..], 16);
        const gas_used_hex_start: usize = if (std.mem.startsWith(u8, parsed.result.gasUsed, "0x")) 2 else 0;
        const gas_used = try std.fmt.parseInt(u64, parsed.result.gasUsed[gas_used_hex_start..], 16);
        const state_root = try self.hexToHash(parsed.result.stateRoot);

        return .{
            .number = number,
            .hash = hash,
            .parent_hash = parent_hash,
            .timestamp = timestamp,
            .gas_limit = gas_limit,
            .gas_used = gas_used,
            .state_root = state_root,
        };
    }

    /// Call JSON-RPC endpoint
    fn callRpc(self: *Self, method: []const u8, params: std.json.Value) ![]u8 {
        // Parse URL
        const url_parts = try self.parseUrl(self.l2_rpc_url);
        const host = url_parts.host;
        const port = url_parts.port;

        // Connect to L2 RPC
        const address = try std.net.Address.parseIp(host, port);
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();

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
            .bool => |b| {
                return try std.fmt.allocPrint(self.allocator, "{}", .{b});
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

    fn hexToBytes(self: *Self, hex: []const u8) ![]u8 {
        const hex_start: usize = if (std.mem.startsWith(u8, hex, "0x")) 2 else 0;
        const hex_data = hex[hex_start..];

        if (hex_data.len % 2 != 0) {
            return error.InvalidHexLength;
        }

        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var i: usize = 0;
        while (i < hex_data.len) : (i += 2) {
            const high = try std.fmt.parseInt(u8, hex_data[i .. i + 1], 16);
            const low = try std.fmt.parseInt(u8, hex_data[i + 1 .. i + 2], 16);
            try result.append((high << 4) | low);
        }

        return result.toOwnedSlice();
    }

    fn hexToBytes32(self: *Self, hex: []const u8) ![32]u8 {
        const bytes = try self.hexToBytes(hex);
        defer self.allocator.free(bytes);

        if (bytes.len != 32) {
            return error.InvalidLength;
        }

        var result: [32]u8 = undefined;
        @memcpy(&result, bytes);
        return result;
    }

    fn hexToU256(self: *Self, hex: []const u8) !u256 {
        const bytes = try self.hexToBytes(hex);
        defer self.allocator.free(bytes);

        var result: u256 = 0;
        for (bytes) |byte| {
            result = (result << 8) | byte;
        }
        return result;
    }

    fn hexToHash(self: *Self, hex: []const u8) !types.Hash {
        const bytes = try self.hexToBytes32(hex);
        return types.hashFromBytes(bytes);
    }
};
