//! Bounded Control -> Render -> Control publication ledger. Canonical bytes
//! bind actual accepted worker PCM, never addresses or mutable ring storage.
const std = @import("std");
const trace = @import("sme-trace");
const Ring = @import("ring.zig").Ring;
pub const Descriptor = struct {
    version: u16 = 1,
    batch_id: u64,
    stream_slot: u16,
    stream_generation: u64,
    asset: u64,
    asset_generation: u64,
    transport_epoch: u64,
    profile_id: u64,
    profile_hash: [32]u8,
    publication_ordinal: u64,
    worker_job: u64,
    job_descriptor_hash: [32]u8,
    prefix_start: u64,
    prefix_end: u64,
    target_cursor: u64,
    loop_epoch: u64,
    channels: u8,
    pcm_hash: [32]u8,
};
pub const canonical_size = trace.codec.maxSize(Descriptor);
pub const Entry = struct {
    descriptor: Descriptor = undefined,
    canonical: [canonical_size]u8 = undefined,
    hash: [32]u8 = undefined,
    ring: *Ring = undefined,
    admission: trace.schema.Admission = undefined,
    replay_release: trace.replay.GateRelease = undefined,
    replay_prepared: std.atomic.Value(bool) = .init(false),
};
pub fn encode(descriptor: Descriptor) [canonical_size]u8 {
    var bytes: [canonical_size]u8 = undefined;
    var encoder: trace.codec.Encoder = .{ .bytes = &bytes };
    encoder.put(descriptor) catch unreachable;
    std.debug.assert(encoder.offset == bytes.len);
    return bytes;
}
