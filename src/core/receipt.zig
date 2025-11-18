const types = @import("types.zig");

pub const Receipt = struct {
    transaction_hash: types.Hash,
    block_number: u64,
    block_hash: types.Hash,
    transaction_index: u32,
    gas_used: u64,
    status: bool,
    logs: []Log,

    pub const Log = struct {
        address: types.Address,
        topics: []types.Hash,
        data: []const u8,
    };
};

