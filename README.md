# Native Sequencer

A production-grade sequencer built in Zig for L2 rollups that accepts transactions, orders them, forms batches, and posts them to L1.

## Overview

The Native Sequencer is a high-performance transaction sequencer designed for Layer 2 rollup solutions. It provides a complete pipeline for accepting L2 transactions from users, validating and ordering them, forming batches, and submitting them to the L1 blockchain.

### Why Zig?

- **Predictable, low overhead runtime** with no garbage collection - ideal for latency-sensitive I/O and high throughput
- **Excellent C interop** - reuse battle-tested C libraries (RocksDB, libsecp256k1, etc.)
- **Strong control over memory layout** - enables zero-copy network stacks and deterministic serialization
- **Modern tooling** - easy cross-compilation for Linux amd64/arm64 containers
- **Production-ready** - built with Zig 0.15.2 for stability and performance

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

```
┌─────────────┐
│ API Server │ ← JSON-RPC requests from users/relayers
└──────┬──────┘
       │
┌──────▼──────┐
│   Ingress   │ ← Validates transactions
└──────┬──────┘
       │
┌──────▼──────┐
│   Mempool   │ ← Priority queue of pending transactions
└──────┬──────┘
       │
┌──────▼────────┐
│  Sequencer    │ ← Builds blocks from mempool
└──────┬────────┘
       │
┌──────▼──────────┐
│  Batch Builder   │ ← Groups blocks into batches
└──────┬───────────┘
       │
┌──────▼──────┐
│  L1 Client  │ ← Submits batches to L1
└─────────────┘
```

**Core Components**:
- **API Server**: Handles JSON-RPC requests from users/relayers
- **Ingress**: Validates and accepts transactions into mempool
- **Mempool**: Maintains priority queue of pending transactions
- **Sequencer**: Builds blocks from mempool transactions
- **Batch Builder**: Groups blocks into batches for L1 submission
- **L1 Client**: Submits batches to L1 blockchain
- **State Manager**: Tracks account state (nonces, balances)
- **Metrics**: Exposes observability metrics

## Building

### Prerequisites

- **Zig 0.15.2** or later ([Install Zig](https://ziglang.org/download/))
- **C compiler** (for vendored C dependencies)

### Build Commands

```bash
# Build the sequencer executable
zig build

# Build and run
zig build run

# Run tests
zig build test

# Run linter
zig build lint
```

The build output will be in `zig-out/bin/sequencer`.

## Running

### Basic Usage

```bash
# Run with default configuration
zig build run

# Or run the built executable directly
./zig-out/bin/sequencer
```

### Configuration

Configure the sequencer using environment variables:

```bash
# API Server Configuration
export API_HOST=0.0.0.0          # API server host (default: 0.0.0.0)
export API_PORT=8545            # API server port (default: 8545)

# L1 Configuration
export L1_RPC_URL=http://localhost:8545  # L1 JSON-RPC endpoint
export L1_CHAIN_ID=1                     # L1 chain ID (default: 1)
export SEQUENCER_KEY=<hex-private-key>   # Sequencer private key (hex)

# Metrics Configuration
export METRICS_PORT=9090        # Metrics server port (default: 9090)

# Mempool Configuration
export MEMPOOL_MAX_SIZE=10000   # Maximum mempool size
export MEMPOOL_WAL_PATH=./wal   # Write-ahead log path

# Batch Configuration
export BATCH_SIZE_LIMIT=100     # Maximum blocks per batch
export BATCH_INTERVAL_MS=1000    # Batch interval in milliseconds
export BLOCK_GAS_LIMIT=30000000  # Gas limit per block
```

### Example

```bash
# Set configuration
export API_PORT=8545
export L1_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
export L1_CHAIN_ID=1
export SEQUENCER_KEY=0x1234567890abcdef...

# Run sequencer
zig build run
```

## API Endpoints

### JSON-RPC Methods

The sequencer exposes standard Ethereum JSON-RPC endpoints:

#### `eth_sendRawTransaction`

Submit a raw transaction to the sequencer.

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "eth_sendRawTransaction",
  "params": ["0x..."],
  "id": 1
}
```

**Response**:
```json
{
  "jsonrpc": "2.0",
  "result": "0x1234...",
  "id": 1
}
```

#### `eth_getTransactionReceipt`

Get transaction receipt by transaction hash.

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "eth_getTransactionReceipt",
  "params": ["0x..."],
  "id": 1
}
```

#### `eth_blockNumber`

Get the current block number.

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "eth_blockNumber",
  "params": [],
  "id": 1
}
```

### Metrics

Access metrics at `http://localhost:9090` (or configured port).

Available metrics:
- Transaction acceptance rate
- Blocks created
- Batches submitted
- L1 submission errors
- Mempool size

## Development Status

This is an initial implementation. Production use requires:

- ✅ Core sequencer architecture
- ✅ Transaction validation and mempool
- ✅ Batch formation and L1 submission
- ✅ Basic state management
- ⏳ Proper RLP encoding/decoding (simplified implementation)
- ⏳ Complete ECDSA signature verification and recovery (basic implementation)
- ⏳ Full transaction execution engine
- ⏳ RocksDB/LMDB integration for persistence
- ⏳ WebSocket/gRPC support for real-time subscriptions
- ⏳ Complete MEV bundle detection
- ⏳ Proper error handling and retry logic
- ⏳ Comprehensive testing

## Technical Details

### Custom U256 Implementation

Due to a compiler bug in Zig 0.15.2's HashMap implementation with native `u256` types, we use a custom `U256` struct implementation. This struct:
- Uses two `u128` fields to represent 256-bit values
- Provides conversion functions to/from native `u256` and byte arrays
- Includes custom hash and equality functions for HashMap compatibility
- Maintains full compatibility with Ethereum's 32-byte hashes and 20-byte addresses

See `src/core/types.zig` for implementation details and rationale.

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

## License

See LICENSE file.
