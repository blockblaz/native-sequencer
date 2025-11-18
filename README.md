# Native Sequencer

**⚠️ EXPERIMENTAL SOFTWARE - USE AT YOUR OWN RISK ⚠️**

This is experimental software and is provided "as is" without warranty of any kind. Use at your own risk. The software may contain bugs, security vulnerabilities, or other issues that could result in loss of funds or data.

A sequencer built in Zig for L2 rollups that accepts transactions, orders them, forms batches, and posts them to L1.

## Overview

The Native Sequencer is a high-performance transaction sequencer designed for Layer 2 rollup solutions. It provides a complete pipeline for accepting L2 transactions from users, validating and ordering them, forming batches, and submitting them to the L1 blockchain.

### Why Zig?

- **Predictable, low overhead runtime** with no garbage collection - ideal for latency-sensitive I/O and high throughput
- **Excellent C interop** - reuse battle-tested C libraries (RocksDB, libsecp256k1, etc.)
- **Strong control over memory layout** - enables zero-copy network stacks and deterministic serialization
- **Modern tooling** - easy cross-compilation for Linux amd64/arm64 containers
- **Built with Zig 0.14.1** for stability and performance

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

- **Zig 0.14.1** ([Install Zig](https://ziglang.org/download/))
- **C compiler** (for vendored C dependencies)

### Build Commands

```bash
# Build the sequencer executable
zig build

# Build and run
zig build run

# Run tests
zig build test

# Run linter (format check + AST checks)
zig build lint

# Format code automatically
zig build fmt

# Run lint-fix (alias for fmt)
zig build lint-fix
```

The build output will be in `zig-out/bin/sequencer`.

### Docker Build

#### Quick Start

```bash
# Build Docker image
docker build -t native-sequencer .

# Run with Docker
docker run -d \
  --name sequencer \
  -p 8545:8545 \
  -p 9090:9090 \
  -v sequencer-data:/app/data \
  -e L1_RPC_URL=http://host.docker.internal:8545 \
  -e SEQUENCER_KEY=<your-private-key> \
  native-sequencer

# View logs
docker logs -f sequencer

# Stop the sequencer
docker stop sequencer
docker rm sequencer
```

#### Dockerfile Details

The Dockerfile uses a multi-stage build:

1. **Builder Stage**: Installs Zig 0.14.1 and builds the sequencer
2. **Runtime Stage**: Creates a minimal runtime image with just the binary

#### Runtime Environment Variables

The container accepts the following environment variables (all have defaults set in the Dockerfile):

**API Configuration**:
- `API_HOST`: API server host (default: `0.0.0.0`)
- `API_PORT`: API server port (default: `8545`)

**L1 Configuration**:
- `L1_RPC_URL`: L1 JSON-RPC endpoint (default: `http://host.docker.internal:8545`)
- `L1_CHAIN_ID`: L1 chain ID (default: `1`)
- `SEQUENCER_KEY`: Sequencer private key in hex format

**Sequencer Configuration**:
- `BATCH_SIZE_LIMIT`: Maximum blocks per batch (default: `1000`)
- `BLOCK_GAS_LIMIT`: Gas limit per block (default: `30000000`)
- `BATCH_INTERVAL_MS`: Batch interval in milliseconds (default: `2000`)

**Mempool Configuration**:
- `MEMPOOL_MAX_SIZE`: Maximum mempool size (default: `100000`)
- `MEMPOOL_WAL_PATH`: Write-ahead log path (default: `/app/data/mempool.wal`)

**State Configuration**:
- `STATE_DB_PATH`: State database path (default: `/app/data/state.db`)

**Observability**:
- `METRICS_PORT`: Metrics server port (default: `9090`)
- `ENABLE_TRACING`: Enable tracing (default: `false`)

**Operator Controls**:
- `EMERGENCY_HALT`: Emergency halt flag (default: `false`)
- `RATE_LIMIT_PER_SECOND`: Rate limit per second (default: `1000`)

#### Ports

The container exposes two ports:
- **8545**: JSON-RPC API endpoint
- **9090**: Metrics endpoint

#### Volumes

The container uses a named volume `sequencer-data` to persist:
- Mempool write-ahead log (`mempool.wal`)
- State database (`state.db`)

To use a host directory instead:
```bash
docker run -v /path/to/data:/app/data ...
```

#### Security

- The container runs as a non-root user (`sequencer`, UID 1000)
- Only necessary runtime dependencies are included
- Source code is not included in the final image

#### Troubleshooting

**Container won't start**:
```bash
docker logs sequencer
```

**Port already in use**:
Change the port mapping:
```bash
docker run -p 18545:8545 -p 19090:9090 ...
```

**L1 connection issues**:
- On Mac/Windows, use `host.docker.internal` to access the host:
  ```bash
  -e L1_RPC_URL=http://host.docker.internal:8545
  ```
- On Linux, you may need to use `--network host`:
  ```bash
  docker run --network host ...
  ```

**Permission issues**:
Ensure the data directory has correct permissions:
```bash
sudo chown -R 1000:1000 /path/to/data
```

#### Building for Different Architectures

**Build for ARM64** (Apple Silicon, Raspberry Pi):
```bash
docker buildx build --platform linux/arm64 -t native-sequencer:arm64 .
```

**Build for AMD64**:
```bash
docker buildx build --platform linux/amd64 -t native-sequencer:amd64 .
```

**Build multi-architecture image**:
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t native-sequencer:latest --push .
```

#### Deployment Considerations

For deployments, consider:

1. **Use a specific tag** instead of `latest`
2. **Set resource limits**
3. **Use secrets** for sensitive data like `SEQUENCER_KEY`
4. **Enable health checks** (currently placeholder)
5. **Set up log aggregation**
6. **Configure monitoring** for metrics endpoint

**Example: Docker with systemd service**:
```bash
# Create systemd service file
cat > /etc/systemd/system/sequencer.service <<EOF
[Unit]
Description=Native Sequencer
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
ExecStart=/usr/bin/docker run --rm --name sequencer \
  -p 8545:8545 -p 9090:9090 \
  -v sequencer-data:/app/data \
  -e L1_RPC_URL=\${L1_RPC_URL} \
  -e SEQUENCER_KEY=\${SEQUENCER_KEY} \
  native-sequencer:v0.1.0
ExecStop=/usr/bin/docker stop sequencer

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
systemctl enable sequencer
systemctl start sequencer
```

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

### L1 Client Features

The sequencer includes a full-featured HTTP client for L1 communication:

- **Standard Transaction Submission**: `eth_sendRawTransaction` for submitting batches to L1
- **Conditional Transaction Submission**: `eth_sendRawTransactionConditional` (EIP-7796) for conditional batch submission with block number constraints
- **Transaction Receipt Polling**: `eth_getTransactionReceipt` for tracking batch inclusion
- **Block Number Queries**: `eth_blockNumber` for L1 state synchronization
- **Automatic Confirmation Waiting**: `waitForInclusion()` method for polling transaction confirmations

#### Conditional Transaction Submission

The sequencer supports EIP-7796 conditional transaction submission, allowing batches to be submitted with preconditions:

```zig
const options = l1.Client.ConditionalOptions{
    .block_number_max = 1000000, // Only include if block <= 1000000
};
const tx_hash = try l1_client.submitBatchConditional(batch, options);
```

This feature enables more efficient batch submission by allowing the sequencer to specify maximum block numbers for inclusion, reducing the need for extensive simulations.

### Metrics

Access metrics at `http://localhost:9090` (or configured port).

Available metrics:
- Transaction acceptance rate
- Blocks created
- Batches submitted
- L1 submission errors
- Mempool size

## Development Status

This is an experimental implementation. The following features are implemented or in progress:

- ✅ Core sequencer architecture
- ✅ Transaction validation and mempool
- ✅ Batch formation and L1 submission
- ✅ Basic state management
- ✅ RLP encoding/decoding (complete implementation with tests)
- ✅ Docker support
- ✅ HTTP server implementation (Zig 0.14.1 networking APIs)
- ✅ HTTP client for L1 communication (JSON-RPC support)
- ✅ Conditional transaction submission (EIP-7796 support)
- ⏳ Complete ECDSA signature verification and recovery (basic implementation)
- ⏳ Full transaction execution engine
- ⏳ RocksDB/LMDB integration for persistence
- ⏳ WebSocket/gRPC support for real-time subscriptions
- ⏳ Complete MEV bundle detection
- ⏳ Proper error handling and retry logic
- ⏳ Comprehensive testing

## Linting

The repository includes comprehensive linting checks to ensure code quality:

- **Format Check**: Validates code formatting using `zig fmt --check`
- **AST Checks**: Validates syntax and type correctness using `zig ast-check` for key modules
- **Format Fix**: Automatically formats code using `zig fmt`

### Linting Commands

```bash
# Run all linting checks (format + AST)
# Exit code 1 if formatting issues are found
zig build lint

# Format code automatically (fixes formatting issues)
zig build fmt

# Run lint-fix (alias for fmt)
zig build lint-fix
```

**Note**: If `zig build lint` fails, run `zig build fmt` to automatically fix formatting issues, then commit the changes.

### CI/CD Integration

A comprehensive GitHub Actions workflow (`.github/workflows/ci.yml`) automatically runs on:
- Push to main/master/develop branches
- Pull requests targeting main/master/develop branches

The CI pipeline includes:

#### Linting & Testing
- **Code formatting validation** (`zig fmt --check`)
- **AST syntax checks** for key modules (`zig ast-check`)
- **Unit tests** (`zig build test`)

#### Multi-Platform Builds
- **Linux (x86_64)**: Builds and verifies binary for Linux
- **macOS (x86_64)**: Builds and verifies binary for Intel Macs
- **macOS (ARM64)**: Builds and verifies binary for Apple Silicon
- **Windows (x86_64)**: Builds and verifies binary for Windows

#### Docker Build Validation
- **Multi-architecture Docker builds**: Tests Docker image builds for both `linux/amd64` and `linux/arm64`
- **Image verification**: Validates Docker image structure and metadata
- **Runtime testing**: Verifies that the Docker image can start and contains the expected binary

The workflow will fail if:
- Code is not properly formatted
- AST checks reveal syntax or type errors
- Unit tests fail
- Build fails on any platform
- Docker image build or validation fails

## Technical Details

### Networking Implementation

The sequencer uses Zig 0.14.1's standard library networking APIs:

- **HTTP Server**: Built on `std.net.Server` and `std.net.Stream` for accepting JSON-RPC connections
- **HTTP Client**: Uses `std.net.tcpConnectToAddress` for L1 RPC communication
- **Connection Handling**: Thread-based concurrent request handling with proper resource cleanup
- **RLP Transaction Parsing**: Full RLP decoding support for transaction deserialization

### Custom U256 Implementation

Due to a compiler bug in Zig 0.14.x's HashMap implementation with native `u256` types, we use a custom `U256` struct implementation. This struct:
- Uses two `u128` fields to represent 256-bit values
- Provides conversion functions to/from native `u256` and byte arrays
- Includes custom hash and equality functions for HashMap compatibility
- Maintains full compatibility with Ethereum's 32-byte hashes and 20-byte addresses

See `src/core/types.zig` for implementation details and rationale.

## Known Issues & Workarounds

### Zig 0.14.x HashMap Allocator Bug (RESOLVED)

**Status**: ✅ **RESOLVED** - Custom U256 implementation workaround implemented

This project encountered a compiler bug in Zig 0.14.x related to HashMap initialization with native `u256` types as keys. The error manifests as:
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

This project previously encountered allocator bugs in Zig 0.14.0 and 0.14.1 related to allocating arrays of structs containing slices. **Verified through testing**: The bug exists in both versions (at different line numbers: 400 vs 412). The issue was resolved by using a custom `U256` implementation instead of native `u256` types.


## License

See LICENSE file.
