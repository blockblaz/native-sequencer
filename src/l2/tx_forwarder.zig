// Transaction forwarder for handling transactions from L2 geth

const std = @import("std");
const core = @import("../core/root.zig");
const types = @import("../core/types.zig");
const validation = @import("../validation/root.zig");
const mempool = @import("../mempool/root.zig");
const engine_api = @import("engine_api_client.zig");

pub const TransactionForwarder = struct {
    allocator: std.mem.Allocator,
    ingress_handler: *validation.ingress.Ingress,
    mempool: *mempool.Mempool,
    engine_client: *engine_api.EngineApiClient,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, ingress: *validation.ingress.Ingress, mp: *mempool.Mempool, engine: *engine_api.EngineApiClient) Self {
        return .{
            .allocator = allocator,
            .ingress_handler = ingress,
            .mempool = mp,
            .engine_client = engine,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No cleanup needed
    }

    /// Forward transaction from L2 geth to sequencer
    /// This is called when L2 geth receives a transaction and forwards it to the sequencer
    pub const ForwardResult = struct {
        accepted: bool,
        tx_hash: ?types.Hash,
        error_message: ?[]const u8,
    };

    pub fn forwardTransaction(self: *Self, raw_tx_hex: []const u8) !ForwardResult {
        // Decode hex transaction
        const raw_tx = try self.hexToBytes(raw_tx_hex);
        defer self.allocator.free(raw_tx);

        // Parse transaction
        const tx = core.transaction.Transaction.fromRaw(self.allocator, raw_tx) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Invalid transaction: {any}", .{err});
            return ForwardResult{
                .accepted = false,
                .tx_hash = null,
                .error_message = error_msg,
            };
        };
        defer self.allocator.free(tx.data);

        // Validate and accept transaction
        const validation_result = self.ingress_handler.acceptTransaction(tx) catch |err| {
            const error_msg = try std.fmt.allocPrint(self.allocator, "Validation error: {any}", .{err});
            return ForwardResult{
                .accepted = false,
                .tx_hash = null,
                .error_message = error_msg,
            };
        };

        if (validation_result != .accepted) {
            const error_msg = switch (validation_result) {
                .invalid => "Transaction is invalid",
                .duplicate => "Transaction already in mempool",
                .insufficient_funds => "Insufficient funds",
                .nonce_too_low => "Nonce too low",
                .nonce_too_high => "Nonce too high",
                .gas_price_too_low => "Gas price too low",
                .accepted => unreachable,
            };

            const error_str = try std.fmt.allocPrint(self.allocator, "{s}", .{error_msg});
            return ForwardResult{
                .accepted = false,
                .tx_hash = null,
                .error_message = error_str,
            };
        }

        // Get transaction hash
        const tx_hash = try tx.hash(self.allocator);
        // tx_hash is u256, no need to free

        return ForwardResult{
            .accepted = true,
            .tx_hash = tx_hash,
            .error_message = null,
        };
    }

    /// Submit sequenced block back to L2 geth via engine_newPayload
    pub fn submitBlockToL2(self: *Self, block: *const core.block.Block) !engine_api.PayloadStatus {
        std.log.info("[TxForwarder] Submitting block #{d} to L2 geth via engine_newPayload", .{block.number});
        const status = try self.engine_client.newPayload(block);
        std.log.info("[TxForwarder] Block #{d} submission result: {s}", .{ block.number, status.status });
        return status;
    }

    /// Convert hex string to bytes
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
};
