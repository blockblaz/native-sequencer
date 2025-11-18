// Root module exports - organized by domain
// zigeth is added as an import to this module in build.zig
// We re-export it here so submodules can access it through this root
pub const zigeth = @import("zigeth");

pub const core = @import("core/root.zig");
pub const crypto = @import("crypto/root.zig");
pub const validation = @import("validation/root.zig");
pub const mempool = @import("mempool/root.zig");
pub const sequencer = @import("sequencer/root.zig");
pub const batch = @import("batch/root.zig");
pub const l1 = @import("l1/root.zig");
pub const state = @import("state/root.zig");
pub const api = @import("api/root.zig");
pub const metrics = @import("metrics/root.zig");
pub const config = @import("config/root.zig");
