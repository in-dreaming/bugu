//! Owned values from actual live Render visibility decisions. Optional reads
//! are absent when their original short-circuit predecessor prevented them.
//! Descriptor/hash data is copied only after the real publication acquire.
const trace = @import("sme-trace").schema;
const visibility = @import("visibility.zig");

pub const Frontier = struct { value: u64 = 0 };
pub const Result = enum(u8) { not_started, empty, failed, admitted, rejected };
pub const Effects = struct {
    visible_advanced: bool = false,
    read_advanced: bool = false,
};
pub const Attempt = struct {
    frontier: u64 = 0,
    gate: u64 = 0,
    frame: u64 = 0,
    order: u32 = 0,
    read: u64 = 0,
    head: ?u64 = null,
    descriptor: ?visibility.Descriptor = null,
    /// Valid only when descriptor is present. Copied, never hashed on Render.
    content_hash: trace.Hash = @splat(0),
    generation: ?u64 = null,
    visible_produced: ?u64 = null,
    produced: ?u64 = null,
    stopped: ?bool = null,
    disposition: ?trace.AdmissionDisposition = null,
    result: Result = .not_started,
    error_code: u32 = 0,
    effects: Effects = .{},
};

pub const frontier_bytes: usize = @sizeOf(Frontier);
pub const attempt_bytes: usize = @sizeOf(Attempt);
comptime {
    if (@sizeOf(Attempt) > 400) @compileError("stream attempt must fit the bounded Render event envelope");
}
