# Native Sequencer

## Known Issues

### Zig 0.14.1 Allocator Bug

This project encountered a compiler bug in Zig 0.14.1 related to allocating arrays of structs containing slices. See **[ZIG_0.14_ALLOCATOR_ERROR.md](ZIG_0.14_ALLOCATOR_ERROR.md)** for detailed explanation and workarounds attempted.

### Upgrading to Zig 0.15.2

This project is being upgraded to Zig 0.15.2 to resolve the allocator bug. See **[ZIG_0.15_UPGRADE.md](ZIG_0.15_UPGRADE.md)** for detailed information about the upgrade process, encountered errors, and solutions.

### Current Status

- ✅ Updated `build.zig.zon` to require Zig 0.15.0+
- ✅ Updated `build.zig` for Zig 0.15 API
- ⏳ Waiting for `zig_eth_secp256k1` dependency to be updated for Zig 0.15 (see [ZIG_0.15_UPGRADE.md](ZIG_0.15_UPGRADE.md) for fork solution)
- ⏳ Code updates for Zig 0.15 API changes (pending - ArrayList, HashMap, etc.)

### Quick Summary

The main blocker is that `zig_eth_secp256k1` dependency still uses the old Zig 0.14 `addStaticLibrary` API, which was replaced with `addLibrary` in Zig 0.15. See the upgrade document for detailed steps on forking and updating the dependency.

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

