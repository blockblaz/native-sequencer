// JSON-RPC 2.0 protocol implementation

const std = @import("std");
const core = @import("../core/root.zig");

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?std.json.Value = null,
    
    pub fn parse(allocator: std.mem.Allocator, json_str: []const u8) !JsonRpcRequest {
        // Use parseFromSliceLeaky for Zig 0.14 - returns owned value
        // We need to handle the parsed value carefully since it owns the strings
        const parsed = try std.json.parseFromSliceLeaky(
            JsonRpcRequest,
            allocator,
            json_str,
            .{},
        );
        return parsed;
    }
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
    id: ?std.json.Value = null,
    
    pub fn success(allocator: std.mem.Allocator, id: ?std.json.Value, result: std.json.Value) ![]u8 {
        const response = JsonRpcResponse{
            .jsonrpc = "2.0",
            .result = result,
            .id = id,
        };
        return try std.json.stringifyAlloc(allocator, response, .{});
    }
    
    pub fn errorResponse(allocator: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]u8 {
        const response = JsonRpcResponse{
            .jsonrpc = "2.0",
            .@"error" = JsonRpcError{
                .code = code,
                .message = message,
            },
            .id = id,
        };
        return try std.json.stringifyAlloc(allocator, response, .{});
    }
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const ErrorCode = struct {
    pub const ParseError: i32 = -32700;
    pub const InvalidRequest: i32 = -32600;
    pub const MethodNotFound: i32 = -32601;
    pub const InvalidParams: i32 = -32602;
    pub const InternalError: i32 = -32603;
    pub const ServerError: i32 = -32000;
};

