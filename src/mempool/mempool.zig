const std = @import("std");
const core = @import("../core/root.zig");
const config = @import("../config/root.zig");
const wal = @import("wal.zig");

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
        const tx_bytes = self.buffer[pos..pos + tx_len];
        
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
    // Store sender -> hash mappings using a custom structure to avoid ArrayList in HashMap
    // Use HashMap<Address, usize> where usize is an index into a separate pre-allocated array
    by_sender: std.HashMap(core.types.Address, usize, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage),
    // Pre-allocated array for sender hash lists (avoids ArrayList storing slices)
    sender_hash_lists: []?[]core.types.Hash,
    sender_hash_lists_count: usize = 0,
    wal: ?wal.WriteAheadLog = null,
    size: usize = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.Config) !Mempool {
        // Initialize custom transaction storage (pre-allocated, avoids allocator bug)
        var storage = try TransactionStorage.init(allocator, @intCast(cfg.mempool_max_size));
        errdefer storage.deinit();
        
        // Don't pre-allocate HashMap capacity - let it grow naturally
        // Pre-allocation might trigger the allocator bug
        var mempool = Mempool{
            .allocator = allocator,
            .config = cfg,
            .storage = storage,
            .by_hash = std.HashMap(core.types.Hash, usize, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
            .metadata = std.HashMap(core.types.Hash, EntryMetadata, std.hash_map.AutoContext(core.types.Hash), std.hash_map.default_max_load_percentage).init(allocator),
            .entries = std.PriorityQueue(QueueEntry, void, compareQueueEntry).init(allocator, {}),
            .by_sender = std.HashMap(core.types.Address, usize, std.hash_map.AutoContext(core.types.Address), std.hash_map.default_max_load_percentage).init(allocator),
            .sender_hash_lists = try allocator.alloc(?[]core.types.Hash, @intCast(cfg.mempool_max_size)),
            .sender_hash_lists_count = 0,
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

        // Clean up sender hash lists
        for (self.sender_hash_lists[0..self.sender_hash_lists_count]) |maybe_hash_list| {
            if (maybe_hash_list) |hash_list| {
                self.allocator.free(hash_list);
            }
        }
        self.allocator.free(self.sender_hash_lists);
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

    pub fn insert(self: *Mempool, tx: core.transaction.Transaction) !bool {
        // Check size limit
        if (self.size >= self.config.mempool_max_size) {
            return error.MempoolFull;
        }

        const tx_hash = try tx.hash(self.allocator);
        defer self.allocator.free(tx_hash);

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

        // Index by sender (store hashes)
        const sender_entry = try self.by_sender.getOrPut(sender);
        if (!sender_entry.found_existing) {
            // Create new hash list
            const hash_list = try self.allocator.alloc(core.types.Hash, 1);
            hash_list[0] = tx_hash;
            const list_index = self.sender_hash_lists_count;
            self.sender_hash_lists[list_index] = hash_list;
            self.sender_hash_lists_count += 1;
            sender_entry.value_ptr.* = list_index;
        } else {
            // Append to existing list
            const list_index = sender_entry.value_ptr.*;
            if (list_index < self.sender_hash_lists_count) {
                if (self.sender_hash_lists[list_index]) |old_list| {
                    const new_list = try self.allocator.realloc(old_list, old_list.len + 1);
                    new_list[old_list.len] = tx_hash;
                    self.sender_hash_lists[list_index] = new_list;
                }
            }
        }

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
        const sender = try tx.sender();
        if (self.by_sender.get(sender)) |list_index| {
            if (list_index < self.sender_hash_lists_count) {
                if (self.sender_hash_lists[list_index]) |hash_list| {
                    var i: usize = 0;
                    while (i < hash_list.len) : (i += 1) {
                        if (std.mem.eql(u8, &hash_list[i], &tx_hash)) {
                            // Remove hash from list
                            if (hash_list.len == 1) {
                                self.allocator.free(hash_list);
                                self.sender_hash_lists[list_index] = null;
                                _ = self.by_sender.remove(sender);
                            } else {
                                const new_list = try self.allocator.realloc(hash_list, hash_list.len - 1);
                                std.mem.copyForwards(core.types.Hash, new_list[0..], hash_list[0..i]);
                                std.mem.copyForwards(core.types.Hash, new_list[i..], hash_list[i + 1..]);
                                self.sender_hash_lists[list_index] = new_list;
                            }
                            break;
                        }
                    }
                }
            }
        }

        self.size -= 1;
        return tx;
    }

    pub fn getTopN(self: *Mempool, gas_limit: u64, max_count: usize) ![]core.transaction.Transaction {
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

            if (tx.gas_limit <= remaining_gas and count < max_count) {
                try result.append(tx);
                remaining_gas -= tx.gas_limit;
                count += 1;
                // Remove from maps since we're using it
                _ = self.by_hash.remove(entry.hash);
                _ = self.metadata.remove(entry.hash);
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
        const list_index = self.by_sender.get(sender) orelse return &[_]core.transaction.Transaction{};
        if (list_index >= self.sender_hash_lists_count) {
            return &[_]core.transaction.Transaction{};
        }
        
        const maybe_sender_hashes = self.sender_hash_lists[list_index];
        const sender_hashes = maybe_sender_hashes orelse return &[_]core.transaction.Transaction{};
        
        var result = std.ArrayList(core.transaction.Transaction).init(self.allocator);
        defer result.deinit();
        
        for (sender_hashes) |hash| {
            if (self.by_hash.get(hash)) |tx_index| {
                const tx = self.storage.get(tx_index) catch {
                    // If retrieval fails, skip
                    continue;
                };
                try result.append(tx);
            }
        }
        
        return result.toOwnedSlice();
    }

    pub fn contains(self: *const Mempool, tx_hash: core.types.Hash) bool {
        return self.by_hash.contains(tx_hash);
    }
};
