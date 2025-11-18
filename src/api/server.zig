const std = @import("std");
const core = @import("../core/root.zig");
const validation = @import("../validation/root.zig");
const metrics = @import("../metrics/root.zig");
const http = @import("http.zig");
const jsonrpc = @import("jsonrpc.zig");

pub const JsonRpcServer = struct {
    allocator: std.mem.Allocator,
    ingress_handler: *validation.ingress.Ingress,
    metrics: *metrics.Metrics,
    http_server: http.HttpServer,

    pub fn init(allocator: std.mem.Allocator, addr: std.net.Address, ing: *validation.ingress.Ingress, m: *metrics.Metrics) JsonRpcServer {
        return .{
            .allocator = allocator,
            .ingress_handler = ing,
            .metrics = m,
            .http_server = http.HttpServer.init(allocator, addr),
        };
    }

    pub fn start(self: *JsonRpcServer) !void {
        try self.http_server.listen();

        while (true) {
            const connection = try self.http_server.accept();
            // Handle in background thread (simplified - in production use async/await)
            const thread = try std.Thread.spawn(.{}, handleConnectionThread, .{ self, connection });
            thread.detach();
        }
    }

    fn handleConnectionThread(server: *JsonRpcServer, conn: http.Connection) void {
        var conn_mut = conn;
        defer conn_mut.close();
        
        var request = conn_mut.readRequest() catch |err| {
            std.log.warn("Failed to read request: {any}", .{err});
            return;
        };
        defer request.deinit();

        if (!std.mem.eql(u8, request.method, "POST") or !std.mem.eql(u8, request.path, "/")) {
            var response = http.HttpResponse.init(server.allocator);
            defer response.deinit();
            response.status_code = 404;
            response.body = "Not Found";
            const formatted = response.format(server.allocator) catch return;
            defer server.allocator.free(formatted);
            conn_mut.writeResponse(formatted) catch return;
            return;
        }

        const json_response = server.handleJsonRpc(request.body) catch |err| {
            std.log.warn("Failed to handle JSON-RPC: {any}", .{err});
            const error_response = jsonrpc.JsonRpcResponse.errorResponse(
                server.allocator,
                null,
                jsonrpc.ErrorCode.InternalError,
                "Internal error"
            ) catch return;
            defer server.allocator.free(error_response);
            
            var http_resp = http.HttpResponse.init(server.allocator);
            defer http_resp.deinit();
            http_resp.body = error_response;
            http_resp.headers.put("Content-Type", "application/json") catch return;
            const formatted = http_resp.format(server.allocator) catch return;
            defer server.allocator.free(formatted);
            conn_mut.writeResponse(formatted) catch return;
            return;
        };
        defer server.allocator.free(json_response);

        var http_resp = http.HttpResponse.init(server.allocator);
        defer http_resp.deinit();
        http_resp.body = json_response;
        http_resp.headers.put("Content-Type", "application/json") catch return;
        const formatted = http_resp.format(server.allocator) catch return;
        defer server.allocator.free(formatted);
        conn_mut.writeResponse(formatted) catch return;
    }

    fn handleJsonRpc(self: *JsonRpcServer, body: []const u8) ![]u8 {
        // Parse JSON-RPC request using the parse method from JsonRpcRequest
        const request = try jsonrpc.JsonRpcRequest.parse(self.allocator, body);

        // Handle method
        if (std.mem.eql(u8, request.method, "eth_sendRawTransaction")) {
            return try self.handleSendRawTransaction(&request);
        } else if (std.mem.eql(u8, request.method, "eth_getTransactionReceipt")) {
            return try self.handleGetTransactionReceipt(&request);
        } else if (std.mem.eql(u8, request.method, "eth_blockNumber")) {
            return try self.handleBlockNumber(&request);
        } else {
            return try jsonrpc.JsonRpcResponse.errorResponse(
                self.allocator,
                request.id,
                jsonrpc.ErrorCode.MethodNotFound,
                "Method not found"
            );
        }
    }

    fn handleSendRawTransaction(self: *JsonRpcServer, request: *const jsonrpc.JsonRpcRequest) ![]u8 {
        self.metrics.incrementTransactionsReceived();

        // Parse params
        const params = request.params orelse {
            return try jsonrpc.JsonRpcResponse.errorResponse(
                self.allocator,
                request.id,
                jsonrpc.ErrorCode.InvalidParams,
                "Missing params"
            );
        };

        // In Zig 0.14, std.json.Value is a union, so we need to use switch
        const params_array = switch (params) {
            .array => |arr| arr,
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(
                    self.allocator,
                    request.id,
                    jsonrpc.ErrorCode.InvalidParams,
                    "Invalid params - expected array"
                );
            },
        };

        if (params_array.items.len == 0) {
            return try jsonrpc.JsonRpcResponse.errorResponse(
                self.allocator,
                request.id,
                jsonrpc.ErrorCode.InvalidParams,
                "Missing transaction data"
            );
        }

        // Access the first element and check if it's a string
        const first_param = params_array.items[0];
        const tx_hex = switch (first_param) {
            .string => |s| s,
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(
                    self.allocator,
                    request.id,
                    jsonrpc.ErrorCode.InvalidParams,
                    "Invalid transaction format"
                );
            },
        };

        // Decode hex string (remove 0x prefix if present)
        const hex_start: usize = if (std.mem.startsWith(u8, tx_hex, "0x")) 2 else 0;
        const hex_data = tx_hex[hex_start..];
        
        var tx_bytes = std.array_list.Managed(u8).init(self.allocator);
        defer tx_bytes.deinit();
        
        var i: usize = 0;
        while (i < hex_data.len) : (i += 2) {
            if (i + 1 >= hex_data.len) break;
            const byte = try std.fmt.parseInt(u8, hex_data[i..i+2], 16);
            try tx_bytes.append(byte);
        }

        // Decode RLP transaction
        const tx_bytes_slice = try tx_bytes.toOwnedSlice();
        defer self.allocator.free(tx_bytes_slice);
        
        const tx = core.transaction.Transaction.fromRaw(self.allocator, tx_bytes_slice) catch {
            return try jsonrpc.JsonRpcResponse.errorResponse(
                self.allocator,
                request.id,
                jsonrpc.ErrorCode.InvalidParams,
                "Invalid transaction encoding"
            );
        };
        defer self.allocator.free(tx.data);

        const result = self.ingress_handler.acceptTransaction(tx) catch {
            self.metrics.incrementTransactionsRejected();
            // Handle actual errors (like allocation failures)
            return try jsonrpc.JsonRpcResponse.errorResponse(
                self.allocator,
                request.id,
                jsonrpc.ErrorCode.ServerError,
                "Transaction processing failed"
            );
        };

        if (result != .valid) {
            self.metrics.incrementTransactionsRejected();
            return try jsonrpc.JsonRpcResponse.errorResponse(
                self.allocator,
                request.id,
                jsonrpc.ErrorCode.ServerError,
                "Transaction validation failed"
            );
        }

        self.metrics.incrementTransactionsAccepted();

        const tx_hash = try tx.hash(self.allocator);

        // Format hash as hex string
        const hash_bytes = core.types.hashToBytes(tx_hash);
        var hex_buf: [66]u8 = undefined; // 0x + 64 hex chars
        hex_buf[0] = '0';
        hex_buf[1] = 'x';
        var j: usize = 0;
        while (j < 32) : (j += 1) {
            const hex_digits = "0123456789abcdef";
            hex_buf[2 + j * 2] = hex_digits[hash_bytes[j] >> 4];
            hex_buf[2 + j * 2 + 1] = hex_digits[hash_bytes[j] & 0xf];
        }
        const hash_hex = try std.fmt.allocPrint(self.allocator, "{s}", .{&hex_buf});
        defer self.allocator.free(hash_hex);

        const result_value = std.json.Value{ .string = hash_hex };
        return try jsonrpc.JsonRpcResponse.success(self.allocator, request.id, result_value);
    }

    fn handleGetTransactionReceipt(self: *JsonRpcServer, request: *const jsonrpc.JsonRpcRequest) ![]u8 {
        // In production, fetch receipt from state manager
        const result_value = std.json.Value{ .null = {} };
        return try jsonrpc.JsonRpcResponse.success(self.allocator, request.id, result_value);
    }

    fn handleBlockNumber(self: *JsonRpcServer, request: *const jsonrpc.JsonRpcRequest) ![]u8 {
        // In production, return current block number
        const block_num_hex = try std.fmt.allocPrint(self.allocator, "0x0", .{});
        defer self.allocator.free(block_num_hex);
        const result_value = std.json.Value{ .string = block_num_hex };
        return try jsonrpc.JsonRpcResponse.success(self.allocator, request.id, result_value);
    }
};
