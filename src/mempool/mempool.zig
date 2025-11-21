const std = @import("std");
const core = @import("../core/root.zig");
const config = @import("../config/root.zig");
const wal = @import("wal.zig");
const conditional_tx = @import("../core/conditional_tx.zig");

// Metadata for priority queue comparison
const EntryMetadata = struct {
    priority: u256,
    received_at: u64,
};

// Queue entry for priority queue (avoids copying Transaction structs with slices)
const QueueEntry = struct {
    hash: core.types.Hash,
    priority: u256,
    received_at: u64,
};

// Comparison function for priority queue
fn compareQueueEntry(_: void, a: QueueEntry, b: QueueEntry) std.math.Order {
    if (a.priority > b.priority) return .gt;
    if (a.priority < b.priority) return .lt;
    if (a.received_at < b.received_at) return .lt;
    if (a.received_at > b.received_at) return .gt;
    return .eq;
}

// Custom transaction storage that avoids allocating arrays
// Uses length-prefixed storage: each transaction is stored as [4-byte length][data]
// This avoids needing a separate offsets array
const TransactionStorage = struct {
    allocator: std.mem.Allocator,
    // Pre-allocated buffer for transaction data (serialized with length prefix)
    buffer: []u8,
    // Current write position
    write_pos: usize = 0,
    // Number of transactions stored
    count: usize = 0,
    // Max capacity
    max_count: usize,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) !TransactionStorage {
        // Pre-allocate a large buffer (estimate: 1KB per transaction on average)
        // Add extra space for length prefixes (4 bytes per transaction)
        const buffer_size = max_size * (1024 + 4);
        const buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(buffer);

        return TransactionStorage{
            .allocator = allocator,
            .buffer = buffer,
            .write_pos = 0,
            .count = 0,
            .max_count = max_size,
        };
    }

    pub fn deinit(self: *TransactionStorage) void {
        self.allocator.free(self.buffer);
    }

    pub fn add(self: *TransactionStorage, tx: core.transaction.Transaction) !usize {
        // Check capacity
        if (self.count >= self.max_count) {
            return error.StorageFull;
        }

        // Serialize transaction
        const tx_bytes = try tx.serialize(self.allocator);
        defer self.allocator.free(tx_bytes);

        // Check if we have space in buffer (4 bytes for length + data)
        if (self.write_pos + 4 + tx_bytes.len > self.buffer.len) {
            return error.StorageFull;
        }

        // Store index before writing
        const index = self.count;

        // Write length prefix (4 bytes, little-endian)
        std.mem.writeInt(u32, self.buffer[self.write_pos..][0..4], @intCast(tx_bytes.len), .little);
        self.write_pos += 4;

        // Copy transaction bytes into buffer
        std.mem.copyForwards(u8, self.buffer[self.write_pos..], tx_bytes);
        self.write_pos += tx_bytes.len;
        self.count += 1;

        return index;
    }

    pub fn get(self: *const TransactionStorage, index: usize) !core.transaction.Transaction {
        if (index >= self.count) {
            return error.InvalidIndex;
        }

        // Scan to find the transaction at the given index
        var pos: usize = 0;
        var current_index: usize = 0;

        while (current_index < index) : (current_index += 1) {
            if (pos + 4 > self.write_pos) {
                return error.InvalidIndex;
            }
            const len = std.mem.readInt(u32, self.buffer[pos..][0..4], .little);
            pos += 4 + len;
        }

        // Read the transaction at the current position
        if (pos + 4 > self.write_pos) {
            return error.InvalidIndex;
        }
        const tx_len = std.mem.readInt(u32, self.buffer[pos..][0..4], .little);
        pos += 4;

        if (pos + tx_len > self.write_pos) {
            return error.InvalidIndex;
        }
        const tx_bytes = self.buffer[pos .. pos + tx_len];

        // Deserialize transaction
        const rlp_module = @import("../core/rlp.zig");
        return rlp_module.decodeTransaction(self.allocator, tx_bytes);
    }

    pub fn remove(self: *TransactionStorage, index: usize) void {
        // Mark as removed by setting offset to invalid value
        // In a production system, you'd want a more sophisticated approach
        // For now, we'll just mark it (we'll need to track removed indices separately)
        _ = self;
        _ = index;
        // TODO: Implement proper removal tracking
    }
};

pub const Mempool = struct {
    allocator: std.mem.Allocator,
    config: *const config.Config,
    // Store transactions in custom storage (avoids HashMap/ArrayList with slices)
    storage: TransactionStorage,
    // HashMap stores hash -> index (usize, not a slice)
    by_hash: std.HashMap(core.types.Hash, usize, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage),
    // Store metadata separately (hash -> metadata)
    metadata: std.HashMap(core.types.Hash, EntryMetadata, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage),
    // Priority queue stores hash with metadata (avoids copying Transaction structs with slices)
    entries: std.PriorityQueue(QueueEntry, void, compareQueueEntry),
    // Store sender -> transaction indices directly
    // Use HashMap<Address, usize> where usize is the first transaction index for that sender
    // Then scan storage for all transactions from that sender
    by_sender: std.HashMap(core.types.Address, usize, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage),
    // Conditional transactions: hash -> conditional options
    conditional_txs: std.HashMap(core.types.Hash, conditional_tx.ConditionalOptions, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage),
    wal: ?wal.WriteAheadLog = null,
    size: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !Mempool {
        // Initialize custom transaction storage (pre-allocated)
        var storage = try TransactionStorage.init(allocator, @intCast(cfg.mempool_max_size));
        errdefer storage.deinit();

        // Don't pre-allocate HashMap capacity - let it grow naturally
        var mempool = Mempool{
            .allocator = allocator,
            .config = cfg,
            .storage = storage,
            .by_hash = std.HashMap(core.types.Hash, usize, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
            .metadata = std.HashMap(core.types.Hash, EntryMetadata, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
            .entries = std.PriorityQueue(QueueEntry, void, compareQueueEntry).init(allocator, {}),
            .by_sender = std.HashMap(core.types.Address, usize, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage).init(allocator),
            .conditional_txs = std.HashMap(core.types.Hash, conditional_tx.ConditionalOptions, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
        };

        // Initialize WAL if configured
        mempool.wal = wal.WriteAheadLog.init(cfg.mempool_wal_path) catch |err| {
            if (err != error.FileNotFound) return err;
            mempool.wal = try wal.WriteAheadLog.init(cfg.mempool_wal_path);
            return mempool;
        };

        return mempool;
    }

    pub fn deinit(self: *Mempool) void {
        // Clean up custom storage
        self.storage.deinit();

        // Clean up conditional transactions
        var cond_iter = self.conditional_txs.iterator();
        while (cond_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.conditional_txs.deinit();

        self.by_sender.deinit();

        // Clear priority queue
        while (self.entries.removeOrNull()) |_| {}
        self.entries.deinit();

        self.metadata.deinit();
        self.by_hash.deinit();

        if (self.wal) |*wal_instance| {
            wal_instance.deinit();
        }
    }

    /// Insert a regular transaction
    pub fn insert(self: *Mempool, tx: core.transaction.Transaction) !bool {
        return self.insertWithConditions(tx, null);
    }

    /// Insert a transaction with conditional options
    pub fn insertWithConditions(self: *Mempool, tx: core.transaction.Transaction, conditions_opt: ?conditional_tx.ConditionalOptions) !bool {
        // Check size limit
        if (self.size >= self.config.mempool_max_size) {
            return error.MempoolFull;
        }

        const tx_hash = try tx.hash(self.allocator);
        // tx_hash is u256 (not allocated), no need to free

        // Check if already exists
        if (self.by_hash.contains(tx_hash)) {
            return false;
        }

        const sender = try tx.sender();
        const priority = tx.priority();
        const now = std.time.timestamp();

        // Store transaction in custom storage (returns index)
        const tx_index = try self.storage.add(tx);

        // Store hash -> index in HashMap (only usize, no slices)
        try self.by_hash.put(tx_hash, tx_index);

        // Store metadata separately
        try self.metadata.put(tx_hash, EntryMetadata{
            .priority = priority,
            .received_at = @intCast(now),
        });

        // Store conditional options if provided
        if (conditions_opt) |*cond| {
            try self.conditional_txs.put(tx_hash, cond.*);
        }

        // Write to WAL
        if (self.wal) |*wal_instance| {
            // Create temporary entry for WAL
            var entry = core.mempool_entry.MempoolEntry{
                .tx = tx,
                .hash = tx_hash,
                .priority = priority,
                .received_at = @intCast(now),
            };
            try wal_instance.writeEntry(self.allocator, &entry);
        }

        // Insert hash with metadata into priority queue
        try self.entries.add(.{
            .hash = tx_hash,
            .priority = priority,
            .received_at = @intCast(now),
        });

        // Index by sender: store first transaction index for this sender
        // We'll scan storage when needed to find all transactions from this sender
        const sender_entry = try self.by_sender.getOrPut(sender);
        if (!sender_entry.found_existing) {
            // New sender: store transaction index
            sender_entry.value_ptr.* = tx_index;
        }
        // For existing senders, we keep the first index (used for scanning)

        self.size += 1;
        return true;
    }

    pub fn remove(self: *Mempool, tx_hash: core.types.Hash) !?core.transaction.Transaction {
        const tx_index_kv = self.by_hash.fetchRemove(tx_hash) orelse return null;
        const tx_index = tx_index_kv.value;

        // Get transaction from storage
        const tx = self.storage.get(tx_index) catch return null;

        // Remove metadata
        _ = self.metadata.remove(tx_hash);

        // Remove from sender index
        // Check if this is the last transaction from this sender
        const sender = try tx.sender();
        var has_other_txs = false;
        // Scan storage to see if sender has other transactions
        var i: usize = 0;
        while (i < self.storage.count) : (i += 1) {
            if (i == tx_index) continue; // Skip the one we're removing
            const other_tx = self.storage.get(i) catch continue;
            const other_sender = other_tx.sender() catch continue;
            if (other_sender == sender) {
                has_other_txs = true;
                break;
            }
        }
        if (!has_other_txs) {
            // Last transaction from this sender, remove entry
            _ = self.by_sender.remove(sender);
        }

        self.size -= 1;
        return tx;
    }

    /// Get top N transactions, checking conditional transaction conditions
    /// current_block_number and current_timestamp are used to filter conditional transactions
    pub fn getTopN(self: *Mempool, gas_limit: u64, max_count: usize, current_block_number: u64, current_timestamp: u64) ![]core.transaction.Transaction {
        var result = std.ArrayList(core.transaction.Transaction).init(self.allocator);
        errdefer result.deinit();

        var remaining_gas: u64 = gas_limit;
        var count: usize = 0;

        // Create a temporary queue to rebuild
        var temp_queue = std.PriorityQueue(QueueEntry, void, compareQueueEntry).init(self.allocator, {});
        defer temp_queue.deinit();

        // Extract valid transactions
        while (self.entries.removeOrNull()) |entry| {
            const tx_index = self.by_hash.get(entry.hash) orelse {
                // Transaction was removed, skip
                continue;
            };

            const tx = self.storage.get(tx_index) catch {
                // If retrieval fails, skip
                continue;
            };

            // Check conditional transaction conditions
            if (self.conditional_txs.get(entry.hash)) |conditions| {
                if (!conditions.checkConditions(current_block_number, current_timestamp)) {
                    // Conditions not met, put back in queue
                    try temp_queue.add(entry);
                    continue;
                }
            }

            if (tx.gas_limit <= remaining_gas and count < max_count) {
                try result.append(tx);
                remaining_gas -= tx.gas_limit;
                count += 1;
                // Remove from maps since we're using it
                _ = self.by_hash.remove(entry.hash);
                _ = self.metadata.remove(entry.hash);
                _ = self.conditional_txs.remove(entry.hash);
            } else {
                // Put back in queue
                try temp_queue.add(entry);
            }
        }

        // Rebuild main queue with remaining entries
        while (temp_queue.removeOrNull()) |entry| {
            try self.entries.add(entry);
        }

        return result.toOwnedSlice();
    }

    pub fn getBySender(self: *const Mempool, sender: core.types.Address) ![]core.transaction.Transaction {
        // Check if sender exists
        _ = self.by_sender.get(sender) orelse return &[_]core.transaction.Transaction{};

        var result = std.ArrayList(core.transaction.Transaction).init(self.allocator);
        defer result.deinit();

        // Scan storage to find all transactions from this sender
        var i: usize = 0;
        while (i < self.storage.count) : (i += 1) {
            const tx = self.storage.get(i) catch continue;
            const tx_sender = tx.sender() catch continue;
            if (tx_sender == sender) {
                try result.append(tx);
            }
        }

        return result.toOwnedSlice();
    }

    pub fn contains(self: *const Mempool, tx_hash: core.types.Hash) bool {
        return self.by_hash.contains(tx_hash);
    }
};
