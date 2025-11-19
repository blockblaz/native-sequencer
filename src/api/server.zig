const std = @import("std");
const core = @import("../core/root.zig");
const validation = @import("../validation/root.zig");
const metrics = @import("../metrics/root.zig");
const l1 = @import("../l1/root.zig");
const http = @import("http.zig");
const jsonrpc = @import("jsonrpc.zig");

pub const JsonRpcServer = struct {
    allocator: std.mem.Allocator,
    ingress_handler: *validation.ingress.Ingress,
    metrics: *metrics.Metrics,
    http_server: http.HttpServer,
    l1_client: ?*l1.Client = null,
    /// Optional sequencer reference for witness generation testing
    sequencer: ?*@import("../sequencer/root.zig").Sequencer = null,

    pub fn init(allocator: std.mem.Allocator, addr: std.net.Address, host: []const u8, port: u16, ing: *validation.ingress.Ingress, m: *metrics.Metrics) JsonRpcServer {
        return .{
            .allocator = allocator,
            .ingress_handler = ing,
            .metrics = m,
            .http_server = http.HttpServer.init(allocator, addr, host, port),
            .l1_client = null,
        };
    }

    pub fn initWithL1Client(allocator: std.mem.Allocator, addr: std.net.Address, host: []const u8, port: u16, ing: *validation.ingress.Ingress, m: *metrics.Metrics, l1_cli: *l1.Client) JsonRpcServer {
        return .{
            .allocator = allocator,
            .ingress_handler = ing,
            .metrics = m,
            .http_server = http.HttpServer.init(allocator, addr, host, port),
            .l1_client = l1_cli,
            .sequencer = null,
        };
    }

    pub fn initWithSequencer(allocator: std.mem.Allocator, addr: std.net.Address, host: []const u8, port: u16, ing: *validation.ingress.Ingress, m: *metrics.Metrics, l1_cli: *l1.Client, seq: *@import("../sequencer/root.zig").Sequencer) JsonRpcServer {
        return .{
            .allocator = allocator,
            .ingress_handler = ing,
            .metrics = m,
            .http_server = http.HttpServer.init(allocator, addr, host, port),
            .l1_client = l1_cli,
            .sequencer = seq,
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
            std.log.warn("Failed to read HTTP request: {any}", .{err});
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
            std.log.warn("Failed to handle JSON-RPC request (method={s}): {any}", .{ request.method, err });
            const error_response = jsonrpc.JsonRpcResponse.errorResponse(server.allocator, null, jsonrpc.ErrorCode.InternalError, "Internal error") catch return;
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
        } else if (std.mem.eql(u8, request.method, "debug_generateWitness")) {
            return try self.handleGenerateWitness(&request);
        } else if (std.mem.eql(u8, request.method, "debug_generateBlockWitness")) {
            return try self.handleGenerateBlockWitness(&request);
        } else {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.MethodNotFound, "Method not found");
        }
    }

    fn handleSendRawTransaction(self: *JsonRpcServer, request: *const jsonrpc.JsonRpcRequest) ![]u8 {
        self.metrics.incrementTransactionsReceived();

        // Parse params
        const params = request.params orelse {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Missing params");
        };

        // In Zig 0.15, std.json.Value is a union, so we need to use switch
        const params_array = switch (params) {
            .array => |arr| arr,
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid params - expected array");
            },
        };

        if (params_array.items.len == 0) {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Missing transaction data");
        }

        // Access the first element and check if it's a string
        const first_param = params_array.items[0];
        const tx_hex = switch (first_param) {
            .string => |s| s,
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid transaction format");
            },
        };

        // Decode hex string (remove 0x prefix if present)
        const hex_start: usize = if (std.mem.startsWith(u8, tx_hex, "0x")) 2 else 0;
        const hex_data = tx_hex[hex_start..];

        var tx_bytes = std.ArrayList(u8).init(self.allocator);
        defer tx_bytes.deinit();

        var i: usize = 0;
        while (i < hex_data.len) : (i += 2) {
            if (i + 1 >= hex_data.len) break;
            const byte = try std.fmt.parseInt(u8, hex_data[i .. i + 2], 16);
            try tx_bytes.append(byte);
        }

        // Decode transaction based on type
        const tx_bytes_slice = try tx_bytes.toOwnedSlice();
        defer self.allocator.free(tx_bytes_slice);

        // Check transaction type (EIP-2718)
        if (tx_bytes_slice.len > 0 and tx_bytes_slice[0] == core.transaction.ExecuteTxType) {
            // ExecuteTx transaction - these are stateless and should be forwarded to L1 geth
            var execute_tx = core.transaction_execute.ExecuteTx.fromRaw(self.allocator, tx_bytes_slice) catch {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid ExecuteTx encoding");
            };
            defer execute_tx.deinit(self.allocator);

            // Minimal validation (signature check for deduplication)
            const result = self.ingress_handler.acceptExecuteTx(&execute_tx) catch {
                self.metrics.incrementTransactionsRejected();
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, "ExecuteTx processing failed");
            };

            if (result != .valid) {
                self.metrics.incrementTransactionsRejected();
                const error_msg = switch (result) {
                    .invalid_signature => "Invalid ExecuteTx signature",
                    .duplicate => "ExecuteTx already seen",
                    else => "ExecuteTx validation failed",
                };
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, error_msg);
            }

            self.metrics.incrementTransactionsAccepted();

            // Forward ExecuteTx to L1 geth via eth_sendRawTransaction
            const tx_hash = if (self.l1_client) |l1_cli| blk: {
                // Forward to L1 geth
                const forwarded_hash = l1_cli.forwardExecuteTx(&execute_tx) catch |err| {
                    std.log.err("Failed to forward ExecuteTx to L1 geth: {any}", .{err});
                    self.metrics.incrementTransactionsRejected();
                    return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, "Failed to forward ExecuteTx to L1");
                };
                break :blk forwarded_hash;
            } else blk: {
                // L1 client not available, just return the transaction hash
                std.log.warn("L1 client not available, ExecuteTx not forwarded", .{});
                break :blk try execute_tx.hash(self.allocator);
            };
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
        } else {
            // Legacy transaction
            const tx = core.transaction.Transaction.fromRaw(self.allocator, tx_bytes_slice) catch {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid transaction encoding");
            };
            defer self.allocator.free(tx.data);

            const result = self.ingress_handler.acceptTransaction(tx) catch {
                self.metrics.incrementTransactionsRejected();
                // Handle actual errors (like allocation failures)
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, "Transaction processing failed");
            };

            if (result != .valid) {
                self.metrics.incrementTransactionsRejected();
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, "Transaction validation failed");
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

    /// Generate witness for a transaction (debug endpoint for testing)
    /// Params: ["0x<raw_transaction_hex>"]
    /// Returns: { "witness": "0x<rlp_encoded_witness>", "witnessSize": <size> }
    fn handleGenerateWitness(self: *JsonRpcServer, request: *const jsonrpc.JsonRpcRequest) ![]u8 {
        if (self.sequencer == null) {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, "Sequencer not available for witness generation");
        }

        const sequencer = self.sequencer.?;

        // Parse params
        const params = request.params orelse {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Missing params");
        };

        const params_array = switch (params) {
            .array => |arr| arr,
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid params - expected array");
            },
        };

        if (params_array.items.len == 0) {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Missing transaction data");
        }

        // Get transaction hex
        const first_param = params_array.items[0];
        const tx_hex = switch (first_param) {
            .string => |s| s,
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid transaction format");
            },
        };

        // Decode hex string
        const hex_start: usize = if (std.mem.startsWith(u8, tx_hex, "0x")) 2 else 0;
        const hex_data = tx_hex[hex_start..];

        var tx_bytes = std.ArrayList(u8).init(self.allocator);
        defer tx_bytes.deinit();

        var i: usize = 0;
        while (i < hex_data.len) : (i += 2) {
            if (i + 1 >= hex_data.len) break;
            const byte = try std.fmt.parseInt(u8, hex_data[i .. i + 2], 16);
            try tx_bytes.append(byte);
        }

        const tx_bytes_slice = try tx_bytes.toOwnedSlice();
        defer self.allocator.free(tx_bytes_slice);

        // Parse transaction (only legacy transactions for now)
        const tx = core.transaction.Transaction.fromRaw(self.allocator, tx_bytes_slice) catch {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid transaction encoding");
        };
        defer self.allocator.free(tx.data);

        // Initialize witness builder
        var witness_builder = core.witness_builder.WitnessBuilder.init(self.allocator);
        defer witness_builder.deinit();

        // Create execution engine with witness builder
        var exec_engine = sequencer.execution_engine;
        exec_engine.witness_builder = &witness_builder;

        // Execute transaction (this will track state access)
        _ = exec_engine.executeTransaction(tx) catch |err| {
            std.log.warn("Transaction execution failed during witness generation: {any}", .{err});
            // Continue anyway to generate witness from what was tracked
        };

        // Build witness
        _ = try witness_builder.buildWitness(sequencer.state_manager, null);

        // Encode witness to RLP
        const witness_rlp = try witness_builder.witness.encodeRLP(self.allocator);
        defer self.allocator.free(witness_rlp);

        // Convert to hex
        var hex_buf = std.ArrayList(u8).init(self.allocator);
        defer hex_buf.deinit();
        try hex_buf.appendSlice("0x");
        for (witness_rlp) |byte| {
            const hex_digits = "0123456789abcdef";
            try hex_buf.append(hex_digits[byte >> 4]);
            try hex_buf.append(hex_digits[byte & 0xf]);
        }
        const witness_hex = try hex_buf.toOwnedSlice();
        defer self.allocator.free(witness_hex);

        // Create response object
        var result_obj = std.json.ObjectMap.init(self.allocator);
        errdefer result_obj.deinit();
        try result_obj.put("witness", std.json.Value{ .string = witness_hex });
        try result_obj.put("witnessSize", std.json.Value{ .integer = @as(i64, @intCast(witness_rlp.len)) });

        const result_value = std.json.Value{ .object = result_obj };
        return try jsonrpc.JsonRpcResponse.success(self.allocator, request.id, result_value);
    }

    /// Generate witness for a block (debug endpoint for testing)
    /// Params: [block_number] or ["latest"]
    /// Returns: { "witness": "0x<rlp_encoded_witness>", "witnessSize": <size>, "blockNumber": <number> }
    fn handleGenerateBlockWitness(self: *JsonRpcServer, request: *const jsonrpc.JsonRpcRequest) ![]u8 {
        if (self.sequencer == null) {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, "Sequencer not available for witness generation");
        }

        const sequencer = self.sequencer.?;

        // Parse params
        const params = request.params orelse {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Missing params");
        };

        const params_array = switch (params) {
            .array => |arr| arr,
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid params - expected array");
            },
        };

        if (params_array.items.len == 0) {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Missing block number");
        }

        // Get block number
        const first_param = params_array.items[0];
        const block_param = switch (first_param) {
            .string => |s| s,
            .integer => |i| {
                // Convert integer to hex string
                const hex_str = try std.fmt.allocPrint(self.allocator, "0x{x}", .{i});
                defer self.allocator.free(hex_str);
                return hex_str;
            },
            else => {
                return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid block number format");
            },
        };

        // Parse block number (for future use when fetching from storage)
        const hex_start: usize = if (std.mem.startsWith(u8, block_param, "0x")) 2 else 0;
        const hex_data = block_param[hex_start..];

        _ = if (std.mem.eql(u8, block_param, "latest") or std.mem.eql(u8, hex_data, "latest")) blk: {
            // Use latest block number (current_block_number - 1 since we increment after building)
            break :blk if (sequencer.current_block_number > 0) sequencer.current_block_number - 1 else 0;
        } else blk: {
            if (hex_data.len == 0) return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.InvalidParams, "Invalid block number");
            break :blk try std.fmt.parseInt(u64, hex_data, 16);
        };

        // For now, we'll build a block from the mempool and generate witness for it
        // In production, you would fetch the block from storage based on block_number
        const block = sequencer.buildBlock() catch {
            return try jsonrpc.JsonRpcResponse.errorResponse(self.allocator, request.id, jsonrpc.ErrorCode.ServerError, "Failed to build block");
        };

        // Initialize witness builder
        var witness_builder = core.witness_builder.WitnessBuilder.init(self.allocator);
        defer witness_builder.deinit();

        // Generate witness for the block
        try witness_builder.generateBlockWitness(&block, &sequencer.execution_engine);

        // Build witness
        _ = try witness_builder.buildWitness(sequencer.state_manager, null);

        // Encode witness to RLP
        const witness_rlp = try witness_builder.witness.encodeRLP(self.allocator);
        defer self.allocator.free(witness_rlp);

        // Convert to hex
        var hex_buf = std.ArrayList(u8).init(self.allocator);
        defer hex_buf.deinit();
        try hex_buf.appendSlice("0x");
        for (witness_rlp) |byte| {
            const hex_digits = "0123456789abcdef";
            try hex_buf.append(hex_digits[byte >> 4]);
            try hex_buf.append(hex_digits[byte & 0xf]);
        }
        const witness_hex = try hex_buf.toOwnedSlice();
        defer self.allocator.free(witness_hex);

        // Create response object
        var result_obj = std.json.ObjectMap.init(self.allocator);
        errdefer result_obj.deinit();
        try result_obj.put("witness", std.json.Value{ .string = witness_hex });
        try result_obj.put("witnessSize", std.json.Value{ .integer = @as(i64, @intCast(witness_rlp.len)) });
        try result_obj.put("blockNumber", std.json.Value{ .integer = @as(i64, @intCast(block.number)) });
        try result_obj.put("transactionCount", std.json.Value{ .integer = @as(i64, @intCast(block.transactions.len)) });

        const result_value = std.json.Value{ .object = result_obj };
        return try jsonrpc.JsonRpcResponse.success(self.allocator, request.id, result_value);
    }
};
