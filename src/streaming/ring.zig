//! Stable SPSC PCM ring. Control is sole writer; renderer is sole consumer.
//! Neither side resets cursors while leased. Seek allocates a new stream slot.
const std = @import("std");
pub const capture_order = @import("sme-capture-order");
pub const Loop = struct { start: u64, end: u64 };
pub const Coordinate = struct { cursor: u64, loop_epoch: u64 };
/// Copies of the actual sequential SPSC loads, never a coherent snapshot.
pub const ReadCut = struct { consumed: u64 = 0, produced: u64 = 0 };
pub const PublishObservation = struct { availability: ?ReadCut = null, write: ?u64 = null, end: ?u64 = null };
pub const consumed_slots: usize = 48;
pub const Consumed = struct { index: u16, generation: u64, value: u64 };
pub const ConsumedRange = struct { index: u16, generation: u64, first: u64, last: u64, count: u32 };
pub const ConsumedSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, Consumed) void };
/// Immutable while the ring is leased. Live capture's callback only copies
/// the actual release; only an offline executor installs checkpoint waits.
pub const ConsumeObserver = struct {
    context: *anyopaque,
    index: u16,
    generation: u64,
    emit: *const fn (*anyopaque, Consumed) void,
    checkpoint: *const fn (*anyopaque, OfflinePoint) void,
};
/// One Render call's actual releases, never inferred from requested frames.
/// The caller reserves its shared event credit before the first touch.
pub const ConsumedRanges = struct {
    entries: [consumed_slots]?ConsumedRange = @splat(null),
    ranges: u16 = 0,
    publications: u32 = 0,
    limit: u32 = 0,
    failed: bool = false,
    pub fn begin(self: *ConsumedRanges, limit: u32) void {
        for (&self.entries) |*entry| entry.* = null;
        self.ranges = 0;
        self.publications = 0;
        self.limit = limit;
        // Failure is permanent for this recording, including later calls.
    }
    pub fn append(self: *ConsumedRanges, value: Consumed) error{InvalidEvidence}!void {
        errdefer self.failed = true;
        if (self.failed or value.index >= consumed_slots or value.generation == 0 or value.value == 0 or self.limit == 0 or self.publications == std.math.maxInt(u32)) return error.InvalidEvidence;
        const entry = &self.entries[value.index];
        if (entry.*) |*range| {
            if (range.generation != value.generation or range.last == std.math.maxInt(u64) or value.value != range.last + 1 or range.count >= self.limit) return error.InvalidEvidence;
            range.last = value.value;
            range.count += 1;
        } else {
            entry.* = .{ .index = value.index, .generation = value.generation, .first = value.value, .last = value.value, .count = 1 };
            self.ranges += 1;
        }
        self.publications += 1;
    }
};
/// Passed only by offline replay at already-observed Control reads/releases.
/// Ordinary capture and Render never install or wait on this callback.
pub const OfflinePoint = struct {
    site: enum { stream_ring_consumed, stream_ring_produced, stream_produced, stream_consumed_release },
    edge: enum { before, after },
    index: u64,
    generation: u64,
    value: u64 = 0,
};
pub const OfflineHook = struct {
    context: *anyopaque,
    index: u64,
    generation: u64,
    checkpoint: *const fn (*anyopaque, OfflinePoint) void,
    fn emit(self: OfflineHook, site: @FieldType(OfflinePoint, "site"), edge: @FieldType(OfflinePoint, "edge"), value: u64) void {
        self.checkpoint(self.context, .{ .site = site, .edge = edge, .index = self.index, .generation = self.generation, .value = value });
    }
};
pub const Ring = struct {
    generation: u64 = 0,
    pcm: []f32,
    channels: u8,
    capacity_frames: u32,
    start_cursor: u64,
    start_loop_epoch: u64,
    frames: u64,
    loop: ?Loop,
    produced: std.atomic.Value(u64) = .init(0),
    /// Attached runtime admits accepted PCM only once at a render gate.
    gated: bool = false,
    visible_produced: std.atomic.Value(u64) = .init(0),
    control_consumed: std.atomic.Value(u64) = .init(0),
    consumed: std.atomic.Value(u64) = .init(0),
    references: std.atomic.Value(u32) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),
    consume_observer: ?ConsumeObserver = null,
    /// Opt-in partial order evidence only. The host installs/removes immutable
    /// bindings at genuine producer/consumer quiescence and keeps storage pinned.
    /// Multiple rings for one role share a collector. Old profiles leave null.
    /// No callback, replay wait, complete recording or publication is installed.
    order_control: ?capture_order.Binding = null,
    order_render: ?capture_order.Binding = null,
    test_peek_hook: if (@import("builtin").is_test) ?struct { context: *anyopaque, call: *const fn (*anyopaque, u64) void } else void = if (@import("builtin").is_test) null else {},
    pub fn coordinate(self: *const Ring, ordinal: u64) ?Coordinate {
        if (self.loop) |loop| {
            const first_length = loop.end - self.start_cursor;
            if (ordinal < first_length) return .{ .cursor = self.start_cursor + ordinal, .loop_epoch = self.start_loop_epoch };
            const after = ordinal - first_length;
            const advance = std.math.add(u64, 1, after / (loop.end - loop.start)) catch return null;
            const epoch = std.math.add(u64, self.start_loop_epoch, advance) catch return null;
            return .{ .cursor = loop.start + after % (loop.end - loop.start), .loop_epoch = epoch };
        }
        const cursor = std.math.add(u64, self.start_cursor, ordinal) catch return null;
        if (cursor >= self.frames) return null;
        return .{ .cursor = cursor, .loop_epoch = self.start_loop_epoch };
    }
    pub fn available(self: *const Ring) u64 {
        return self.availableObserved(null);
    }
    pub fn availableObserved(self: *const Ring, observation: ?*ReadCut) u64 {
        return self.availableObservedReplay(observation, null);
    }
    pub fn availableObservedReplay(self: *const Ring, observation: ?*ReadCut, offline: ?OfflineHook) u64 {
        if (offline) |hook| hook.emit(.stream_ring_consumed, .before, 0);
        if (self.order_control) |binding| binding.emitFor(.control, .ring_consumed, .before, null);
        const read = self.consumed.load(.acquire);
        if (self.order_control) |binding| binding.emitFor(.control, .ring_consumed, .after, read);
        if (offline) |hook| hook.emit(.stream_ring_consumed, .after, read);
        if (offline) |hook| hook.emit(.stream_ring_produced, .before, 0);
        if (self.order_control) |binding| binding.emitFor(.control, .ring_produced, .before, null);
        const write = self.produced.load(.acquire);
        if (self.order_control) |binding| binding.emitFor(.control, .ring_produced, .after, write);
        if (offline) |hook| hook.emit(.stream_ring_produced, .after, write);
        if (observation) |value| value.* = .{ .consumed = read, .produced = write };
        return write - read;
    }
    pub fn writable(self: *const Ring) u64 {
        return self.writableObserved(null);
    }
    pub fn writableObserved(self: *const Ring, observation: ?*ReadCut) u64 {
        return self.writableObservedReplay(observation, null);
    }
    pub fn writableObservedReplay(self: *const Ring, observation: ?*ReadCut, offline: ?OfflineHook) u64 {
        return self.capacity_frames - self.availableObservedReplay(observation, offline);
    }
    /// Control-only. Publish only actual accepted contiguous worker PCM.
    pub fn publish(self: *Ring, pcm: []const f32) error{ InvalidWindow, RingFull }!void {
        return self.publishObserved(pcm, null);
    }
    pub fn publishObserved(self: *Ring, pcm: []const f32, observation: ?*PublishObservation) error{ InvalidWindow, RingFull }!void {
        return self.publishObservedReplay(pcm, observation, null);
    }
    pub fn publishObservedReplay(self: *Ring, pcm: []const f32, observation: ?*PublishObservation, offline: ?OfflineHook) error{ InvalidWindow, RingFull }!void {
        if (observation) |value| value.* = .{};
        if (pcm.len % self.channels != 0 or pcm.len == 0) return error.InvalidWindow;
        const count = pcm.len / self.channels;
        var cut: ReadCut = .{};
        const writable_frames = self.writableObservedReplay(if (observation != null) &cut else null, offline);
        if (observation) |value| value.availability = cut;
        if (count > writable_frames) return error.RingFull;
        const write = self.produced.load(.monotonic);
        if (observation) |value| value.write = write;
        const end = std.math.add(u64, write, count) catch return error.InvalidWindow;
        if (observation) |value| value.end = end;
        for (0..count) |i| {
            const offset = @as(usize, @intCast((write + i) % self.capacity_frames)) * self.channels;
            @memcpy(self.pcm[offset..][0..self.channels], pcm[i * self.channels ..][0..self.channels]);
        }
        if (offline) |hook| hook.emit(.stream_produced, .before, end);
        if (self.order_control) |binding| binding.emitFor(.control, .produced_release, .before, end);
        self.produced.store(end, .release);
        if (self.order_control) |binding| binding.emitFor(.control, .produced_release, .after, end);
        if (offline) |hook| hook.emit(.stream_produced, .after, end);
    }
    pub fn renderProduced(self: *const Ring) u64 {
        return if (self.gated) self.visible_produced.load(.acquire) else self.produced.load(.acquire);
    }
    /// Render-only preflight. Does not consume: every required layer must pass
    /// before the group commits any read or emits any sample.
    pub fn peek(self: *const Ring, cursor: u64, epoch: u64, output: []f32) bool {
        if (comptime @import("builtin").is_test) if (self.test_peek_hook) |hook| hook.call(hook.context, self.consumed.load(.monotonic));
        if (output.len != self.channels or self.stopped.load(.acquire)) return false;
        const read = self.consumed.load(.monotonic);
        const write = self.renderProduced();
        if (read >= write) return false;
        const at = self.coordinate(read) orelse return false;
        if (at.cursor != cursor or at.loop_epoch != epoch) return false;
        const offset = @as(usize, @intCast(read % self.capacity_frames)) * self.channels;
        @memcpy(output, self.pcm[offset..][0..self.channels]);
        return true;
    }
    /// Render-only, after successful whole-group preflight. A frame retained by
    /// this consumer cannot be overwritten before its release publication.
    pub fn consume(self: *Ring) void {
        const read = self.consumed.load(.monotonic);
        std.debug.assert(read < self.produced.load(.acquire));
        const observer = self.consume_observer;
        if (observer) |hook| hook.checkpoint(hook.context, .{ .site = .stream_consumed_release, .edge = .before, .index = hook.index, .generation = hook.generation, .value = read + 1 });
        if (self.order_render) |binding| binding.emitFor(.render, .consumed_release, .before, read + 1);
        self.consumed.store(read + 1, .release);
        if (self.order_render) |binding| binding.emitFor(.render, .consumed_release, .after, read + 1);
        if (observer) |hook| {
            hook.checkpoint(hook.context, .{ .site = .stream_consumed_release, .edge = .after, .index = hook.index, .generation = hook.generation, .value = read + 1 });
            hook.emit(hook.context, .{ .index = hook.index, .generation = hook.generation, .value = read + 1 });
        }
    }
    pub fn retain(self: *Ring) error{InvalidState}!void {
        if (self.stopped.load(.acquire)) return error.InvalidState;
        // Exactly one renderer can consume a ring. Additional ownership leases
        // are tracked by Service; this lease represents a consuming group.
        if (self.references.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return error.InvalidState;
    }
    pub fn release(self: *Ring) void {
        std.debug.assert(self.references.swap(0, .acq_rel) == 1);
    }
};
