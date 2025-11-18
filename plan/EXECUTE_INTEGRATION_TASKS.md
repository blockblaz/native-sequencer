# EXECUTE Precompile Integration Tasks

This document outlines all tasks needed to integrate the native-sequencer with the go-ethereum EXECUTE precompile implementation for a native rollup architecture.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    L1 Node (geth)                            │
│  - Runs standard geth with EXECUTE precompile               │
│  - Accepts ExecuteTx transactions                            │
│  - Executes stateless transactions via EXECUTE precompile   │
└─────────────────────────────────────────────────────────────┘
                        ▲
                        │ ExecuteTx batches
                        │
┌─────────────────────────────────────────────────────────────┐
│                    L2 Node (geth)                            │
│  - Runs geth with EXECUTE precompile                         │
│  - Exposes Engine API for sequencer communication            │
│  - Accepts L2 transactions from users                        │
│  - Provides state to native-sequencer via Engine API        │
└─────────────────────────────────────────────────────────────┘
                        ▲
                        │ Engine API (JSON-RPC)
                        │ - engine_newPayload
                        │ - engine_getPayload
                        │ - engine_forkchoiceUpdated
                        │ - eth_getBlockByNumber
                        │ - eth_getBalance
                        │ - eth_getCode
                        │
┌─────────────────────────────────────────────────────────────┐
│              Native Sequencer (Zig)                          │
│  - Accepts L2 transactions                                   │
│  - Sequences and orders transactions                         │
│  - Builds blocks and batches                                  │
│  - Generates witnesses for stateless execution              │
│  - Communicates with L2 geth via Engine API                  │
│  - Creates ExecuteTx transactions for L1                     │
│  - Submits batches to L1 via ExecuteTx                       │
└─────────────────────────────────────────────────────────────┘
```

## Task Categories

### 🔴 Critical Priority (Required for Basic Functionality)

#### 1. ExecuteTx Transaction Type Support
**Status**: ⏳ Pending  
**Priority**: Critical  
**Estimated Effort**: High

**Tasks**:
- [ ] **1.1** Define `ExecuteTx` struct in Zig matching go-ethereum's `ExecuteTx`
  - Standard fields: `ChainID`, `Nonce`, `GasTipCap`, `GasFeeCap`, `Gas`
  - Execution target: `To`, `Value`, `Data`
  - EXECUTE-specific: `PreStateHash`, `WitnessSize`, `WithdrawalsSize`, `Coinbase`, `BlockNumber`, `Timestamp`, `Witness`, `Withdrawals`, `BlobHashes`
  - Signature: `V`, `R`, `S`
  - **File**: `src/core/transaction_execute.zig` (new file)

- [ ] **1.2** Implement RLP encoding/decoding for `ExecuteTx`
  - Encode all fields according to go-ethereum format
  - Decode ExecuteTx from raw RLP bytes
  - Handle transaction type `0x05` (ExecuteTxType)
  - **File**: `src/core/transaction_execute.zig`

- [ ] **1.3** Implement JSON serialization/deserialization
  - Add ExecuteTx fields to JSON-RPC request/response
  - Handle ExecuteTx in `eth_sendRawTransaction`
  - Support ExecuteTx in transaction queries
  - **File**: `src/api/jsonrpc.zig`, `src/core/transaction_execute.zig`

- [ ] **1.4** Update transaction type system
  - Add `ExecuteTxType = 0x05` constant
  - Update transaction type detection logic
  - Support ExecuteTx in transaction validation
  - **Files**: `src/core/transaction.zig`, `src/validation/ingress.zig`

#### 2. Witness Generation and Management
**Status**: ⏳ Pending  
**Priority**: Critical  
**Estimated Effort**: Very High

**Tasks**:
- [ ] **2.1** Define Witness struct matching go-ethereum format
  - `Headers`: Array of block headers (for BLOCKHASH opcode)
  - `Codes`: Map of contract bytecodes (keyed by code hash)
  - `State`: Map of MPT trie nodes (keyed by node hash)
  - **File**: `src/core/witness.zig` (new file)

- [ ] **2.2** Implement witness RLP encoding/decoding
  - Encode witness to RLP format matching go-ethereum
  - Decode witness from RLP bytes
  - Validate witness structure
  - **File**: `src/core/witness.zig`

- [ ] **2.3** Implement witness generation from state
  - Extract state trie nodes needed for transaction execution
  - Extract contract bytecodes accessed during execution
  - Extract block headers needed for BLOCKHASH opcode
  - Track state access during execution to build witness
  - **File**: `src/core/witness_builder.zig` (new file)

- [ ] **2.4** Integrate witness generation with execution engine
  - Track state reads during transaction execution
  - Collect trie nodes, codes, and headers as execution proceeds
  - Build witness incrementally during block building
  - **Files**: `src/sequencer/execution.zig`, `src/core/witness_builder.zig`

- [ ] **2.5** Implement witness validation
  - Verify witness root matches pre-state hash
  - Validate witness contains all required data
  - Check witness completeness before execution
  - **File**: `src/core/witness.zig`

#### 3. L1 Batch Submission with ExecuteTx
**Status**: ⏳ Pending  
**Priority**: Critical  
**Estimated Effort**: High

**Tasks**:
- [ ] **3.1** Update batch structure for ExecuteTx format
  - Include pre-state hash in batch
  - Include witness data in batch
  - Include block context (coinbase, block number, timestamp, gas price)
  - **File**: `src/core/batch.zig`

- [ ] **3.2** Implement ExecuteTx creation from batch
  - Convert batch to ExecuteTx transaction
  - Set execution target (To, Value, Data) from batch
  - Include witness data in ExecuteTx
  - Set block context fields
  - **File**: `src/l1/execute_tx_builder.zig` (new file)

- [ ] **3.3** Update L1 client to submit ExecuteTx
  - Replace current batch submission with ExecuteTx submission
  - Serialize ExecuteTx to RLP format
  - Sign ExecuteTx with sequencer key
  - Submit via `eth_sendRawTransaction`
  - **File**: `src/l1/client.zig`

- [ ] **3.4** Implement ExecuteTx signing
  - Sign ExecuteTx with EIP-2718 typed transaction format
  - Use sequencer's private key
  - Set correct chain ID for L1
  - **File**: `src/crypto/signature.zig` (extend)

#### 4. L2 Node Integration
**Status**: ⏳ Pending  
**Priority**: Critical  
**Estimated Effort**: Very High

**Tasks**:
- [ ] **4.1** Design L2 node interface protocol
  - Use Engine API (JSON-RPC) for communication between geth and native-sequencer
  - Engine API endpoints: `engine_newPayload`, `engine_getPayload`, `engine_forkchoiceUpdated`
  - Standard Ethereum JSON-RPC endpoints: `eth_getBlockByNumber`, `eth_getBalance`, `eth_getCode`, `eth_getStorageAt`
  - Transaction submission endpoints: `eth_sendRawTransaction`
  - **File**: `docs/L2_NODE_INTEGRATION.md` (new file)

- [ ] **4.2** Implement Engine API client in native-sequencer
  - Implement Engine API client for L2 geth communication
  - `engine_newPayload` - Submit sequencer-built blocks to L2 geth
  - `engine_getPayload` - Retrieve payloads from L2 geth
  - `engine_forkchoiceUpdated` - Update fork choice state
  - Use standard Ethereum JSON-RPC for state queries (`eth_getBlockByNumber`, `eth_getBalance`, `eth_getCode`, etc.)
  - **File**: `src/l2/engine_api_client.zig` (new file)

- [ ] **4.3** Implement state provider for native-sequencer
  - Query L2 geth node for state data via Engine API and standard JSON-RPC
  - Use `eth_getBalance` for account balances
  - Use `eth_getTransactionCount` for nonces
  - Use `eth_getCode` for contract bytecodes
  - Use `eth_getBlockByNumber` for block headers
  - Use `eth_getStorageAt` for storage values
  - **File**: `src/l2/state_provider.zig` (new file)

- [ ] **4.4** Implement transaction forwarding
  - L2 geth forwards transactions to native-sequencer via Engine API or custom endpoint
  - Native-sequencer validates and sequences transactions
  - Submit sequenced blocks back to L2 geth via `engine_newPayload`
  - Handle transaction validation responses
  - Forward execution results back to geth via Engine API
  - **File**: `src/l2/tx_forwarder.zig` (new file)

- [ ] **4.5** Implement block synchronization
  - Sync sequencer blocks to L2 geth node via `engine_newPayload`
  - Update fork choice state via `engine_forkchoiceUpdated`
  - Update L2 geth state with sequencer blocks
  - Handle reorgs and chain reorganization via Engine API
  - Monitor L2 geth sync status
  - **File**: `src/l2/sync.zig` (new file)

### 🟡 High Priority (Required for Production)

#### 5. State Management Integration
**Status**: ⏳ Pending  
**Priority**: High  
**Estimated Effort**: High

**Tasks**:
- [ ] **5.1** Integrate RocksDB with witness generation
  - Store witness data in RocksDB
  - Query RocksDB for state trie nodes
  - Cache frequently accessed state data
  - **File**: `src/persistence/witness_storage.zig` (new file)

- [ ] **5.2** Implement state root computation
  - Compute state root from state manager
  - Update state root after each block
  - Verify state root matches witness root
  - **File**: `src/state/state_root.zig` (new file)

- [ ] **5.3** Implement MPT (Merkle Patricia Trie) support
  - Build state trie from account data
  - Generate trie nodes for witness
  - Verify trie proofs
  - **File**: `src/core/trie.zig` (new file) or use existing trie library

- [ ] **5.4** Implement storage trie support
  - Build storage tries for contracts
  - Generate storage trie nodes for witness
  - Handle storage slot access tracking
  - **File**: `src/core/storage_trie.zig` (new file)

#### 6. Execution Engine Enhancements
**Status**: ⏳ Pending  
**Priority**: High  
**Estimated Effort**: Very High

**Tasks**:
- [ ] **6.1** Implement full EVM execution (or integration)
  - Option A: Integrate with geth's EVM via FFI/C interop
  - Option B: Implement minimal EVM subset for stateless execution
  - Option C: Use geth as execution backend via RPC
  - **Decision needed**: Which approach to use?
  - **Files**: TBD based on approach

- [ ] **6.2** Implement state access tracking
  - Track all state reads during execution
  - Track contract code accesses
  - Track block hash accesses (BLOCKHASH opcode)
  - Build witness incrementally
  - **File**: `src/sequencer/execution.zig` (extend)

- [ ] **6.3** Implement gas metering for ExecuteTx
  - Calculate gas costs for ExecuteTx creation
  - Account for witness size in gas costs
  - Handle dynamic gas for stateless execution
  - **File**: `src/core/gas.zig` (extend or new)

- [ ] **6.4** Handle execution errors
  - Detect missing witness data errors
  - Handle out-of-gas scenarios
  - Handle execution failures
  - Return proper error codes
  - **File**: `src/sequencer/execution.zig` (extend)

#### 7. Block and Batch Building
**Status**: ⏳ Pending  
**Priority**: High  
**Estimated Effort**: Medium

**Tasks**:
- [ ] **7.1** Update block structure for ExecuteTx compatibility
  - Include pre-state hash in block header
  - Include witness data in block
  - Include block context fields
  - **File**: `src/core/block.zig`

- [ ] **7.2** Implement batch-to-ExecuteTx conversion
  - Convert batch of blocks to single ExecuteTx
  - Aggregate witnesses from multiple blocks
  - Set execution target to batch data
  - **File**: `src/batch/execute_tx_converter.zig` (new file)

- [ ] **7.3** Implement witness aggregation
  - Merge witnesses from multiple blocks
  - Deduplicate trie nodes, codes, headers
  - Optimize witness size
  - **File**: `src/core/witness_builder.zig` (extend)

- [ ] **7.4** Update batch submission logic
  - Replace current batch submission with ExecuteTx
  - Handle ExecuteTx transaction lifecycle
  - Track ExecuteTx status on L1
  - **File**: `src/batch/builder.zig`, `src/l1/client.zig`

### 🟢 Medium Priority (Enhancements)

#### 8. Configuration and Setup
**Status**: ⏳ Pending  
**Priority**: Medium  
**Estimated Effort**: Low

**Tasks**:
- [ ] **8.1** Add ExecuteTx configuration options
  - ExecuteTx precompile address (`0x12`)
  - L1 chain ID for ExecuteTx
  - Witness generation settings
  - **File**: `src/config/config.zig`

- [ ] **8.2** Add L2 node connection configuration
  - L2 geth Engine API URL
  - L2 geth JSON-RPC URL (for standard endpoints)
  - Engine API JWT secret for authentication
  - L2 chain ID
  - Connection timeout settings
  - **File**: `src/config/config.zig`

- [ ] **8.3** Update Docker configuration
  - Add L2 node connection environment variables
  - Configure ExecuteTx settings
  - **File**: `Dockerfile`

#### 9. Testing and Validation
**Status**: ⏳ Pending  
**Priority**: Medium  
**Estimated Effort**: High

**Tasks**:
- [ ] **9.1** Create ExecuteTx unit tests
  - Test ExecuteTx encoding/decoding
  - Test ExecuteTx signing
  - Test ExecuteTx validation
  - **File**: `src/core/transaction_execute_test.zig` (new file)

- [ ] **9.2** Create witness generation tests
  - Test witness building from state
  - Test witness RLP encoding/decoding
  - Test witness validation
  - **File**: `src/core/witness_test.zig` (new file)

- [ ] **9.3** Create integration tests
  - Test ExecuteTx submission to L1
  - Test witness generation during execution
  - Test L2 node integration
  - **File**: `tests/integration/execute_test.zig` (new file)

- [ ] **9.4** Create end-to-end tests
  - Test full flow: L2 tx → sequencer → ExecuteTx → L1
  - Test stateless execution verification
  - Test reorg handling
  - **File**: `tests/e2e/execute_e2e_test.zig` (new file)

#### 10. Documentation
**Status**: ⏳ Pending  
**Priority**: Medium  
**Estimated Effort**: Medium

**Tasks**:
- [ ] **10.1** Document ExecuteTx integration architecture
  - Architecture diagram
  - Data flow diagrams
  - Component interactions
  - **File**: `docs/EXECUTE_ARCHITECTURE.md` (new file)

- [ ] **10.2** Document witness format
  - Witness structure specification
  - RLP encoding format
  - Witness generation process
  - **File**: `docs/WITNESS_FORMAT.md` (new file)

- [ ] **10.3** Document L2 node integration
  - Engine API endpoint specifications
  - Standard JSON-RPC endpoint usage
  - Communication protocol and message flow
  - Setup instructions for Engine API
  - Authentication and security considerations
  - **File**: `docs/L2_NODE_INTEGRATION.md` (new file)

- [ ] **10.4** Update README with ExecuteTx support
  - Add ExecuteTx feature description
  - Update architecture diagram
  - Add setup instructions for L1/L2 nodes
  - **File**: `README.md`

### 🔵 Low Priority (Future Enhancements)

#### 11. Performance Optimizations
**Status**: ⏳ Pending  
**Priority**: Low  
**Estimated Effort**: Medium

**Tasks**:
- [ ] **11.1** Optimize witness generation
  - Parallel witness building
  - Witness caching
  - Incremental witness updates
  - **Files**: Various

- [ ] **11.2** Optimize ExecuteTx creation
  - Batch witness compression
  - Witness deduplication
  - Efficient RLP encoding
  - **Files**: Various

- [ ] **11.3** Implement witness compression
  - Compress witness data before encoding
  - Decompress on L1 side
  - Reduce ExecuteTx size
  - **File**: `src/core/witness.zig` (extend)

#### 12. Advanced Features
**Status**: ⏳ Pending  
**Priority**: Low  
**Estimated Effort**: High

**Tasks**:
- [ ] **12.1** Implement withdrawals support
  - Parse withdrawals from ExecuteTx
  - Process withdrawals in witness
  - Handle withdrawal execution
  - **File**: `src/core/withdrawals.zig` (new file)

- [ ] **12.2** Implement blob transaction support
  - Parse blob hashes from ExecuteTx
  - Handle blob data in execution
  - **File**: `src/core/blob.zig` (new file)

- [ ] **12.3** Implement EIP-2935 block hash support
  - Extract block headers from witness
  - Provide GetHash function for BLOCKHASH opcode
  - **File**: `src/core/block_hash.zig` (new file)

## Implementation Phases

### Phase 1: Foundation (Critical)
**Goal**: Basic ExecuteTx support and witness structure

1. Implement ExecuteTx transaction type (Tasks 1.1-1.4)
2. Implement Witness struct and RLP encoding (Tasks 2.1-2.2)
3. Update L1 client for ExecuteTx submission (Tasks 3.1-3.4)

**Deliverable**: Can create and submit ExecuteTx transactions to L1

### Phase 2: Witness Generation (Critical)
**Goal**: Generate witnesses from sequencer state

1. Implement witness generation from state (Tasks 2.3-2.4)
2. Integrate with execution engine (Task 2.4)
3. Implement state root computation (Task 5.2)

**Deliverable**: Can generate witnesses for batches

### Phase 3: L2 Integration (Critical)
**Goal**: Connect native-sequencer with L2 geth node

1. Design L2 node interface (Task 4.1)
2. Implement state provider (Task 4.3)
3. Implement transaction forwarding (Task 4.4)
4. Implement block synchronization (Task 4.5)

**Deliverable**: L2 geth node can interface with native-sequencer

### Phase 4: Production Readiness (High)
**Goal**: Full production-ready implementation

1. Implement MPT/trie support (Tasks 5.3-5.4)
2. Enhance execution engine (Tasks 6.1-6.4)
3. Complete testing suite (Tasks 9.1-9.4)
4. Documentation (Tasks 10.1-10.4)

**Deliverable**: Production-ready native rollup with ExecuteTx

## Key Design Decisions Needed

### 1. EVM Execution Approach
**Question**: How should native-sequencer execute transactions?

**Options**:
- **Option A**: Integrate geth EVM via C FFI
  - Pros: Full EVM compatibility, proven execution
  - Cons: Complex FFI integration, C interop overhead
- **Option B**: Implement minimal EVM subset
  - Pros: Full control, no external dependencies
  - Cons: Large implementation effort, compatibility risk
- **Option C**: Use geth as execution backend via RPC
  - Pros: Simple integration, full compatibility
  - Cons: Network overhead, dependency on geth availability

**Recommendation**: Start with Option C (RPC), migrate to Option A if needed

### 2. Witness Generation Strategy
**Question**: When and how to generate witnesses?

**Options**:
- **Option A**: Generate witness during execution (tracking)
  - Pros: Accurate, includes only accessed data
  - Cons: Requires execution first, may miss some data
- **Option B**: Generate witness before execution (prediction)
  - Pros: Can validate before execution
  - Cons: May include unnecessary data, harder to predict
- **Option C**: Hybrid - generate during execution, validate before submission
  - Pros: Best of both worlds
  - Cons: More complex

**Recommendation**: Option A (tracking during execution)

### 3. State Storage Format
**Question**: How to store state for witness generation?

**Options**:
- **Option A**: Store full MPT trie in RocksDB
  - Pros: Complete state, easy witness generation
  - Cons: Large storage, complex trie management
- **Option B**: Store flat state, build trie on-demand
  - Pros: Simple storage, smaller footprint
  - Cons: Slower witness generation, trie building overhead
- **Option C**: Hybrid - store trie nodes + flat state
  - Pros: Fast witness generation, complete state
  - Cons: More storage, complexity

**Recommendation**: Option C (hybrid approach)

## Dependencies and Prerequisites

### External Dependencies
- [ ] go-ethereum with EXECUTE precompile (already available)
- [ ] Engine API support in L2 geth node (standard Engine API)
- [ ] MPT trie library for Zig (may need to implement or use existing)
- [ ] RLP encoding/decoding (already implemented)
- [ ] Keccak-256 hashing (already implemented)
- [ ] ECDSA signing (already implemented)

### Infrastructure Setup
- [ ] L1 geth node with EXECUTE precompile enabled
- [ ] L2 geth node with EXECUTE precompile enabled and Engine API exposed
- [ ] Engine API authentication configured (JWT secret)
- [ ] Network connectivity between L1, L2, and sequencer
- [ ] Test environment setup with Engine API endpoints

## Testing Strategy

### Unit Tests
- ExecuteTx encoding/decoding
- Witness generation and validation
- State root computation
- RLP encoding/decoding

### Integration Tests
- ExecuteTx submission to L1
- Witness generation during execution
- L2 node communication via Engine API
- Engine API endpoint testing (`engine_newPayload`, `engine_getPayload`, `engine_forkchoiceUpdated`)
- State synchronization via Engine API

### End-to-End Tests
- Full flow: L2 tx → sequencer → ExecuteTx → L1
- Stateless execution verification
- Reorg handling
- Error scenarios

## Estimated Timeline

- **Phase 1**: 2-3 weeks
- **Phase 2**: 3-4 weeks
- **Phase 3**: 2-3 weeks
- **Phase 4**: 4-6 weeks

**Total**: ~11-16 weeks for complete implementation

## Notes

- The go-ethereum EXECUTE precompile is already implemented and tested
- The native-sequencer has basic transaction handling but needs ExecuteTx support
- Witness generation is the most complex part and will require significant effort
- L2 node integration uses Engine API (standard protocol, no geth modifications needed)
- Engine API provides standardized communication between sequencer and L2 execution client
- Consider starting with a simplified witness format for initial implementation


