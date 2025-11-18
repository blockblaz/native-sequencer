# Multi-stage Dockerfile for Native Sequencer
# Stage 1: Build stage
FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    build-essential \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2
ENV ZIG_VERSION=0.15.2
RUN curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" -o zig.tar.xz \
    && tar -xf zig.tar.xz \
    && mv zig-linux-x86_64-${ZIG_VERSION} /opt/zig \
    && rm zig.tar.xz

# Add Zig to PATH
ENV PATH="/opt/zig:${PATH}"

# Set working directory
WORKDIR /build

# Copy build files
COPY build.zig build.zig.zon ./
COPY src ./src
COPY vendor ./vendor

# Build the sequencer
RUN zig build -Doptimize=ReleaseSafe

# Stage 2: Runtime stage
FROM ubuntu:22.04

# Install runtime dependencies (minimal - just libc)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd -m -u 1000 sequencer

# Set working directory
WORKDIR /app

# Copy binary from builder
COPY --from=builder /build/zig-out/bin/sequencer /app/sequencer

# Create data directory for WAL and state
RUN mkdir -p /app/data && chown -R sequencer:sequencer /app

# Switch to non-root user
USER sequencer

# Expose ports
# 8545: JSON-RPC API
# 9090: Metrics
EXPOSE 8545 9090

# Set environment variables with defaults
ENV API_HOST=0.0.0.0
ENV API_PORT=8545
ENV METRICS_PORT=9090
ENV L1_RPC_URL=http://localhost:8545
ENV L1_CHAIN_ID=1
ENV MEMPOOL_WAL_PATH=/app/data/mempool.wal
ENV STATE_DB_PATH=/app/data/state.db

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD echo "Health check not implemented yet" || exit 1

# Run the sequencer
CMD ["./sequencer"]

