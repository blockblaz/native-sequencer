// JSON-RPC 2.0 protocol implementation

const std = @import("std");
const core = @import("../core/root.zig");

pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: ?std.json.Value = null,

    pub fn parse(allocator: std.mem.Allocator, json_str: []const u8) !JsonRpcRequest {
        // Use parseFromSliceLeaky for Zig 0.15 - returns owned value
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
        return try serializeResponse(allocator, response);
    }

    pub fn errorResponse(allocator: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]u8 {
        const error_msg = try allocator.dupe(u8, message);
        const response = JsonRpcResponse{
            .jsonrpc = "2.0",
            .@"error" = JsonRpcError{
                .code = code,
                .message = error_msg,
            },
            .id = id,
        };
        defer allocator.free(error_msg);
        return try serializeResponse(allocator, response);
    }

    fn serializeResponse(allocator: std.mem.Allocator, response: JsonRpcResponse) ![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        try list.writer().writeAll("{\"jsonrpc\":\"2.0\",");

        if (response.result) |result| {
            try list.writer().writeAll("\"result\":");
            try serializeJsonValue(list.writer(), result);
            try list.writer().writeAll(",");
        }

        if (response.@"error") |err| {
            try list.writer().writeAll("\"error\":{");
            try list.writer().print("\"code\":{},", .{err.code});
            try list.writer().writeAll("\"message\":");
            try serializeJsonValue(list.writer(), std.json.Value{ .string = err.message });
            if (err.data) |data| {
                try list.writer().writeAll(",\"data\":");
                try serializeJsonValue(list.writer(), data);
            }
            try list.writer().writeAll("},");
        }

        try list.writer().writeAll("\"id\":");
        if (response.id) |id| {
            try serializeJsonValue(list.writer(), id);
        } else {
            try list.writer().writeAll("null");
        }

        try list.writer().writeAll("}");

        return try list.toOwnedSlice();
    }

    fn serializeJsonValue(writer: anytype, value: std.json.Value) !void {
        switch (value) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.print("{}", .{b}),
            .integer => |i| try writer.print("{}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .number_string => |ns| try writer.print("\"{s}\"", .{ns}),
            .string => |s| {
                // Escape string properly
                try writer.writeByte('"');
                for (s) |char| {
                    switch (char) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(char),
                    }
                }
                try writer.writeByte('"');
            },
            .array => |arr| {
                try writer.writeAll("[");
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(",");
                    try serializeJsonValue(writer, item);
                }
                try writer.writeAll("]");
            },
            .object => |obj| {
                try writer.writeAll("{");
                var iter = obj.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.print("\"{s}\":", .{entry.key_ptr.*});
                    try serializeJsonValue(writer, entry.value_ptr.*);
                }
                try writer.writeAll("}");
            },
        }
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
