//! Immutable render-facing stream descriptor. No codec, I/O, allocator or
//! callback function pointers. Identity participates in canonical group hashes.
const std = @import("std");
const r = @import("ring.zig");
pub const Identity = struct {
    asset: u64,
    asset_generation: u64,
    transport_epoch: u64,
    stream_generation: u64,
    profile_id: u64,
    profile_hash: [32]u8,
    encoded_hash: [32]u8,
    start_cursor: u64,
    start_loop_epoch: u64,
    frame_count: u64,
    channels: u8,
    minimum_playable_frames: u32,
    loop: ?r.Loop,
};
pub const Source = struct {
    ring: *r.Ring,
    identity: Identity,
    pub fn validate(self: Source) bool {
        const id = self.identity;
        return !self.ring.stopped.load(.acquire) and id.asset != 0 and id.asset_generation != 0 and id.transport_epoch != 0 and id.stream_generation != 0 and id.stream_generation == self.ring.generation and id.profile_id != 0 and id.start_cursor == self.ring.start_cursor and id.start_loop_epoch == self.ring.start_loop_epoch and id.frame_count == self.ring.frames and id.channels == self.ring.channels and std.meta.eql(id.loop, self.ring.loop) and id.minimum_playable_frames != 0 and id.minimum_playable_frames < self.ring.capacity_frames;
    }
    pub fn ready(self: Source, cursor: u64, loop_epoch: u64) bool {
        if (self.ring.stopped.load(.acquire)) return false;
        const read = self.ring.consumed.load(.acquire);
        const coordinate = self.ring.coordinate(read) orelse return false;
        if (coordinate.cursor != cursor or coordinate.loop_epoch != loop_epoch) return false;
        const end = if (self.identity.loop) |loop| loop.end else self.identity.frame_count;
        const available = self.ring.renderProduced() - read;
        return available >= @min(self.identity.minimum_playable_frames, end - cursor);
    }
    /// Control preparation and reclamation only. They are atomic and do not
    /// free memory; Service.close performs actual worker/asset teardown later.
    pub fn retain(self: Source) error{InvalidState}!void {
        if (!self.validate()) return error.InvalidState;
        return self.ring.retain();
    }
    pub fn release(self: Source) void {
        self.ring.release();
    }
};
