//! Optional OFFLINE full-PCM companion to ChunkRecordingV1. Old recording and
//! replay envelopes are unchanged. No allocation, I/O, lock, or Render hook.
//!
//! TRUSTED OBSERVATION CONTRACT: the serialized offline host calls Capture.init
//! immediately after the successful original begin, then appendSuccessfulRender
//! exactly once with each actual successful recordChunkRenderV1 observation and
//! that call's still-unmodified interleaved Render output, before buffer reuse.
//! Worker-decoded PCM, replay PCM, and invented observations are NOT capture
//! evidence. No software digest can establish provenance if this caller lies.
//! Do not copy/mutate an active accumulator or call it concurrently. All these
//! functions run outside the RT callback, exclusively with capture/finalization.
//!
//! Cost is O(frames * channels) per append, constant memory, with a hard maximum
//! of 4096 stereo frames (8192 samples, 32768 canonical bytes) per call. Quantum values above
//! that are unsupported by this optional mode. Long recordings require repeated
//! bounded calls, never a whole-recording PCM buffer. Hashing latency is not an
//! RT guarantee. Every sample preserves its exact IEEE-754 f32 bit pattern,
//! including signed zero, infinities, and all NaN signs/payloads; no arithmetic,
//! normalization, denormal flushing, or NaN canonicalization is performed.
//!
//! A successful export receipt certifies accepted writes only, not durability.
//! This companion checks PCM equality only, not resource authorization, replay
//! grammar/runtime acceptance, authenticity, or filesystem publication. The host
//! must retain the original companion with the immutable recording, and perform
//! its real replay closure/reconciliation before using Verifier.finish().
const std = @import("std");
const schema = @import("trace_schema.zig");
const codec = @import("trace_codec.zig");
const chunks = @import("recording_chunks.zig");
const recording = @import("chunk_recording.zig");

pub const Hash = schema.Hash;
pub const version: u16 = 1;
pub const max_quantum_frames: u32 = 4096;
pub const channels: u16 = 2;
pub const digest_algorithm: u16 = 1; // SHA-256
pub const sample_encoding: u16 = 1; // exact f32 bits, LE u32, frame-major L/R
pub const samples_domain = "SME/chunk-pcm-samples/v1\x00";
pub const proof_domain = "SME/chunk-pcm-proof/v1\x00";
/// Keep the SHA-256 bit length representable, including its domain prefix.
pub const max_audio_frames: u64 = (std.math.maxInt(u64) / 8 - samples_domain.len) / (4 * channels);
pub const Error = chunks.Error || recording.Error || error{
    InvalidProof,
    UnsupportedPcmMode,
    MissingOriginalProof,
    ProofBindingMismatch,
    PcmMismatch,
    IncompletePcm,
    InvalidRenderObservation,
    InvalidSampleCount,
    InvalidCaptureStart,
};

/// Canonical companion wire order. source_container_frames explicitly counts
/// container frames, never audio. Local storage IDs bind the original receipt;
/// replay storage is independent and must NOT match them.
pub const Proof = struct {
    magic: [8]u8 = "SMEPCM01".*,
    version: u16 = version,
    digest_algorithm: u16 = digest_algorithm,
    sample_encoding: u16 = sample_encoding,
    channels: u16 = channels,
    sample_rate: u32,
    identity: chunks.Identity,
    recording_id: Hash,
    source_terminal_hash: Hash,
    storage_id: u64,
    incarnation: u64,
    storage_generation: u64,
    source_inputs: u64,
    source_schedule: u64,
    source_container_frames: u64,
    source_bytes: u64,
    audio_frames: u64,
    render_calls: u64,
    pcm_digest: Hash,
    proof_hash: Hash,

    pub fn validate(self: Proof) Error!void {
        if (!std.mem.eql(u8, &self.magic, "SMEPCM01")) return error.InvalidProof;
        if (self.version != 1 or self.digest_algorithm != 1 or self.sample_encoding != 1) return error.UnknownVersion;
        try validateIdentity(self.identity);
        if (self.channels != channels or self.sample_rate != self.identity.sample_rate or
            self.storage_id == 0 or self.incarnation == 0 or self.storage_generation == 0 or
            schema.isZero(self.recording_id) or schema.isZero(self.source_terminal_hash) or
            self.source_inputs < 2 or self.source_container_frames == 0 or self.source_bytes < chunks.preamble_bytes + chunks.frame_header_bytes + chunks.terminal_prefix_bytes or
            self.audio_frames > max_audio_frames or self.render_calls > self.audio_frames or
            (self.audio_frames == 0) != (self.render_calls == 0)) return error.InvalidProof;
        // Compare against ceil(frames / quantum), not calls * quantum: many
        // legitimate short calls can overflow that product while their actual
        // sample count remains within the SHA-256 length bound. Identity
        // validation already guarantees a nonzero quantum. Division plus a
        // remainder increment cannot overflow for these bounded frame counts.
        const minimum_calls = self.audio_frames / self.identity.quantum_frames +
            @as(u64, @intFromBool(self.audio_frames % self.identity.quantum_frames != 0));
        if (self.render_calls < minimum_calls) return error.InvalidProof;
        const expected = try self.expectedHash();
        if (!std.mem.eql(u8, &self.proof_hash, &expected)) return error.HashMismatch;
    }

    fn expectedHash(self: Proof) Error!Hash {
        var bytes: [proof_bytes]u8 = undefined;
        var encoder: codec.Encoder = .{ .bytes = &bytes };
        try encoder.put(self);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(proof_domain);
        hash.update(bytes[0 .. proof_bytes - 32]);
        var result: Hash = undefined;
        hash.final(&result);
        return result;
    }
};

pub const proof_bytes: usize = codec.maxSize(Proof);

pub fn encode(bytes: []u8, proof: Proof) Error![]const u8 {
    try proof.validate();
    var encoder: codec.Encoder = .{ .bytes = bytes };
    try encoder.put(proof);
    return bytes[0..encoder.offset];
}

pub fn decode(bytes: []const u8) Error!Proof {
    var decoder: codec.Decoder = .{ .bytes = bytes };
    const result = try decoder.get(Proof);
    try decoder.finish();
    try result.validate();
    return result;
}

/// Construct from actual immutable-source preflight. audio_frames is the
/// independently checked public grammar's rendered_frames, NOT total_frames.
/// The driver separately checks Prepared.runtime_profile (framing lacks it).
pub const SourceBinding = struct {
    identity: chunks.Identity,
    recording_id: Hash,
    terminal_hash: Hash,
    total_inputs: u64,
    total_schedule: u64,
    container_frames: u64,
    total_bytes: u64,
    audio_frames: u64,

    pub fn fromFraming(framing: chunks.SuccessfulTerminalFraming, audio_frames: u64) SourceBinding {
        return .{
            .identity = framing.identity,
            .recording_id = framing.recording_id,
            .terminal_hash = framing.terminal_hash,
            .total_inputs = framing.total_inputs,
            .total_schedule = framing.total_schedule,
            .container_frames = framing.total_frames,
            .total_bytes = framing.total_bytes,
            .audio_frames = audio_frames,
        };
    }

    fn validate(self: SourceBinding) Error!void {
        try validateIdentity(self.identity);
        if (schema.isZero(self.recording_id) or schema.isZero(self.terminal_hash) or
            self.total_inputs < 2 or self.container_frames == 0 or
            self.total_bytes < chunks.preamble_bytes + chunks.frame_header_bytes + chunks.terminal_prefix_bytes or
            self.audio_frames > max_audio_frames) return error.InvalidProof;
    }

    fn matches(self: SourceBinding, proof: Proof) bool {
        return std.meta.eql(self.identity, proof.identity) and
            std.mem.eql(u8, &self.recording_id, &proof.recording_id) and
            std.mem.eql(u8, &self.terminal_hash, &proof.source_terminal_hash) and
            self.total_inputs == proof.source_inputs and self.total_schedule == proof.source_schedule and
            self.container_frames == proof.source_container_frames and self.total_bytes == proof.source_bytes and
            self.audio_frames == proof.audio_frames;
    }
};

fn validateIdentity(identity: chunks.Identity) Error!void {
    try identity.validate();
    if (identity.quantum_frames > max_quantum_frames) return error.UnsupportedPcmMode;
}

const Phase = enum { active, failed, finished };
const Stream = struct {
    hash: std.crypto.hash.sha2.Sha256,
    quantum_frames: u32,
    audio_frames: u64 = 0,
    render_calls: u64 = 0,
    next_call: u64 = 0,

    fn init(quantum_frames: u32) Stream {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(samples_domain);
        return .{ .hash = hash, .quantum_frames = quantum_frames };
    }

    fn append(self: *Stream, observation: anytype, samples: []const f32) Error!void {
        // Structural typing accepts public_replay.RenderObservation without a
        // trace -> public_replay -> trace import cycle. The host passes the actual
        // returned value unchanged; these exact scalar types are also required.
        comptime {
            if (@TypeOf(observation.requested_frames) != u32 or @TypeOf(observation.frame_before) != u64 or
                @TypeOf(observation.frame_after) != u64 or @TypeOf(observation.call_sequence_before) != u64 or
                @TypeOf(observation.call_sequence_after) != u64 or @TypeOf(observation.completed) != bool)
                @compileError("pass the actual public RenderObservation unchanged");
        }
        const frames = observation.requested_frames;
        if (!observation.completed or frames == 0) return error.InvalidRenderObservation;
        if (frames > max_quantum_frames or frames > self.quantum_frames) return error.WorkLimit;
        if (observation.frame_before != self.audio_frames or observation.call_sequence_before != self.next_call or
            observation.call_sequence_before & 1 != 0) return error.InvalidRenderObservation;
        const frame_after = std.math.add(u64, self.audio_frames, frames) catch return error.CounterOverflow;
        const call_after = std.math.add(u64, self.next_call, 2) catch return error.CounterOverflow;
        const render_calls = std.math.add(u64, self.render_calls, 1) catch return error.CounterOverflow;
        if (frame_after > max_audio_frames) return error.CounterOverflow;
        if (observation.frame_after != frame_after or observation.call_sequence_after != call_after) return error.InvalidRenderObservation;
        const sample_count = std.math.mul(usize, frames, channels) catch return error.CounterOverflow;
        if (samples.len != sample_count) return error.InvalidSampleCount;
        // All validation precedes the bounded hash loop. Bitcast preserves every
        // f32 payload; canonical LE encoding is independent of host endianness.
        for (samples) |sample| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @bitCast(sample), .little);
            self.hash.update(&bytes);
        }
        self.audio_frames = frame_after;
        self.next_call = call_after;
        self.render_calls = render_calls;
    }

    fn digest(self: *const Stream) Hash {
        var hash = self.hash;
        var result: Hash = undefined;
        hash.final(&result);
        return result;
    }
};

pub const Capture = struct {
    storage: *const recording.Storage,
    preamble: chunks.Preamble,
    storage_id: u64,
    incarnation: u64,
    storage_generation: u64,
    stream: Stream,
    phase: Phase = .active,

    /// Explicit opt-in OFFLINE full-proof capability. The live, address-stable
    /// storage outlives this value and is read only under host serialization.
    pub fn init(storage: *const recording.Storage) Error!Capture {
        return initImpl(storage, null);
    }

    /// Explicit profile selection permits chunk-only fill-state and context bridges.
    /// Legacy init remains limited to profiles 2/3; proof fields and hash domains
    /// do not change because recording_id already binds the exact preamble.
    pub fn initForProfile(storage: *const recording.Storage, profile: schema.RuntimeProfile) Error!Capture {
        return initImpl(storage, profile);
    }

    fn initImpl(storage: *const recording.Storage, required_profile: ?schema.RuntimeProfile) Error!Capture {
        const status = storage.status();
        if (storage.bound_address != @intFromPtr(storage) or storage.storage_id == 0 or storage.incarnation == 0 or storage.storage_generation == 0 or
            status.state != .active or status.reason != .none or status.export_failed or status.producer_closed or
            status.retained_inputs != 1 or status.retained_schedule != 0 or
            storage.frontier.control_tick != 0 or storage.frontier.control_frame != 0 or storage.frontier.render_call_sequence != 0)
            return error.InvalidCaptureStart;
        try storage.preamble.validate();
        try validateIdentity(storage.preamble.identity);
        const profile = storage.preamble.runtime_profile;
        if (required_profile) |expected| {
            if (profile != expected or (profile != .stream_serial_v1 and profile != .stream_direct_state_serial_v1 and profile != .stream_fill_state_serial_v1 and profile != .stream_context_serial_v1)) return error.UnsupportedPcmMode;
        } else if (profile != .stream_serial_v1 and profile != .stream_direct_state_serial_v1) return error.UnsupportedPcmMode;
        return .{
            .storage = storage,
            .preamble = storage.preamble,
            .storage_id = storage.storage_id,
            .incarnation = storage.incarnation,
            .storage_generation = storage.storage_generation,
            .stream = Stream.init(storage.preamble.identity.quantum_frames),
        };
    }

    pub fn fail(self: *Capture) void {
        self.phase = .failed;
    }

    pub fn appendSuccessfulRender(self: *Capture, observation: anytype, actual_output: []const f32) Error!void {
        if (self.phase != .active) return error.InvalidState;
        errdefer self.phase = .failed;
        try self.checkStorage();
        const status = self.storage.status();
        if (status.state != .active or status.reason != .none or status.export_failed or status.producer_closed) return error.RecorderIncomplete;
        try self.stream.append(observation, actual_output);
    }

    /// The caller does not provide a receipt-shaped struct: ask the real bound
    /// exporter for its confirmed success receipt here. Manual ack, open/failed
    /// exports and mismatched exporters cannot yield a proof. Calling too early
    /// irreversibly fails this accumulator rather than certifying a prefix later.
    pub fn finish(self: *Capture, exporter: *recording.Exporter) Error!Proof {
        if (self.phase != .active) return error.InvalidState;
        errdefer self.phase = .failed;
        try self.checkStorage();
        if (exporter.storage != self.storage) return error.ProofBindingMismatch;
        const completion = try exporter.completion();
        if (completion.storage_id != self.storage_id or completion.incarnation != self.incarnation or
            completion.storage_generation != self.storage_generation or
            !std.mem.eql(u8, &completion.recording_id, &self.preamble.recording_id)) return error.ProofBindingMismatch;
        const terminal = self.storage.terminal.value;
        if (terminal.status != .complete or terminal.reason != .none or terminal.counters_exhausted or
            terminal.final_control_frame != self.stream.audio_frames or terminal.final_render_call_sequence != self.stream.next_call or
            terminal.total_inputs != completion.total_inputs or terminal.total_schedule != completion.total_schedule)
            return error.IncompletePcm;
        var proof: Proof = .{
            .sample_rate = self.preamble.identity.sample_rate,
            .identity = self.preamble.identity,
            .recording_id = completion.recording_id,
            .source_terminal_hash = completion.terminal_hash,
            .storage_id = completion.storage_id,
            .incarnation = completion.incarnation,
            .storage_generation = completion.storage_generation,
            .source_inputs = completion.total_inputs,
            .source_schedule = completion.total_schedule,
            .source_container_frames = completion.total_frames,
            .source_bytes = completion.total_bytes,
            .audio_frames = self.stream.audio_frames,
            .render_calls = self.stream.render_calls,
            .pcm_digest = self.stream.digest(),
            .proof_hash = @splat(0),
        };
        proof.proof_hash = try proof.expectedHash();
        try proof.validate();
        self.phase = .finished;
        return proof;
    }

    fn checkStorage(self: *const Capture) Error!void {
        if (self.storage.bound_address != @intFromPtr(self.storage) or self.storage.storage_id != self.storage_id or
            self.storage.incarnation != self.incarnation or self.storage.storage_generation != self.storage_generation or
            !std.meta.eql(self.storage.preamble, self.preamble)) return error.ProofBindingMismatch;
    }
};

pub const PcmEvidence = enum { original_not_supplied, original_pcm_matches };
pub const PcmAssessment = struct {
    evidence: PcmEvidence,
    audio_frames: u64,
    render_calls: u64,
    pcm_digest: Hash,
    /// Even .original_pcm_matches is only PCM evidence. Runtime acceptance and
    /// original proof provenance remain separate trusted host responsibilities.
    runtime_reconciliation_required: void = {},

    pub fn requireOriginalMatch(self: PcmAssessment) Error!void {
        if (self.evidence != .original_pcm_matches) return error.MissingOriginalProof;
    }
};

pub const Verifier = struct {
    original: ?Proof,
    expected: SourceBinding,
    stream: Stream,
    phase: Phase = .active,

    /// Invoke before replay owner mutation. A missing proof supports an explicit
    /// schedule-only result; it can never yield .original_pcm_matches. A supplied
    /// invalid/mismatched proof is an error, never silently downgraded to absent.
    pub fn init(original: ?Proof, expected: SourceBinding) Error!Verifier {
        try expected.validate();
        if (original) |proof| {
            try proof.validate();
            if (!expected.matches(proof)) return error.ProofBindingMismatch;
        }
        return .{ .original = original, .expected = expected, .stream = Stream.init(expected.identity.quantum_frames) };
    }

    pub fn fail(self: *Verifier) void {
        self.phase = .failed;
    }

    pub fn appendSuccessfulRender(self: *Verifier, observation: anytype, actual_output: []const f32) Error!void {
        if (self.phase != .active) return error.InvalidState;
        errdefer self.phase = .failed;
        try self.stream.append(observation, actual_output);
        if (self.stream.audio_frames > self.expected.audio_frames) return error.IncompletePcm;
    }

    /// Only after actual runtime closure, source EOF, and reconciliation. Does
    /// not create an original ExportCompletion from this replay's manual acks.
    pub fn finish(self: *Verifier) Error!PcmAssessment {
        if (self.phase != .active) return error.InvalidState;
        errdefer self.phase = .failed;
        if (self.stream.audio_frames != self.expected.audio_frames) return error.IncompletePcm;
        const digest = self.stream.digest();
        if (self.original) |proof| {
            if (self.stream.render_calls != proof.render_calls) return error.IncompletePcm;
            if (!std.mem.eql(u8, &digest, &proof.pcm_digest)) return error.PcmMismatch;
        }
        self.phase = .finished;
        return .{
            .evidence = if (self.original == null) .original_not_supplied else .original_pcm_matches,
            .audio_frames = self.stream.audio_frames,
            .render_calls = self.stream.render_calls,
            .pcm_digest = digest,
        };
    }
};
