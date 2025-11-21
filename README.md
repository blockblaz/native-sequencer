# Native Sequencer

**⚠️ EXPERIMENTAL SOFTWARE - USE AT YOUR OWN RISK ⚠️**

This is experimental software and is provided "as is" without warranty of any kind. Use at your own risk. The software may contain bugs, security vulnerabilities, or other issues that could result in loss of funds or data.

A sequencer built in Zig for L2 rollups that accepts transactions, orders them, forms batches, and posts them to L1.

## Overview

The Native Sequencer is a high-performance transaction sequencer designed for Layer 2 rollup solutions. It provides a complete pipeline for accepting L2 transactions from users, validating and ordering them, forming batches, and submitting them to the L1 blockchain.

### Why Zig?

- **Predictable, low overhead runtime** with no garbage collection - ideal for latency-sensitive I/O and high throughput
- **Excellent C interop** - reuse battle-tested C libraries (LMDB, libsecp256k1, etc.)
- **Strong control over memory layout** - enables zero-copy network stacks and deterministic serialization
- **Modern tooling** - easy cross-compilation for Linux amd64/arm64 containers
- **Built with Zig 0.14.1** for stability and performance

## Features

- **op-node Style Architecture**: Delegates execution to L2 geth via Engine API
- **L1 Derivation**: Derives safe blocks from L1 batches
- **Witness Generation**: Generates witness data for stateless execution on L1
- **ExecuteTx Support**: Uses ExecuteTx transactions (type 0x05) for L1 submission
- **State Queries**: Queries L2 geth for state instead of maintaining local state
- **MEV-Aware Ordering**: Transaction ordering with MEV support
- **Metrics & Observability**: Prometheus-style metrics endpoint

## Architecture

The native-sequencer follows an op-node style architecture, delegating execution to L2 geth while handling consensus, transaction ordering, and L1 derivation. It uses ExecuteTx transactions for stateless execution on L1.

### High-Level Flow

```
┌──────────────────┐
│ native-sequencer │ (Consensus Layer)
└────────┬─────────┘
         │ 1. Request block building
         │    engine_forkchoiceUpdated(payload_attrs)
         ▼
┌──────────────────┐
│   L2 geth        │ (Execution Layer)
│                  │ 2. Build block
│                  │ 3. Execute transactions
│                  │ 4. Return payload
└────────┬─────────┘
         │ 5. Generate Witness data
         │    (State trie nodes, contract code, block headers)
         ▼
┌──────────────────┐
│ native-sequencer │
│                  │ 6. Build witness from execution
│                  │ 7. Update fork choice
│                  │ 8. Submit ExecuteTx transaction to L1
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│      L1          │ (Stateless execution via EXECUTE precompile)
│                  │ (Witness provides state for execution)
└──────────────────┘
```

### Module Responsibilities

#### Core Modules (`src/core/`)
- **`transaction.zig`**: Transaction data structures, RLP encoding/decoding, signature recovery
- **`transaction_execute.zig`**: ExecuteTx transaction type (0x05) implementation for stateless execution
- **`block.zig`**: Block data structures and serialization
- **`batch.zig`**: Batch data structures for grouping blocks
- **`witness.zig`**: Witness data structures (state trie nodes, contract code, block headers)
- **`witness_builder.zig`**: Witness generation from execution traces
- **`rlp.zig`**: RLP (Recursive Length Prefix) encoding/decoding for Ethereum data
- **`types.zig`**: Common type definitions (Hash, Address, etc.)
- **`signature.zig`**: ECDSA signature verification and recovery

#### API Layer (`src/api/`)
- **`server.zig`**: JSON-RPC HTTP server for transaction submission and queries
- **`jsonrpc.zig`**: JSON-RPC protocol implementation
- **`http.zig`**: HTTP request/response handling

#### Validation (`src/validation/`)
- **`ingress.zig`**: Transaction ingress handler - accepts and validates transactions
- **`transaction.zig`**: Transaction validator - validates signatures, nonces, balances using L2 geth state

#### Mempool (`src/mempool/`)
- **`mempool.zig`**: Priority queue of pending transactions with gas price ordering
- **`wal.zig`**: Write-ahead log for mempool persistence

#### Sequencer (`src/sequencer/`)
- **`sequencer.zig`**: Main sequencer logic - requests payloads from L2 geth, manages block state
- **`block_state.zig`**: Tracks safe/unsafe/finalized/head blocks (op-node style)
- **`execution.zig`**: Local execution engine for witness generation (not used in main block building path)
- **`mev.zig`**: MEV-aware transaction ordering
- **`reorg_handler.zig`**: Chain reorganization detection and handling

#### L1 Integration (`src/l1/`)
- **`client.zig`**: L1 JSON-RPC client for batch submission and block queries
- **`derivation.zig`**: L1 derivation pipeline - derives L2 blocks from L1 batches (op-node style)
- **`batch_parser.zig`**: Parses L2 batch data from L1 transaction calldata
- **`execute_tx_builder.zig`**: Builds ExecuteTx transactions with witness data for L1 submission

#### L2 Integration (`src/l2/`)
- **`engine_api_client.zig`**: Engine API client for requesting payloads from L2 geth
- **`payload_attrs.zig`**: Payload attributes builder for `engine_forkchoiceUpdated`
- **`state_provider.zig`**: State provider for querying L2 geth state (nonces, balances, code)

#### Batch Management (`src/batch/`)
- **`builder.zig`**: Groups blocks into batches for L1 submission with size/gas limits

#### State Management (`src/state/`)
- **`manager.zig`**: State manager for tracking nonces, balances, receipts (used for witness generation)
- **`state_root.zig`**: State root computation utilities

#### Persistence (`src/persistence/`)
- **`lmdb.zig`**: LMDB database bindings for persistent state storage
- **`witness_storage.zig`**: Witness data storage and retrieval

#### Configuration (`src/config/`)
- **`config.zig`**: Configuration management from environment variables

#### Metrics (`src/metrics/`)
- **`metrics.zig`**: Metrics collection (transaction counts, blocks created, batches submitted)
- **`server.zig`**: Metrics HTTP server for Prometheus-style metrics

#### Crypto (`src/crypto/`)
- **`hash.zig`**: Cryptographic hashing (Keccak256)
- **`secp256k1_wrapper.zig`**: ECDSA signature operations via libsecp256k1
- **`signature.zig`**: Signature verification and address recovery

### Architecture Characteristics

1. **op-node Style**: Delegates execution to L2 geth via Engine API (same as op-node)
2. **L1 Derivation**: Derives safe blocks from L1 batches (op-node style)
3. **Safe/Unsafe Blocks**: Tracks safe (L1-derived) and unsafe (sequencer-proposed) blocks
4. **Witness Generation**: Generates witness data for stateless execution on L1
5. **ExecuteTx Submission**: Uses ExecuteTx transactions (type 0x05) for L1 submission
6. **State Queries**: Queries L2 geth for state (nonces, balances) instead of maintaining local state

## Building

### Prerequisites

- **Zig 0.14.1** ([Install Zig](https://ziglang.org/download/))
- **C compiler** (for vendored C dependencies)
- **LMDB** (Lightning Memory-Mapped Database) - for persistence
  - macOS: `brew install lmdb`
  - Linux: `sudo apt-get install liblmdb-dev` (Debian/Ubuntu) or `sudo yum install lmdb-devel` (RHEL/CentOS)
  - Or build from source: https://github.com/LMDB/lmdb

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
  -p 6197:6197 \
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

#### Troubleshooting

**Container won't start**:
```bash
docker logs sequencer
```

**Port already in use**:
Change the port mapping:
```bash
docker run -p 16197:6197 -p 19090:9090 ...
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


## Running

### Basic Usage

```bash
# Run with default configuration
zig build run

# Or run the built executable directly
./zig-out/bin/sequencer
```

### Configuration

Configure the sequencer using environment variables. Key variables:

- **API**: `API_HOST`, `API_PORT` (default: `0.0.0.0:6197`)
- **L1**: `L1_RPC_URL`, `L1_CHAIN_ID`, `SEQUENCER_KEY`
- **L2**: `L2_RPC_URL`, `L2_ENGINE_API_PORT` (default: `http://localhost:8545:8551`)
- **Mempool**: `MEMPOOL_MAX_SIZE`, `MEMPOOL_WAL_PATH`
- **Batch**: `BATCH_SIZE_LIMIT`, `BATCH_INTERVAL_MS`, `BLOCK_GAS_LIMIT`
- **State**: `STATE_DB_PATH`
- **Metrics**: `METRICS_PORT` (default: `9090`)
- **Controls**: `EMERGENCY_HALT`, `RATE_LIMIT_PER_SECOND`

All variables have defaults. See `src/config/config.zig` for complete list.

## API Endpoints

The native-sequencer exposes a JSON-RPC API over HTTP. All endpoints accept POST requests to `/` with JSON-RPC 2.0 formatted requests.

### Base URL

```
http://<API_HOST>:<API_PORT>/
```

Default: `http://0.0.0.0:6197/`

### JSON-RPC Methods

#### `eth_sendRawTransaction`

Submit a raw transaction to the sequencer. Supports both legacy transactions and ExecuteTx transactions (type 0x05).

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "eth_sendRawTransaction",
  "params": ["0x<raw_transaction_hex>"],
  "id": 1
}
```

**Parameters**:
- `params[0]` (string, required): Hex-encoded raw transaction bytes (with or without `0x` prefix)

**Response (Success)**:
```json
{
  "jsonrpc": "2.0",
  "result": "0x<transaction_hash>",
  "id": 1
}
```

**Response (Error)**:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32602,
    "message": "Invalid transaction encoding"
  },
  "id": 1
}
```

**Transaction Types Supported**:

1. **Legacy Transactions** (Standard Ethereum transactions):
   - Validated for signature, nonce, balance, and gas price
   - Added to mempool if valid
   - Sequenced into blocks by the sequencer
   - Returns transaction hash

2. **ExecuteTx Transactions (Type 0x05)**:
   - Stateless transactions designed for L1 execution
   - Minimally validated (signature check for deduplication)
   - Automatically forwarded to L1 geth via `eth_sendRawTransaction`
   - Not stored in sequencer's mempool
   - Returns transaction hash (from L1 if forwarded, or computed locally)

**Error Codes**:
- `-32602` (InvalidParams): Missing or invalid transaction data
- `-32000` (ServerError): Transaction validation failed, processing failed, or forwarding failed

**Example (Legacy Transaction)**:
```bash
curl -X POST http://localhost:6197/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_sendRawTransaction",
    "params": ["0xf86c808502540be400825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc9e3c0a9f6eccdf15726f5f"],
    "id": 1
  }'
```

**Example (ExecuteTx Transaction)**:
```bash
curl -X POST http://localhost:6197/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_sendRawTransaction",
    "params": ["0x05<execute_tx_rlp_encoded>"],
    "id": 1
  }'
```

---

#### `eth_sendRawTransactionConditional`

Submit a raw transaction with conditional inclusion criteria (EIP-7796). The transaction will only be included in a block if the specified conditions are met.

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "eth_sendRawTransactionConditional",
  "params": [
    "0x<raw_transaction_hex>",
    {
      "blockNumberMin": "0x42",
      "blockNumberMax": "0x100",
      "timestampMin": "0x1234567890",
      "timestampMax": "0x123456789a"
    }
  ],
  "id": 1
}
```

**Parameters**:
- `params[0]` (string, required): Hex-encoded raw transaction bytes (with or without `0x` prefix)
- `params[1]` (object, required): Conditional options object with the following optional fields:
  - `blockNumberMin` (string, optional): Minimum block number (hex string, e.g., `"0x42"`)
  - `blockNumberMax` (string, optional): Maximum block number (hex string, e.g., `"0x100"`)
  - `timestampMin` (string or integer, optional): Minimum block timestamp (hex string or integer)
  - `timestampMax` (string or integer, optional): Maximum block timestamp (hex string or integer)

**Response (Success)**:
```json
{
  "jsonrpc": "2.0",
  "result": "0x<transaction_hash>",
  "id": 1
}
```

**Response (Error)**:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32602,
    "message": "Failed to parse conditional options"
  },
  "id": 1
}
```

**Conditional Inclusion**:
- The transaction is added to the mempool but will only be included in a block when all specified conditions are satisfied
- Conditions are checked against the current block number and timestamp when building blocks
- If conditions are not met, the transaction remains in the mempool until conditions are satisfied or it expires
- ExecuteTx transactions (type 0x05) do not support conditional submission

**Error Codes**:
- `-32602` (InvalidParams): Missing or invalid transaction data or options
- `-32000` (ServerError): Transaction validation failed, processing failed, or insertion failed

**Example**:
```bash
curl -X POST http://localhost:6197/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_sendRawTransactionConditional",
    "params": [
      "0xf86c808502540be400825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc9e3c0a9f6eccdf15726f5f",
      {
        "blockNumberMin": "0x100",
        "blockNumberMax": "0x200"
      }
    ],
    "id": 1
  }'
```

---

#### `eth_getTransactionReceipt`

Get transaction receipt by transaction hash.

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "eth_getTransactionReceipt",
  "params": ["0x<transaction_hash>"],
  "id": 1
}
```

**Parameters**:
- `params[0]` (string, required): Transaction hash (hex-encoded, with or without `0x` prefix)

**Response (Success)**:
```json
{
  "jsonrpc": "2.0",
  "result": null,
  "id": 1
}
```

**Note**: Currently returns `null` as receipt storage is not yet implemented. Future versions will return full receipt data including block number, gas used, logs, etc.

**Response (Error)**:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32602,
    "message": "Missing params"
  },
  "id": 1
}
```

**Example**:
```bash
curl -X POST http://localhost:6197/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_getTransactionReceipt",
    "params": ["0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"],
    "id": 1
  }'
```

---

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

**Parameters**: None (empty array)

**Response (Success)**:
```json
{
  "jsonrpc": "2.0",
  "result": "0x0",
  "id": 1
}
```

**Note**: Currently returns `0x0` as block number tracking is not yet fully implemented. Future versions will return the actual current block number.

**Example**:
```bash
curl -X POST http://localhost:6197/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_blockNumber",
    "params": [],
    "id": 1
  }'
```

---

#### `debug_generateWitness` (Debug Endpoint)

Generate witness data for a single transaction. This is a debug/testing endpoint for witness generation.

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "debug_generateWitness",
  "params": ["0x<raw_transaction_hex>"],
  "id": 1
}
```

**Parameters**:
- `params[0]` (string, required): Hex-encoded raw transaction bytes (with or without `0x` prefix)

**Response (Success)**:
```json
{
  "jsonrpc": "2.0",
  "result": {
    "witness": "0x<rlp_encoded_witness>",
    "witnessSize": 1234
  },
  "id": 1
}
```

**Response Fields**:
- `witness` (string): Hex-encoded RLP-encoded witness data containing state trie nodes, contract code, and block headers
- `witnessSize` (integer): Size of the witness in bytes

**Response (Error)**:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32000,
    "message": "Sequencer not available for witness generation"
  },
  "id": 1
}
```

**Error Codes**:
- `-32602` (InvalidParams): Missing or invalid transaction data
- `-32000` (ServerError): Sequencer not available, transaction execution failed, or witness generation failed

**Note**: This endpoint executes the transaction locally to track state access. In production, witness generation happens during ExecuteTx building.

**Example**:
```bash
curl -X POST http://localhost:6197/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "debug_generateWitness",
    "params": ["0xf86c808502540be400825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc9e3c0a9f6eccdf15726f5f"],
    "id": 1
  }'
```

---

#### `debug_generateBlockWitness` (Debug Endpoint)

Generate witness data for a block. This is a debug/testing endpoint for block witness generation.

**Request**:
```json
{
  "jsonrpc": "2.0",
  "method": "debug_generateBlockWitness",
  "params": ["latest"]
}
```

or

```json
{
  "jsonrpc": "2.0",
  "method": "debug_generateBlockWitness",
  "params": ["0x42"]
}
```

**Parameters**:
- `params[0]` (string or integer, required): Block number as hex string (`"0x42"`), decimal integer (`42`), or `"latest"` for the latest block

**Response (Success)**:
```json
{
  "jsonrpc": "2.0",
  "result": {
    "witness": "0x<rlp_encoded_witness>",
    "witnessSize": 5678,
    "blockNumber": 42,
    "transactionCount": 5
  },
  "id": 1
}
```

**Response Fields**:
- `witness` (string): Hex-encoded RLP-encoded witness data containing state trie nodes, contract code, and block headers for all transactions in the block
- `witnessSize` (integer): Size of the witness in bytes
- `blockNumber` (integer): Block number for which witness was generated
- `transactionCount` (integer): Number of transactions in the block

**Response (Error)**:
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32000,
    "message": "Failed to build block"
  },
  "id": 1
}
```

**Error Codes**:
- `-32602` (InvalidParams): Missing or invalid block number
- `-32000` (ServerError): Sequencer not available or failed to build block

**Note**: This endpoint builds a new block from the mempool and generates witness for it. In production, witness generation happens during ExecuteTx batch building.

**Example**:
```bash
curl -X POST http://localhost:6197/ \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "debug_generateBlockWitness",
    "params": ["latest"],
    "id": 1
  }'
```

---

### JSON-RPC Error Codes

The sequencer uses standard JSON-RPC 2.0 error codes:

| Code | Name | Description |
|------|------|-------------|
| `-32700` | ParseError | Invalid JSON was received |
| `-32600` | InvalidRequest | The JSON sent is not a valid Request object |
| `-32601` | MethodNotFound | The method does not exist |
| `-32602` | InvalidParams | Invalid method parameters |
| `-32603` | InternalError | Internal JSON-RPC error |
| `-32000` | ServerError | Server error (validation failures, processing errors) |

### HTTP Status Codes

- `200 OK`: Request processed successfully (even if JSON-RPC returns an error)
- `404 Not Found`: Invalid HTTP method or path (must be POST `/`)

### Metrics

Access metrics at `http://localhost:9090` (or configured port).

Available metrics:
- Transaction acceptance rate
- Blocks created
- Batches submitted
- L1 submission errors
- Mempool size

## Development Status

This is experimental software. Core features are implemented:
- ✅ op-node style architecture (L1 derivation, Engine API, safe/unsafe blocks)
- ✅ Transaction validation and mempool
- ✅ Batch formation and L1 submission via ExecuteTx
- ✅ LMDB persistence
- ✅ Witness generation for stateless execution
- ⏳ L1 subscription monitoring (WebSocket support)
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

GitHub Actions workflow (`.github/workflows/ci.yml`) runs linting, testing, and multi-platform builds (Linux, macOS, Windows) on push/PR.

## Technical Details

### ExecuteTx Transaction Support

The sequencer supports ExecuteTx transactions (type 0x05) for stateless execution on L1. ExecuteTx transactions are:
- **Stateless**: Designed for execution by L1 geth nodes
- **Forwarded to L1**: Automatically forwarded to L1 geth via `eth_sendRawTransaction`
- **Minimally Validated**: Only signature check for deduplication (full validation by L1 geth)
- **Not Mempooled**: Not stored in sequencer's mempool

ExecuteTx includes pre-state hash, witness data, withdrawals, and standard EIP-1559 fields. See `src/core/transaction_execute.zig` for implementation details.

## Known Issues & Workarounds

### Linux Build Requirements

**LMDB**: The sequencer uses LMDB for persistence. Make sure LMDB is installed on your system (see Prerequisites section above).

```bash
zig build -Dtarget=x86_64-linux-gnu.2.38
```

**CI Compatibility**: GitHub Actions `ubuntu-latest` runners use Ubuntu 22.04 (glibc 2.35), which is insufficient. The CI workflow specifies glibc 2.38 in the build target to ensure compatibility. For local builds on older Linux distributions, you may need to:

1. Use a newer Linux distribution (Ubuntu 24.04+ or equivalent)
2. Build in a container with glibc 2.38+
3. Use the Docker build which includes the correct glibc version

## License

See LICENSE file.
