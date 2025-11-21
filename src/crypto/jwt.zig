// JWT token generation for Engine API authentication
// Implements HS256 JWT signing with minimal claims (iat only)

const std = @import("std");
const crypto = std.crypto;

const base64_url_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Base64 URL encoding (without padding)
fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < data.len) : (i += 3) {
        var buf: [3]u8 = undefined;
        var buf_len: usize = 0;

        // Read up to 3 bytes
        while (buf_len < 3 and i + buf_len < data.len) {
            buf[buf_len] = data[i + buf_len];
            buf_len += 1;
        }

        // Encode to base64
        if (buf_len == 3) {
            const b1 = buf[0] >> 2;
            const b2 = ((buf[0] & 0x03) << 4) | (buf[1] >> 4);
            const b3 = ((buf[1] & 0x0f) << 2) | (buf[2] >> 6);
            const b4 = buf[2] & 0x3f;

            try result.append(base64_url_chars[b1]);
            try result.append(base64_url_chars[b2]);
            try result.append(base64_url_chars[b3]);
            try result.append(base64_url_chars[b4]);
        } else if (buf_len == 2) {
            const b1 = buf[0] >> 2;
            const b2 = ((buf[0] & 0x03) << 4) | (buf[1] >> 4);
            const b3 = (buf[1] & 0x0f) << 2;

            try result.append(base64_url_chars[b1]);
            try result.append(base64_url_chars[b2]);
            try result.append(base64_url_chars[b3]);
        } else if (buf_len == 1) {
            const b1 = buf[0] >> 2;
            const b2 = (buf[0] & 0x03) << 4;

            try result.append(base64_url_chars[b1]);
            try result.append(base64_url_chars[b2]);
        }
    }

    return result.toOwnedSlice();
}

/// Generate JWT token for Engine API authentication
/// Uses HS256 signing with minimal claims (iat only)
/// Returns a JWT token string (format: header.payload.signature)
pub fn generateEngineAPIToken(allocator: std.mem.Allocator, secret: [32]u8) ![]const u8 {
    // JWT Header: {"alg":"HS256","typ":"JWT"}
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b64 = try base64UrlEncode(allocator, header_json);
    defer allocator.free(header_b64);

    // JWT Payload: {"iat":<current_timestamp>}
    const current_time = @as(i64, @intCast(std.time.timestamp()));
    const payload_json = try std.fmt.allocPrint(allocator, "{{\"iat\":{d}}}", .{current_time});
    defer allocator.free(payload_json);
    const payload_b64 = try base64UrlEncode(allocator, payload_json);
    defer allocator.free(payload_b64);

    // Combine header and payload
    const unsigned_token = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(unsigned_token);

    // Sign with HMAC-SHA256
    var hmac_result: [32]u8 = undefined;
    var hmac = crypto.auth.hmac.sha2.HmacSha256.init(&secret);
    hmac.update(unsigned_token);
    hmac.final(&hmac_result);

    // Encode signature
    const signature_b64 = try base64UrlEncode(allocator, &hmac_result);
    defer allocator.free(signature_b64);

    // Combine all parts
    const token = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ unsigned_token, signature_b64 });

    return token;
}
