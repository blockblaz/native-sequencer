// Conditional transaction options (EIP-7796)
// Supports conditional transaction submission with block number and timestamp constraints

const std = @import("std");
const types = @import("types.zig");

/// Conditional options for transaction submission
pub const ConditionalOptions = struct {
    block_number_min: ?u64 = null,
    block_number_max: ?u64 = null,
    timestamp_min: ?u64 = null,
    timestamp_max: ?u64 = null,
    // known_accounts: ?std.json.Value = null, // Future: support account state checks

    pub fn deinit(self: *ConditionalOptions) void {
        _ = self;
        // No cleanup needed for now
    }

    /// Check if conditions are satisfied given current block state
    pub fn checkConditions(self: *const ConditionalOptions, current_block_number: u64, current_timestamp: u64) bool {
        // Check block number constraints
        if (self.block_number_min) |min| {
            if (current_block_number < min) {
                return false;
            }
        }
        if (self.block_number_max) |max| {
            if (current_block_number > max) {
                return false;
            }
        }

        // Check timestamp constraints
        if (self.timestamp_min) |min| {
            if (current_timestamp < min) {
                return false;
            }
        }
        if (self.timestamp_max) |max| {
            if (current_timestamp > max) {
                return false;
            }
        }

        return true;
    }

    /// Parse conditional options from JSON-RPC params
    pub fn fromJson(allocator: std.mem.Allocator, options_json: std.json.Value) !ConditionalOptions {
        _ = allocator;
        var options = ConditionalOptions{};

        const options_obj = switch (options_json) {
            .object => |obj| obj,
            else => return error.InvalidOptionsFormat,
        };

        // Parse blockNumberMin
        if (options_obj.get("blockNumberMin")) |value| {
            const block_num_str = switch (value) {
                .string => |s| s,
                else => return error.InvalidBlockNumberFormat,
            };
            const hex_start: usize = if (std.mem.startsWith(u8, block_num_str, "0x")) 2 else 0;
            options.block_number_min = try std.fmt.parseInt(u64, block_num_str[hex_start..], 16);
        }

        // Parse blockNumberMax
        if (options_obj.get("blockNumberMax")) |value| {
            const block_num_str = switch (value) {
                .string => |s| s,
                else => return error.InvalidBlockNumberFormat,
            };
            const hex_start: usize = if (std.mem.startsWith(u8, block_num_str, "0x")) 2 else 0;
            options.block_number_max = try std.fmt.parseInt(u64, block_num_str[hex_start..], 16);
        }

        // Parse timestampMin
        if (options_obj.get("timestampMin")) |value| {
            const timestamp_val = switch (value) {
                .string => |s| blk: {
                    const hex_start: usize = if (std.mem.startsWith(u8, s, "0x")) 2 else 0;
                    break :blk try std.fmt.parseInt(u64, s[hex_start..], 16);
                },
                .integer => |i| @as(u64, @intCast(i)),
                else => return error.InvalidTimestampFormat,
            };
            options.timestamp_min = timestamp_val;
        }

        // Parse timestampMax
        if (options_obj.get("timestampMax")) |value| {
            const timestamp_val = switch (value) {
                .string => |s| blk: {
                    const hex_start: usize = if (std.mem.startsWith(u8, s, "0x")) 2 else 0;
                    break :blk try std.fmt.parseInt(u64, s[hex_start..], 16);
                },
                .integer => |i| @as(u64, @intCast(i)),
                else => return error.InvalidTimestampFormat,
            };
            options.timestamp_max = timestamp_val;
        }

        return options;
    }
};

/// Conditional transaction entry (transaction + conditions)
pub const ConditionalTx = struct {
    tx: transaction.Transaction,
    conditions: ConditionalOptions,

    pub fn deinit(self: *ConditionalTx, allocator: std.mem.Allocator) void {
        self.tx.deinit(allocator);
        self.conditions.deinit();
    }
};

const transaction = @import("transaction.zig");
