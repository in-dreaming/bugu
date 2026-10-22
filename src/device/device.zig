const std = @import("std");
const core = @import("../core/engine.zig");
const runtime = @import("../runtime/runtime.zig");
const music = @import("music");
pub const channel_layout = @import("sme-channels");
pub const render_witness = @import("sme-render-witness");

const c = @cImport({
    @cInclude("miniaudio.h");
});

pub const DeviceConfig = struct {
    sample_rate: u32 = 48_000,
    channels: u32 = 2,
    period_frames: u32 = 256,
    /// Null derives a strict request from the renderer. Conversion is opt-in.
    output_layout_request: ?channel_layout.OutputLayoutRequest = null,
    /// Explicit headless smoke only; never silently fall back to a null device.
    backend: enum { system, null_backend } = .system,
};

pub const max_quantum_frames = 1024;
pub const max_channels = channel_layout.max_channels;
pub const max_pending_samples = max_quantum_frames * max_channels;

pub const FixedQuantumAdapter = struct {
    engine: *core.Engine,
    pending: [max_pending_samples]f32 = undefined,
    pending_start: usize = 0,
    pending_len: usize = 0,

    pub fn init(engine: *core.Engine) core.BuguError!FixedQuantumAdapter {
        try validateAdapter(engine.config.quantum_frames, engine.config.channels, engine.mixer.output_layout);
        return .{ .engine = engine };
    }

    pub fn render(self: *FixedQuantumAdapter, output: []f32, frame_count: u32) void {
        self.renderChecked(output, frame_count) catch @panic("invalid fixed-quantum output view");
    }

    pub fn renderChecked(self: *FixedQuantumAdapter, output: []f32, frame_count: u32) core.BuguError!void {
        const requested_samples = try channel_layout.sampleCount(frame_count, self.engine.config.channels);
        if (output.len != requested_samples) return error.InvalidArgument;
        try self.preflight(frame_count);
        _ = self.engine.telemetry.callback_count.fetchAdd(1, .monotonic);
        self.renderInner(output, frame_count);
    }

    fn preflight(self: *const FixedQuantumAdapter, frame_count: u32) core.BuguError!void {
        try validateAdapter(self.engine.config.quantum_frames, self.engine.config.channels, self.engine.mixer.output_layout);
        try validatePending(self.pending_start, self.pending_len, self.engine.config.channels);
        try checkGenerationFrontier(self.engine.telemetry.rendered_frames.load(.monotonic), frame_count, self.pending_len / self.engine.config.channels, self.engine.config.quantum_frames);
    }

    fn renderInner(self: *FixedQuantumAdapter, output: []f32, frame_count: u32) void {
        const channel_count = self.engine.config.channels;
        const quantum_frames = self.engine.config.quantum_frames;
        const quantum_samples = channel_layout.sampleCount(quantum_frames, channel_count) catch unreachable;
        const requested_samples = channel_layout.sampleCount(frame_count, channel_count) catch unreachable;
        std.debug.assert(self.pending_len % channel_count == 0 and self.pending_start % channel_count == 0);
        var written: usize = 0;

        if (self.pending_len > 0) {
            const take = @min(self.pending_len, requested_samples);
            @memcpy(output[0..take], self.pending[self.pending_start..][0..take]);
            self.pending_start += take;
            self.pending_len -= take;
            written += take;
            if (self.pending_len == 0) {
                self.pending_start = 0;
            }
        }

        while (written < requested_samples) {
            const remaining = requested_samples - written;
            if (remaining >= quantum_samples) {
                self.engine.render(output[written..][0..quantum_samples], quantum_frames);
                written += quantum_samples;
            } else {
                self.engine.render(self.pending[0..quantum_samples], quantum_frames);
                @memcpy(output[written..][0..remaining], self.pending[0..remaining]);
                self.pending_start = remaining;
                self.pending_len = quantum_samples - remaining;
                written += remaining;
            }
        }
    }
};

pub const RuntimeAccounting = struct {
    observation_sequence: u64 = 0,
    generated_frames: u64,
    submitted_frames: u64,
    pending_frames: u64,
    flushed_frames: u64,
    device_epoch: u64,
    epoch_submitted_frames: u64,
    pending_start_frame: u64,
    pending_end_frame: u64,
    delivery: music.DeliveredFrames,
};

/// Production output-only observation, independent of diagnostic/test hooks.
/// Submitted PCM is the negotiated driver output. Discarded PCM is still in
/// the renderer's channel layout: pending tail and shutdown generation are
/// distinct dispositions and must never be counted as submitted audio.
pub const SemanticAudioPcmDisposition = enum { submitted, discarded_pending, discarded_generated };
pub const SemanticAudioCallbackReturn = enum { no_output, loss_zero, no_negotiated_output, sample_count_failed, negotiated_render_failed, completed };
pub const SemanticAudioEvent = union(enum) {
    callback_begin: struct {
        frame_count: u32,
        channels: u16,
        device_epoch: u64,
        output_present: bool,
        accounting: RuntimeAccounting,
    },
    loss_acquired: bool,
    callback_return: struct { kind: SemanticAudioCallbackReturn, failure: ?anyerror, accounting: RuntimeAccounting },
    pcm: struct {
        disposition: SemanticAudioPcmDisposition,
        device_epoch: u64,
        /// Null denotes actual fallback output, not generated engine frames.
        /// Its callback return remains an explicit unsupported/error branch.
        first_frame: ?u64,
        channels: u16,
        samples: []const f32,
    },
    /// Follows the original accounting publication, including empty flushes.
    epoch_changed: struct { flush: music.DeviceFlushRecord, accounting: RuntimeAccounting },
};

/// The sink cannot return a decision or modify engine behavior. Its context
/// and function are pinned and immutable from attachment through real device
/// stop/join and the host's final shutdown drain. Callback and joined-host
/// discard observations are serialized by that existing ownership transfer.
///
/// Every PCM slice is borrowed ONLY for this call. The sink must synchronously
/// make a bounded owned copy into preallocated storage, or mark capture
/// incomplete without copying. It must never retain the slice, allocate,
/// perform file I/O, or call back into the engine. Capture attachment also
/// forbids waits, locks and retries. Only the explicit null-device offline
/// replay attachment permits suspension at verified replay cuts; it does not
/// permit supplying expected PCM or outcomes. Overflow or an unsupported event
/// may poison capture evidence only; original capture playback continues.
pub const SemanticCallbackAdmission = enum { admit, cancel_pending };
pub const SemanticAudioSink = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, SemanticAudioEvent) void,
    /// Null-device offline owner only. Peeks scheduling inputs without consuming
    /// a logical callback. Failure must release waits through genuine stop.
    /// A cancellation is honored only after native expected_stop is observed;
    /// an admitted final callback still executes normally even during stop.
    wait_callback: ?*const fn (*anyopaque, *const std.atomic.Value(bool)) SemanticCallbackAdmission = null,
};

const AccountingPublication = struct {
    sequence: std.atomic.Value(u64) = .init(0),
    generated: std.atomic.Value(u64) = .init(0),
    submitted: std.atomic.Value(u64) = .init(0),
    pending: std.atomic.Value(u64) = .init(0),
    flushed: std.atomic.Value(u64) = .init(0),
    epoch: std.atomic.Value(u64) = .init(1),
    epoch_submitted: std.atomic.Value(u64) = .init(0),
    pending_start: std.atomic.Value(u64) = .init(0),
    pending_end: std.atomic.Value(u64) = .init(0),
    quality: std.atomic.Value(u8) = .init(0),
    delivered: std.atomic.Value(u64) = .init(0),
    delivery_error: std.atomic.Value(u64) = .init(0),
};

pub const RuntimeFixedQuantumAdapter = struct {
    renderer: *runtime.RuntimeRenderer,
    quantum_frames: u32,
    channels: u16,
    pending: [max_pending_samples]f32 = undefined,
    pending_start: usize = 0,
    pending_len: usize = 0,
    origin_render_frame: u64,
    pending_first_frame: u64 = 0,
    pending_epoch: u64 = 1,
    device_epoch: u64 = 1,
    submitted_frames: u64 = 0,
    epoch_submitted_frames: u64 = 0,
    flushed_frames: u64 = 0,
    delivery: music.DeliveredFrames = .unavailable,
    last_flush: ?music.DeviceFlushRecord = null,
    publication: AccountingPublication = .{},
    // Set/removed only with actual renderer/device quiescence. Storage, adapter
    // and renderer remain pinned until detach, even after witness closure.
    witness: ?struct {
        bridge: *render_witness.Bridge,
        session: render_witness.Session,
        // Attach or most recent observed callback boundary. Device shutdown
        // draining and direct renderer calls do not silently extend coverage.
        render_frame: u64,
        render_call_sequence: u64,
        render_call_exhausted: bool,
    } = null,
    witness_callback_active: bool = false,
    // Changed only through the backend's host-exclusive attachment API.
    // Retained across stop/changeEpoch and all shutdown drain invocations.
    semantic_audio: ?SemanticAudioSink = null,

    /// Parameter-only validation; never constructs the large pending buffer.
    pub fn validateConfig(renderer: *const runtime.RuntimeRenderer, quantum_frames: u32, channel_count: u16) core.BuguError!void {
        try validateAdapter(quantum_frames, channel_count, renderer.mixer.output_layout);
    }

    pub fn init(renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channel_count: u16) core.BuguError!RuntimeFixedQuantumAdapter {
        var adapter: RuntimeFixedQuantumAdapter = undefined;
        try adapter.initInPlace(renderer, quantum_frames, channel_count);
        return adapter;
    }

    /// Host-exclusive construction at the final address; no adapter-sized
    /// temporary is placed on the caller's bounded stack. All fallible checks
    /// precede destination mutation. Do not reset a live/bound adapter here.
    pub fn initInPlace(self: *RuntimeFixedQuantumAdapter, renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channel_count: u16) core.BuguError!void {
        try validateConfig(renderer, quantum_frames, channel_count);
        self.renderer = renderer;
        self.quantum_frames = quantum_frames;
        self.channels = channel_count;
        // Pending PCM remains undefined until actual generation fills it;
        // pending_len=0 prevents reads and avoids a large initialization copy.
        self.pending_start = 0;
        self.pending_len = 0;
        self.origin_render_frame = renderer.renderFrame();
        self.pending_first_frame = 0;
        self.pending_epoch = 1;
        self.device_epoch = 1;
        self.submitted_frames = 0;
        self.epoch_submitted_frames = 0;
        self.flushed_frames = 0;
        self.delivery = .unavailable;
        self.last_flush = null;
        self.publication = .{};
        self.witness = null;
        self.witness_callback_active = false;
        self.semantic_audio = null;
        self.publishAccounting();
    }

    pub fn render(self: *RuntimeFixedQuantumAdapter, output: []f32, frame_count: u32) void {
        self.renderChecked(output, frame_count) catch @panic("invalid runtime fixed-quantum output view");
    }

    pub fn renderChecked(self: *RuntimeFixedQuantumAdapter, output: []f32, frame_count: u32) core.BuguError!void {
        const witnessing = self.beginWitnessCallback(.adapter_call, frame_count, self.channels);
        var witness_failure: render_witness.Failure = .callback_error;
        defer self.endWitnessCallback(witnessing, witness_failure);
        const requested_samples = try checkedSamples(frame_count, self.channels);
        if (output.len != requested_samples) return error.InvalidArgument;
        try self.preflight(frame_count);
        _ = self.renderer.telemetry.callback_count.fetchAdd(1, .monotonic);
        self.renderInner(output, frame_count);
        witness_failure = .none;
    }

    /// Host only. The token excludes registered callbacks, not just a gap
    /// between callbacks. Also serialize any unregistered direct adapter
    /// caller through its entire call, and exclude the witness consumer.
    pub fn attachWitnessQuiescent(self: *RuntimeFixedQuantumAdapter, bridge: *render_witness.Bridge, token: runtime.RuntimeRenderer.DeviceQuiescence) !render_witness.Session {
        try self.renderer.validateDeviceQuiescence(token);
        if (self.witness != null) return error.InvalidState;
        const session = try bridge.attachQuiescent(self);
        const observation = self.witnessObservation();
        self.witness = .{
            .bridge = bridge,
            .session = session,
            .render_frame = observation.render_frame,
            .render_call_sequence = observation.render_call_sequence,
            .render_call_exhausted = observation.render_call_exhausted,
        };
        self.witness_callback_active = false;
        return session;
    }

    /// Host fallback when there is no next callback to acknowledge stop. This
    /// seals only the metadata interval; existing audio lifetime is unchanged.
    pub fn closeWitnessQuiescent(self: *RuntimeFixedQuantumAdapter, token: runtime.RuntimeRenderer.DeviceQuiescence) !void {
        try self.renderer.validateDeviceQuiescence(token);
        const binding = self.witness orelse return error.InvalidState;
        const observation = self.witnessObservation();
        self.checkWitnessFrontier(observation);
        try binding.bridge.closeQuiescent(binding.session, self, observation);
        self.witness_callback_active = false;
    }

    /// Closed does not make the pointer safe to free: callbacks still inspect
    /// this binding. Require actual quiescence and serialized consumer lifetime.
    pub fn detachWitnessQuiescent(self: *RuntimeFixedQuantumAdapter, token: runtime.RuntimeRenderer.DeviceQuiescence) !void {
        try self.renderer.validateDeviceQuiescence(token);
        const binding = self.witness orelse return error.InvalidState;
        try binding.bridge.detachQuiescent(binding.session, self);
        self.witness = null;
        self.witness_callback_active = false;
    }

    fn witnessObservation(self: *const RuntimeFixedQuantumAdapter) render_witness.Observation {
        const frame = self.renderer.renderFrame();
        const call = self.renderer.callObservation();
        const pending = if (self.channels != 0) self.pending_len / self.channels else 0;
        const first = if (pending != 0) self.pending_first_frame else frame;
        return .{
            .render_frame = frame,
            .render_call_sequence = call.sequence,
            .render_call_exhausted = call.exhausted,
            .generated_frames = frame -| self.origin_render_frame,
            .submitted_frames = self.submitted_frames,
            .epoch_submitted_frames = self.epoch_submitted_frames,
            .pending_frames = pending,
            .pending_start_frame = first,
            .pending_end_frame = first +| pending,
            .flushed_frames = self.flushed_frames,
            .device_epoch = self.device_epoch,
            .delivery = switch (self.delivery) {
                .unavailable => .{},
                .exact => |frames| .{ .quality = .exact, .frames = frames },
                .estimated => |value| .{ .quality = .estimated, .frames = value.frames, .max_error_frames = value.max_error_frames },
            },
        };
    }

    fn checkWitnessFrontier(self: *RuntimeFixedQuantumAdapter, observation: render_witness.Observation) void {
        const binding = self.witness orelse return;
        if (observation.render_frame != binding.render_frame or observation.render_call_sequence != binding.render_call_sequence or observation.render_call_exhausted != binding.render_call_exhausted) {
            binding.bridge.observeUncoveredRender(binding.session);
        }
    }

    fn beginWitnessCallback(self: *RuntimeFixedQuantumAdapter, source: render_witness.Source, frames: u32, channels: u16) bool {
        const binding = self.witness orelse return false;
        // Negotiated output can split one real device callback into chunks.
        // Keep its outer interval; never invent a callback for each chunk.
        if (self.witness_callback_active) return false;
        const observation = self.witnessObservation();
        self.checkWitnessFrontier(observation);
        const entered = binding.bridge.beginCallback(binding.session, source, frames, channels, observation);
        self.witness_callback_active = entered;
        return entered;
    }

    fn endWitnessCallback(self: *RuntimeFixedQuantumAdapter, entered: bool, failure: render_witness.Failure) void {
        if (!entered) return;
        const binding = self.witness orelse unreachable;
        const observation = self.witnessObservation();
        binding.bridge.endCallback(binding.session, observation, failure);
        self.witness.?.render_frame = observation.render_frame;
        self.witness.?.render_call_sequence = observation.render_call_sequence;
        self.witness.?.render_call_exhausted = observation.render_call_exhausted;
        self.witness_callback_active = false;
    }

    fn renderWitnessQuantum(self: *RuntimeFixedQuantumAdapter, output: []f32) void {
        if (self.witness_callback_active) if (self.witness) |binding| {
            binding.bridge.beginQuantum(binding.session, self.quantum_frames, self.channels, self.witnessObservation());
        };
        // Always the sole production renderer. Evidence failure never changes
        // PCM, skips a render, substitutes silence, or takes an offline route.
        self.renderer.renderFromAdapter(output, self.quantum_frames, self.channels);
        if (self.witness_callback_active) if (self.witness) |binding| {
            binding.bridge.endQuantum(binding.session, self.witnessObservation());
        };
    }

    fn preflight(self: *const RuntimeFixedQuantumAdapter, frame_count: u32) core.BuguError!void {
        try validateAdapter(self.quantum_frames, self.channels, self.renderer.mixer.output_layout);
        try validatePending(self.pending_start, self.pending_len, self.channels);
        const frame = self.renderer.renderFrame();
        if (frame < self.origin_render_frame) return error.InvalidState;
        try checkGenerationFrontier(frame, frame_count, self.pending_len / self.channels, self.quantum_frames);
        _ = std.math.add(u64, self.submitted_frames, frame_count) catch return error.ArithmeticOverflow;
        _ = std.math.add(u64, self.epoch_submitted_frames, frame_count) catch return error.ArithmeticOverflow;
    }

    fn renderInner(self: *RuntimeFixedQuantumAdapter, output: []f32, frame_count: u32) void {
        std.debug.assert(self.pending_len % self.channels == 0 and self.pending_start % self.channels == 0);
        // Epoch changes require host quiescence and flush. Never copy old PCM.
        std.debug.assert(self.pending_len == 0 or self.pending_epoch == self.device_epoch);
        const quantum_samples = checkedSamples(self.quantum_frames, self.channels) catch unreachable;
        const requested_samples = checkedSamples(frame_count, self.channels) catch unreachable;
        var written: usize = 0;
        if (self.pending_len > 0) {
            const take = @min(self.pending_len, requested_samples);
            @memcpy(output[0..take], self.pending[self.pending_start..][0..take]);
            self.pending_start += take;
            self.pending_len -= take;
            self.pending_first_frame += take / self.channels;
            written += take;
            if (self.pending_len == 0) self.pending_start = 0;
        }
        while (written < requested_samples) {
            const remaining = requested_samples - written;
            if (remaining >= quantum_samples) {
                self.renderWitnessQuantum(output[written..][0..quantum_samples]);
                written += quantum_samples;
            } else {
                const first = self.renderer.renderFrame();
                self.renderWitnessQuantum(self.pending[0..quantum_samples]);
                @memcpy(output[written..][0..remaining], self.pending[0..remaining]);
                self.pending_start = remaining;
                self.pending_len = quantum_samples - remaining;
                self.pending_first_frame = first + remaining / self.channels;
                self.pending_epoch = self.device_epoch;
                written += remaining;
            }
        }
        self.submitted_frames += frame_count;
        self.epoch_submitted_frames += frame_count;
        self.publishAccounting();
    }

    /// Control/host only, after the callback has quiesced. This operation drops
    /// only a genuinely lost device's pending PCM, never music stop/pause PCM.
    pub fn changeEpoch(self: *RuntimeFixedQuantumAdapter, next: u64) core.BuguError!music.DeviceFlushRecord {
        if (next <= self.device_epoch) return error.InvalidState;
        const count = self.pending_len / self.channels;
        const first = if (count != 0) self.pending_first_frame else self.renderer.renderFrame();
        const record: music.DeviceFlushRecord = .{ .old_device_epoch = @enumFromInt(self.device_epoch), .new_device_epoch = @enumFromInt(next), .discarded = .{ .start = first, .end = first + count }, .hardware_uncertainty = null };
        if (count != 0) if (self.semantic_audio) |sink| sink.call(sink.context, .{ .pcm = .{
            .disposition = .discarded_pending,
            .device_epoch = self.device_epoch,
            .first_frame = first,
            .channels = self.channels,
            .samples = self.pending[self.pending_start..][0..self.pending_len],
        } });
        self.flushed_frames += count;
        self.pending_len = 0;
        self.pending_start = 0;
        self.pending_first_frame = record.discarded.end;
        self.pending_epoch = next;
        self.device_epoch = next;
        self.epoch_submitted_frames = 0;
        self.delivery = .unavailable;
        self.last_flush = record;
        self.publishAccounting();
        if (self.semantic_audio) |sink| sink.call(sink.context, .{ .epoch_changed = .{ .flush = record, .accounting = self.accounting() } });
        return record;
    }

    /// Host-only shutdown progress after callbacks have stopped. No driver
    /// callback is needed; exactly generated frames are charged as discarded.
    pub fn drainShutdownQuiescent(self: *RuntimeFixedQuantumAdapter, token: runtime.RuntimeRenderer.DeviceQuiescence) !void {
        if (self.pending_len != 0) return error.InvalidState;
        const samples = try checkedSamples(self.quantum_frames, self.channels);
        const before = self.renderer.renderFrame();
        _ = try std.math.add(u64, self.flushed_frames, self.quantum_frames);
        try self.renderer.renderShutdownQuiescent(token, self.pending[0..samples], self.quantum_frames, self.channels);
        if (self.semantic_audio) |sink| sink.call(sink.context, .{ .pcm = .{
            .disposition = .discarded_generated,
            .device_epoch = self.device_epoch,
            .first_frame = if (self.renderer.renderFrame() != before) before else null,
            .channels = self.channels,
            .samples = self.pending[0..samples],
        } });
        self.flushed_frames += self.renderer.renderFrame() - before;
        self.pending_first_frame = self.renderer.renderFrame();
        self.publishAccounting();
    }

    /// Adapter owner, or host after callback quiescence. Live readers use
    /// tryAccounting; external observers never write the callback-owned fields.
    pub fn observeDelivery(self: *RuntimeFixedQuantumAdapter, epoch: u64, delivered: music.DeliveredFrames) core.BuguError!void {
        if (epoch != self.device_epoch) return error.InvalidState;
        const observation: music.DeliveryObservation = .{ .device_epoch = @enumFromInt(epoch), .render_frame = self.renderer.renderFrame(), .submitted_frames = self.epoch_submitted_frames, .delivered_frames = delivered };
        observation.validate() catch return error.InvalidState;
        self.delivery = delivered;
        self.publishAccounting();
    }

    fn publishAccounting(self: *RuntimeFixedQuantumAdapter) void {
        const snapshot = self.accounting();
        const p = &self.publication;
        const sequence = p.sequence.load(.seq_cst);
        p.sequence.store(sequence +% 1, .seq_cst);
        p.generated.store(snapshot.generated_frames, .seq_cst);
        p.submitted.store(snapshot.submitted_frames, .seq_cst);
        p.pending.store(snapshot.pending_frames, .seq_cst);
        p.flushed.store(snapshot.flushed_frames, .seq_cst);
        p.epoch.store(snapshot.device_epoch, .seq_cst);
        p.epoch_submitted.store(snapshot.epoch_submitted_frames, .seq_cst);
        p.pending_start.store(snapshot.pending_start_frame, .seq_cst);
        p.pending_end.store(snapshot.pending_end_frame, .seq_cst);
        switch (snapshot.delivery) {
            .unavailable => {
                p.quality.store(0, .seq_cst);
                p.delivered.store(0, .seq_cst);
                p.delivery_error.store(0, .seq_cst);
            },
            .exact => |frames| {
                p.quality.store(1, .seq_cst);
                p.delivered.store(frames, .seq_cst);
                p.delivery_error.store(0, .seq_cst);
            },
            .estimated => |v| {
                p.quality.store(2, .seq_cst);
                p.delivered.store(v.frames, .seq_cst);
                p.delivery_error.store(v.max_error_frames, .seq_cst);
            },
        }
        p.sequence.store(sequence +% 2, .seq_cst);
    }

    /// Three bounded attempts; null means observation contention, never a fake
    /// zero or an inconsistent accounting tuple. Every shared datum is atomic.
    /// Values describe the last fully published callback/flush/observation.
    pub fn tryAccounting(self: *const RuntimeFixedQuantumAdapter) ?RuntimeAccounting {
        const p = &self.publication;
        for (0..3) |_| {
            const sequence = p.sequence.load(.seq_cst);
            if (sequence & 1 != 0) continue;
            var result: RuntimeAccounting = .{
                .observation_sequence = sequence,
                .generated_frames = p.generated.load(.seq_cst),
                .submitted_frames = p.submitted.load(.seq_cst),
                .pending_frames = p.pending.load(.seq_cst),
                .flushed_frames = p.flushed.load(.seq_cst),
                .device_epoch = p.epoch.load(.seq_cst),
                .epoch_submitted_frames = p.epoch_submitted.load(.seq_cst),
                .pending_start_frame = p.pending_start.load(.seq_cst),
                .pending_end_frame = p.pending_end.load(.seq_cst),
                .delivery = .unavailable,
            };
            const quality = p.quality.load(.seq_cst);
            const delivered = p.delivered.load(.seq_cst);
            const delivery_error = p.delivery_error.load(.seq_cst);
            if (sequence != p.sequence.load(.seq_cst)) continue;
            result.delivery = switch (quality) {
                0 => .unavailable,
                1 => .{ .exact = delivered },
                2 => .{ .estimated = .{ .frames = delivered, .max_error_frames = delivery_error } },
                else => return null,
            };
            return result;
        }
        return null;
    }

    /// Read on adapter owner or after quiescence; not a racy control snapshot.
    pub fn accounting(self: *const RuntimeFixedQuantumAdapter) RuntimeAccounting {
        const pending = self.pending_len / self.channels;
        const first = if (pending != 0) self.pending_first_frame else self.renderer.renderFrame();
        return .{ .generated_frames = self.renderer.renderFrame() - self.origin_render_frame, .submitted_frames = self.submitted_frames, .pending_frames = pending, .flushed_frames = self.flushed_frames, .device_epoch = self.device_epoch, .epoch_submitted_frames = self.epoch_submitted_frames, .pending_start_frame = first, .pending_end_frame = first + pending, .delivery = self.delivery };
    }
};

pub const OfflinePcm = struct {
    samples: []f32,
    frame_count: u32,
    sample_rate: u32,
    layout: channel_layout.ChannelLayout,
    pub fn deinit(self: OfflinePcm, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
    }
};

pub const OfflineBackend = struct {
    engine: *core.Engine,
    adapter: FixedQuantumAdapter,

    pub fn init(engine: *core.Engine) OfflineBackend {
        return .{ .engine = engine, .adapter = FixedQuantumAdapter.init(engine) catch unreachable };
    }

    pub fn renderFrames(self: *OfflineBackend, allocator: std.mem.Allocator, frame_count: u32) ![]f32 {
        const buffer = try allocator.alloc(f32, try checkedSamples(frame_count, self.engine.config.channels));
        errdefer allocator.free(buffer);
        try self.adapter.renderChecked(buffer, frame_count);
        return buffer;
    }

    pub fn renderPcm(self: *OfflineBackend, allocator: std.mem.Allocator, frame_count: u32) !OfflinePcm {
        return .{ .samples = try self.renderFrames(allocator, frame_count), .frame_count = frame_count, .sample_rate = self.engine.config.sample_rate, .layout = self.engine.mixer.output_layout };
    }

    pub fn renderWav(self: *OfflineBackend, writer: *std.Io.Writer, frame_count: u32) !void {
        try writeRenderedWav(&self.adapter, writer, frame_count, self.engine.config.sample_rate, self.engine.config.quantum_frames, self.engine.mixer.output_layout);
    }

    pub fn renderWavFile(self: *OfflineBackend, io: std.Io, path: []const u8, seconds: f32) !void {
        const frames = try durationFrames(seconds, self.engine.config.sample_rate);
        // Validate the complete header before creating/truncating the file.
        _ = try wavSizes(frames, self.engine.config.sample_rate, self.engine.mixer.output_layout);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var writer_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &writer_buffer);
        try self.renderWav(&writer.interface, frames);
        try writer.interface.flush();
    }
};

pub const RuntimeOfflineBackend = struct {
    renderer: *runtime.RuntimeRenderer,
    adapter: RuntimeFixedQuantumAdapter,
    loss_signal: music.DeviceRecoveryV1.Signal = .{},
    loss: ?music.DeviceRecoveryV1.Loss = null,
    loss_queued: bool = false,
    lost: bool = false,

    pub fn init(renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channel_count: u16) core.BuguError!RuntimeOfflineBackend {
        var backend: RuntimeOfflineBackend = undefined;
        try backend.initInPlace(renderer, quantum_frames, channel_count);
        return backend;
    }

    /// Host-exclusive construction in final storage. The adapter performs all
    /// validation before mutation; remaining field initialization cannot fail.
    pub fn initInPlace(self: *RuntimeOfflineBackend, renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channel_count: u16) core.BuguError!void {
        try self.adapter.initInPlace(renderer, quantum_frames, channel_count);
        self.renderer = renderer;
        self.loss_signal = .{};
        self.loss = null;
        self.loss_queued = false;
        self.lost = false;
    }

    pub fn renderFrames(self: *RuntimeOfflineBackend, allocator: std.mem.Allocator, frame_count: u32) ![]f32 {
        if (self.lost or self.loss_signal.pending.load(.acquire)) return error.DeviceUnavailable;
        const buffer = try allocator.alloc(f32, try checkedSamples(frame_count, self.adapter.channels));
        errdefer allocator.free(buffer);
        try self.adapter.renderChecked(buffer, frame_count);
        return buffer;
    }

    /// Same bounded notification cell as the real device callback. Offline
    /// callers serialize render/service just as a stopped real callback does.
    pub fn signalLost(self: *RuntimeOfflineBackend) bool {
        return self.loss_signal.notify();
    }
    pub fn notifyLost(self: *RuntimeOfflineBackend) !void {
        _ = self.signalLost();
        try self.serviceDeviceLoss(.restart_at_bar);
    }
    pub fn serviceDeviceLoss(self: *RuntimeOfflineBackend, policy: music.DeviceRecoveryPolicy) !void {
        if (!self.loss_signal.pending.load(.acquire)) return;
        try checkRuntimeLossThread(self.renderer);
        self.lost = true;
        try publishRuntimeLoss(self, policy);
    }
    pub fn reopen(self: *RuntimeOfflineBackend, epoch: u64) !void {
        if (!self.lost or epoch != self.adapter.device_epoch or !self.loss_queued) return error.InvalidState;
        if (self.renderer.runtime.music_runtime) |owner| if (owner.usesDeviceControlV1() and !owner.deviceEpochAcceptedV1(epoch)) return error.DrainPending;
        self.loss = null;
        self.loss_queued = false;
        self.loss_signal.pending.store(false, .release);
        self.lost = false;
    }
    pub fn drainShutdown(self: *RuntimeOfflineBackend) !void {
        if (!self.lost) return error.InvalidState;
        const token = try self.renderer.acquireDeviceQuiescence();
        defer self.renderer.releaseDeviceQuiescence(token) catch unreachable;
        try self.adapter.drainShutdownQuiescent(token);
    }

    pub fn renderPcm(self: *RuntimeOfflineBackend, allocator: std.mem.Allocator, frame_count: u32) !OfflinePcm {
        return .{ .samples = try self.renderFrames(allocator, frame_count), .frame_count = frame_count, .sample_rate = self.renderer.mixer.sample_rate, .layout = self.renderer.mixer.output_layout };
    }

    pub fn renderWav(self: *RuntimeOfflineBackend, writer: *std.Io.Writer, frame_count: u32) !void {
        try writeRenderedWav(&self.adapter, writer, frame_count, self.renderer.mixer.sample_rate, self.adapter.quantum_frames, self.renderer.mixer.output_layout);
    }

    pub fn renderWavFile(self: *RuntimeOfflineBackend, io: std.Io, path: []const u8, seconds: f32) !void {
        const frames = try durationFrames(seconds, self.renderer.mixer.sample_rate);
        _ = try wavSizes(frames, self.renderer.mixer.sample_rate, self.renderer.mixer.output_layout);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var writer_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &writer_buffer);
        try self.renderWav(&writer.interface, frames);
        try writer.interface.flush();
    }
};

/// The backend-native speaker set and the application callback set are checked
/// independently: miniaudio may otherwise silently convert between them.
pub const NegotiatedSpeakers = struct {
    layout: channel_layout.ChannelLayout,
    order: [max_channels]channel_layout.Speaker,

    pub fn init(order: []const channel_layout.Speaker) core.BuguError!NegotiatedSpeakers {
        if (order.len == 0 or order.len > max_channels) return error.UnsupportedChannelLayout;
        var mask: u32 = 0;
        var result: NegotiatedSpeakers = undefined;
        for (order, 0..) |speaker, i| {
            const bit = @intFromEnum(speaker);
            if (bit & ~channel_layout.known_mask != 0 or @popCount(bit) != 1 or mask & bit != 0) return error.UnsupportedChannelLayout;
            mask |= bit;
            result.order[i] = speaker;
        }
        result.layout = try channel_layout.ChannelLayout.init(.explicit_mask, @intCast(order.len), mask);
        @memset(result.order[order.len..], .fc);
        return result;
    }
};

pub const NegotiationRecord = struct {
    requested: channel_layout.ChannelLayout,
    target: channel_layout.ChannelLayout,
    negotiated: NegotiatedSpeakers,
    callback: NegotiatedSpeakers,
    matrix_id: u64,
    reason: enum { strict_match, explicit_conversion },
    backend: enum { unbound, system, null_backend } = .unbound,
};

pub const NegotiatedOutput = struct {
    record: NegotiationRecord,
    matrix: channel_layout.Matrix,
    /// Applied to canonical target PCM before writing the callback buffer.
    permutation: channel_layout.Permutation,
    /// Audited native ordering. Miniaudio's precompiled converter maps the
    /// declared callback map to this native map; it must not change speaker set.
    native_permutation: channel_layout.Permutation,

    pub fn prepare(request: channel_layout.OutputLayoutRequest, native_order: []const channel_layout.Speaker, callback_order: []const channel_layout.Speaker) core.BuguError!NegotiatedOutput {
        const target = try request.target();
        const native = try NegotiatedSpeakers.init(native_order);
        const callback = try NegotiatedSpeakers.init(callback_order);
        const matrix = try channel_layout.Matrix.compile(request.layout, target);
        return .{
            .record = .{ .requested = request.layout, .target = target, .negotiated = native, .callback = callback, .matrix_id = matrix.id, .reason = if (request.policy == .strict_match) .strict_match else .explicit_conversion },
            .matrix = matrix,
            .permutation = try channel_layout.Permutation.compile(target, callback_order),
            .native_permutation = try channel_layout.Permutation.compile(target, native_order),
        };
    }

    /// Bounded chunks use caller-owned scratch; matrices/permutations were
    /// compiled before device start. No allocation, file I/O, locking or lookup.
    pub fn render(self: *const NegotiatedOutput, adapter: anytype, scratch: *[max_pending_samples]f32, output: []f32, frame_count: u32) core.BuguError!void {
        const witnessing = if (@TypeOf(adapter) == *RuntimeFixedQuantumAdapter) adapter.beginWitnessCallback(.negotiated_call, frame_count, self.matrix.output.count) else false;
        var witness_failure: render_witness.Failure = .callback_error;
        defer if (@TypeOf(adapter) == *RuntimeFixedQuantumAdapter) adapter.endWitnessCallback(witnessing, witness_failure);
        if (output.len != try checkedSamples(frame_count, self.matrix.output.count)) return error.InvalidArgument;
        if (@TypeOf(adapter) == *RuntimeFixedQuantumAdapter) {
            if (!channel_layout.ChannelLayout.eql(self.matrix.input, adapter.renderer.mixer.output_layout)) return error.UnsupportedChannelLayout;
            try adapter.preflight(frame_count);
            _ = adapter.renderer.telemetry.callback_count.fetchAdd(1, .monotonic);
        } else if (@TypeOf(adapter) == *FixedQuantumAdapter) {
            if (!channel_layout.ChannelLayout.eql(self.matrix.input, adapter.engine.mixer.output_layout)) return error.UnsupportedChannelLayout;
            try adapter.preflight(frame_count);
            _ = adapter.engine.telemetry.callback_count.fetchAdd(1, .monotonic);
        } else @compileError("output conversion requires a fixed-quantum adapter");
        var done: usize = 0;
        while (done < frame_count) {
            const frames: u32 = @intCast(@min(frame_count - done, max_quantum_frames));
            const source_samples = try checkedSamples(frames, self.matrix.input.count);
            adapter.renderInner(scratch[0..source_samples], frames);
            for (0..frames) |frame| {
                const source_offset = try checkedSamples(frame, self.matrix.input.count);
                const output_offset = try checkedSamples(done + frame, self.matrix.output.count);
                const destination = output[output_offset..][0..self.matrix.output.count];
                @memset(destination, 0);
                self.matrix.addFrame(scratch[source_offset..][0..self.matrix.input.count], destination, 1);
                self.permutation.apply(destination);
            }
            done += frames;
        }
        witness_failure = .none;
    }
};

fn validatePending(start: usize, len: usize, count: u16) core.BuguError!void {
    if (start > max_pending_samples or len > max_pending_samples - start or start % count != 0 or len % count != 0) return error.InvalidState;
}

/// The callback can consume a single frame while generating a whole quantum.
/// Reject the complete rounded frontier before copying or changing any counts.
fn checkGenerationFrontier(current: u64, requested: u32, pending_frames: usize, quantum: u32) core.BuguError!void {
    const needed: u64 = @as(u64, requested) -| @as(u64, pending_frames);
    const quanta = (needed + quantum - 1) / quantum;
    const generated = std.math.mul(u64, quanta, quantum) catch return error.ArithmeticOverflow;
    _ = std.math.add(u64, current, generated) catch return error.ArithmeticOverflow;
}

fn checkedSamples(frames: usize, count: u16) core.BuguError!usize {
    return channel_layout.sampleCount(frames, count);
}

fn validateAdapter(quantum_frames: u32, count: u16, layout: channel_layout.ChannelLayout) core.BuguError!void {
    if (quantum_frames == 0 or quantum_frames > max_quantum_frames) return error.InvalidArgument;
    try layout.validate();
    if (count != layout.count) return error.UnsupportedChannelLayout;
    if (try checkedSamples(quantum_frames, count) > max_pending_samples) return error.InvalidArgument;
}

fn deviceRequest(config: DeviceConfig, source: channel_layout.ChannelLayout, sample_rate: u32) core.BuguError!channel_layout.OutputLayoutRequest {
    if (config.sample_rate != sample_rate or config.period_frames == 0) return error.InvalidArgument;
    const request = config.output_layout_request orelse channel_layout.OutputLayoutRequest{ .layout = source };
    if (!channel_layout.ChannelLayout.eql(request.layout, source)) return error.UnsupportedChannelLayout;
    const target = try request.target();
    if (config.channels != target.count) return error.UnsupportedChannelLayout;
    return request;
}

fn verifyExisting(output: NegotiatedOutput, next: DeviceConfig, current: DeviceConfig, request: channel_layout.OutputLayoutRequest) core.BuguError!void {
    const target = try request.target();
    const reason: @TypeOf(output.record.reason) = if (request.policy == .strict_match) .strict_match else .explicit_conversion;
    if (!channel_layout.ChannelLayout.eql(target, output.record.target) or reason != output.record.reason or next.backend != current.backend or next.period_frames != current.period_frames) return error.InvalidState;
}

fn maSpeaker(speaker: channel_layout.Speaker) c.ma_channel {
    // The 18 WAVE speaker bits correspond to miniaudio's contiguous positions.
    return @intCast(@ctz(@intFromEnum(speaker)) + c.MA_CHANNEL_FRONT_LEFT);
}

fn readMaSpeakers(count: u32, map: []const c.ma_channel) core.BuguError!NegotiatedSpeakers {
    if (count == 0 or count > max_channels or count > map.len) return error.UnsupportedChannelLayout;
    var speakers: [max_channels]channel_layout.Speaker = @splat(.fc);
    for (map[0..count], 0..) |position, i| {
        if (count == 1 and position == c.MA_CHANNEL_MONO) {
            speakers[i] = .fc;
        } else {
            if (position < c.MA_CHANNEL_FRONT_LEFT or position > c.MA_CHANNEL_TOP_BACK_RIGHT) return error.UnsupportedChannelLayout;
            speakers[i] = @enumFromInt(@as(u32, 1) << @as(u5, @intCast(position - c.MA_CHANNEL_FRONT_LEFT)));
        }
    }
    return NegotiatedSpeakers.init(speakers[0..count]);
}

fn openDevice(self: anytype, config: DeviceConfig, request: channel_layout.OutputLayoutRequest, callback: c.ma_device_data_proc) core.BuguError!void {
    const target = try request.target();
    var map: [max_channels]c.ma_channel = undefined;
    for (target.order[0..target.count], 0..) |speaker, i| map[i] = maSpeaker(speaker);
    var ma_config = c.ma_device_config_init(c.ma_device_type_playback);
    ma_config.playback.format = c.ma_format_f32;
    ma_config.playback.channels = target.count;
    ma_config.playback.pChannelMap = &map;
    ma_config.sampleRate = config.sample_rate;
    ma_config.periodSizeInFrames = config.period_frames;
    ma_config.dataCallback = callback;
    if (@TypeOf(self) == *RuntimeMiniaudioBackend) ma_config.notificationCallback = runtimeNotificationCallback;
    ma_config.pUserData = self;
    // No clipping/normalization in the negotiated conversion. Device PCM must
    // preserve the frozen matrix, including values above unity.
    ma_config.noClip = c.MA_TRUE;
    // Prevent WASAPI from hiding channel conversion behind AUTOCONVERTPCM.
    ma_config.wasapi.noAutoConvertSRC = c.MA_TRUE;
    var context: ?*c.ma_context = null;
    if (config.backend == .null_backend) {
        const backends = [_]c.ma_backend{c.ma_backend_null};
        if (c.ma_context_init(&backends, 1, null, &self.context) != c.MA_SUCCESS) return error.DeviceUnavailable;
        self.context_initialized = true;
        context = &self.context;
    }
    errdefer closeContext(self);
    if (c.ma_device_init(context, &ma_config, &self.device) != c.MA_SUCCESS) return error.DeviceUnavailable;
    errdefer c.ma_device_uninit(&self.device);
    const is_null = self.device.pContext.*.backend == c.ma_backend_null;
    if (is_null and config.backend != .null_backend) return error.DeviceUnavailable;
    if (self.device.playback.format != c.ma_format_f32) return error.UnsupportedChannelLayout;
    const native = try readMaSpeakers(self.device.playback.internalChannels, &self.device.playback.internalChannelMap);
    const external = try readMaSpeakers(self.device.playback.channels, &self.device.playback.channelMap);
    self.output = try NegotiatedOutput.prepare(request, native.order[0..native.layout.count], external.order[0..external.layout.count]);
    self.output.?.record.backend = if (is_null) .null_backend else .system;
}

fn closeContext(self: anytype) void {
    if (self.context_initialized) {
        _ = c.ma_context_uninit(&self.context);
        self.context_initialized = false;
    }
}

fn closeDevice(self: anytype) void {
    c.ma_device_uninit(&self.device);
    closeContext(self);
}

pub const RuntimeDeviceState = enum { closed, open, running, lost, reopening, stopped };

/// Host-only, after the real device has joined its callbacks or the offline
/// caller has serialized access. The exclusive renderer token is transferred
/// to Control only after its one event slot is successfully reserved.
fn checkRuntimeLossThread(renderer: *runtime.RuntimeRenderer) !void {
    if (renderer.runtime.music_runtime) |owner| if (owner.usesDeviceControlV1()) try owner.validateDeviceServiceThreadV1();
}
fn publishRuntimeLoss(self: anytype, policy: music.DeviceRecoveryPolicy) !void {
    try checkRuntimeLossThread(self.renderer);
    if (self.loss_queued) return;
    const token = try self.renderer.acquireDeviceQuiescence();
    var transferred = false;
    defer if (!transferred) self.renderer.releaseDeviceQuiescence(token) catch unreachable;
    if (self.loss == null) {
        const epoch = try std.math.add(u64, self.adapter.device_epoch, 1);
        const flush = try self.adapter.changeEpoch(epoch);
        self.loss = .{ .flush = flush, .render_frame = self.renderer.renderFrame(), .submitted_frames = self.adapter.submitted_frames, .sample_rate = self.renderer.mixer.sample_rate, .channels = self.renderer.mixer.output_layout.count, .channel_mask = self.renderer.mixer.output_layout.mask, .policy = policy };
    }
    if (self.renderer.runtime.music_runtime) |owner| if (owner.usesDeviceControlV1()) {
        try owner.enqueueDeviceLossV1(self.loss.?, token);
        transferred = true;
    };
    self.loss_queued = true;
}

fn runtimeNotificationCallback(notification: [*c]const c.ma_device_notification) callconv(.c) void {
    if (notification == null or notification.*.pDevice == null) return;
    const backend: *RuntimeMiniaudioBackend = @ptrCast(@alignCast(notification.*.pDevice.*.pUserData));
    if (backend.expected_stop.load(.acquire)) return;
    switch (notification.*.type) {
        c.ma_device_notification_type_stopped, c.ma_device_notification_type_rerouted, c.ma_device_notification_type_interruption_began => _ = backend.signalLost(),
        else => {},
    }
}

pub const RuntimeMiniaudioBackend = struct {
    /// Test observer only: actual negotiated callback output, never a render
    /// source. Borrowed context must survive device callback quiescence.
    pub const TestPcm = struct {
        context: *anyopaque,
        call: *const fn (*anyopaque, u64, u64, u16, []const f32) void,
    };
    /// Passive facts from the original callback branch sites. The fixed
    /// consumer owns outer/subcall IDs; this table never supplies engine input.
    /// Reached errors are native values, mapped explicitly by the private codec.
    pub const TestCallbackReturn = enum { no_output, loss_zero, no_negotiated_output, sample_count_failed, negotiated_render_failed, completed };
    pub const TestCallbackEvent = union(enum) {
        enter: struct { frame_count: u32, channels: u16, output_present: bool },
        loss_acquired: bool,
        returned: struct { kind: TestCallbackReturn, failure: ?anyerror },
    };
    pub const TestCallbackFacts = struct { context: *anyopaque, call: *const fn (*anyopaque, TestCallbackEvent) void };
    renderer: *runtime.RuntimeRenderer,
    adapter: RuntimeFixedQuantumAdapter,
    device: c.ma_device = undefined,
    context: c.ma_context = undefined,
    context_initialized: bool = false,
    output: ?NegotiatedOutput = null,
    callback_scratch: [max_pending_samples]f32 = undefined,
    config: DeviceConfig = .{},
    state: RuntimeDeviceState = .closed,
    generation: u32 = 0,
    lost_count: u64 = 0,
    reopen_count: u64 = 0,
    loss_signal: music.DeviceRecoveryV1.Signal = .{},
    loss: ?music.DeviceRecoveryV1.Loss = null,
    loss_queued: bool = false,
    expected_stop: std.atomic.Value(bool) = .init(false),
    callback_registered: bool = false,
    // Host-exclusive binding mode, not an engine or callback decision input.
    // A closed replay binding must open only an actual null backend.
    semantic_audio_replay: bool = false,
    test_started_hook: if (@import("builtin").is_test) ?*const fn (*RuntimeMiniaudioBackend) void else void = if (@import("builtin").is_test) null else {},
    test_start_driver: if (@import("builtin").is_test) ?*const fn (*RuntimeMiniaudioBackend) core.BuguError!void else void = if (@import("builtin").is_test) null else {},
    test_fail_stop_once: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},
    test_pcm: if (@import("builtin").is_test) ?TestPcm else void = if (@import("builtin").is_test) null else {},
    test_callback_facts: if (@import("builtin").is_test) ?TestCallbackFacts else void = if (@import("builtin").is_test) null else {},

    pub fn init(renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channel_count: u16) core.BuguError!RuntimeMiniaudioBackend {
        return .{ .renderer = renderer, .adapter = try RuntimeFixedQuantumAdapter.init(renderer, quantum_frames, channel_count) };
    }

    /// Host-exclusive, before start can register/invoke any callbacks. The
    /// owner also excludes direct adapter callers and sink consumers here.
    /// Capture sinks must never wait, lock, retry, or alter producer pacing.
    pub fn attachSemanticAudioQuiescent(self: *RuntimeMiniaudioBackend, sink: SemanticAudioSink, token: runtime.RuntimeRenderer.DeviceQuiescence) !void {
        if (sink.wait_callback != null) return error.InvalidState;
        try self.attachSemanticAudioBindingQuiescent(sink, token);
    }
    fn attachSemanticAudioBindingQuiescent(self: *RuntimeMiniaudioBackend, sink: SemanticAudioSink, token: runtime.RuntimeRenderer.DeviceQuiescence) !void {
        try self.renderer.validateDeviceQuiescence(token);
        if ((self.state != .closed and self.state != .open) or self.callback_registered or
            self.renderer.device_callbacks_active.load(.acquire) or self.adapter.semantic_audio != null) return error.InvalidState;
        self.adapter.semantic_audio = sink;
    }

    /// Explicit OFFLINE replay owner only, separately constructed from the
    /// original capture. This permits suspending the real null-device callback
    /// at verified replay release/read cuts, never installing PCM or returning
    /// expected engine decisions. The caller owns complete preflight and must
    /// unblock suspended callbacks on mismatch BEFORE native stop/join.
    ///
    /// A closed backend may attach before source loading: open then rejects
    /// non-null config before driver effects, and start verifies the actual
    /// opened null device before callback registration. The same pinned token,
    /// sink lifetime and final drain/join exclusion rules as capture apply.
    pub fn attachSemanticAudioReplayQuiescent(self: *RuntimeMiniaudioBackend, sink: SemanticAudioSink, token: runtime.RuntimeRenderer.DeviceQuiescence) !void {
        try self.renderer.validateDeviceQuiescence(token);
        if (self.state == .open and !self.semanticReplayDeviceEligible()) return error.InvalidState;
        try self.attachSemanticAudioBindingQuiescent(sink, token);
        self.semantic_audio_replay = true;
    }

    fn semanticReplayDeviceEligible(self: *const RuntimeMiniaudioBackend) bool {
        return self.config.backend == .null_backend and self.context_initialized and self.output != null and
            self.output.?.record.backend == .null_backend and self.device.pContext != null and
            self.device.pContext.*.backend == c.ma_backend_null;
    }

    /// The caller must retain the sink through its FINAL shutdown drain, not
    /// detach at the first zero-drain snapshot. This checks actual device
    /// exclusion, not Runtime/Worker lifetime, which remains the host's duty.
    /// stop/deinit never detach implicitly, including on loss/failure paths.
    pub fn detachSemanticAudioQuiescent(self: *RuntimeMiniaudioBackend, token: runtime.RuntimeRenderer.DeviceQuiescence) !void {
        try self.renderer.validateDeviceQuiescence(token);
        if ((self.state != .closed and self.state != .stopped and self.state != .lost) or
            self.context_initialized or self.callback_registered or self.renderer.device_callbacks_active.load(.acquire) or
            self.adapter.pending_len != 0 or self.adapter.semantic_audio == null) return error.InvalidState;
        self.adapter.semantic_audio = null;
        self.semantic_audio_replay = false;
    }

    pub fn open(self: *RuntimeMiniaudioBackend, config: DeviceConfig) core.BuguError!void {
        // Replay must never open a physical/system driver, even when attachment
        // preceded device selection. Ordinary capture/device behavior is intact.
        if (self.semantic_audio_replay and config.backend != .null_backend) return error.InvalidArgument;
        if (self.state == .open or self.state == .running) {
            const request = try deviceRequest(config, self.renderer.mixer.output_layout, self.renderer.mixer.sample_rate);
            try verifyExisting(self.output.?, config, self.config, request);
            return;
        }
        if (self.state != .closed and self.state != .stopped and self.state != .reopening) return core.BuguError.InvalidState;
        const request = try deviceRequest(config, self.renderer.mixer.output_layout, self.renderer.mixer.sample_rate);
        // The prior device is closed/joined at every admitted new-open boundary.
        // Arm before init/start: a driver may report a new loss before start
        // returns, and that fact must not inherit the old intentional-stop mask.
        self.expected_stop.store(false, .release);
        try openDevice(self, config, request, runtimeDataCallback);
        self.config = config;
        self.state = .open;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }

    pub fn start(self: *RuntimeMiniaudioBackend) core.BuguError!void {
        if (self.state == .running) return;
        if (self.state != .open) return core.BuguError.InvalidState;
        if (self.semantic_audio_replay and !self.semanticReplayDeviceEligible()) return error.InvalidState;
        try self.renderer.registerDeviceCallbacks();
        self.callback_registered = true;
        self.startDriver() catch {
            self.expected_stop.store(true, .release);
            closeDevice(self); // even a partially started driver must be joined
            self.clearCallbackRegistration();
            // Start may call Render before reporting failure. This is a new
            // discontinuity with its own actual PCM/epoch, never the old reopen
            // fact. Reopen remains blocked until this obligation is serviced.
            self.state = .lost;
            self.lost_count += 1;
            _ = self.signalLost();
            publishRuntimeLoss(self, .restart_at_bar) catch {};
            return core.BuguError.DeviceStartFailed;
        };
        self.state = .running;
        if (@import("builtin").is_test) if (self.test_started_hook) |hook| hook(self);
    }

    /// Preserved synchronous HOST operation. Callback code calls signalLost,
    /// never this method. For a V1 owner this must run on its recorded Control
    /// thread, outside a tick; errors remain observable through serviceDeviceLoss.
    /// On ingress pressure the durable loss remains pending; reopen fails closed.
    /// Host services and backend destruction are serialized. Before freeing a
    /// lost V1 backend, service its copied loss on Control (loss_queued == true).
    pub fn notifyLost(self: *RuntimeMiniaudioBackend) void {
        if (self.state == .closed or self.state == .stopped) return;
        _ = self.signalLost();
        self.serviceDeviceLoss(.restart_at_bar) catch return;
    }
    pub fn signalLost(self: *RuntimeMiniaudioBackend) bool {
        return self.loss_signal.notify();
    }
    pub fn serviceDeviceLoss(self: *RuntimeMiniaudioBackend, policy: music.DeviceRecoveryPolicy) !void {
        if (!self.loss_signal.pending.load(.acquire)) return;
        try checkRuntimeLossThread(self.renderer); // before stop, flush, or token
        if (self.state == .closed) return error.InvalidState;
        var stop_failed = false;
        if (self.state != .lost) {
            self.expected_stop.store(true, .release);
            if (self.state == .running) self.stopDriver() catch {
                stop_failed = true;
            };
            // A failed stop does not discharge callback lifetime. Uninit is
            // mandatory and joins the real worker before releasing registration.
            if (self.state != .stopped) closeDevice(self);
            self.clearCallbackRegistration();
            self.state = .lost;
            self.lost_count += 1;
        }
        try publishRuntimeLoss(self, policy);
        if (stop_failed) return error.DeviceStopFailed;
    }

    pub fn reopen(self: *RuntimeMiniaudioBackend) core.BuguError!void {
        if (self.state != .lost) return core.BuguError.InvalidState;
        if (!self.loss_queued) return error.InvalidState;
        if (self.renderer.runtime.music_runtime) |owner| if (owner.usesDeviceControlV1() and !owner.deviceEpochAcceptedV1(self.adapter.device_epoch)) return error.InvalidState;
        const previous_loss = self.loss;
        // Consume only the old closed-device fact, before any new device can
        // notify. Never clear the signal after start; that erases early loss.
        self.loss = null;
        self.loss_queued = false;
        self.loss_signal.pending.store(false, .release);
        self.state = .reopening;
        self.open(self.config) catch |err| {
            self.restoreUnstartedLoss(previous_loss);
            return err;
        };
        self.start() catch |err| {
            if (self.state == .open) {
                // Registration rejected before any driver start/render.
                self.expected_stop.store(true, .release);
                closeDevice(self);
                self.clearCallbackRegistration();
                self.restoreUnstartedLoss(previous_loss);
            }
            // A driver start failure has already closed/joined the device and
            // owns a NEW loss. Never overwrite its flushed PCM/epoch or event.
            return err;
        };
        self.reopen_count += 1;
    }
    pub fn reopenEpoch(self: *RuntimeMiniaudioBackend, epoch: u64) core.BuguError!void {
        if (epoch != self.adapter.device_epoch) return error.InvalidState;
        try self.reopen();
    }
    pub fn drainShutdown(self: *RuntimeMiniaudioBackend) !void {
        if (self.state != .lost and self.state != .stopped) return error.InvalidState;
        const token = try self.renderer.acquireDeviceQuiescence();
        defer self.renderer.releaseDeviceQuiescence(token) catch unreachable;
        try self.adapter.drainShutdownQuiescent(token);
    }

    pub fn stop(self: *RuntimeMiniaudioBackend) void {
        if (self.state == .closed or self.state == .stopped) return;
        if (self.state == .lost) {
            if (self.loss_signal.pending.load(.acquire)) publishRuntimeLoss(self, .restart_at_bar) catch {};
            return;
        }
        self.expected_stop.store(true, .release);
        var stop_failed = false;
        if (self.state == .running) self.stopDriver() catch {
            stop_failed = true;
        };
        if (self.state == .open or self.state == .running) {
            // Keep the original void stop/deinit safety guarantee even when a
            // driver stop fails, the caller is not Control, or ingress is full.
            closeDevice(self);
            self.clearCallbackRegistration();
            if (self.loss_signal.pending.load(.acquire) or stop_failed) {
                self.state = .lost;
                self.lost_count += 1;
                _ = self.signalLost();
                publishRuntimeLoss(self, .restart_at_bar) catch {};
            } else {
                self.state = .stopped;
                _ = self.adapter.changeEpoch(self.adapter.device_epoch + 1) catch unreachable;
            }
        }
    }
    fn restoreUnstartedLoss(self: *RuntimeMiniaudioBackend, previous: ?music.DeviceRecoveryV1.Loss) void {
        self.loss = previous;
        self.loss_queued = true;
        self.loss_signal.pending.store(true, .release);
        self.state = .lost;
    }
    fn startDriver(self: *RuntimeMiniaudioBackend) core.BuguError!void {
        if (@import("builtin").is_test) if (self.test_start_driver) |hook| return hook(self);
        if (c.ma_device_start(&self.device) != c.MA_SUCCESS) return error.DeviceStartFailed;
    }
    fn stopDriver(self: *RuntimeMiniaudioBackend) core.BuguError!void {
        if (@import("builtin").is_test) if (self.test_fail_stop_once) {
            self.test_fail_stop_once = false;
            return error.DeviceStopFailed;
        };
        if (c.ma_device_stop(&self.device) != c.MA_SUCCESS) return error.DeviceStopFailed;
    }

    pub fn deinit(self: *RuntimeMiniaudioBackend) void {
        self.stop();
        if (self.state == .lost or self.state == .reopening) self.state = .stopped;
    }
    /// Test-only driver fault source: this calls the real null/backend stop,
    /// so the installed miniaudio notification callback supplies the loss fact.
    pub const DriverTest = if (@import("builtin").is_test) struct {
        /// Same installed callback, with a genuinely opened but never-started
        /// null device. Tests supply only outer arguments; the real negotiated
        /// adapter chooses chunks, quanta and pending output. No device fields
        /// or engine state are forged, and no concurrent callback is admitted.
        pub fn callbackUnstarted(self: *RuntimeMiniaudioBackend, output: ?[]f32, frames: u32) core.BuguError!void {
            if (self.state != .open or self.config.backend != .null_backend or !self.context_initialized or
                self.callback_registered or self.renderer.device_callbacks_active.load(.acquire)) return error.InvalidState;
            if (output) |samples| {
                const count = try checkedSamples(frames, @intCast(self.device.playback.channels));
                if (samples.len != count) return error.InvalidArgument;
            }
            runtimeDataCallback(&self.device, if (output) |samples| @as(*anyopaque, @ptrCast(samples.ptr)) else null, null, frames);
        }
        /// Controlled driver boundary fault, not a claim of physical hardware
        /// failure. Invoke the installed real callback/adapter for one frame,
        /// leaving a genuine pending quantum, then fail the start operation.
        pub fn renderThenFailStart(self: *RuntimeMiniaudioBackend) core.BuguError!void {
            var pcm: [max_channels]f32 = undefined;
            runtimeDataCallback(&self.device, &pcm, null, 1);
            return error.DeviceStartFailed;
        }
        pub fn stopDriver(self: *RuntimeMiniaudioBackend) core.BuguError!void {
            if (self.state != .running) return error.InvalidState;
            if (c.ma_device_stop(&self.device) != c.MA_SUCCESS) return error.DeviceStopFailed;
        }
    } else struct {};
    fn clearCallbackRegistration(self: *RuntimeMiniaudioBackend) void {
        if (!self.callback_registered) return;
        self.renderer.unregisterDeviceCallbacksQuiescent();
        self.callback_registered = false;
    }
};

pub const MiniaudioBackend = struct {
    engine: *core.Engine,
    adapter: FixedQuantumAdapter,
    device: c.ma_device = undefined,
    context: c.ma_context = undefined,
    context_initialized: bool = false,
    output: ?NegotiatedOutput = null,
    callback_scratch: [max_pending_samples]f32 = undefined,
    initialized: bool = false,
    started: bool = false,
    config: DeviceConfig = .{},

    pub fn init(engine: *core.Engine) MiniaudioBackend {
        return .{
            .engine = engine,
            .adapter = FixedQuantumAdapter.init(engine) catch unreachable,
        };
    }

    pub fn open(self: *MiniaudioBackend, config: DeviceConfig) core.BuguError!void {
        const request = try deviceRequest(config, self.engine.mixer.output_layout, self.engine.config.sample_rate);
        if (self.initialized) return verifyExisting(self.output.?, config, self.config, request);
        try openDevice(self, config, request, dataCallback);
        self.config = config;
        self.initialized = true;
    }

    pub fn start(self: *MiniaudioBackend) core.BuguError!void {
        if (self.started) return;
        if (!self.initialized) return core.BuguError.InvalidState;
        if (c.ma_device_start(&self.device) != c.MA_SUCCESS) {
            return core.BuguError.DeviceStartFailed;
        }
        self.started = true;
    }

    pub fn stop(self: *MiniaudioBackend) void {
        if (self.started) {
            _ = c.ma_device_stop(&self.device);
            self.started = false;
        }
    }

    pub fn deinit(self: *MiniaudioBackend) void {
        self.stop();
        if (self.initialized) {
            closeDevice(self);
            self.initialized = false;
        }
    }
};

fn dataCallback(device: [*c]c.ma_device, output: ?*anyopaque, input: ?*const anyopaque, frame_count: c.ma_uint32) callconv(.c) void {
    _ = input;
    if (device == null or output == null) return;
    const backend: *MiniaudioBackend = @ptrCast(@alignCast(device.*.pUserData));
    const negotiated = &(backend.output orelse return);
    const sample_count = checkedSamples(frame_count, negotiated.matrix.output.count) catch return;
    const out: [*]f32 = @ptrCast(@alignCast(output));
    negotiated.render(&backend.adapter, &backend.callback_scratch, out[0..sample_count], frame_count) catch @memset(out[0..sample_count], 0);
}

fn runtimeDataCallback(device: [*c]c.ma_device, output: ?*anyopaque, input: ?*const anyopaque, frame_count: c.ma_uint32) callconv(.c) void {
    _ = input;
    if (device == null) return;
    const backend: *RuntimeMiniaudioBackend = @ptrCast(@alignCast(device.*.pUserData));
    const callback_channels: u16 = std.math.cast(u16, device.*.playback.channels) orelse 0;
    // A null timer may wake after the final recorded logical callback. Only
    // the separate offline binding can hold that unadmitted wake. Capture and
    // physical drivers always take the unchanged callback path below.
    if (backend.semantic_audio_replay) if (backend.adapter.semantic_audio) |sink| if (sink.wait_callback) |wait_callback| {
        const admission = wait_callback(sink.context, &backend.expected_stop);
        if (admission == .cancel_pending and backend.expected_stop.load(.acquire)) {
            if (output) |pointer| {
                const count = checkedSamples(frame_count, callback_channels) catch return;
                const samples: [*]f32 = @ptrCast(@alignCast(pointer));
                @memset(samples[0..count], 0);
            }
            // Driver silence, not engine PCM: no Render, witness, semantic event
            // or logical accounting occurred. stopDriver still joins this thread.
            return;
        }
        // A premature cancellation cannot suppress a native callback. Let the
        // actual callback/comparison expose the gate owner's protocol violation.
    };
    var callback_return: RuntimeMiniaudioBackend.TestCallbackReturn = .no_output;
    var callback_failure: ?anyerror = null;
    if (@import("builtin").is_test) if (backend.test_callback_facts) |hook|
        hook.call(hook.context, .{ .enter = .{ .frame_count = frame_count, .channels = callback_channels, .output_present = output != null } });
    if (backend.adapter.semantic_audio) |sink| sink.call(sink.context, .{ .callback_begin = .{
        .frame_count = frame_count,
        .channels = callback_channels,
        .device_epoch = backend.adapter.device_epoch,
        .output_present = output != null,
        .accounting = backend.adapter.accounting(),
    } });
    defer if (backend.adapter.semantic_audio) |sink| sink.call(sink.context, .{ .callback_return = .{
        .kind = switch (callback_return) {
            .no_output => .no_output,
            .loss_zero => .loss_zero,
            .no_negotiated_output => .no_negotiated_output,
            .sample_count_failed => .sample_count_failed,
            .negotiated_render_failed => .negotiated_render_failed,
            .completed => .completed,
        },
        .failure = callback_failure,
        .accounting = backend.adapter.accounting(),
    } });
    defer if (@import("builtin").is_test) {
        if (backend.test_callback_facts) |hook| hook.call(hook.context, .{ .returned = .{ .kind = callback_return, .failure = callback_failure } });
    };
    const witnessing = backend.adapter.beginWitnessCallback(.device_callback, frame_count, callback_channels);
    var witness_failure: render_witness.Failure = .callback_error;
    defer backend.adapter.endWitnessCallback(witnessing, witness_failure);
    if (output == null) return;
    const loss_pending = backend.loss_signal.pending.load(.acquire);
    if (@import("builtin").is_test) if (backend.test_callback_facts) |hook| hook.call(hook.context, .{ .loss_acquired = loss_pending });
    if (backend.adapter.semantic_audio) |sink| sink.call(sink.context, .{ .loss_acquired = loss_pending });
    if (loss_pending) {
        callback_return = .loss_zero;
        const samples: [*]f32 = @ptrCast(@alignCast(output.?));
        @memset(samples[0 .. @as(usize, frame_count) * device.*.playback.channels], 0);
        if (backend.adapter.semantic_audio) |sink| sink.call(sink.context, .{ .pcm = .{
            .disposition = .submitted,
            .device_epoch = backend.adapter.device_epoch,
            .first_frame = null,
            .channels = callback_channels,
            .samples = samples[0 .. @as(usize, frame_count) * device.*.playback.channels],
        } });
        return;
    }
    const negotiated = &(backend.output orelse {
        callback_return = .no_negotiated_output;
        return;
    });
    const sample_count = checkedSamples(frame_count, negotiated.matrix.output.count) catch |err| {
        callback_return = .sample_count_failed;
        callback_failure = err;
        return;
    };
    const out: [*]f32 = @ptrCast(@alignCast(output));
    const first_frame = if (@import("builtin").is_test or backend.adapter.semantic_audio != null)
        (if (backend.adapter.pending_len != 0) backend.adapter.pending_first_frame else backend.renderer.renderFrame())
    else
        0;
    negotiated.render(&backend.adapter, &backend.callback_scratch, out[0..sample_count], frame_count) catch |err| {
        callback_return = .negotiated_render_failed;
        callback_failure = err;
        @memset(out[0..sample_count], 0);
        if (backend.adapter.semantic_audio) |sink| sink.call(sink.context, .{ .pcm = .{
            .disposition = .submitted,
            .device_epoch = backend.adapter.device_epoch,
            .first_frame = null,
            .channels = negotiated.matrix.output.count,
            .samples = out[0..sample_count],
        } });
        return;
    };
    callback_return = .completed;
    witness_failure = .none;
    if (@import("builtin").is_test) if (backend.test_pcm) |hook|
        hook.call(hook.context, backend.adapter.device_epoch, first_frame, negotiated.matrix.output.count, out[0..sample_count]);
    if (backend.adapter.semantic_audio) |sink| sink.call(sink.context, .{ .pcm = .{
        .disposition = .submitted,
        .device_epoch = backend.adapter.device_epoch,
        .first_frame = first_frame,
        .channels = negotiated.matrix.output.count,
        .samples = out[0..sample_count],
    } });
}

const WavSizes = struct { extensible: bool, block_align: u16, byte_rate: u32, data_bytes: u32, riff_size: u32 };
fn wavSizes(frame_count: u32, sample_rate: u32, layout: channel_layout.ChannelLayout) core.BuguError!WavSizes {
    try layout.validate();
    if (sample_rate == 0) return error.InvalidArgument;
    const extensible = layout.count > 2 or (layout.count == 1 and layout.mask != channel_layout.mono.mask) or (layout.count == 2 and layout.mask != channel_layout.stereo.mask);
    const block_align = std.math.mul(u16, layout.count, 2) catch return error.ArithmeticOverflow;
    const byte_rate = std.math.mul(u32, sample_rate, block_align) catch return error.ArithmeticOverflow;
    const data_bytes = std.math.mul(u32, frame_count, block_align) catch return error.ArithmeticOverflow;
    const riff_size = std.math.add(u32, if (extensible) 60 else 36, data_bytes) catch return error.ArithmeticOverflow;
    return .{ .extensible = extensible, .block_align = block_align, .byte_rate = byte_rate, .data_bytes = data_bytes, .riff_size = riff_size };
}

pub fn writeWavHeader(writer: *std.Io.Writer, frame_count: u32, sample_rate: u32, layout: channel_layout.ChannelLayout) !void {
    const sizes = try wavSizes(frame_count, sample_rate, layout);
    try writer.writeAll("RIFF");
    try writer.writeInt(u32, sizes.riff_size, .little);
    try writer.writeAll("WAVEfmt ");
    try writer.writeInt(u32, if (sizes.extensible) 40 else 16, .little);
    try writer.writeInt(u16, if (sizes.extensible) 0xfffe else 1, .little);
    try writer.writeInt(u16, layout.count, .little);
    try writer.writeInt(u32, sample_rate, .little);
    try writer.writeInt(u32, sizes.byte_rate, .little);
    try writer.writeInt(u16, sizes.block_align, .little);
    try writer.writeInt(u16, 16, .little);
    if (sizes.extensible) {
        try writer.writeInt(u16, 22, .little); // cbSize
        try writer.writeInt(u16, 16, .little); // valid bits
        try writer.writeInt(u32, layout.mask, .little);
        // KSDATAFORMAT_SUBTYPE_PCM, serialized little-endian GUID.
        try writer.writeAll(&.{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 });
    }
    try writer.writeAll("data");
    try writer.writeInt(u32, sizes.data_bytes, .little);
}

fn durationFrames(seconds: f32, sample_rate: u32) core.BuguError!u32 {
    const frames = @as(f64, seconds) * @as(f64, @floatFromInt(sample_rate));
    if (!std.math.isFinite(frames) or frames < 0 or frames > std.math.maxInt(u32)) return error.InvalidArgument;
    return @intFromFloat(frames);
}

/// Serialize already-rendered interleaved PCM using the same exact conversion
/// as the production offline WAV path. The caller writes the real WAV header.
pub fn writeWavSamples(writer: *std.Io.Writer, samples: []const f32) !void {
    for (samples) |sample| {
        if (!std.math.isFinite(sample)) return error.InvalidArgument;
        const pcm: i16 = @intFromFloat(std.math.clamp(sample, -1.0, 1.0) * 32767.0);
        try writer.writeInt(i16, pcm, .little);
    }
}

fn writeRenderedWav(adapter: anytype, writer: *std.Io.Writer, frame_count: u32, sample_rate: u32, quantum_frames: u32, layout: channel_layout.ChannelLayout) !void {
    try writeWavHeader(writer, frame_count, sample_rate, layout);
    var buffer: [max_pending_samples]f32 = undefined;
    var remaining = frame_count;
    while (remaining != 0) {
        const frames = @min(remaining, quantum_frames);
        const sample_count = try checkedSamples(frames, layout.count);
        try adapter.renderChecked(buffer[0..sample_count], frames);
        try writeWavSamples(writer, buffer[0..sample_count]);
        remaining -= frames;
    }
}

test "offline backend writes samples" {
    var engine = try core.Engine.init(.{});
    try engine.startTestVoice(.{ .frequency_hz = 330.0, .gain = 0.2 });
    var backend = OfflineBackend.init(&engine);
    const samples = try backend.renderFrames(std.testing.allocator, 127);
    defer std.testing.allocator.free(samples);
    try std.testing.expect(samples.len == 254);
    try std.testing.expectEqual(@as(u64, 1), engine.telemetrySnapshot().callback_count);
    try std.testing.expectEqual(@as(u64, 256), engine.telemetrySnapshot().rendered_frames);
    try std.testing.expect(engine.telemetrySnapshot().peak_abs > 0.0);
}

test "runtime offline backend handles variable callback sizes through immutable snapshots" {
    const samples = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    var owner = try runtime.SampleOwner.init(&samples);
    const control = try runtime.ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(control);
    const instance = try control.reserveInstance();
    try control.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true } });
    _ = try control.controlTick(runtime.max_control_drain);
    var renderer = runtime.RuntimeRenderer.init(control, 48_000);
    var backend = try RuntimeOfflineBackend.init(&renderer, 256, 2);
    inline for (.{ 1, 127, 256, 300, 513 }) |frames| {
        const output = try backend.renderFrames(std.testing.allocator, frames);
        defer std.testing.allocator.free(output);
        for (output) |sample| try std.testing.expect(std.math.isFinite(sample));
    }
    try control.submitStop(.{ .instance = instance, .fade_frames = 1 });
    _ = try control.controlTick(runtime.max_control_drain);
    const tail = try backend.renderFrames(std.testing.allocator, 513);
    defer std.testing.allocator.free(tail);
    _ = try control.controlTick(runtime.max_control_drain);
    owner.retire();
    try control.destroy();
    try std.testing.expect(owner.canDestroy());
}

test "TASK-025 runtime adapter preserves exactly-once short PCM across callback sizes" {
    const samples = [_]f32{ 0.5, -0.25, 0.125, -0.0625 };
    var owner = try runtime.SampleOwner.init(&samples);
    const control = try runtime.ControlRuntime.create(std.testing.allocator);
    defer std.testing.allocator.destroy(control);
    const instance = try control.reserveInstance();
    try control.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{} });
    _ = try control.controlTick(runtime.max_control_drain);
    var renderer = runtime.RuntimeRenderer.init(control, 48_000);
    var backend = try RuntimeOfflineBackend.init(&renderer, 256, 2);
    var total_frames: usize = 0;
    var nonzero_samples: usize = 0;
    inline for (.{ 1, 127, 256, 300, 513 }) |frames| {
        const output = try backend.renderFrames(std.testing.allocator, frames);
        defer std.testing.allocator.free(output);
        for (output, 0..) |sample, offset| {
            try std.testing.expect(std.math.isFinite(sample));
            if (sample != 0) {
                nonzero_samples += 1;
                // Startup/filter tail may extend past the source, but all
                // its PCM belongs to the first quantum. Later quantums
                // must not restart it from the unchanged snapshot.
                try std.testing.expect(total_frames + offset / 2 < 256);
            }
        }
        total_frames += frames;
    }
    try std.testing.expect(nonzero_samples > 0);
    _ = try control.controlTick(runtime.max_control_drain);
    const completion = control.pollCompletion() orelse return error.MissingCompletion;
    try std.testing.expect(completion.instance.eql(instance));
    try std.testing.expectEqual(runtime.CompletionReason.finished, completion.reason);
    try std.testing.expect(control.pollCompletion() == null);
    owner.retire();
    try control.destroy();
    try std.testing.expect(owner.canDestroy());
}
