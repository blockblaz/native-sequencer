# Pending Tasks

This document tracks all pending tasks for the Native Sequencer project, organized by priority and category.

## 🔴 Critical Priority (Blocks Production)

### 1. Networking Implementation
**Status**: ✅ Completed  
**Files**: `src/api/http.zig`, `src/l1/client.zig`, `src/metrics/server.zig`

- [x] **HTTP Server** (`src/api/http.zig`)
  - ✅ Implement proper socket binding using Zig 0.15 APIs
  - ✅ Replace placeholder socket implementation
  - ✅ Implement proper `accept()` method
  - ⏳ Add async/await support for concurrent connections (future enhancement)
  
- [x] **HTTP Client for L1** (`src/l1/client.zig`)
  - ✅ Implement proper HTTP client using Zig 0.15 APIs
  - ✅ Replace placeholder hash return in `submitBatch()`
  - ✅ Implement `getLatestBlockNumber()` method
  - ✅ Implement `waitForInclusion()` with polling logic
  - ✅ Implement `eth_sendRawTransactionConditional` (EIP-7796)
  
- [x] **Metrics Server** (`src/metrics/server.zig`)
  - ✅ Implement proper metrics server using Zig 0.15 networking APIs
  - ✅ Replace sleep loop placeholder
  - ✅ Add Prometheus-compatible metrics endpoint

### 2. JSON Serialization
**Status**: ✅ Completed  
**Files**: `src/api/jsonrpc.zig`

- [x] Fix JSON-RPC response serialization
  - ✅ Replace placeholder strings with proper JSON serialization implementation
  - ✅ Implement proper JSON encoding for `JsonRpcResponse`
  - ✅ Implement proper JSON encoding for `JsonRpcError`
  - ✅ Add proper request ID handling
  - ✅ Handle all JSON value types (null, bool, integer, float, number_string, string, array, object)
  - ✅ Proper string escaping for JSON output

### 3. Transaction Execution Engine
**Status**: ✅ Completed  
**Files**: `src/sequencer/execution.zig`, `src/sequencer/sequencer.zig`

- [x] Implement full transaction execution
  - ✅ Replace simplified execution in `buildBlock()`
  - ✅ Add proper gas metering (base cost + data cost + contract creation cost)
  - ✅ Implement execution engine with `ExecutionEngine` struct
  - ✅ Add state transition logic (balance updates, nonce increments)
  - ✅ Handle contract creation and calls
  - ⏳ Full EVM bytecode execution (future enhancement - may require EVM integration)

### 4. ECDSA Signature Verification
**Status**: ✅ Completed  
**Files**: `src/crypto/signature.zig`, `src/crypto/signature_test.zig`

- [x] Implement full ECDSA signature verification
  - ✅ Add comprehensive signature validation
  - ✅ Implement edge case handling
  - ✅ Add EIP-155 chain ID support
  - ✅ Add unit tests for signature verification
  - ✅ Add tests for EIP-155 scenarios

### 5. Persistence Layer
**Status**: ✅ Completed  
**Files**: `src/persistence/rocksdb.zig`, `src/state/manager.zig`, `build.zig`

- [x] Integrate RocksDB for persistence
  - ✅ Add RocksDB dependency (`Syndica/rocksdb-zig`)
  - ✅ Implement `Database` struct with open/close methods
  - ✅ Implement state storage functions (`putNonce`, `getNonce`, `putBalance`, `getBalance`, `putReceipt`, `getReceipt`)
  - ✅ Integrate RocksDB with `StateManager`
  - ✅ Add persistence configuration options
  - ✅ Handle Windows platform (RocksDB not supported, graceful fallback)
  - ✅ Fix glibc compatibility issues (require glibc 2.38+ for Linux builds)
  - ✅ Fix cross-compilation issues (ensure RocksDB builds for correct target architecture)

## 🟡 High Priority (Required for Production)

### 6. Mempool Persistence
**Status**: ⏳ Pending  
**Files**: `src/mempool/mempool.zig`, `src/persistence/rocksdb.zig`

- [ ] Integrate RocksDB with mempool for checkpoints
  - [ ] Store mempool state in RocksDB
  - [ ] Restore mempool on startup
  - [ ] Periodic mempool checkpoints
  - [ ] Handle mempool recovery after crash

### 7. State Root Computation
**Status**: ⏳ Pending  
**Files**: `src/state/state_root.zig` (new file)

- [ ] Implement state root computation
  - [ ] Build Merkle Patricia Trie (MPT) from state
  - [ ] Compute state root hash
  - [ ] Update state root after each block
  - [ ] Verify state root matches expected value

### 8. MPT (Merkle Patricia Trie) Support
**Status**: ⏳ Pending  
**Files**: `src/core/trie.zig` (new file) or use existing trie library

- [ ] Implement MPT support
  - [ ] Build state trie from account data
  - [ ] Generate trie nodes for witness (if needed for stateless execution)
  - [ ] Verify trie proofs
  - [ ] Handle trie node serialization/deserialization

### 9. Storage Trie Support
**Status**: ⏳ Pending  
**Files**: `src/core/storage_trie.zig` (new file)

- [ ] Implement storage trie support
  - [ ] Build storage tries for contracts
  - [ ] Generate storage trie nodes for witness (if needed)
  - [ ] Handle storage slot access tracking
  - [ ] Support storage proof generation

## 🟢 Medium Priority (Enhancements)

### 10. WebSocket Support
**Status**: ⏳ Pending  
**Files**: `src/api/websocket.zig` (new file)

- [ ] Implement WebSocket server
  - [ ] WebSocket handshake handling
  - [ ] WebSocket frame parsing
  - [ ] Real-time transaction status updates
  - [ ] Subscription management

### 11. Enhanced MEV Support
**Status**: ⏳ Pending  
**Files**: `src/sequencer/mev.zig`

- [ ] Enhance MEV ordering
  - [ ] Bundle support
  - [ ] Backrun detection
  - [ ] MEV profit optimization
  - [ ] Configurable MEV policies

### 12. Block Explorer / Debug UI
**Status**: ⏳ Pending  
**Files**: `src/api/explorer.zig` (new file), `web/` (new directory)

- [ ] Implement block explorer
  - [ ] Block and transaction viewing
  - [ ] Account state inspection
  - [ ] Mempool visualization
  - [ ] Real-time metrics dashboard

### 13. Operator Controls
**Status**: ⏳ Pending  
**Files**: `src/operator/` (new directory)

- [ ] Implement operator controls
  - [ ] Emergency halt mechanism
  - [ ] Rate limiting configuration
  - [ ] Sequencer key management
  - [ ] Upgrade mechanism

### 14. Enhanced Observability
**Status**: ⏳ Pending  
**Files**: `src/metrics/` (extend), `src/tracing/` (new directory)

- [ ] Add structured logging
  - [ ] Log levels and filtering
  - [ ] Contextual logging
  - [ ] Log rotation
- [ ] Add distributed tracing
  - [ ] Trace transaction flow
  - [ ] Performance profiling
  - [ ] Latency tracking

### 15. Prover Integration Hooks
**Status**: ⏳ Pending  
**Files**: `src/prover/` (new directory)

- [ ] Add prover integration hooks
  - [ ] ZK proof generation hooks
  - [ ] Fraud proof monitoring hooks
  - [ ] Proof submission interface
  - [ ] Proof verification interface

## 🔵 Low Priority (Future Enhancements)

### 16. Performance Optimizations
**Status**: ⏳ Pending

- [ ] Optimize mempool operations
  - [ ] Improve priority queue performance
  - [ ] Optimize hash map lookups
  - [ ] Reduce memory allocations
- [ ] Optimize batch building
  - [ ] Parallel transaction processing
  - [ ] Batch compression
  - [ ] Efficient serialization
- [ ] Optimize state management
  - [ ] State caching strategies
  - [ ] Incremental state updates
  - [ ] State pruning

### 17. Advanced Features
**Status**: ⏳ Pending

- [ ] Support for blob transactions (EIP-4844)
- [ ] Support for account abstraction (EIP-4337)
- [ ] Support for EIP-1559 fee market
- [ ] Support for EIP-2930 access lists
- [ ] Support for EIP-3074 batch transactions

### 18. Testing Infrastructure
**Status**: ⏳ Pending

- [ ] Add comprehensive integration tests
- [ ] Add end-to-end tests
- [ ] Add performance benchmarks
- [ ] Add fuzzing tests
- [ ] Add chaos engineering tests

### 19. Documentation
**Status**: ⏳ Pending

- [ ] API documentation
- [ ] Architecture documentation
- [ ] Deployment guide
- [ ] Operations runbook
- [ ] Developer guide

## Notes

- Tasks marked with ✅ are completed
- Tasks marked with ⏳ are pending or in progress
- Tasks marked with 🔴 are critical and block production
- Tasks marked with 🟡 are high priority for production readiness
- Tasks marked with 🟢 are medium priority enhancements
- Tasks marked with 🔵 are low priority future enhancements

## Related Documents

- `plan/REQUIREMENTS.md` - Original requirements document
- `plan/EXECUTE_INTEGRATION_TASKS.md` - Tasks for EXECUTE precompile integration

