// HTTP server implementation using Zig 0.15 networking

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    server: ?std.net.Server = null,
    
    pub fn init(allocator: std.mem.Allocator, address: std.net.Address) HttpServer {
        return .{
            .allocator = allocator,
            .address = address,
        };
    }
    
    pub fn listen(self: *HttpServer) !void {
        const server = try self.address.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128,
        });
        self.server = server;
        
        std.log.info("HTTP server listening on {any}", .{self.address});
    }
    
    pub fn accept(self: *HttpServer) !Connection {
        var server = self.server orelse return error.NotListening;
        
        const conn = try server.accept();
        
        return Connection{
            .stream = conn.stream,
            .allocator = self.allocator,
        };
    }
    
    pub fn deinit(self: *HttpServer) void {
        if (self.server) |*server| {
            server.deinit();
        }
    }
};

pub const Connection = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    
    pub fn readRequest(self: *Connection) !HttpRequest {
        var buffer: [8192]u8 = undefined;
        const bytes_read = try self.stream.read(&buffer);
        if (bytes_read == 0) return error.ConnectionClosed;
        
        const request_str = buffer[0..bytes_read];
        return try HttpRequest.parse(self.allocator, request_str);
    }
    
    pub fn writeResponse(self: *Connection, response: []const u8) !void {
        _ = try self.stream.writeAll(response);
    }
    
    pub fn close(self: *Connection) void {
        self.stream.close();
    }
};

pub const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    
    pub fn parse(allocator: std.mem.Allocator, raw: []const u8) !HttpRequest {
        var lines = std.mem.splitSequence(u8, raw, "\r\n");
        
        // Parse request line
        const request_line = lines.next() orelse return error.InvalidRequest;
        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method = parts.next() orelse return error.InvalidRequest;
        const path = parts.next() orelse return error.InvalidRequest;
        
        // Parse headers
        var headers = std.StringHashMap([]const u8).init(allocator);
        while (lines.next()) |line| {
            if (line.len == 0) break; // Empty line indicates end of headers
            
            if (std.mem.indexOf(u8, line, ": ")) |colon_idx| {
                const key = line[0..colon_idx];
                const value = line[colon_idx + 2..];
                try headers.put(key, value);
            }
        }
        
        // Body is everything after the empty line
        const body_start = std.mem.indexOf(u8, raw, "\r\n\r\n");
        const body = if (body_start) |idx| raw[idx + 4..] else "";
        
        return HttpRequest{
            .method = method,
            .path = path,
            .headers = headers,
            .body = body,
        };
    }
    
    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
    }
};

pub const HttpResponse = struct {
    status_code: u16 = 200,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    
    pub fn init(allocator: std.mem.Allocator) HttpResponse {
        return .{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = "",
        };
    }
    
    pub fn format(self: *const HttpResponse, allocator: std.mem.Allocator) ![]u8 {
        var result = std.array_list.Managed(u8).init(allocator);
        errdefer result.deinit();
        
        const status_text = switch (self.status_code) {
            200 => "OK",
            400 => "Bad Request",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };
        
        try result.writer().print("HTTP/1.1 {d} {s}\r\n", .{ self.status_code, status_text });
        
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            try result.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        
        try result.writer().print("Content-Length: {d}\r\n", .{self.body.len});
        try result.writer().print("\r\n", .{});
        try result.writer().writeAll(self.body);
        
        return result.toOwnedSlice();
    }
    
    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }
};

