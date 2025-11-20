const std = @import("std");
const core = @import("../core/root.zig");
const persistence = @import("../persistence/root.zig");

pub const StateManager = struct {
    allocator: std.mem.Allocator,
    nonces: std.HashMap(core.types.Address, u64, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage),
    balances: std.HashMap(core.types.Address, u256, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage),
    receipts: std.HashMap(core.types.Hash, core.receipt.Receipt, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage),
    current_block_number: u64 = 0,
    db: ?*persistence.lmdb.Database = null,
    use_persistence: bool = false,

    /// Initialize StateManager with optional LMDB persistence
    pub fn init(allocator: std.mem.Allocator) StateManager {
        return .{
            .allocator = allocator,
            .nonces = std.HashMap(core.types.Address, u64, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage).init(allocator),
            .balances = std.HashMap(core.types.Address, u256, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage).init(allocator),
            .receipts = std.HashMap(core.types.Hash, core.receipt.Receipt, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
            .db = null,
            .use_persistence = false,
        };
    }

    /// Initialize StateManager with LMDB persistence
    pub fn initWithPersistence(allocator: std.mem.Allocator, db: *persistence.lmdb.Database) !StateManager {
        var sm = init(allocator);
        sm.db = db;
        sm.use_persistence = true;

        // Load persisted state from database
        try sm.loadFromDatabase();

        return sm;
    }

    /// Load state from LMDB database
    fn loadFromDatabase(self: *StateManager) !void {
        if (self.db == null) return;

        const db = self.db.?;

        // Load current block number
        if (try db.getBlockNumber()) |block_num| {
            self.current_block_number = block_num;
            std.log.info("Loaded block number from database: {d}", .{block_num});
        }

        // Note: Loading all nonces/balances/receipts into memory would be expensive
        // For now, we load on-demand. In production, consider using iterators or
        // loading only frequently accessed data
        std.log.info("State manager initialized with LMDB persistence", .{});
    }

    pub fn deinit(self: *StateManager) void {
        self.nonces.deinit();
        self.balances.deinit();
        var receipt_iter = self.receipts.iterator();
        while (receipt_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.logs);
            for (entry.value_ptr.logs) |log| {
                self.allocator.free(log.topics);
                self.allocator.free(log.data);
            }
        }
        self.receipts.deinit();
    }

    pub fn getNonce(self: *StateManager, address: core.types.Address) !u64 {
        // Check in-memory cache first
        if (self.nonces.get(address)) |nonce| {
            return nonce;
        }

        // If using persistence, try to load from database
        if (self.use_persistence) {
            if (self.db) |db| {
                if (try db.getNonce(address)) |nonce| {
                    // Cache in memory
                    try self.nonces.put(address, nonce);
                    return nonce;
                }
            }
        }

        // Default to 0 for new addresses
        try self.nonces.put(address, 0);
        return 0;
    }

    pub fn getBalance(self: *StateManager, address: core.types.Address) !u256 {
        // Check in-memory cache first
        if (self.balances.get(address)) |balance| {
            return balance;
        }

        // If using persistence, try to load from database
        if (self.use_persistence) {
            if (self.db) |db| {
                if (try db.getBalance(address)) |balance| {
                    // Cache in memory
                    try self.balances.put(address, balance);
                    return balance;
                }
            }
        }

        // Default to 0 for new addresses
        try self.balances.put(address, 0);
        return 0;
    }

    pub fn setBalance(self: *StateManager, address: core.types.Address, balance: u256) !void {
        // Update in-memory cache
        try self.balances.put(address, balance);

        // Persist to database if enabled
        if (self.use_persistence) {
            if (self.db) |db| {
                try db.putBalance(address, balance);
            }
        }
    }

    pub fn incrementNonce(self: *StateManager, address: core.types.Address) !void {
        const current = try self.getNonce(address);
        const new_nonce = current + 1;
        try self.setNonce(address, new_nonce);
    }

    pub fn setNonce(self: *StateManager, address: core.types.Address, nonce: u64) !void {
        // Update in-memory cache
        try self.nonces.put(address, nonce);

        // Persist to database if enabled
        if (self.use_persistence) {
            if (self.db) |db| {
                try db.putNonce(address, nonce);
            }
        }
    }

    pub fn applyTransaction(self: *StateManager, tx: core.transaction.Transaction, gas_used: u64) !core.receipt.Receipt {
        const sender = try tx.sender();
        const gas_cost = tx.gas_price * gas_used;

        // Update balance
        const current_balance = try self.getBalance(sender);
        const new_balance = if (current_balance >= (tx.value + gas_cost)) current_balance - tx.value - gas_cost else 0;
        try self.setBalance(sender, new_balance);

        // Update recipient balance if transfer
        if (tx.to) |to| {
            const recipient_balance = try self.getBalance(to);
            try self.setBalance(to, recipient_balance + tx.value);
        }

        // Increment nonce
        try self.incrementNonce(sender);

        // Create receipt
        // Note: tx.hash() returns Hash ([32]u8), not an allocated slice, so no need to free
        const tx_hash = try tx.hash(self.allocator);

        const receipt = core.receipt.Receipt{
            .transaction_hash = tx_hash,
            .block_number = self.current_block_number,
            .block_hash = core.types.hashFromBytes([_]u8{0} ** 32), // Will be set when block is finalized
            .transaction_index = 0, // Will be set properly
            .gas_used = gas_used,
            .status = true,
            .logs = &[_]core.receipt.Receipt.Log{},
        };

        try self.receipts.put(tx_hash, receipt);

        return receipt;
    }

    pub fn getReceipt(self: *const StateManager, tx_hash: core.types.Hash) ?core.receipt.Receipt {
        return self.receipts.get(tx_hash);
    }

    pub fn finalizeBlock(self: *StateManager, block: core.block.Block) !void {
        self.current_block_number = block.number + 1;

        // Persist block number to database if enabled
        if (self.use_persistence) {
            if (self.db) |db| {
                try db.putBlockNumber(self.current_block_number);
            }
        }
    }
};
