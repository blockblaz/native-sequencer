// Block synchronization for syncing sequencer blocks to L2 geth

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const block_module = @import("../core/block.zig");
const engine_api = @import("engine_api_client.zig");
const state_provider = @import("state_provider.zig");

pub const BlockSync = struct {
    allocator: std.mem.Allocator,
    engine_client: *engine_api.EngineApiClient,
    state_provider: *state_provider.StateProvider,
    head_block_hash: ?types.Hash = null,
    safe_block_hash: ?types.Hash = null,
    finalized_block_hash: ?types.Hash = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, engine: *engine_api.EngineApiClient, state: *state_provider.StateProvider) Self {
        return .{
            .allocator = allocator,
            .engine_client = engine,
            .state_provider = state,
            .head_block_hash = null,
            .safe_block_hash = null,
            .finalized_block_hash = null,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed
    }

    /// Sync block to L2 geth via engine_newPayload
    pub fn syncBlock(self: *Self, block: *const block_module.Block) !engine_api.PayloadStatus {
        std.log.info("[BlockSync] Syncing block #{d} to L2 geth", .{block.number});

        // Submit block to L2 geth
        const status = try self.engine_client.newPayload(block);

        // Update fork choice if block is valid
        if (std.mem.eql(u8, status.status, "VALID")) {
            const block_hash = block.hash();
            self.head_block_hash = block_hash;

            std.log.info("[BlockSync] Block #{d} accepted, updating fork choice", .{block.number});

            // Update fork choice state
            _ = try self.updateForkChoice(block_hash, block_hash, block_hash);
        } else {
            std.log.warn("[BlockSync] Block #{d} sync failed with status: {s}", .{ block.number, status.status });
            if (status.validation_error) |err| {
                std.log.warn("[BlockSync] Validation error: {s}", .{err});
            }
        }

        return status;
    }

    /// Update fork choice state in L2 geth
    pub fn updateForkChoice(self: *Self, head_hash: types.Hash, safe_hash: types.Hash, finalized_hash: types.Hash) !engine_api.ForkChoiceUpdateResponse {
        std.log.info("[BlockSync] Updating fork choice state", .{});

        const response = try self.engine_client.forkchoiceUpdated(head_hash, safe_hash, finalized_hash);

        // Update local fork choice state
        self.head_block_hash = head_hash;
        self.safe_block_hash = safe_hash;
        self.finalized_block_hash = finalized_hash;

        std.log.info("[BlockSync] Fork choice updated successfully", .{});

        return response;
    }

    /// Handle chain reorganization (reorg)
    pub fn handleReorg(self: *Self, new_head_hash: types.Hash, common_ancestor_hash: types.Hash) !void {
        // Update fork choice to new head
        // Safe and finalized blocks remain unchanged unless explicitly updated
        const safe_hash = self.safe_block_hash orelse common_ancestor_hash;
        const finalized_hash = self.finalized_block_hash orelse common_ancestor_hash;

        _ = try self.updateForkChoice(new_head_hash, safe_hash, finalized_hash);
    }

    /// Get L2 geth sync status
    pub fn getSyncStatus(self: *Self) !struct {
        synced: bool,
        current_block: u64,
        highest_block: u64,
    } {
        // Query L2 geth for sync status via eth_syncing
        const result = try self.state_provider.callRpc("eth_syncing", std.json.Value{ .array = std.json.Array.init(self.allocator) });
        defer self.allocator.free(result);

        // Parse response
        const parsed = try std.json.parseFromSliceLeaky(
            struct {
                result: union(enum) {
                    boolean: bool,
                    object: struct {
                        currentBlock: []const u8,
                        highestBlock: []const u8,
                    },
                },
            },
            self.allocator,
            result,
            .{},
        );

        switch (parsed.result) {
            .boolean => |synced| {
                if (synced) {
                    // Still syncing, but we don't have block numbers
                    return .{
                        .synced = false,
                        .current_block = 0,
                        .highest_block = 0,
                    };
                } else {
                    // Synced, get current block number
                    const current_block = try self.state_provider.getBlockByNumber(0, false); // Get latest
                    return .{
                        .synced = true,
                        .current_block = current_block.number,
                        .highest_block = current_block.number,
                    };
                }
            },
            .object => |sync_info| {
                const hex_start: usize = if (std.mem.startsWith(u8, sync_info.currentBlock, "0x")) 2 else 0;
                const current = try std.fmt.parseInt(u64, sync_info.currentBlock[hex_start..], 16);
                const highest_hex_start: usize = if (std.mem.startsWith(u8, sync_info.highestBlock, "0x")) 2 else 0;
                const highest = try std.fmt.parseInt(u64, sync_info.highestBlock[highest_hex_start..], 16);

                return .{
                    .synced = false,
                    .current_block = current,
                    .highest_block = highest,
                };
            },
        }
    }

    /// Sync multiple blocks in sequence
    pub fn syncBlocks(self: *Self, blocks: []const block_module.Block) !void {
        for (blocks) |block| {
            const status = try self.syncBlock(&block);

            if (!std.mem.eql(u8, status.status, "VALID")) {
                std.log.warn("Block #{d} sync failed: {s}", .{ block.number, status.status });
                if (status.validation_error) |err| {
                    std.log.warn("Validation error: {s}", .{err});
                }
                // Continue syncing other blocks
            }
        }
    }

    /// Call RPC via state provider (helper method)
    fn callRpcViaStateProvider(self: *Self, method: []const u8, params: std.json.Value) ![]u8 {
        // Parse URL
        const url_parts = try self.parseUrl(self.state_provider.l2_rpc_url);
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
            .boolean => |b| {
                return try std.fmt.allocPrint(self.allocator, "{}", .{b});
            },
            else => return error.UnsupportedJsonType,
        }
    }
};
