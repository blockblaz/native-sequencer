# Native Sequencer

## Known Issues & Workarounds

### Zig 0.15.2 HashMap Allocator Bug (RESOLVED)

**Status**: ✅ **RESOLVED** - Custom U256 implementation workaround implemented

This project encountered a compiler bug in Zig 0.15.2 related to HashMap initialization with native `u256` types as keys. The error manifests as:
```
error: access of union field 'pointer' while field 'int' is active
at std/mem/Allocator.zig:425:45
```

**Root Cause**: The bug is in HashMap's `AutoContext` type introspection code when handling large integer types (`u256`). This is a compiler bug, not an issue with our code.

**Solution**: We implemented a custom `U256` struct using two `u128` fields with explicit `hash()` and `eql()` methods, along with custom HashMap contexts (`HashContext`, `AddressContext`). This bypasses the problematic `AutoContext` code path entirely.

**Implementation Details**:
- Custom `U256` struct in `src/core/types.zig` with two `u128` fields (`low`, `high`)
- Custom hash function combining both halves via XOR
- Custom equality comparison
- Custom HashMap contexts for `Hash` and `Address` types
- Full compatibility with 32-byte hashes and 20-byte addresses

**Performance**: No performance penalty - the struct is stack-allocated and operations are efficient.

See `src/core/types.zig` for detailed comments explaining the implementation.

### Zig 0.14.x Allocator Bug (Historical)

This project previously encountered allocator bugs in Zig 0.14.0 and 0.14.1 related to allocating arrays of structs containing slices. **Verified through testing**: The bug exists in both versions (at different line numbers: 400 vs 412). See **[ZIG_0.14_ALLOCATOR_ERROR.md](ZIG_0.14_ALLOCATOR_ERROR.md)** for detailed explanation and workarounds attempted.

### Upgrading to Zig 0.15.2

This project has been successfully upgraded to Zig 0.15.2. See **[ZIG_0.15_UPGRADE.md](ZIG_0.15_UPGRADE.md)** for detailed information about the upgrade process, encountered errors, and solutions.

### Current Status

- ✅ Updated `build.zig.zon` to require Zig 0.15.2
- ✅ Updated `build.zig` for Zig 0.15 API changes
- ✅ Vendored `zig_eth_secp256k1` dependency (C library integration)
- ✅ Updated code for Zig 0.15 API changes (ArrayList → array_list.Managed, etc.)
- ✅ Resolved HashMap allocator bug with custom U256 implementation
- ✅ Project builds successfully with Zig 0.15.2

---

# Native Sequencer

A production-grade sequencer built in Zig for L2 rollups that accepts transactions, orders them, forms batches, and posts them to L1.

## Features

- **API Layer**: JSON-RPC/HTTP endpoint for transaction submission
- **Ingress/Validation**: Fast transaction validation pipeline (signature, nonce, gas, balance checks)
- **Mempool**: In-memory priority queue with write-ahead-log persistence
- **Sequencing Engine**: MEV-aware transaction ordering with configurable policies
- **Batch Formation**: Efficient batch building with gas limit management
- **L1 Submission**: Submit batches to L1 via JSON-RPC
- **State Management**: Track nonces, balances, and receipts
- **Observability**: Metrics endpoint for monitoring
- **Operator Controls**: Emergency halt, rate limiting, configuration management

## Architecture

The sequencer follows a modular architecture:

- **API Server**: Handles JSON-RPC requests from users/relayers
- **Ingress**: Validates and accepts transactions into mempool
- **Mempool**: Maintains priority queue of pending transactions
- **Sequencer**: Builds blocks from mempool transactions
- **Batch Builder**: Groups blocks into batches for L1 submission
- **L1 Client**: Submits batches to L1 blockchain
- **State Manager**: Tracks account state (nonces, balances)
- **Metrics**: Exposes observability metrics

## Technical Details

### Custom U256 Implementation

Due to a compiler bug in Zig 0.15.2's HashMap implementation with native `u256` types, we use a custom `U256` struct implementation. This struct:
- Uses two `u128` fields to represent 256-bit values
- Provides conversion functions to/from native `u256` and byte arrays
- Includes custom hash and equality functions for HashMap compatibility
- Maintains full compatibility with Ethereum's 32-byte hashes and 20-byte addresses

See `src/core/types.zig` for implementation details and rationale.

## Building

```bash
zig build
```

## Running

```bash
zig build run
```

## Configuration

Set environment variables:

- `API_HOST`: API server host (default: 0.0.0.0)
- `API_PORT`: API server port (default: 8545)
- `L1_RPC_URL`: L1 JSON-RPC endpoint (default: http://localhost:8545)
- `L1_CHAIN_ID`: L1 chain ID (default: 1)
- `SEQUENCER_KEY`: Sequencer private key (hex)
- `METRICS_PORT`: Metrics server port (default: 9090)

## API Endpoints

### JSON-RPC Methods

- `eth_sendRawTransaction`: Submit a raw transaction
- `eth_getTransactionReceipt`: Get transaction receipt
- `eth_blockNumber`: Get current block number

### Metrics

Access metrics at `http://localhost:9090` (or configured port).

## Development Status

This is an initial implementation. Production use requires:

- Proper RLP encoding/decoding
- Complete ECDSA signature verification and recovery
- Full transaction execution engine
- RocksDB/LMDB integration for persistence
- WebSocket/gRPC support for real-time subscriptions
- Complete MEV bundle detection
- Proper error handling and retry logic
- Comprehensive testing

## License

See LICENSE file.

