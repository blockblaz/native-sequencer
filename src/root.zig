// Root module exports - organized by domain
pub const core = @import("core/root.zig");
pub const crypto = @import("crypto/root.zig");
pub const validation = @import("validation/root.zig");
pub const mempool = @import("mempool/root.zig");
pub const sequencer = @import("sequencer/root.zig");
pub const batch = @import("batch/root.zig");
pub const l1 = @import("l1/root.zig");
pub const l2 = @import("l2/root.zig");
pub const state = @import("state/root.zig");
pub const api = @import("api/root.zig");
pub const metrics = @import("metrics/root.zig");
pub const config = @import("config/root.zig");
pub const persistence = @import("persistence/root.zig");
