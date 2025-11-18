// Common error types used throughout the sequencer

pub const SequencerError = error{
    // Transaction errors
    InvalidTransaction,
    InvalidSignature,
    InvalidNonce,
    InsufficientGas,
    InsufficientBalance,
    InvalidGasPrice,
    DuplicateTransaction,
    TransactionTooLarge,

    // Mempool errors
    MempoolFull,
    MempoolEntryNotFound,

    // Block/Batch errors
    BlockGasLimitExceeded,
    BatchSizeExceeded,
    InvalidBlock,

    // L1 errors
    L1ConnectionFailed,
    L1SubmissionFailed,
    L1TransactionReverted,

    // State errors
    StateCorruption,
    InvalidStateTransition,

    // Network errors
    NetworkError,
    InvalidRequest,
    RateLimitExceeded,

    // System errors
    EmergencyHalt,
    ConfigurationError,
    InternalError,
};

pub fn formatError(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidTransaction => "Invalid transaction",
        error.InvalidSignature => "Invalid signature",
        error.InvalidNonce => "Invalid nonce",
        error.InsufficientGas => "Insufficient gas",
        error.InsufficientBalance => "Insufficient balance",
        error.InvalidGasPrice => "Invalid gas price",
        error.DuplicateTransaction => "Duplicate transaction",
        error.MempoolFull => "Mempool full",
        error.L1ConnectionFailed => "L1 connection failed",
        error.EmergencyHalt => "Emergency halt",
        else => "Unknown error",
    };
}
