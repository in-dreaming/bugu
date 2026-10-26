//! Bounded worker/Control/render streaming owner. Only workerOne performs I/O
//! and Opus decoding. Only acceptCompleted publishes PCM. Renderer borrows a
//! stable SPSC Ring and never enters this service's worker/control methods.
const std = @import("std");
const SupplyHasher = @import("music").LiveSemanticFormat.IntegrityHasher;
const order = @import("sme-capture-order");
pub const live_semantic = @import("sme-live-semantic");
const opus = @import("sme-opus");
const schema = @import("sme-bank").schema;
const indexer = @import("sme-stream-index");
const trace = @import("sme-trace");
const p = @import("prefetch.zig");
const ring = @import("ring.zig");
const visibility = @import("visibility.zig");
pub const Error = p.Error || opus.Error || error{ InvalidStreamAsset, InvalidSeekIndex, StreamCapacity, JobCapacity, StaleStream, DrainPending, WorkerBusy, InvalidWindow, RingFull, ReplayMismatch, IncompleteTrace, HashMismatch, ResourceNotPrepared };
pub const observation = @import("acceptance_observation.zig");
pub const render_observation = @import("render_observation.zig");
pub const readiness_observation = @import("readiness_observation.zig");
pub const Handle = observation.Handle;
/// Copied only at the failed acquire guard of one explicitly live observation.
/// A missing value means that guard returned before acquiring it.
pub const LiveObservationDeferV1 = struct {
    reason: enum { odd_sequence, frame_mismatch, sequence_changed },
    operation: enum { prefetch, request, readiness, readiness_control_before, readiness_control_after },
    handle: Handle,
    requested_frame: ?u64 = null,
    observed_frame: ?u64 = null,
    sequence_before: ?u64 = null,
    sequence_after: ?u64 = null,
};
/// Actual owner context returned by the installed Control validator.
pub const InitialEntryContextV1 = struct {
    position: trace.schema.Position,
    context: u64,
    control_epoch: u64,
};
/// A successful completed-DSP acquire. Production uses a stack-local value,
/// never diagnostic storage, to choose the acceptance position and capacity.
pub const CompletedDspCutV1 = struct {
    sequence: u64,
    frame: u64,
    consumed: u64,
    produced: u64,
    available: u64,
};
/// Borrowed only for one synchronous Control callback. Copy fields needed by
/// a bounded recorder; never retain pointers or reenter/mutate the engine.
/// This is an acceptance seam, not a complete Live replay recording.
pub const LiveAcceptanceAttemptV1 = struct {
    incoming: trace.schema.Position,
    cut: ?CompletedDspCutV1 = null,
    deferred: ?struct {
        reason: enum { odd_sequence, sequence_changed },
        handle: Handle,
        observed_frame: ?u64,
        sequence_before: ?u64,
        sequence_after: ?u64,
    } = null,
    evidence: observation.Acceptance = .{},
    returned_error: ?Error = null,
};
pub const LivePrefetchOutcomeV1 = union(enum) { submitted: ?u64, deferred: LiveObservationDeferV1 };
pub const AvailabilityStage = enum { before_sequence, after_sequence, after_frame, before_final_sequence, after_final_sequence };
/// Test-only copied points at exact shipping supply operations. No witness
/// sink is installed and no observer state is admitted in production.
pub const TestSupplyPoint = struct {
    stage: enum { prefetch_begin, request_begin, request_queued },
    handle: Handle,
    job_slot: ?u16 = null,
    job: ?u64 = null,
};
/// Passive test-only terminal observation. Null/false means the original path
/// did not acquire that field. A nested request returns before its prefetch.
/// Callbacks must copy synchronously, never reenter or mutate this Service.
pub const TestSupplyReturn = struct {
    operation: enum { prefetch, request },
    handle: Handle,
    nested_prefetch: bool = false,
    reason: enum { unobserved, lookup_error, availability_error, high_water, before_lead, above_low_water, nested_request, cancelled, stopped, failed, pending, coordinate_unavailable, zero_count, job_id_exhausted, job_capacity, descriptor_error, queued } = .unobserved,
    available: ?u64 = null,
    pending_observed: bool = false,
    pending_job: ?u16 = null,
    job_slot: ?u16 = null,
    job: ?u64 = null,
    deferred: ?LiveObservationDeferV1 = null,
    returned_error: ?Error = null,
};
pub const AvailabilityHook = struct { context: *anyopaque, call: *const fn (*anyopaque, AvailabilityStage, u64) void };
pub const Consumed = ring.Consumed;
pub const ConsumedRange = ring.ConsumedRange;
pub const ConsumedRanges = ring.ConsumedRanges;
pub const ConsumedCheckpoint = ring.OfflinePoint;
pub const consumed_slots = ring.consumed_slots;
pub const Failure = enum(u16) { none, io, hash, decode, cancelled, stale_generation, invalid_window };
pub const Asset = struct {
    pub const Descriptor = @import("asset_source.zig").Descriptor;
    pub fn fromSource(scratch: []u8, descriptor: Descriptor, profile: p.StreamCapacityProfile) Error!Asset {
        const info = try @import("asset_source.zig").derive(scratch, descriptor, profile);
        const result: Asset = .{ .sound_index = descriptor.sound_index, .sound = descriptor.sound, .codec = descriptor.codec, .info = info, .chunks = descriptor.chunks, .seeks = descriptor.seeks, .source = descriptor.source };
        try result.validate(profile);
        return result;
    }
    sound_index: u32,
    sound: schema.Sound,
    codec: schema.Codec,
    info: opus.OpusStreamInfo,
    chunks: []const schema.Chunk,
    seeks: []const schema.SeekEntryV1,
    source: opus.ByteSource,
    references: std.atomic.Value(u32) = .init(1),
    retired: std.atomic.Value(bool) = .init(false),
    pub fn validate(self: *const Asset, profile: p.StreamCapacityProfile) Error!void {
        try profile.validate();
        const s = self.sound;
        if (trace.schema.isZero(s.audio_hash) or s.key.id == 0 or s.storage != .streaming or self.codec.kind != .ogg_opus or self.codec.version != 1 or s.frames == 0 or s.frames != self.info.audible_frames or s.channels != self.info.channels or s.channels > profile.max_channels or s.layout != self.info.layout or s.channel_mask != self.info.channel_mask or s.sample_rate_hz != profile.sample_rate or self.info.sample_rate_hz != profile.sample_rate or s.blob_length != self.source.length or self.source.length == 0 or self.chunks.len == 0 or self.chunks.len > 65536 or self.seeks.len == 0 or self.seeks.len > 65536 or s.chunks.count != self.chunks.len or s.seeks.count != self.seeks.len or self.codec.pre_skip != self.info.pre_skip or self.codec.end_trim != self.info.end_trim or self.codec.channel_mapping_family != self.info.mapping_family or self.codec.stream_count != self.info.stream_count or self.codec.coupled_count != self.info.coupled_count or !std.mem.eql(u8, &self.codec.channel_mapping, &self.info.channel_mapping)) return error.InvalidStreamAsset;
        // Recheck byte arithmetic and descriptor policy. This loader has no
        // whole-file-resident escape hatch, including for short streaming data.
        const samples = std.math.mul(u64, s.frames, s.channels) catch return error.InvalidStreamAsset;
        _ = std.math.mul(u64, samples, 4) catch return error.InvalidStreamAsset;
        var bytes: u64 = 0;
        var frames: u64 = 0;
        for (self.chunks) |chunk| {
            if (chunk.sound != self.sound_index or chunk.byte_offset != bytes or chunk.first_frame != frames or chunk.byte_length == 0 or chunk.byte_length > profile.max_encoded_chunk_bytes or chunk.frame_count == 0 or trace.schema.isZero(chunk.hash)) return error.InvalidStreamAsset;
            bytes = std.math.add(u64, bytes, chunk.byte_length) catch return error.InvalidStreamAsset;
            frames = std.math.add(u64, frames, chunk.frame_count) catch return error.InvalidStreamAsset;
        }
        if (bytes != self.source.length or frames != s.frames or self.seeks[0].logical_frame != 0) return error.InvalidStreamAsset;
        var previous: ?u64 = null;
        for (self.seeks) |entry| {
            if (entry.sound != self.sound_index or entry.packet_byte_offset >= bytes or (previous != null and entry.logical_frame <= previous.?) or (previous != null and entry.logical_frame - previous.? > 48_000)) return error.InvalidStreamAsset;
            _ = try indexer.recovery(entry, self.info);
            previous = entry.logical_frame;
        }
    }
    pub fn retain(self: *Asset) Error!void {
        if (self.retired.load(.acquire)) return error.InvalidState;
        var count = self.references.load(.acquire);
        for (0..8) |_| {
            if (count == 0 or count == std.math.maxInt(u32)) return error.InvalidState;
            count = self.references.cmpxchgStrong(count, count + 1, .acq_rel, .acquire) orelse return;
        }
        return error.InvalidState;
    }
    pub fn release(self: *Asset) void {
        std.debug.assert(self.references.fetchSub(1, .acq_rel) > 0);
    }
    pub fn retire(self: *Asset) void {
        if (!self.retired.swap(true, .acq_rel)) self.release();
    }
    pub fn canDestroy(self: *const Asset) bool {
        return self.retired.load(.acquire) and self.references.load(.acquire) == 0;
    }
};
pub const Open = struct {
    generation: u64,
    transport_epoch: u64,
    group: u64,
    layer: u64,
    start_cursor: u64 = 0,
    loop_epoch: u64 = 0,
    loop: ?ring.Loop = null,
    priority: p.Priority = .active_required,
    deadline_frame: u64 = 0,
    operation: trace.schema.WorkerOperation = .prefetch,
};
const State = observation.JobState;
const Job = struct {
    state: std.atomic.Value(State) = .init(.free),
    handle: Handle = .{ .index = 0, .generation = 0 },
    descriptor: trace.schema.readiness.JobDescriptor = undefined,
    ordinal: u64 = 0,
    count: u32 = 0,
    priority: p.Priority = .optional,
    pcm: []f32 = &.{},
    outcome: trace.schema.Readiness = .not_ready,
    failure: Failure = .none,
    hash: [32]u8 = @splat(0),
    elapsed_ns: u64 = 0,
    descriptor_bytes: [128]u8 = undefined,
    descriptor_len: usize = 0,
};
const Slot = struct {
    occupied: bool = false,
    generation: u64 = 0,
    asset: *Asset = undefined,
    options: Open = undefined,
    pcm_ring: ring.Ring = undefined,
    pending_job: ?u16 = null,
    cancel: std.atomic.Value(bool) = .init(false),
    packets: opus.BoundedPacketSource = undefined,
    decoder: ?opus.Decoder = null,
    source_context: SourceContext = undefined,
    failed: Failure = .none,
    filling: bool = false,
    snapshot_version: u64 = 1,
    replay_readiness: ?trace.Input = null,
    visibility_refs: u32 = 0,
    // Control-owned, derived only from real admitted visibility receipts.
    acknowledged_visible_prefix: u64 = 0,
};
const SourceContext = struct { service: *Service, slot: *Slot, job: u64 = 0 };
pub const Memory = struct { owned_bytes: usize, native_decoder_bytes: usize, peak_native_decoder_bytes: usize, total_requested_bytes: usize, pcm_capacity_bytes: usize };
pub const Accepted = observation.Accepted;
/// Non-RT deterministic barriers. Both observed and ordinary operations call
/// the same hook. No engine mutation/reentrancy; tests may coordinate Worker
/// or Render on their own threads. Entirely absent from shipping state.
pub const AcceptanceStage = enum { before_scan, before_job_state, after_job_state, after_scan, before_accept_job, after_accept_job, before_visibility_poll, after_visibility_poll };
pub const AcceptanceHook = struct { context: *anyopaque, call: *const fn (*anyopaque, AcceptanceStage, usize) void };
/// Offline exact-load/release barriers. Before-frontier has no loaded value
/// and passes zero; all other stages pass the actual head/publication ordinal.
pub const PublicationStage = enum { before_frontier, after_frontier, before_publication_release, after_publication_release };
pub const PublicationHook = struct { context: *anyopaque, call: *const fn (*anyopaque, PublicationStage, u64) void };
/// Real Worker publication/idle boundaries. The job identity is copied before
/// completed becomes visible and is never read from a returned job slot.
pub const WorkerStage = enum { after_completed, before_idle, after_idle };
pub const WorkerStageHook = struct { context: *anyopaque, call: *const fn (*anyopaque, WorkerStage, u64) void };
/// Owned facts from the real Worker. This is a diagnostic producer, not a
/// dispatch API: a sink must only copy into its bounded Worker-owned lane.
/// It may not block, allocate, encode, perform I/O or mutate this service.
/// A queued descriptor is copied only after its acquire; free/running/completed
/// slots deliberately carry no descriptor that Control could concurrently reuse.
pub const WorkerFact = union(enum) {
    scan: struct {
        index: u16,
        state: observation.JobState,
        job: u64 = 0,
        handle: Handle = .{ .index = 0, .generation = 0 },
        generation: u64 = 0,
        transport_epoch: u64 = 0,
    },
    selected: struct { job: u64, slot: u16 },
    clock: struct { stage: WorkerClockStage, job: u64, value: u64, available: bool, error_code: u32 },
    source_read: struct {
        asset: u64,
        asset_hash: [32]u8,
        slot: u16,
        generation: u64,
        offset: u64,
        length: u32,
        error_code: u32,
    },
    completed: struct { job: u64, slot: u16 },
    idle: struct { job: u64 },
};
pub const WorkerClockStage = enum(u8) { begin, end };
/// Stable wire classifications. The original engine error still propagates
/// normally; profile v1 rejects nonzero external failures as incomplete.
pub const WorkerExternalError = enum(u32) { none = 0, clock_failure = 1, source_failure = 2 };
pub const WorkerFactSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, WorkerFact) void };
/// Exact external source calls from Service preparation and real decoder I/O.
/// These owned facts are output-only. They never inject bytes or errors. Calls
/// are Worker/preparation-exclusion ordered; call zero is an overflow sentinel
/// which permanently invalidates a recording, never the engine operation.
pub const SourceFact = struct {
    phase: enum(u8) { prepare, decode },
    edge: live_semantic.Edge,
    call: u64,
    asset: u64,
    asset_hash: [32]u8,
    sound_index: u32,
    job: u64 = 0,
    slot: ?u16 = null,
    generation: u64 = 0,
    offset: u64,
    length: u64,
    error_code: u32 = 0,
    bytes_hash: [32]u8 = @splat(0),
};
pub const SourceFactSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, SourceFact) void };
/// Borrowed immutable binding, installed only at genuinely excluded startup.
/// Capture is passive/bounded. Offline cuts may coordinate replay-owned roles;
/// only clock may provide raw input and only through the separate offline bind.
/// Worker facts and source results have no return/decision channel.
/// Offline-only pacing at real DSP consumed releases. No return channel,
/// cursor assignment, PCM injection, or capture-side per-sample records.
/// The binding is frozen before any stream exists until genuine joined teardown.
pub const LiveSemanticConsumeCheckpoint = struct {
    context: *anyopaque,
    checkpoint: *const fn (*anyopaque, ConsumedCheckpoint) void,
};
/// Explicit capture-only controlled workload. Not an engine-result channel.
/// Context is immutable and pinned until genuine Worker/Render joins. Only
/// the test coordinator may wait, with bounded cancellation, at rendezvous
/// events; queue_before and worker_completed are notification-only.
pub const TestRetryWorkloadEvent = union(enum) {
    queue_before: struct { job: u64, handle: Handle },
    worker_completed: struct { job: u64, outcome: trace.schema.Readiness },
    before_attempt: trace.schema.Position,
    after_attempt: struct { attempt: *const LiveAcceptanceAttemptV1, effective_frame: u64, finished: bool },
    render_odd: u64,
    render_even: u64,
    /// Test capture rendezvous after the original frame load, before its AFTER marker.
    frame_loaded: u64,
    consumed_loaded: struct { index: u64, generation: u64, value: u64 },
};
pub const TestRetryWorkload = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque, TestRetryWorkloadEvent) void,
};
pub const LiveSemanticHooks = struct {
    cuts: live_semantic.Binding,
    worker_facts: ?WorkerFactSink = null,
    source: ?SourceFactSink = null,
    clock: ?*live_semantic.OfflineClock = null,
    consume: ?LiveSemanticConsumeCheckpoint = null,
    test_retry_workload: if (@import("builtin").is_test) ?TestRetryWorkload else void = if (@import("builtin").is_test) null else {},
    pub fn same(a: LiveSemanticHooks, b: LiveSemanticHooks) bool {
        return live_semantic.Binding.same(a.cuts, b.cuts) and std.meta.eql(a.worker_facts, b.worker_facts) and
            std.meta.eql(a.source, b.source) and a.clock == b.clock and std.meta.eql(a.consume, b.consume) and
            (if (@import("builtin").is_test) std.meta.eql(a.test_retry_workload, b.test_retry_workload) else true);
    }
};

/// Profile-5-only evidence for one successfully acquired and released use of
/// worker_busy. No shared readiness/acceptance witness layout is extended.
pub const ServiceExclusionOwner = union(enum) {
    worker: struct { job: u64 },
    stream_close: struct { handle: Handle, parent_attempt: u64 },
    prepare_asset: struct { sound_index: u32, asset: u64, encoded_hash: [32]u8 },
};
pub const ServiceExclusion = struct { ticket: u64, owner: ServiceExclusionOwner };
/// Diagnostic identity for each actual worker_busy CAS, including failures.
/// The Worker job is not known until after a successful claim and scan.
pub const ServiceClaimKind = union(enum) {
    worker: void,
    stream_close: struct { handle: Handle, parent_attempt: u64 },
    prepare_asset: struct { sound_index: u32, asset: u64, encoded_hash: [32]u8 },
};
pub const ServiceClaimAttempt = struct { kind: ServiceClaimKind, token: u64, observed: u64 };
/// One actual post-unlock publication by the single recorded Worker producer.
/// token is the successful CAS token; ticket is its original exclusion ticket.
pub const ServiceWorkerRelease = struct { token: u64, ticket: u64 };
/// Only this target uses the word-sized holder token. Other targets retain
/// the original bool atomic and reject token recording through overflow.
pub const supports_causal_claim_tokens = @import("builtin").cpu.arch == .x86_64;
const BusyState = struct {
    const Value = if (supports_causal_claim_tokens) u64 else bool;
    value: std.atomic.Value(Value),

    pub fn init(value: bool) BusyState {
        return .{ .value = .init(if (comptime supports_causal_claim_tokens) @as(u64, @intFromBool(value)) else value) };
    }
    pub fn load(self: *const BusyState, comptime memory_order: std.builtin.AtomicOrder) bool {
        if (comptime supports_causal_claim_tokens) {
            return self.value.load(memory_order) != 0;
        } else {
            return self.value.load(memory_order);
        }
    }
    pub fn store(self: *BusyState, value: bool, comptime memory_order: std.builtin.AtomicOrder) void {
        self.value.store(if (comptime supports_causal_claim_tokens) @as(u64, @intFromBool(value)) else value, memory_order);
    }
    fn claim(self: *BusyState, token: u64) u64 {
        if (comptime supports_causal_claim_tokens) {
            return self.value.cmpxchgStrong(0, token, .acquire, .monotonic) orelse 0;
        } else {
            return @intFromBool(self.value.cmpxchgStrong(false, true, .acquire, .monotonic) orelse false);
        }
    }
};
pub const ServiceExclusionSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, ServiceExclusion) void,
    /// Permanently fail recording only. The original operation still executes
    /// its existing release and returns its original engine result.
    overflow: *const fn (*anyopaque) void,
    /// Recorder-owned role/ordinal allocation, before the one original CAS.
    /// Both hooks must be bounded and nonblocking, including on failed claims.
    claim_token: ?*const fn (*anyopaque, ServiceClaimKind) u64 = null,
    /// Called immediately after the CAS, before the existing offline hook.
    /// observed is zero for success, otherwise the actual held token.
    claim_attempt: ?*const fn (*anyopaque, ServiceClaimAttempt) void = null,
    /// Enables the independently published Worker release frontier. Called
    /// after its release-store; copy only into the bounded Worker-owned lane.
    worker_release: ?*const fn (*anyopaque, ServiceWorkerRelease) void = null,
};
/// Pinned by the profile-5 recorder. Attach/reset only at its genuine initial
/// Worker pause; detach only after all callers have joined. Ticket fields are
/// accessed solely while the ORIGINAL worker_busy claim is held. The release
/// frontier has one recorded Worker producer and actual Control acquire reads.
pub const ServiceExclusionWitness = struct {
    sink: ServiceExclusionSink,
    last_ticket: u64 = 0,
    overflowed: bool = false,
    last_worker_released: if (supports_causal_claim_tokens) std.atomic.Value(u64) else void = if (supports_causal_claim_tokens) .init(0) else {},
    fn claim(self: *ServiceExclusionWitness) ?ServiceExclusionClaim {
        if (self.overflowed) return null;
        if (self.last_ticket == std.math.maxInt(u64)) {
            self.overflowed = true;
            self.sink.overflow(self.sink.context);
            return null;
        }
        self.last_ticket += 1;
        return .{ .sink = self.sink, .ticket = self.last_ticket };
    }
};
const ServiceExclusionClaim = struct {
    sink: ServiceExclusionSink,
    ticket: u64,
    fn released(self: ServiceExclusionClaim, owner: ServiceExclusionOwner) void {
        // A later holder may already have advanced the witness counter. Only
        // this claim's copied ticket/sink survive the actual release store.
        self.sink.emit(self.sink.context, .{ .ticket = self.ticket, .owner = owner });
    }
};
/// Internal offline executor ABI. This is deliberately separate from live
/// observation. Only a pristine offline owner may install it, before starting
/// replay-owned threads; removal follows their actual joins. Ordinary capture
/// never installs this pointer and never waits for its observer.
pub const OfflineSite = enum {
    availability_readiness_sequence_before,
    availability_readiness_frame,
    availability_readiness_control_consumed,
    availability_readiness_produced,
    availability_readiness_sequence_after,
    availability_acceptance_sequence_before,
    availability_acceptance_frame,
    availability_acceptance_control_consumed,
    availability_acceptance_produced,
    availability_acceptance_sequence_after,
    stream_ring_consumed,
    stream_ring_produced,
    stream_produced,
    stream_observation_frame,
    worker_claim,
    worker_scan,
    worker_running,
    worker_completed,
    worker_idle,
    job_queued,
    job_free,
    worker_cancel,
    worker_stopped,
    acceptance_scan,
    publication_release,
    publication_frontier,
    visibility_head,
    visibility_produced,
    visibility_stopped,
    visibility_release,
    visibility_poll,
    visibility_ack,
    readiness_stopped_first,
    readiness_stopped_second,
    readiness_sequence,
    readiness_frame,
    readiness_consumed,
    readiness_produced,
    readiness_job,
    readiness_final_sequence,
    render_sequence_odd,
    render_consumed,
    render_frame,
    render_sequence_even,
    stream_close_claim,
    stream_close_pending,
    stream_close_idle,
    service_prepare_claim,
    service_prepare_idle,
    stream_consumed_release,
    stream_close_visibility,
    stream_close_stopped,
    worker_release_progress,
    control_release_progress,
    // Append-only private Live observer sites; not old causal wire tags.
    slot_guard_open,
    slot_guard_close,
    slot_guard_render_claim,
    slot_guard_render_release,
    initial_entry_consumed,
    initial_entry_cancel,
};
pub const OfflineEdge = enum { before, after };
pub const OfflineCheckpoint = struct { site: OfflineSite, edge: OfflineEdge, index: u64 = 0, generation: u64 = 0, value: u64 = 0 };
pub const OfflineClockSample = struct { value: u64, available: bool, error_code: u32 = 0 };
pub const OfflineReplayHooks = struct {
    context: *anyopaque,
    checkpoint: *const fn (*anyopaque, OfflineCheckpoint) void,
    /// Reuses only the raw external clock observation at this matching clock
    /// call. It cannot supply elapsed time, throughput, jobs or decoded PCM.
    clock: *const fn (*anyopaque, WorkerClockStage, u64) OfflineClockSample,
};
/// Test-only controlled-recipe raw-input seam. Capture leaves replay null and
/// observes the original native clock sample. Replay replaces only that raw
/// input; elapsed time, throughput, job selection and decode remain real.
/// Callbacks must use bounded owned storage and latch every failure. The test
/// dispatcher must reject after the current genuine operation returns; a neutral
/// sample used to unwind a failed callback is never accepted replay evidence.
pub const TestCheckpointHook = struct { context: *anyopaque, call: *const fn (*anyopaque, OfflineCheckpoint) void };
/// Pinned state for the explicit joined fixture only. Worker owns mutation during
/// a command. Host may abort only after the real command return/acquire; the
/// fixed serialized fixture excludes all other writers. Health is never custody.
pub const TestJoinedClock = struct {
    pub const Source = enum { capture_native, replay_input, abort_native };
    pub const Failure = enum { none, expected_input, host_abort };
    pub const Next = *const fn (*anyopaque, WorkerClockStage, u64) ?OfflineClockSample;
    address: ?*TestJoinedClock = null,
    // One owner-issued joined session for this pinned lifetime. Never reset or
    // released for reuse, including after free; Host retains it through joins.
    session: ?*anyopaque = null,
    sample_attempts: u64 = 0,
    context: *anyopaque = undefined,
    next: ?Next = null,
    failure: TestJoinedClock.Failure = .none,
    source: TestJoinedClock.Source = .capture_native,
    native_attempts: u64 = 0,

    pub fn init(self: *TestJoinedClock, context: *anyopaque, next: ?Next) !void {
        if (self.address != null) return error.InvalidState;
        self.* = .{ .address = self, .context = context, .next = next };
    }
    pub fn validateInitial(self: *const TestJoinedClock) !void {
        if (self.address != self or self.session != null or self.sample_attempts != 0 or self.failure != .none or self.native_attempts != 0) return error.InvalidState;
    }
    /// Infallible owner startup commit after complete checked registration.
    pub fn claimSession(self: *TestJoinedClock, session: *anyopaque) void {
        std.debug.assert(self.address == self and self.session == null and self.sample_attempts == 0);
        self.session = session;
    }
    /// Host-only after actual return/acquire; no expected callback is called
    /// after this irreversible failure. The hook identity itself is unchanged.
    pub fn abortAfterReturn(self: *TestJoinedClock) void {
        std.debug.assert(self.address == self);
        if (self.failure == .none) self.failure = .host_abort;
    }
};
/// Passive copy of the already acquired Worker clock result. No replacement
/// function or clock access is exposed. Install/remove under Worker exclusion;
/// callbacks must not wait or perform I/O and their storage outlives the Worker.
pub const TestWorkerClockObserver = if (@import("builtin").is_test) struct {
    context: *anyopaque,
    observe: *const fn (*anyopaque, WorkerClockStage, u64, OfflineClockSample) void,
} else struct {};

pub const TestWorkerClockHook = struct {
    context: *anyopaque,
    observe: *const fn (*anyopaque, WorkerClockStage, u64, OfflineClockSample) void,
    replay: ?*const fn (*anyopaque, WorkerClockStage, u64) OfflineClockSample = null,
    /// Mutually exclusive with legacy replay. Checked joined registration binds
    /// the exact state, context and decision function before actual preparation.
    joined: ?*TestJoinedClock = null,
};
/// Attachment shape only; no mode certifies a complete recording/profile.
/// Semantic span explicitly opts out of per-sample Ring order and consumed
/// callbacks, including when finite offline replay hooks remain installed.
/// Semantic replay opts a fresh offline owner into consumed checkpoints only;
/// it retains the same real engine path and never attaches per-sample order.
pub const OrderAttachmentMode = enum(u8) { prerequisite, semantic_span, semantic_replay };
pub const Service = struct {
    allocator: std.mem.Allocator,
    profile: p.StreamCapacityProfile,
    slots: []Slot,
    jobs: []Job,
    slot_guards: []std.atomic.Value(u8), // 0 live, 1 bounded render pin, 2 closed
    publications: []visibility.Entry,
    acknowledged_visibility_invalid: bool = false,
    publication_head: std.atomic.Value(u64) = .init(0),
    publication_read: std.atomic.Value(u64) = .init(0),
    publication_tail: std.atomic.Value(u64) = .init(0),
    runtime_attached: bool = false,
    /// Installed only by the real Control attachment, never supplied by a
    /// readiness/prefetch caller. Control-only, cleared on genuine detach.
    initial_entry_owner: ?struct {
        context: *anyopaque,
        validate: *const fn (*anyopaque, *Service, u64, u64, Handle) Error!InitialEntryContextV1,
    } = null,
    visibility_backpressure: u64 = 0,
    last_batch_id: u64 = 0,
    visibility_discarded: bool = false,
    last_render_gate: std.atomic.Value(u64) = .init(0),
    last_render_frame: std.atomic.Value(u64) = .init(0),
    observation_sequence: std.atomic.Value(u64) = .init(0),
    observation_frame: std.atomic.Value(u64) = .init(0),
    free_indices: []u16,
    free_stream_count: usize,
    free_job_count: usize,
    rings_pcm: []f32,
    job_pcm: []f32,
    encoded_cache: []u8,
    cache_slot: ?u16 = null,
    cache_generation: u64 = 0,
    cache_chunk: usize = 0,
    source_failure: Failure = .none,
    worker_busy: BusyState = .init(false),
    next_generation: u64 = 1,
    next_job: u64 = 1,
    next_snapshot: u64 = 1,
    throughput: p.Throughput = .{},
    clock: ?trace.metrics.Clock,
    native_bytes: std.atomic.Value(usize) = .init(0),
    peak_native_bytes: std.atomic.Value(usize) = .init(0),
    decoder_zig_bytes: std.atomic.Value(usize) = .init(0),
    accepted_count: u64 = 0,
    stale_completions: u64 = 0,
    job_overflows: u64 = 0,
    replay_mode: bool = false,
    /// Control-owned and scoped to the admitted integrated tick.
    readiness_supply_sink: ?readiness_observation.SupplySink = null,
    readiness_lifecycle_sink: ?readiness_observation.LifecycleSink = null,
    readiness_attached: bool = false,
    /// Attach/detach only with genuine Worker exclusion. The public recording
    /// session supplies attribution and sticky overflow handling; the service
    /// never treats an emitted fact as an acknowledgement of Worker lifetime.
    public_causal_worker_sink: ?WorkerFactSink = null,
    public_causal_exclusion: ?*ServiceExclusionWitness = null,
    public_causal_consumed_sink: ?ring.ConsumedSink = null,
    offline_causal_replay: ?OfflineReplayHooks = null,
    /// Separate production semantic binding. No all-scalar collector or old
    /// replay hook is attached. The caller keeps this value and context pinned
    /// until real Worker/Render joins plus serialized Control exclusion.
    live_semantic_hooks: ?LiveSemanticHooks = null,
    /// Sole Worker/preparation owner under worker_busy; never read by Render.
    semantic_source_call: u64 = 0,
    /// Startup eligibility only, accessed under actual preparation exclusion.
    semantic_preparation_started: bool = false,
    /// Immutable borrowed collectors installed only under real caller exclusion.
    /// Every subsystem and PCM ring shares these same per-role producer lanes.
    prerequisite_order: ?order.Roles = null,
    /// Immutable with prerequisite_order until the matching quiescent detach.
    /// Accounted by capacityBytes/memory through @sizeOf(Service).
    prerequisite_order_mode: OrderAttachmentMode = .prerequisite,
    // Immutable during producer activity. Explicit Live attachment only.
    live_slot_guard_points: bool = false,
    /// Same explicit Live attachment lifetime; no change to legacy offline sites.
    live_availability_points: bool = false,
    /// Test-only passive checkpoints; unlike offline replay this never replaces
    /// clocks/values or changes live admission. Install before publication.
    test_checkpoint_hook: if (@import("builtin").is_test) ?TestCheckpointHook else void = if (@import("builtin").is_test) null else {},
    /// Install only while the sole Worker is parked; absent from shipping state.
    test_worker_clock_hook: if (@import("builtin").is_test) ?TestWorkerClockHook else void = if (@import("builtin").is_test) null else {},
    /// Test-only passive result notification, distinct from the substituting
    /// clock hook. It never selects a sample or changes workerClock's return.
    test_worker_clock_observer: if (@import("builtin").is_test) ?TestWorkerClockObserver else void = if (@import("builtin").is_test) null else {},
    /// Narrow deterministic original-capture seam. Offline replay never calls it.
    test_consumed_hook: if (@import("builtin").is_test) ?struct { context: *anyopaque, call: *const fn (*anyopaque, OfflineCheckpoint) void } else void = if (@import("builtin").is_test) null else {},
    test_readiness_hook: if (@import("builtin").is_test) ?readiness_observation.ReadHook else void = if (@import("builtin").is_test) null else {},
    test_availability_hook: if (@import("builtin").is_test) ?AvailabilityHook else void = if (@import("builtin").is_test) null else {},
    test_supply_hook: if (@import("builtin").is_test) ?struct { context: *anyopaque, call: *const fn (*anyopaque, TestSupplyPoint) void } else void = if (@import("builtin").is_test) null else {},
    test_supply_return_hook: if (@import("builtin").is_test) ?struct { context: *anyopaque, call: *const fn (*anyopaque, TestSupplyReturn) void } else void = if (@import("builtin").is_test) null else {},
    test_frontier_hook: if (@import("builtin").is_test) ?readiness_observation.FrontierHook else void = if (@import("builtin").is_test) null else {},
    /// Deterministic race barrier, compiled out of shipping service state.
    test_worker_hook: if (@import("builtin").is_test) ?struct { context: *anyopaque, call: *const fn (*anyopaque, u64) void } else void = if (@import("builtin").is_test) null else {},
    test_worker_stage_hook: if (@import("builtin").is_test) ?WorkerStageHook else void = if (@import("builtin").is_test) null else {},
    test_acceptance_hook: if (@import("builtin").is_test) ?AcceptanceHook else void = if (@import("builtin").is_test) null else {},
    test_publication_hook: if (@import("builtin").is_test) ?PublicationHook else void = if (@import("builtin").is_test) null else {},
    /// Preallocation admission includes a native-state upper bound, all packet
    /// buffers and a conservative 4KiB decoder metadata/alignment allowance.
    /// Actual requested Zig/native bytes remain separately measured below.
    pub fn capacityBytes(profile: p.StreamCapacityProfile) Error!usize {
        try profile.validate();
        const per_stream = @sizeOf(std.atomic.Value(u8)) + @sizeOf(Slot) + @sizeOf(Asset) + @sizeOf(@import("file_source.zig").FileSource) + opus.max_page_bytes + opus.container.max_packet_bytes + opus.types.max_packet_frames * @as(usize, profile.max_channels) * 4 + 4096 + opus.max_native_state_bytes;
        const fixed = @as(usize, profile.visibility_capacity) * @sizeOf(visibility.Entry) + @sizeOf(Service) + (@as(usize, profile.max_streams) + profile.job_capacity) * @sizeOf(u16) + @as(usize, profile.max_streams) * per_stream + @as(usize, profile.job_capacity) * @sizeOf(Job) + profile.max_encoded_chunk_bytes;
        return std.math.add(usize, fixed, try profile.pcmBytes()) catch error.CapacityOverflow;
    }
    pub fn create(allocator: std.mem.Allocator, profile: p.StreamCapacityProfile) Error!*Service {
        try profile.validate();
        if (try capacityBytes(profile) > profile.allocation_budget_bytes) return error.InvalidStreamProfile;
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        const slots = try allocator.alloc(Slot, profile.max_streams);
        errdefer allocator.free(slots);
        const guards = try allocator.alloc(std.atomic.Value(u8), profile.max_streams);
        errdefer allocator.free(guards);
        for (guards) |*guard| guard.* = .init(2);
        const publications = try allocator.alloc(visibility.Entry, profile.visibility_capacity);
        errdefer allocator.free(publications);
        const jobs = try allocator.alloc(Job, profile.job_capacity);
        errdefer allocator.free(jobs);
        const rings_pcm = try allocator.alloc(f32, @as(usize, profile.max_streams) * profile.ring_frames * profile.max_channels);
        errdefer allocator.free(rings_pcm);
        const job_pcm = try allocator.alloc(f32, @as(usize, profile.job_capacity) * profile.decode_chunk_frames * profile.max_channels);
        errdefer allocator.free(job_pcm);
        const cache = try allocator.alloc(u8, profile.max_encoded_chunk_bytes);
        errdefer allocator.free(cache);
        const free_indices = try allocator.alloc(u16, @as(usize, profile.max_streams) + profile.job_capacity);
        errdefer allocator.free(free_indices);
        for (free_indices[0..profile.max_streams], 0..) |*index, i| index.* = @intCast(profile.max_streams - 1 - i);
        for (free_indices[profile.max_streams..], 0..) |*index, i| index.* = @intCast(profile.job_capacity - 1 - i);
        self.* = .{ .allocator = allocator, .profile = profile, .slots = slots, .jobs = jobs, .slot_guards = guards, .publications = publications, .free_indices = free_indices, .free_stream_count = profile.max_streams, .free_job_count = profile.job_capacity, .rings_pcm = rings_pcm, .job_pcm = job_pcm, .encoded_cache = cache, .clock = trace.metrics.Clock.init() catch null };
        for (slots) |*slot| slot.* = .{};
        for (jobs, 0..) |*job, i| job.* = .{ .pcm = job_pcm[i * profile.decode_chunk_frames * profile.max_channels ..][0 .. profile.decode_chunk_frames * profile.max_channels] };
        return self;
    }
    /// Host must stop its worker caller before destruction. All streams and
    /// render leases must be acknowledged first; no callback frees storage.
    /// The joined host must detach borrowed prerequisite collectors first.
    /// Semantic storage stays pinned through this call; only the successful
    /// final free boundary clears it, after all fallible native drain gates.
    pub fn destroy(self: *Service) Error!void {
        try self.validateDestroyQuiescent();
        // Final infallible free boundary under the caller's genuine Control /
        // Worker / Render exclusion. Keep semantic callbacks through every
        // fallible native drain gate; a failed destroy cannot detach them.
        self.live_semantic_hooks = null;
        const allocator = self.allocator;
        allocator.free(self.free_indices);
        allocator.free(self.encoded_cache);
        allocator.free(self.job_pcm);
        allocator.free(self.rings_pcm);
        allocator.free(self.jobs);
        allocator.free(self.publications);
        allocator.free(self.slot_guards);
        allocator.free(self.slots);
        allocator.destroy(self);
    }
    /// The exact original non-mutating destroy gates. The caller must already
    /// exclude all users; this check is not proof of park, callback stop or join.
    /// Shared with the staged owner's late boundary, without weakening destroy.
    pub fn validateDestroyQuiescent(self: *Service) Error!void {
        if (self.prerequisite_order != null) return error.DrainPending;
        try self.validatePhysicalDestroyQuiescent();
    }
    /// Same physical gates for an authenticated test-only owned borrow. This
    /// grants no permission to detach or free; prerequisite borrows still need
    /// explicit detach. Semantic bindings survive until successful final free.
    pub fn validatePhysicalDestroyQuiescent(self: *Service) Error!void {
        if (self.readiness_attached or self.runtime_attached or self.worker_busy.load(.acquire) or self.publication_tail.load(.acquire) != self.publication_head.load(.acquire)) return error.DrainPending;
        for (self.slots) |*slot| if (slot.occupied) return error.DrainPending;
        for (self.jobs) |*job| if (job.state.load(.acquire) != .free) return error.DrainPending;
    }
    /// Worker/preparation-only construction from bank descriptors and real
    /// authenticated source headers. Reuses this service's bounded cache; the
    /// caller need not retain an offline Scan or manually invent codec metadata.
    pub fn prepareAsset(self: *Service, descriptor: Asset.Descriptor) Error!Asset {
        self.offline(.service_prepare_claim, .before, descriptor.sound_index, descriptor.sound.key.id, 0);
        self.orderCheckpoint(.worker, .service_prepare_claim, .before, descriptor.sound_index, descriptor.sound.key.id, null);
        const busy = self.claimBusy(.{ .prepare_asset = .{ .sound_index = descriptor.sound_index, .asset = descriptor.sound.key.id, .encoded_hash = descriptor.sound.audio_hash } }) != null;
        self.orderCheckpoint(.worker, .service_prepare_claim, .after, descriptor.sound_index, descriptor.sound.key.id, @intFromBool(busy));
        self.offline(.service_prepare_claim, .after, descriptor.sound_index, descriptor.sound.key.id, @intFromBool(busy));
        if (busy) return error.WorkerBusy;
        self.semantic_preparation_started = true;
        const exclusion = self.exclusionClaim();
        defer {
            self.offline(.service_prepare_idle, .before, descriptor.sound_index, descriptor.sound.key.id, 0);
            self.orderCheckpoint(.worker, .service_prepare_idle, .before, descriptor.sound_index, descriptor.sound.key.id, 0);
            self.worker_busy.store(false, .release);
            self.orderCheckpoint(.worker, .service_prepare_idle, .after, descriptor.sound_index, descriptor.sound.key.id, 0);
            self.offline(.service_prepare_idle, .after, descriptor.sound_index, descriptor.sound.key.id, 0);
            if (exclusion) |claim| claim.released(.{ .prepare_asset = .{ .sound_index = descriptor.sound_index, .asset = descriptor.sound.key.id, .encoded_hash = descriptor.sound.audio_hash } });
        }
        self.cache_slot = null;
        if (self.live_semantic_hooks) |hooks| if (hooks.source != null) {
            var source_context: SemanticSourceContext = .{
                .service = self,
                .source = descriptor.source,
                .fact = .{ .phase = .prepare, .edge = .before, .call = 0, .asset = descriptor.sound.key.id, .asset_hash = descriptor.sound.audio_hash, .sound_index = descriptor.sound_index, .offset = 0, .length = 0 },
            };
            var wrapped = descriptor;
            wrapped.source = .{ .context = &source_context, .length = descriptor.source.length, .read_at = semanticSourceRead };
            var asset = try Asset.fromSource(self.encoded_cache, wrapped, self.profile);
            // The stack wrapper exists only for synchronous derivation. Never
            // publish its context into the returned asset's borrowed lifetime.
            asset.source = descriptor.source;
            return asset;
        };
        return Asset.fromSource(self.encoded_cache, descriptor, self.profile);
    }
    /// Control-only registration. Source + typed tables remain borrowed under
    /// Asset's lease until close succeeds. No file API or decoder is called.
    pub fn open(self: *Service, asset: *Asset, options: Open) Error!Handle {
        return self.openObserved(asset, options, 0);
    }
    pub fn observeReadinessLifecycle(self: *Service, read: readiness_observation.LifecycleRead) u64 {
        const sink = self.readiness_lifecycle_sink orelse return 0;
        return sink.emit(sink.context, read);
    }
    pub fn openObserved(self: *Service, asset: *Asset, options: Open, parent_attempt: u64) Error!Handle {
        var read: readiness_observation.StreamOpenRead = .{
            .parent_attempt = parent_attempt,
            .asset_generation = options.generation,
            .transport_epoch = options.transport_epoch,
            .group = options.group,
            .layer = options.layer,
            .start_cursor = options.start_cursor,
            .loop_epoch = options.loop_epoch,
        };
        defer _ = self.observeReadinessLifecycle(.{ .open = read });
        errdefer |err| read.error_code = @intFromError(err);
        // Reject a conflicting attachment before any stream/asset mutation.
        // Collector overflow is not attachment failure and never gates open.
        if (self.prerequisite_order_mode == .semantic_span and
            (self.prerequisite_order == null or self.public_causal_consumed_sink != null)) return error.InvalidState;
        if (self.prerequisite_order_mode == .semantic_replay and
            (self.prerequisite_order == null or self.offline_causal_replay == null or
                self.replay_mode or self.public_causal_consumed_sink != null)) return error.InvalidState;
        try asset.validate(self.profile);
        if (options.generation == 0 or options.transport_epoch == 0 or options.group == 0 or options.layer == 0 or options.start_cursor >= asset.sound.frames or self.next_snapshot == std.math.maxInt(u64) or self.next_generation == std.math.maxInt(u64)) return error.InvalidStreamAsset;
        if (options.loop) |loop| if (loop.start >= loop.end or loop.end > asset.sound.frames or options.start_cursor >= loop.end) return error.InvalidStreamAsset;
        const free_before = self.free_stream_count;
        read.free_before = @intCast(free_before);
        if (free_before == 0) return error.StreamCapacity;
        const index = self.free_indices[free_before - 1];
        read.selected_index = index;
        try asset.retain();
        errdefer asset.release();
        const slot = &self.slots[index];
        const count: usize = @as(usize, self.profile.ring_frames) * self.profile.max_channels;
        slot.* = .{ .generation = self.next_generation, .asset = asset, .options = options, .pcm_ring = .{ .gated = self.runtime_attached, .generation = self.next_generation, .pcm = self.rings_pcm[index * count ..][0..count], .channels = asset.info.channels, .capacity_frames = self.profile.ring_frames, .start_cursor = options.start_cursor, .start_loop_epoch = options.loop_epoch, .frames = asset.sound.frames, .loop = options.loop } };
        // Semantic capture leaves both Render-side pointers null from creation,
        // even with offline hooks installed. The separate fresh-offline replay
        // attachment enables actual consumed-release pacing, never Ring order.
        if (self.prerequisite_order_mode == .prerequisite and
            (self.public_causal_consumed_sink != null or self.offline_causal_replay != null)) slot.pcm_ring.consume_observer = .{ .context = self, .index = index, .generation = self.next_generation, .emit = consumedPublication, .checkpoint = ringPoint };
        if (self.prerequisite_order_mode == .semantic_replay) slot.pcm_ring.consume_observer = .{ .context = self, .index = index, .generation = self.next_generation, .emit = consumedPublication, .checkpoint = ringPoint };
        if (self.live_semantic_hooks) |hooks| if (hooks.consume != null) {
            // Replay attachment was validated before preparation. The observer
            // is installed before this ring is published to any consumer.
            std.debug.assert(hooks.clock != null and slot.pcm_ring.consume_observer == null);
            slot.pcm_ring.consume_observer = .{ .context = self, .index = index, .generation = self.next_generation, .emit = semanticConsumedNoop, .checkpoint = semanticConsumedPoint };
        };
        slot.source_context = .{ .service = self, .slot = slot };
        slot.packets = try opus.BoundedPacketSource.prepare(self.allocator, .{ .context = &slot.source_context, .length = asset.source.length, .read_at = verifiedRead }, asset.info);
        // Identity is final and preparation succeeded, but no handle or live
        // render guard has escaped. Ring checkpoints use the service's lanes.
        if (self.prerequisite_order) |roles| {
            slot.pcm_ring.order_control = .{ .collector = roles.control, .index = index, .generation = slot.generation };
            if (self.prerequisite_order_mode == .prerequisite) slot.pcm_ring.order_render = .{ .collector = roles.render, .index = index, .generation = slot.generation };
        }
        slot.occupied = true;
        self.slotGuardPoint(.control, .slot_guard_open, .before, index, slot.generation, 0);
        self.slot_guards[index].store(0, .release);
        self.slotGuardPoint(.control, .slot_guard_open, .after, index, slot.generation, 0);
        read.guard_published = 0;
        self.free_stream_count -= 1;
        read.free_after = @intCast(self.free_stream_count);
        slot.snapshot_version = self.next_snapshot;
        self.next_snapshot += 1;
        self.next_generation += 1;
        read.next_generation_after = self.next_generation;
        const handle: Handle = .{ .index = @intCast(index), .generation = slot.generation };
        read.result = handle;
        return handle;
    }
    fn get(self: *Service, handle: Handle) Error!*Slot {
        return self.getObserved(handle, null);
    }
    fn getObserved(self: *Service, handle: Handle, observed: ?*readiness_observation.StreamValidation) Error!*Slot {
        const in_bounds = handle.index < self.slots.len;
        if (observed) |value| value.index_in_bounds = in_bounds;
        if (!in_bounds) return error.StaleStream;
        const slot = &self.slots[handle.index];
        const occupied = slot.occupied;
        if (observed) |value| value.occupied = occupied;
        if (!occupied) return error.StaleStream;
        const generation = slot.generation;
        if (observed) |value| value.generation = generation;
        if (generation != handle.generation) return error.StaleStream;
        return slot;
    }
    pub fn renderSource(self: *Service, handle: Handle) Error!@import("source.zig").Source {
        const slot = try self.get(handle);
        return .{ .ring = &slot.pcm_ring, .identity = .{ .asset = slot.asset.sound.key.id, .asset_generation = slot.options.generation, .transport_epoch = slot.options.transport_epoch, .stream_generation = handle.generation, .profile_id = self.profile.id, .profile_hash = self.profile.hash(), .encoded_hash = slot.asset.sound.audio_hash, .start_cursor = slot.options.start_cursor, .start_loop_epoch = slot.options.loop_epoch, .frame_count = slot.asset.sound.frames, .channels = slot.asset.info.channels, .minimum_playable_frames = self.profile.critical_frames, .loop = slot.options.loop } };
    }
    pub fn ringFor(self: *Service, handle: Handle) Error!*ring.Ring {
        return &(try self.get(handle)).pcm_ring;
    }
    /// Control-only realization admission. Supply cancellation is deliberately
    /// distinct from the scheduler's recorded execution cancellation/claim.
    pub fn openOptions(self: *Service, handle: Handle) Error!Open {
        return (try self.get(handle)).options;
    }
    pub fn canPrepareRealize(self: *Service, handle: Handle) Error!bool {
        const slot = try self.get(handle);
        return !slot.cancel.load(.acquire) and slot.failed == .none and !slot.pcm_ring.stopped.load(.acquire);
    }
    pub fn handleForSource(self: *Service, source: @import("source.zig").Source) Error!Handle {
        for (self.slots, 0..) |*slot, i| {
            if (!slot.occupied or &slot.pcm_ring != source.ring or slot.generation != source.identity.stream_generation) continue;
            const handle: Handle = .{ .index = @intCast(i), .generation = slot.generation };
            const actual = try self.renderSource(handle);
            if (!std.meta.eql(actual.identity, source.identity)) return error.InvalidStreamAsset;
            return handle;
        }
        return error.StaleStream;
    }
    pub fn cancel(self: *Service, handle: Handle) Error!void {
        return self.cancelObserved(handle, 0);
    }
    pub fn cancelObserved(self: *Service, handle: Handle, parent_attempt: u64) Error!void {
        var read: readiness_observation.StreamCancelRead = .{ .parent_attempt = parent_attempt, .handle = handle };
        defer _ = self.observeReadinessLifecycle(.{ .cancel = read });
        errdefer |err| read.error_code = @intFromError(err);
        const slot = try self.getObserved(handle, &read.validation);
        self.semanticBoundary(.control, .service_cancel_release, .before, handle.index, handle.generation, 1);
        slot.cancel.store(true, .release);
        self.semanticBoundary(.control, .service_cancel_release, .after, handle.index, handle.generation, 1);
        read.cancel_published = true;
        slot.replay_readiness = null;
        read.replay_readiness_cleared = true;
        // Cancellation invalidates future worker publication, not already read
        // PCM. The scheduled group stop owns the audible cut and ring release.
    }
    pub fn close(self: *Service, handle: Handle) Error!void {
        return self.closeObserved(handle, 0);
    }
    pub fn closeObserved(self: *Service, handle: Handle, parent_attempt: u64) Error!void {
        var read: readiness_observation.StreamCloseRead = .{ .parent_attempt = parent_attempt, .handle = handle };
        defer _ = self.observeReadinessLifecycle(.{ .close = read });
        errdefer |err| read.error_code = @intFromError(err);
        // Bounded exclusion from native creation/cache use; render never calls
        // this. Teardown retries after the single worker acknowledges idle.
        self.offline(.stream_close_claim, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.control, .stream_close_claim, .before, handle.index, handle.generation, null);
        const busy = self.claimBusy(.{ .stream_close = .{ .handle = handle, .parent_attempt = parent_attempt } });
        self.orderCheckpoint(.control, .stream_close_claim, .after, handle.index, handle.generation, @intFromBool(busy orelse false));
        self.offline(.stream_close_claim, .after, handle.index, handle.generation, @intFromBool(busy orelse false));
        read.worker_busy = busy orelse false;
        if (busy != null) return error.DrainPending;
        const exclusion = self.exclusionClaim();
        defer {
            self.offline(.stream_close_idle, .before, handle.index, handle.generation, 0);
            self.orderCheckpoint(.control, .stream_close_idle, .before, handle.index, handle.generation, 0);
            self.worker_busy.store(false, .release);
            self.orderCheckpoint(.control, .stream_close_idle, .after, handle.index, handle.generation, 0);
            self.offline(.stream_close_idle, .after, handle.index, handle.generation, 0);
            read.worker_idle_published = true;
            if (exclusion) |claim| claim.released(.{ .stream_close = .{ .handle = handle, .parent_attempt = parent_attempt } });
        }
        const slot = try self.getObserved(handle, &read.validation);
        self.offline(.stream_close_pending, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.control, .stream_close_pending, .before, handle.index, handle.generation, null);
        const pending_job = slot.pending_job;
        // Zero is the actual empty optional; every present slot is encoded
        // plus one, so slot zero cannot be confused with an absent read.
        self.orderCheckpoint(.control, .stream_close_pending, .after, handle.index, handle.generation, if (pending_job) |index| @as(u64, index) + 1 else 0);
        self.offline(.stream_close_pending, .after, handle.index, handle.generation, if (pending_job) |index| @as(u64, index) + 1 else 0);
        read.pending_job_reached = true;
        read.pending_job = pending_job;
        if (pending_job != null) return error.DrainPending;
        self.offline(.stream_close_visibility, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.control, .stream_close_visibility, .before, handle.index, handle.generation, null);
        const visibility_refs = slot.visibility_refs;
        self.orderCheckpoint(.control, .stream_close_visibility, .after, handle.index, handle.generation, visibility_refs);
        self.offline(.stream_close_visibility, .after, handle.index, handle.generation, visibility_refs);
        read.visibility_refs = visibility_refs;
        if (visibility_refs != 0) return error.DrainPending;
        const references = slot.pcm_ring.references.load(.acquire);
        read.ring_references = references;
        if (references != 0) return error.DrainPending;
        self.slotGuardPoint(.control, .slot_guard_close, .before, handle.index, handle.generation, null);
        const guard = self.slot_guards[handle.index].cmpxchgStrong(0, 2, .acq_rel, .acquire);
        self.slotGuardPoint(.control, .slot_guard_close, .after, handle.index, handle.generation, guard orelse 0);
        read.guard = guard orelse 0;
        if (guard != null) return error.DrainPending;
        if (slot.decoder) |*decoder| {
            _ = self.native_bytes.fetchSub(decoder.nativeStateBytes(), .monotonic);
            _ = self.decoder_zig_bytes.fetchSub(decoder.allocatedBytes() - decoder.nativeStateBytes(), .monotonic);
            decoder.deinit();
        }
        slot.packets.deinit();
        slot.asset.release();
        self.offline(.stream_close_stopped, .before, handle.index, handle.generation, 1);
        self.orderCheckpoint(.control, .stream_close_stopped, .before, handle.index, handle.generation, 1);
        self.semanticBoundary(.control, .service_stopped_release, .before, handle.index, handle.generation, 1);
        slot.pcm_ring.stopped.store(true, .release);
        self.semanticBoundary(.control, .service_stopped_release, .after, handle.index, handle.generation, 1);
        self.orderCheckpoint(.control, .stream_close_stopped, .after, handle.index, handle.generation, 1);
        self.offline(.stream_close_stopped, .after, handle.index, handle.generation, 1);
        read.stopped_published = true;
        // The successful close claim, zero leases and closed render guard
        // exclude every ring user. Clear only after the actual stopped release.
        slot.pcm_ring.order_control = null;
        slot.pcm_ring.order_render = null;
        slot.pcm_ring.consume_observer = null;
        slot.pcm_ring.generation = 0;
        slot.occupied = false;
        const free_before = self.free_stream_count;
        read.free_before = @intCast(free_before);
        self.free_indices[free_before] = handle.index;
        self.free_stream_count += 1;
        read.free_after = @intCast(self.free_stream_count);
        read.returned = true;
    }
    /// Immutable replacement for seek/virtual realize. Caller prefetches this
    /// handle and admits an atomic old-stop/new-start group phase. No in-place
    /// ring reset can race an outstanding renderer or old worker completion.
    pub fn prepareSeek(self: *Service, old: Handle, target: u64, transport_epoch: u64) Error!Handle {
        const slot = try self.get(old);
        var options = slot.options;
        options.start_cursor = target;
        options.transport_epoch = transport_epoch;
        options.loop_epoch = 0;
        options.operation = .seek;
        return self.open(slot.asset, options);
    }
    /// Control supply decisions use a coherent completed-DSP frontier. They
    /// never reclaim PCM merely because Render consumed it mid-span: replay at
    /// the accepted frame must still possess exactly that historical window.
    fn controlAvailable(self: *Service, slot: *Slot, accepted_frame: ?u64) Error!u64 {
        return self.controlAvailableObserved(slot, accepted_frame, null, .readiness, null);
    }
    const AvailabilityOrigin = enum { readiness, acceptance };
    fn controlAvailableObserved(self: *Service, slot: *Slot, accepted_frame: ?u64, observed: ?*observation.Availability, origin: AvailabilityOrigin, live: ?*?LiveObservationDeferV1) Error!u64 {
        return self.controlAvailableCutObserved(slot, accepted_frame, observed, origin, live, null);
    }
    fn controlAvailableCutObserved(self: *Service, slot: *Slot, accepted_frame: ?u64, observed: ?*observation.Availability, origin: AvailabilityOrigin, live: ?*?LiveObservationDeferV1, acquired: ?*CompletedDspCutV1) Error!u64 {
        if (observed) |value| value.* = .{ .attached = self.runtime_attached, .requested_frame = accepted_frame };
        errdefer |err| if (observed) |value| {
            value.error_code = @intFromError(err);
        };
        if (!self.runtime_attached) {
            var cut: ring.ReadCut = .{};
            const available = slot.pcm_ring.availableObserved(if (observed != null) &cut else null);
            if (observed) |value| {
                value.consumed = cut.consumed;
                value.produced = cut.produced;
                value.available = available;
            }
            return available;
        }
        // The two independent witness producers retain their own occurrence
        // namespace; assembler lane order never determines a replay cut.
        const sites: [5]OfflineSite = switch (origin) {
            .readiness => .{ .availability_readiness_sequence_before, .availability_readiness_frame, .availability_readiness_control_consumed, .availability_readiness_produced, .availability_readiness_sequence_after },
            .acceptance => .{ .availability_acceptance_sequence_before, .availability_acceptance_frame, .availability_acceptance_control_consumed, .availability_acceptance_produced, .availability_acceptance_sequence_after },
        };
        const index = (@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot);
        const generation = slot.generation;
        // Ordinary/legacy unobserved calls keep their old callback coverage.
        // Explicit Live attachment exposes the same already-emitted lane points.
        const offline_availability = observed != null or self.live_availability_points;
        if (offline_availability) self.offline(sites[0], .before, index, generation, 0);
        self.orderCheckpoint(.control, sites[0], .before, index, generation, null);
        self.availabilityHook(.before_sequence, 0);
        const sequence = self.observation_sequence.load(.acquire);
        self.availabilityHook(.after_sequence, sequence);
        self.orderCheckpoint(.control, sites[0], .after, index, generation, sequence);
        if (offline_availability) self.offline(sites[0], .after, index, generation, sequence);
        if (observed) |value| value.sequence_before = sequence;
        if (sequence & 1 != 0) {
            if (live) |value| value.* = .{ .reason = .odd_sequence, .operation = if (accepted_frame != null) .prefetch else .request, .handle = .{ .index = @intCast(index), .generation = generation }, .requested_frame = accepted_frame, .sequence_before = sequence };
            return error.InvalidState;
        }
        if (offline_availability) self.offline(sites[1], .before, index, generation, 0);
        self.orderCheckpoint(.control, sites[1], .before, index, generation, null);
        const frame = self.observation_frame.load(.acquire);
        if (@import("builtin").is_test) self.testRetryWorkload(.{ .frame_loaded = frame });
        self.orderCheckpoint(.control, sites[1], .after, index, generation, frame);
        if (offline_availability) self.offline(sites[1], .after, index, generation, frame);
        if (observed) |value| value.frame = frame;
        self.availabilityHook(.after_frame, frame);
        if (accepted_frame) |expected| if (frame != expected) {
            if (live) |value| value.* = .{ .reason = .frame_mismatch, .operation = .prefetch, .handle = .{ .index = @intCast(index), .generation = generation }, .requested_frame = expected, .observed_frame = frame, .sequence_before = sequence };
            return error.InvalidState;
        };
        if (offline_availability) self.offline(sites[2], .before, index, generation, 0);
        self.orderCheckpoint(.control, sites[2], .before, index, generation, null);
        const read = slot.pcm_ring.control_consumed.load(.acquire);
        if (@import("builtin").is_test) self.testRetryWorkload(.{ .consumed_loaded = .{ .index = index, .generation = generation, .value = read } });
        self.orderCheckpoint(.control, sites[2], .after, index, generation, read);
        if (offline_availability) self.offline(sites[2], .after, index, generation, read);
        if (offline_availability) self.offline(sites[3], .before, index, generation, 0);
        self.orderCheckpoint(.control, sites[3], .before, index, generation, null);
        const write = slot.pcm_ring.produced.load(.monotonic);
        self.orderCheckpoint(.control, sites[3], .after, index, generation, write);
        if (offline_availability) self.offline(sites[3], .after, index, generation, write);
        if (offline_availability) self.offline(sites[4], .before, index, generation, 0);
        self.orderCheckpoint(.control, sites[4], .before, index, generation, null);
        self.availabilityHook(.before_final_sequence, 0);
        const after = self.observation_sequence.load(.acquire);
        self.availabilityHook(.after_final_sequence, after);
        self.orderCheckpoint(.control, sites[4], .after, index, generation, after);
        if (offline_availability) self.offline(sites[4], .after, index, generation, after);
        if (observed) |value| {
            value.consumed = read;
            value.produced = write;
            value.sequence_after = after;
        }
        // Ring corruption is never a progress outcome, even when the same
        // attempt also overlaps a frontier publication.
        if (read > write or write - read > slot.pcm_ring.capacity_frames) return error.InvalidState;
        if (sequence != after) {
            if (live) |value| value.* = .{ .reason = .sequence_changed, .operation = if (accepted_frame != null) .prefetch else .request, .handle = .{ .index = @intCast(index), .generation = generation }, .requested_frame = accepted_frame, .observed_frame = frame, .sequence_before = sequence, .sequence_after = after };
            return error.InvalidState;
        }
        if (acquired) |value| value.* = .{ .sequence = sequence, .frame = frame, .consumed = read, .produced = write, .available = write - read };
        if (observed) |value| value.available = write - read;
        return write - read;
    }
    fn projected(self: *Service, slot: *const Slot, position: trace.schema.Position, facts: trace.schema.readiness.Facts) trace.schema.readiness.Projection {
        return self.projectedObserved(slot, position, facts, null);
    }
    fn projectedObserved(self: *Service, slot: *const Slot, position: trace.schema.Position, facts: trace.schema.readiness.Facts, observed: ?*readiness_observation.QueryRead) trace.schema.readiness.Projection {
        const end = if (slot.options.loop) |loop| loop.end else slot.asset.sound.frames;
        const failed = slot.failed;
        if (observed) |value| {
            value.saw(.failure);
            value.failure_code = @intFromEnum(failed);
        }
        const future_rate = if (failed == .none) blk: {
            const cancelled = slot.cancel.load(.acquire);
            if (observed) |value| {
                value.saw(.cancel);
                value.cancel = cancelled;
            }
            break :blk if (!cancelled) facts.throughput_pcm_frames_per_second else null;
        } else null;
        return p.project(self.profile, position.accepted_control_frame, facts.available_frames, facts.queued_frames, facts.backlog_frames, future_rate, slot.options.deadline_frame, @min(self.profile.critical_frames, end - facts.pcm_start));
    }
    /// Shipping prefetch policy. Future target/fill and soon-realize streams
    /// enter their explicit lead window; active/optional streams start below
    /// low water and continue to high water. A missed deadline never blocks.
    pub fn prefetch(self: *Service, handle: Handle, observed_control_frame: u64) Error!?u64 {
        return self.prefetchObserved(handle, observed_control_frame, null, .exact);
    }
    /// Opt-in live supply. The stack witness is consumed immediately, before
    /// any other operation can fail; unknown InvalidState remains an error.
    pub fn prefetchLiveV1(self: *Service, handle: Handle, observed_control_frame: u64) Error!LivePrefetchOutcomeV1 {
        var deferred: ?LiveObservationDeferV1 = null;
        const submitted = self.prefetchObserved(handle, observed_control_frame, &deferred, .exact) catch |err| {
            if (err == error.InvalidState) if (deferred) |value| return .{ .deferred = value };
            return err;
        };
        return .{ .submitted = submitted };
    }
    /// Only the validated live owner may select this for an executed stable
    /// active group. This queues private Worker staging; acceptance keeps its
    /// original publication/capacity checks. No historical-frame equality is
    /// asserted for this same-call coherent completed-DSP availability cut.
    pub fn prefetchActiveLiveV1(self: *Service, handle: Handle, policy_frame: u64) Error!LivePrefetchOutcomeV1 {
        var deferred: ?LiveObservationDeferV1 = null;
        const submitted = self.prefetchObserved(handle, policy_frame, &deferred, .latest_completed) catch |err| {
            if (err == error.InvalidState) if (deferred) |value| return .{ .deferred = value };
            return err;
        };
        return .{ .submitted = submitted };
    }
    const SupplyDomain = enum { exact, latest_completed, initial_unconsumed };
    /// Internal owner route: the live Tick revalidates request custody and the
    /// exact handle on every call. No naked initial flag or source identity.
    pub fn prefetchInitialEntryV1(self: *Service, tick_serial: u64, request_id: u64, handle: Handle, policy_frame: u64) Error!?u64 {
        const owner = self.initial_entry_owner orelse return error.InvalidState;
        const actual = try owner.validate(owner.context, self, tick_serial, request_id, handle);
        if (policy_frame != actual.position.accepted_control_frame) return error.InvalidState;
        return self.prefetchObserved(handle, policy_frame, null, .initial_unconsumed);
    }
    fn initialEntryConsumed(self: *Service, slot: *Slot) Error!u64 {
        const index = (@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot);
        self.orderCheckpoint(.control, .initial_entry_cancel, .before, index, slot.generation, null);
        const cancelled = slot.cancel.load(.acquire);
        self.orderCheckpoint(.control, .initial_entry_cancel, .after, index, slot.generation, @intFromBool(cancelled));
        if (cancelled or slot.failed != .none) return error.InvalidState;
        self.orderCheckpoint(.control, .readiness_stopped_first, .before, index, slot.generation, null);
        const stopped = slot.pcm_ring.stopped.load(.acquire);
        self.orderCheckpoint(.control, .readiness_stopped_first, .after, index, slot.generation, @intFromBool(stopped));
        if (stopped or !self.runtime_attached or self.replay_mode) return error.InvalidState;
        self.orderCheckpoint(.control, .initial_entry_consumed, .before, index, slot.generation, null);
        const consumed = slot.pcm_ring.consumed.load(.acquire);
        self.orderCheckpoint(.control, .initial_entry_consumed, .after, index, slot.generation, consumed);
        if (consumed != 0) return error.InvalidState;
        return consumed;
    }
    fn initialEntryAvailable(self: *Service, slot: *Slot, observed: ?*observation.Availability) Error!u64 {
        if (observed) |value| value.* = .{ .attached = self.runtime_attached };
        errdefer |err| if (observed) |value| {
            value.error_code = @intFromError(err);
        };
        const consumed = try self.initialEntryConsumed(slot);
        const index = (@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot);
        self.orderCheckpoint(.control, .readiness_produced, .before, index, slot.generation, null);
        const produced = slot.pcm_ring.produced.load(.acquire);
        self.orderCheckpoint(.control, .readiness_produced, .after, index, slot.generation, produced);
        if (observed) |value| {
            value.consumed = consumed;
            value.produced = produced;
        }
        if (produced < consumed or produced - consumed > slot.pcm_ring.capacity_frames) return error.InvalidState;
        if (observed) |value| value.available = produced - consumed;
        return produced - consumed;
    }
    fn prefetchObserved(self: *Service, handle: Handle, observed_control_frame: u64, live: ?*?LiveObservationDeferV1, domain: SupplyDomain) Error!?u64 {
        var diagnostic: if (@import("builtin").is_test) TestSupplyReturn else void = if (@import("builtin").is_test) .{ .operation = .prefetch, .handle = handle } else {};
        defer if (@import("builtin").is_test) if (self.test_supply_return_hook) |hook| hook.call(hook.context, diagnostic);
        errdefer |err| if (@import("builtin").is_test) {
            diagnostic.returned_error = err;
            if (live) |witness| diagnostic.deferred = witness.*;
        };
        const sink = self.readiness_supply_sink;
        const observed = if (sink) |value| value.begin(value.context, .prefetch, handle, observed_control_frame, 0) else null;
        var observation_open = observed != null;
        defer if (observation_open) {
            _ = sink.?.finish(sink.?.context);
        };
        errdefer |err| if (observation_open) {
            observed.?.error_code = @intFromError(err);
        };
        const slot = self.get(handle) catch |err| {
            if (@import("builtin").is_test) diagnostic.reason = .lookup_error;
            return @as(Error!?u64, err);
        };
        if (@import("builtin").is_test) if (self.test_supply_hook) |hook| hook.call(hook.context, .{ .stage = .prefetch_begin, .handle = handle });
        const available = (if (domain == .initial_unconsumed) self.initialEntryAvailable(slot, if (observed) |value| &value.availability else null) else self.controlAvailableObserved(slot, if (domain == .latest_completed) null else observed_control_frame, if (observed) |value| &value.availability else null, .readiness, live)) catch |err| {
            if (@import("builtin").is_test) diagnostic.reason = .availability_error;
            // This failure belongs to prefetch's own read, not a later nested
            // request read. Keep the actual absent exact-frame requirement.
            if (domain == .latest_completed) if (live) |witness| if (witness.*) |*value| {
                value.operation = .prefetch;
            };
            return @as(Error!?u64, err);
        };
        if (@import("builtin").is_test) diagnostic.available = available;
        if (available >= self.profile.high_frames) {
            if (@import("builtin").is_test) diagnostic.reason = .high_water;
            slot.filling = false;
            return null;
        }
        switch (slot.options.priority) {
            .imminent_target_fill, .virtual_soon_realize => {
                if (observed_control_frame < slot.options.deadline_frame -| self.profile.prefetch_lead_frames) {
                    if (@import("builtin").is_test) diagnostic.reason = .before_lead;
                    return null;
                }
                slot.filling = true;
            },
            .active_required, .optional => {
                if (!slot.filling and available >= self.profile.low_frames) {
                    if (@import("builtin").is_test) diagnostic.reason = .above_low_water;
                    return null;
                }
                slot.filling = true;
            },
        }
        var parent: u64 = 0;
        if (observed) |value| {
            value.invokes_request = true;
            parent = sink.?.finish(sink.?.context);
            observation_open = false;
        }
        if (@import("builtin").is_test) diagnostic.reason = .nested_request;
        const result = try self.requestObserved(handle, parent, live, domain == .initial_unconsumed, if (@import("builtin").is_test) true else {});
        if (@import("builtin").is_test) diagnostic.job = result;
        return result;
    }

    /// Single Control owner, at most one outstanding job per stream.
    pub fn request(self: *Service, handle: Handle) Error!?u64 {
        return self.requestObserved(handle, 0, null, false, if (@import("builtin").is_test) false else {});
    }
    fn requestObserved(self: *Service, handle: Handle, parent: u64, live: ?*?LiveObservationDeferV1, initial: bool, nested_prefetch: if (@import("builtin").is_test) bool else void) Error!?u64 {
        var diagnostic: if (@import("builtin").is_test) TestSupplyReturn else void = if (@import("builtin").is_test) .{ .operation = .request, .handle = handle, .nested_prefetch = nested_prefetch } else {};
        defer if (@import("builtin").is_test) if (self.test_supply_return_hook) |hook| hook.call(hook.context, diagnostic);
        errdefer |err| if (@import("builtin").is_test) {
            diagnostic.returned_error = err;
            if (live) |witness| diagnostic.deferred = witness.*;
        };
        const sink = self.readiness_supply_sink;
        const observed = if (sink) |value| value.begin(value.context, .request, handle, null, parent) else null;
        defer if (observed != null) {
            _ = sink.?.finish(sink.?.context);
        };
        errdefer |err| if (observed) |value| {
            value.error_code = @intFromError(err);
        };
        const slot = self.get(handle) catch |err| {
            if (@import("builtin").is_test) diagnostic.reason = .lookup_error;
            return @as(Error!?u64, err);
        };
        if (@import("builtin").is_test) if (self.test_supply_hook) |hook| hook.call(hook.context, .{ .stage = .request_begin, .handle = handle });
        const cancelled = slot.cancel.load(.acquire);
        if (observed) |value| {
            value.reached |= readiness_observation.bit(.request_cancel);
            value.cancel = cancelled;
        }
        if (cancelled) {
            if (@import("builtin").is_test) diagnostic.reason = .cancelled;
            return error.InvalidState;
        }
        const stopped = slot.pcm_ring.stopped.load(.acquire);
        if (observed) |value| {
            value.reached |= readiness_observation.bit(.request_stopped);
            value.stopped = stopped;
        }
        if (stopped) {
            if (@import("builtin").is_test) diagnostic.reason = .stopped;
            return error.InvalidState;
        }
        const failed = slot.failed;
        if (observed) |value| {
            value.reached |= readiness_observation.bit(.request_failed);
            value.failure_code = @intFromEnum(failed);
        }
        if (failed != .none) {
            if (@import("builtin").is_test) diagnostic.reason = .failed;
            return error.InvalidState;
        }
        const pending = slot.pending_job;
        if (observed) |value| {
            value.reached |= readiness_observation.bit(.request_pending);
            value.pending_job = pending;
        }
        if (@import("builtin").is_test) {
            diagnostic.pending_observed = true;
            diagnostic.pending_job = pending;
        }
        if (pending != null) {
            if (@import("builtin").is_test) diagnostic.reason = .pending;
            return null;
        }
        const available = (if (initial) self.initialEntryAvailable(slot, if (observed) |value| &value.availability else null) else self.controlAvailableObserved(slot, null, if (observed) |value| &value.availability else null, .readiness, live)) catch |err| {
            if (@import("builtin").is_test) diagnostic.reason = .availability_error;
            return @as(Error!?u64, err);
        };
        if (@import("builtin").is_test) diagnostic.available = available;
        if (available >= self.profile.high_frames) {
            if (@import("builtin").is_test) diagnostic.reason = .high_water;
            return null;
        }
        const ordinal = slot.pcm_ring.produced.load(.monotonic);
        if (observed) |value| {
            value.reached |= readiness_observation.bit(.request_ordinal);
            value.ordinal = ordinal;
        }
        const coordinate = slot.pcm_ring.coordinate(ordinal) orelse {
            if (@import("builtin").is_test) diagnostic.reason = .coordinate_unavailable;
            return null;
        };
        const remaining = (if (slot.options.loop) |loop| loop.end else slot.asset.sound.frames) - coordinate.cursor;
        const count: u32 = @intCast(@min(remaining, @min(self.profile.decode_chunk_frames, self.profile.high_frames - available)));
        if (count == 0 or self.next_job == std.math.maxInt(u64)) {
            if (@import("builtin").is_test) diagnostic.reason = if (count == 0) .zero_count else .job_id_exhausted;
            return error.InvalidState;
        }
        if (self.free_job_count == 0) {
            if (@import("builtin").is_test) diagnostic.reason = .job_capacity;
            self.job_overflows +|= 1;
            return error.JobCapacity;
        }
        const job_index = self.free_indices[@as(usize, self.profile.max_streams) + self.free_job_count - 1];
        const job = &self.jobs[job_index];
        const pcm = job.pcm;
        _ = pcm;
        job.handle = handle;
        job.ordinal = ordinal;
        job.count = count;
        job.priority = slot.options.priority;
        job.outcome = .not_ready;
        job.failure = .none;
        job.hash = @splat(0);
        job.elapsed_ns = 0;
        job.descriptor = .{ .job = self.next_job, .asset = slot.asset.sound.key.id, .generation = slot.options.generation, .transport_epoch = slot.options.transport_epoch, .operation = if (ordinal == 0) slot.options.operation else .decode, .group = slot.options.group, .layer = slot.options.layer, .loop_epoch = coordinate.loop_epoch, .target_cursor = coordinate.cursor, .realize_frame = slot.options.deadline_frame };
        job.descriptor_len = (trace.replay.encodeJobDescriptor(&job.descriptor_bytes, job.descriptor) catch {
            if (@import("builtin").is_test) diagnostic.reason = .descriptor_error;
            return @as(Error!?u64, error.InvalidState);
        }).len;
        slot.pending_job = @intCast(job_index);
        self.free_job_count -= 1;
        self.next_job += 1;
        const queued_descriptor = job.descriptor;
        self.offline(.job_queued, .before, job_index, queued_descriptor.job, @intFromEnum(State.queued));
        self.orderCheckpoint(.control, .job_queued, .before, job_index, queued_descriptor.job, @intFromEnum(State.queued));
        // All descriptor fields are initialized. No Worker can see queued yet.
        if (@import("builtin").is_test) self.testRetryWorkload(.{ .queue_before = .{ .job = queued_descriptor.job, .handle = handle } });
        job.state.store(.queued, .release);
        self.orderCheckpoint(.control, .job_queued, .after, job_index, queued_descriptor.job, @intFromEnum(State.queued));
        self.offline(.job_queued, .after, job_index, queued_descriptor.job, @intFromEnum(State.queued));
        if (observed) |value| {
            value.job_slot = job_index;
            value.descriptor = queued_descriptor;
            value.count = count;
            value.result_job = queued_descriptor.job;
        }
        if (@import("builtin").is_test) if (self.test_supply_hook) |hook| hook.call(hook.context, .{ .stage = .request_queued, .handle = handle, .job_slot = job_index, .job = queued_descriptor.job });
        if (@import("builtin").is_test) {
            diagnostic.reason = .queued;
            diagnostic.job_slot = job_index;
            diagnostic.job = queued_descriptor.job;
        }
        return queued_descriptor.job;
    }
    fn before(a: *const Job, b: *const Job) bool {
        if (a.priority != b.priority) return @intFromEnum(a.priority) < @intFromEnum(b.priority);
        if (a.descriptor.realize_frame != b.descriptor.realize_frame) return a.descriptor.realize_frame < b.descriptor.realize_frame;
        return a.descriptor.job < b.descriptor.job;
    }
    /// Worker-only pump, safe against simultaneous pumps (one wins; no lock or
    /// wait). Every job has its own preallocated staging PCM and completion slot.
    pub const LiveWorkerOutcomeV1 = union(enum) {
        completed: ?u64,
        deferred: ServiceClaimAttempt,
    };
    pub fn workerOne(self: *Service) Error!?u64 {
        return self.workerOneAttempt(null);
    }
    /// Only the initial failed claim can defer. No job has been scanned or
    /// admitted, and later errors cannot borrow this invocation's witness.
    pub fn workerOneLiveV1(self: *Service) Error!LiveWorkerOutcomeV1 {
        var deferred: ?ServiceClaimAttempt = null;
        const completed = self.workerOneAttempt(&deferred) catch |err| {
            if (err == error.WorkerBusy) if (deferred) |attempt| return .{ .deferred = attempt };
            return err;
        };
        return .{ .completed = completed };
    }
    fn workerOneAttempt(self: *Service, deferred: ?*?ServiceClaimAttempt) Error!?u64 {
        self.semanticBoundary(.worker, .service_worker_attempt, .before, 0, 0, null);
        defer self.semanticBoundary(.worker, .service_worker_attempt, .after, 0, 0, null);
        self.offline(.worker_claim, .before, 0, 0, 0);
        self.orderCheckpoint(.worker, .worker_claim, .before, 0, 0, null);
        const attempt = self.claimBusyToken(.worker);
        const busy = attempt.observed != 0;
        self.orderCheckpoint(.worker, .worker_claim, .after, 0, 0, @intFromBool(busy));
        self.offline(.worker_claim, .after, 0, 0, @intFromBool(busy));
        if (busy) {
            if (deferred) |value| value.* = attempt;
            return error.WorkerBusy;
        }
        const exclusion = self.exclusionClaim();
        var completed_id: u64 = 0;
        defer {
            if (comptime @import("builtin").is_test) if (self.test_worker_stage_hook) |hook| hook.call(hook.context, .before_idle, completed_id);
            self.offline(.worker_idle, .before, 0, completed_id, 0);
            self.orderCheckpoint(.worker, .worker_idle, .before, 0, completed_id, 0);
            self.worker_busy.store(false, .release);
            self.orderCheckpoint(.worker, .worker_idle, .after, 0, completed_id, 0);
            self.offline(.worker_idle, .after, 0, completed_id, 0);
            if (comptime @import("builtin").is_test) if (self.test_worker_stage_hook) |hook| hook.call(hook.context, .after_idle, completed_id);
            self.workerFact(.{ .idle = .{ .job = completed_id } });
            if (exclusion) |claim| {
                claim.released(.{ .worker = .{ .job = completed_id } });
                self.publishWorkerReleaseProgress(.{ .token = attempt.token, .ticket = claim.ticket });
            }
        }
        var best: ?*Job = null;
        var best_index: u16 = 0;
        // Capture never paces this scan. Its bounded envelope lets the recorder
        // packetize original per-slot cuts without changing their occurrences
        // or supplying state values; the selector still reads actual state.
        self.semanticBoundary(.worker, .service_worker_scan, .before, self.jobs.len, 0, null);
        for (self.jobs, 0..) |*job, index| {
            self.offline(.worker_scan, .before, index, 0, 0);
            self.orderCheckpoint(.worker, .worker_scan, .before, index, 0, null);
            const state = job.state.load(.acquire);
            self.orderCheckpoint(.worker, .worker_scan, .after, index, 0, @intFromEnum(state));
            self.offline(.worker_scan, .after, index, 0, @intFromEnum(state));
            if (self.public_causal_worker_sink != null or (self.live_semantic_hooks != null and self.live_semantic_hooks.?.worker_facts != null)) {
                var fact: WorkerFact = .{ .scan = .{ .index = @intCast(index), .state = state } };
                if (state == .queued) {
                    fact.scan.job = job.descriptor.job;
                    fact.scan.handle = job.handle;
                    fact.scan.generation = job.descriptor.generation;
                    fact.scan.transport_epoch = job.descriptor.transport_epoch;
                }
                self.workerFact(fact);
            }
            if (state == .queued and (best == null or before(job, best.?))) {
                best = job;
                best_index = @intCast(index);
            }
        }
        self.semanticBoundary(.worker, .service_worker_scan, .after, self.jobs.len, 0, null);
        const job = best orelse return null;
        self.workerFact(.{ .selected = .{ .job = job.descriptor.job, .slot = best_index } });
        self.semanticBoundary(.worker, .service_worker_selected, .after, best_index, job.descriptor.job, null);
        self.offline(.worker_running, .before, best_index, job.descriptor.job, @intFromEnum(State.running));
        self.orderCheckpoint(.worker, .worker_running, .before, best_index, job.descriptor.job, @intFromEnum(State.running));
        job.state.store(.running, .release);
        self.orderCheckpoint(.worker, .worker_running, .after, best_index, job.descriptor.job, @intFromEnum(State.running));
        self.offline(.worker_running, .after, best_index, job.descriptor.job, @intFromEnum(State.running));
        if (comptime @import("builtin").is_test) if (self.test_worker_hook) |hook| hook.call(hook.context, job.descriptor.job);
        const begin = self.workerClock(.begin, job.descriptor.job);
        self.source_failure = .none;
        self.decodeJob(job) catch |err| {
            job.outcome = .failed;
            job.failure = if (self.source_failure != .none) self.source_failure else switch (err) {
                error.OutOfMemory, error.DecodeFailure, error.InvalidPcm => .decode,
                else => .invalid_window,
            };
        };
        const end = self.workerClock(.end, job.descriptor.job);
        job.elapsed_ns = if (begin != 0 and end > begin) end - begin else 0;
        const completed_outcome = if (@import("builtin").is_test) job.outcome else {};
        completed_id = job.descriptor.job;
        self.offline(.worker_completed, .before, best_index, completed_id, @intFromEnum(State.completed));
        self.orderCheckpoint(.worker, .worker_completed, .before, best_index, completed_id, @intFromEnum(State.completed));
        job.state.store(.completed, .release);
        self.orderCheckpoint(.worker, .worker_completed, .after, best_index, completed_id, @intFromEnum(State.completed));
        self.offline(.worker_completed, .after, best_index, completed_id, @intFromEnum(State.completed));
        // Control can now return/reuse the slot. Only copied identity survives.
        self.workerFact(.{ .completed = .{ .job = completed_id, .slot = best_index } });
        if (@import("builtin").is_test) self.testRetryWorkload(.{ .worker_completed = .{ .job = completed_id, .outcome = completed_outcome } });
        if (comptime @import("builtin").is_test) if (self.test_worker_stage_hook) |hook| hook.call(hook.context, .after_completed, completed_id);
        return completed_id;
    }
    fn publishWorkerReleaseProgress(self: *Service, value: ServiceWorkerRelease) void {
        if (comptime supports_causal_claim_tokens) {
            const witness = self.public_causal_exclusion orelse return;
            const emit = witness.sink.worker_release orelse return;
            // This distinct store may lag the original unlock. Neither the
            // idle hook nor emission order is a substitute for its checkpoint.
            self.offline(.worker_release_progress, .before, value.token, value.ticket, value.token);
            self.orderCheckpoint(.worker, .worker_release_progress, .before, value.token, value.ticket, value.token);
            witness.last_worker_released.store(value.token, .release);
            self.orderCheckpoint(.worker, .worker_release_progress, .after, value.token, value.ticket, value.token);
            self.offline(.worker_release_progress, .after, value.token, value.ticket, value.token);
            emit(witness.sink.context, value);
        }
    }
    /// One actual Control acquire observation. Rules 2 reads with index zero
    /// before each runtime tick; this never drives live engine decisions.
    pub fn readWorkerReleaseProgress(self: *Service, observation_index: u64) u64 {
        if (comptime supports_causal_claim_tokens) {
            const witness = self.public_causal_exclusion orelse return 0;
            if (witness.sink.worker_release == null) return 0;
            self.offline(.control_release_progress, .before, observation_index, 0, 0);
            self.orderCheckpoint(.control, .control_release_progress, .before, observation_index, 0, null);
            const token = witness.last_worker_released.load(.acquire);
            self.orderCheckpoint(.control, .control_release_progress, .after, observation_index, 0, token);
            self.offline(.control_release_progress, .after, observation_index, 0, token);
            return token;
        } else {
            return 0;
        }
    }
    fn claimBusy(self: *Service, kind: ServiceClaimKind) ?bool {
        return if (self.claimBusyToken(kind).observed == 0) null else true;
    }
    fn claimBusyToken(self: *Service, kind: ServiceClaimKind) ServiceClaimAttempt {
        // The sink is pinned across callers; only copy it here. Ticket state
        // remains accessed below, exclusively under the successful claim.
        const sink = if (self.public_causal_exclusion) |witness| witness.sink else null;
        var token: u64 = 1;
        if (sink) |observer| {
            if (comptime supports_causal_claim_tokens) {
                if (observer.claim_token) |claim_token| {
                    token = claim_token(observer.context, kind);
                    if (token == 0) {
                        observer.overflow(observer.context);
                        token = 1;
                    }
                }
            } else if (observer.claim_token != null or observer.claim_attempt != null or observer.worker_release != null) {
                observer.overflow(observer.context);
            }
        }
        const observed = self.worker_busy.claim(token);
        if (comptime supports_causal_claim_tokens) if (sink) |observer| if (observer.claim_attempt) |claim_attempt| {
            claim_attempt(observer.context, .{ .kind = kind, .token = token, .observed = observed });
        };
        return .{ .kind = kind, .token = token, .observed = observed };
    }
    fn exclusionClaim(self: *Service) ?ServiceExclusionClaim {
        return if (self.public_causal_exclusion) |witness| witness.claim() else null;
    }
    fn workerFact(self: *Service, fact: WorkerFact) void {
        if (self.public_causal_worker_sink) |sink| sink.emit(sink.context, fact);
        if (self.live_semantic_hooks) |hooks| if (hooks.worker_facts) |sink| sink.emit(sink.context, fact);
    }
    fn semanticBoundary(self: *Service, role: live_semantic.Role, site: live_semantic.Boundary, edge: live_semantic.Edge, index: u64, generation: u64, value: ?u64) void {
        const hooks = self.live_semantic_hooks orelse return;
        hooks.cuts.boundary(hooks.cuts.context, .{ .role = role, .site = site, .edge = edge, .index = index, .generation = generation, .value = value });
    }
    /// Direct bounded producer path, independent of the offline callback ABI.
    /// The actual caller supplies its role; a site name never selects a lane.
    fn orderCheckpoint(self: *Service, role: order.Role, site: OfflineSite, edge: order.Edge, index: u64, generation: u64, value: ?u64) void {
        if (self.live_semantic_hooks) |hooks| {
            const detached_consumed = site == .readiness_consumed and !self.runtime_attached;
            const point: live_semantic.Point = .{ .role = role, .site = if (detached_consumed) .service_readiness_raw_consumed else orderSite(site), .edge = edge, .index = index, .generation = generation, .value = value };
            // Do not silently omit or mislabel a real raw-domain load. The
            // finite semantic recorder rejects this explicit unsupported site;
            // the native operation and legacy prerequisite trace are unchanged.
            if (detached_consumed or live_semantic.allowedPoint(point)) hooks.cuts.point(hooks.cuts.context, point);
        }
        if (self.prerequisite_order) |roles| roles.get(role).pointFor(role, orderSite(site), edge, index, generation, value);
    }
    // Same before/after ordering as existing points: offline-before, order-before,
    // actual atomic, order-after, offline-after. No observed value is reloaded.
    fn slotGuardPoint(self: *Service, role: order.Role, site: OfflineSite, edge: order.Edge, index: u64, generation: u64, value: ?u64) void {
        if (!self.live_slot_guard_points and self.live_semantic_hooks == null) return;
        if (edge == .before) self.offline(site, .before, index, generation, value orelse 0);
        self.orderCheckpoint(role, site, edge, index, generation, value);
        if (edge == .after) self.offline(site, .after, index, generation, value orelse 0);
    }
    fn offline(self: *Service, site: OfflineSite, edge: OfflineEdge, index: u64, generation: u64, value: u64) void {
        if (@import("builtin").is_test) if (self.test_checkpoint_hook) |hook| hook.call(hook.context, .{ .site = site, .edge = edge, .index = index, .generation = generation, .value = value });
        if (self.offline_causal_replay) |hooks| hooks.checkpoint(hooks.context, .{ .site = site, .edge = edge, .index = index, .generation = generation, .value = value });
    }
    fn workerClock(self: *Service, stage: WorkerClockStage, job: u64) u64 {
        const sample: OfflineClockSample = sample: {
            if (comptime @import("builtin").is_test) {
                if (self.test_worker_clock_hook) |hook| {
                    // This assertion and every hook access are test-only. The seam
                    // cannot silently take precedence over an old replay binding.
                    std.debug.assert(self.offline_causal_replay == null);
                    if (hook.joined) |joined| {
                        std.debug.assert(hook.replay == null and joined.address == joined);
                        joined.sample_attempts +|= 1;
                        if (joined.failure == .none) {
                            if (joined.next) |next| {
                                if (next(joined.context, stage, job)) |value| {
                                    joined.source = .replay_input;
                                    break :sample value;
                                }
                                // Sticky BEFORE the one native read. No expected
                                // inputs are consumed after this failed proof.
                                joined.failure = .expected_input;
                            }
                        }
                        joined.source = if (joined.failure == .none) .capture_native else .abort_native;
                        joined.native_attempts +|= 1;
                        break :sample self.nativeWorkerClockSample();
                    }
                    if (hook.replay) |replay| break :sample replay(hook.context, stage, job);
                }
            }
            if (self.offline_causal_replay) |hooks| break :sample hooks.clock(hooks.context, stage, job);
            if (self.live_semantic_hooks) |hooks| if (hooks.clock) |clock| {
                if (clock.sample(@enumFromInt(@intFromEnum(stage)), job)) |raw| {
                    break :sample .{ .value = raw.value, .available = raw.available, .error_code = raw.error_code };
                }
                // A missing/mismatched raw input poisons the pinned clock before
                // falling back. Failed replay cleanup performs the native read.
            };
            break :sample self.nativeWorkerClockSample();
        };
        if (comptime @import("builtin").is_test) if (self.test_worker_clock_hook) |hook|
            hook.observe(hook.context, stage, job, sample);
        self.workerFact(.{ .clock = .{ .stage = stage, .job = job, .value = sample.value, .available = sample.available, .error_code = sample.error_code } });
        if (comptime @import("builtin").is_test) if (self.test_worker_clock_observer) |observer|
            observer.observe(observer.context, stage, job, sample);
        return sample.value;
    }
    /// Original raw acquisition, including availability and failure semantics.
    /// Both ordinary and failed-proof joined cleanup reach this same one read.
    fn nativeWorkerClockSample(self: *Service) OfflineClockSample {
        var code: u32 = 0;
        const value = if (self.clock) |clock| clock.now() catch blk: {
            code = @intFromEnum(WorkerExternalError.clock_failure);
            break :blk 0;
        } else 0;
        return .{ .value = value, .available = self.clock != null, .error_code = code };
    }
    fn workerCancelled(self: *Service, slot: *Slot, handle: Handle) bool {
        self.offline(.worker_cancel, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.worker, .worker_cancel, .before, handle.index, handle.generation, null);
        const value = slot.cancel.load(.acquire);
        self.orderCheckpoint(.worker, .worker_cancel, .after, handle.index, handle.generation, @intFromBool(value));
        self.offline(.worker_cancel, .after, handle.index, handle.generation, @intFromBool(value));
        return value;
    }
    fn workerStopped(self: *Service, slot: *Slot, handle: Handle) bool {
        self.offline(.worker_stopped, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.worker, .worker_stopped, .before, handle.index, handle.generation, null);
        const value = slot.pcm_ring.stopped.load(.acquire);
        self.orderCheckpoint(.worker, .worker_stopped, .after, handle.index, handle.generation, @intFromBool(value));
        self.offline(.worker_stopped, .after, handle.index, handle.generation, @intFromBool(value));
        return value;
    }
    fn decodeJob(self: *Service, job: *Job) Error!void {
        const slot = try self.get(job.handle);
        slot.source_context.job = job.descriptor.job;
        defer slot.source_context.job = 0;
        if (self.workerCancelled(slot, job.handle) or self.workerStopped(slot, job.handle)) {
            job.outcome = .cancelled;
            return;
        }
        if (slot.decoder == null) {
            const first = slot.asset.seeks[0];
            try slot.packets.positionAt(first.page_byte_offset, first.recovery_byte_offset);
            slot.decoder = try opus.Decoder.prepare(self.allocator, slot.asset.info, slot.packets.reader(), first.recovery_byte_offset);
            const bytes = slot.decoder.?.nativeStateBytes();
            const current = self.native_bytes.fetchAdd(bytes, .monotonic) + bytes;
            _ = self.decoder_zig_bytes.fetchAdd(slot.decoder.?.allocatedBytes() - bytes, .monotonic);
            if (current > self.peak_native_bytes.load(.monotonic)) self.peak_native_bytes.store(current, .monotonic);
        }
        const decoder = &slot.decoder.?;
        const target = job.descriptor.target_cursor;
        if (decoder.position() != target or (target == slot.options.start_cursor and job.ordinal == 0 and target != 0)) {
            var lo: usize = 0;
            var hi: usize = slot.asset.seeks.len;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (slot.asset.seeks[mid].logical_frame <= target) lo = mid else hi = mid;
            }
            const recovery = try indexer.recovery(slot.asset.seeks[lo], slot.asset.info);
            try slot.packets.positionAt(recovery.page_byte_offset, recovery.packet_byte_offset);
            try decoder.seek(recovery, target);
        }
        const pcm = job.pcm[0 .. @as(usize, job.count) * slot.asset.info.channels];
        const result = try decoder.decode(pcm);
        if (result.frames != job.count or decoder.position() != target + job.count) return error.InvalidWindow;
        if (self.workerCancelled(slot, job.handle) or self.workerStopped(slot, job.handle)) {
            job.outcome = .cancelled;
            return;
        }
        for (pcm) |sample| if (!std.math.isFinite(sample)) return error.InvalidPcm;
        job.hash = hashPcm(pcm);
        job.outcome = .ready;
    }
    const SemanticSourceContext = struct { service: *Service, source: opus.ByteSource, fact: SourceFact };
    fn semanticSourceRead(context: *anyopaque, offset: u64, destination: []u8) opus.Error!void {
        const ctx: *SemanticSourceContext = @ptrCast(@alignCast(context));
        const self = ctx.service;
        const hooks = self.live_semantic_hooks orelse return ctx.source.read_at(ctx.source.context, offset, destination);
        const sink = hooks.source orelse return ctx.source.read_at(ctx.source.context, offset, destination);
        var fact = ctx.fact;
        if (self.semantic_source_call < std.math.maxInt(u64)) {
            self.semantic_source_call += 1;
            fact.call = self.semantic_source_call;
        } else fact.call = 0;
        fact.offset = offset;
        fact.length = destination.len;
        fact.edge = .before;
        sink.emit(sink.context, fact);
        // Preserve the exact source callback and its native result. This wrapper
        // observes loader reads and actual cache misses, not synthetic fetches.
        ctx.source.read_at(ctx.source.context, offset, destination) catch |err| {
            fact.edge = .after;
            fact.error_code = @intFromError(err);
            sink.emit(sink.context, fact);
            return err;
        };
        fact.edge = .after;
        SupplyHasher.hash(destination, &fact.bytes_hash, .{});
        sink.emit(sink.context, fact);
    }
    fn verifiedRead(context: *anyopaque, offset: u64, destination: []u8) opus.Error!void {
        const ctx: *SourceContext = @ptrCast(@alignCast(context));
        const self = ctx.service;
        const slot = ctx.slot;
        if (offset > slot.asset.source.length or destination.len > slot.asset.source.length - offset) return error.TruncatedContainer;
        var copied: usize = 0;
        while (copied < destination.len) {
            const position = offset + copied;
            var lo: usize = 0;
            var hi: usize = slot.asset.chunks.len;
            while (lo + 1 < hi) {
                const mid = lo + (hi - lo) / 2;
                if (slot.asset.chunks[mid].byte_offset <= position) lo = mid else hi = mid;
            }
            const chunk = slot.asset.chunks[lo];
            const slot_index: u16 = @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
            if (self.cache_slot != slot_index or self.cache_generation != slot.generation or self.cache_chunk != lo) {
                self.cache_slot = null;
                const bytes = self.encoded_cache[0..@intCast(chunk.byte_length)];
                var source_context: SemanticSourceContext = .{
                    .service = self,
                    .source = slot.asset.source,
                    .fact = .{ .phase = .decode, .edge = .before, .call = 0, .asset = slot.asset.sound.key.id, .asset_hash = slot.asset.sound.audio_hash, .sound_index = slot.asset.sound_index, .job = ctx.job, .slot = slot_index, .generation = slot.generation, .offset = chunk.byte_offset, .length = bytes.len },
                };
                semanticSourceRead(&source_context, chunk.byte_offset, bytes) catch |err| {
                    self.workerFact(.{ .source_read = .{ .asset = slot.asset.sound.key.id, .asset_hash = slot.asset.sound.audio_hash, .slot = slot_index, .generation = slot.generation, .offset = chunk.byte_offset, .length = @intCast(bytes.len), .error_code = @intFromEnum(WorkerExternalError.source_failure) } });
                    self.source_failure = .io;
                    return err;
                };
                self.workerFact(.{ .source_read = .{ .asset = slot.asset.sound.key.id, .asset_hash = slot.asset.sound.audio_hash, .slot = slot_index, .generation = slot.generation, .offset = chunk.byte_offset, .length = @intCast(bytes.len), .error_code = 0 } });
                var hash: [32]u8 = undefined;
                SupplyHasher.hash(bytes, &hash, .{});
                if (!std.mem.eql(u8, &hash, &chunk.hash)) {
                    self.source_failure = .hash;
                    return error.InvalidContainer;
                }
                self.cache_slot = slot_index;
                self.cache_generation = slot.generation;
                self.cache_chunk = lo;
            }
            const local: usize = @intCast(position - chunk.byte_offset);
            if (local >= chunk.byte_length) return error.TruncatedContainer;
            const n = @min(destination.len - copied, @as(usize, @intCast(chunk.byte_length)) - local);
            @memcpy(destination[copied..][0..n], self.encoded_cache[local..][0..n]);
            copied += n;
        }
    }
    fn event(self: *Service, job: *const Job) trace.schema.Worker {
        const slot = &self.slots[job.handle.index];
        const d = job.descriptor;
        return .{ .job = d.job, .asset = d.asset, .generation = d.generation, .transport_epoch = d.transport_epoch, .operation = d.operation, .state = job.outcome, .pcm_start = d.target_cursor, .pcm_end = d.target_cursor + job.count, .available_frames = if (job.outcome == .ready) job.count else 0, .channel_count = slot.asset.info.channels, .content_hash = job.hash, .readiness_version = slot.snapshot_version, .failure_code = if (job.outcome == .failed) @intFromEnum(job.failure) else 0, .group = d.group, .layer = d.layer, .loop_epoch = d.loop_epoch, .target_cursor = d.target_cursor, .realize_frame = d.realize_frame, .job_descriptor_hash = trace.replay.hashPcm(job.descriptor_bytes[0..job.descriptor_len]) };
    }
    /// Actual accepted order is smallest completed job ID at this Control tick;
    /// record the returned fact. A late worker simply leaves no completion.
    pub fn acceptCompleted(self: *Service, position: trace.schema.Position) Error!?Accepted {
        if (self.runtime_attached) return error.InvalidState;
        return self.acceptCompletedWithBatch(position, 0);
    }
    /// Serialized Control, after the runtime completion consumer detached.
    /// This accepts only the actual completed job of this exact cancelled
    /// stream incarnation and runtime generation. It never drains an unrelated
    /// ready job from a shared pool and never publishes detached PCM.
    pub fn acceptCancelledCompletion(self: *Service, handle: Handle, generation: u64, position: trace.schema.Position) Error!?Accepted {
        if (self.runtime_attached or self.replay_mode) return error.InvalidState;
        const slot = try self.get(handle);
        if (generation == 0 or slot.options.generation != generation) return error.StaleStream;
        if (!slot.cancel.load(.acquire)) return error.InvalidState;
        const index = slot.pending_job orelse return null;
        const job = &self.jobs[index];
        if (job.state.load(.acquire) != .completed) return null;
        if (!std.meta.eql(job.handle, handle) or job.descriptor.generation != generation) return error.StaleStream;
        return try self.acceptJob(job, position, null, 0, null, null);
    }
    pub fn acceptCompletedWithBatch(self: *Service, position: trace.schema.Position, batch_id: u64) Error!?Accepted {
        return self.acceptCompletedWithBatchObserved(position, batch_id, null);
    }
    /// Optional owned evidence for this exact operation. Direct Service calls
    /// have no integrated tick scope; only ControlRuntime attaches a witness.
    /// Diagnostic capacity/failure never changes the operation's return value.
    pub fn acceptCompletedWithBatchObserved(self: *Service, position: trace.schema.Position, batch_id: u64, observed: ?*observation.Acceptance) Error!?Accepted {
        return self.acceptCompletedWithBatchMode(position, batch_id, observed, false, null);
    }
    /// Explicit opt-in only. Existing fixed-frame Service/replay callers do not
    /// enter here. The caller owns serialized Control and the effective frame.
    pub fn acceptCompletedLiveV1(self: *Service, position: trace.schema.Position, batch_id: u64, attempt: *LiveAcceptanceAttemptV1) Error!?Accepted {
        attempt.* = .{ .incoming = position };
        errdefer |err| attempt.returned_error = err;
        return self.acceptCompletedWithBatchMode(position, batch_id, &attempt.evidence, true, attempt);
    }
    fn acceptCompletedWithBatchMode(self: *Service, position: trace.schema.Position, batch_id: u64, observed: ?*observation.Acceptance, comptime live: bool, attempt: ?*LiveAcceptanceAttemptV1) Error!?Accepted {
        self.semanticBoundary(.control, .service_acceptance_attempt, .before, position.control_tick, position.input_order, position.accepted_control_frame);
        defer self.semanticBoundary(.control, .service_acceptance_attempt, .after, position.control_tick, position.input_order, position.accepted_control_frame);
        if (observed) |value| value.* = .{ .position = position, .batch_id = batch_id, .runtime_attached = self.runtime_attached, .replay_mode = self.replay_mode, .job_slots = self.jobs.len, .representation_complete = self.jobs.len <= observation.job_capacity };
        errdefer |err| if (observed) |value| {
            value.outcome = .failed;
            value.error_code = @intFromError(err);
        };
        if (self.replay_mode or (live and !self.runtime_attached)) return error.InvalidState;
        self.acceptanceHook(.before_scan, 0);
        self.semanticBoundary(.control, .service_acceptance_scan, .before, self.jobs.len, 0, null);
        var best: ?*Job = null;
        var best_index: usize = 0;
        for (self.jobs, 0..) |*job, index| {
            self.acceptanceHook(.before_job_state, index);
            self.offline(.acceptance_scan, .before, index, 0, 0);
            self.orderCheckpoint(.control, .acceptance_scan, .before, index, 0, null);
            const state = job.state.load(.acquire);
            self.orderCheckpoint(.control, .acceptance_scan, .after, index, 0, @intFromEnum(state));
            self.offline(.acceptance_scan, .after, index, 0, @intFromEnum(state));
            if (observed) |value| {
                value.scanned += 1;
                if (index < observation.job_capacity) {
                    value.states[index] = state;
                    if (state == .completed) value.completed[index] = .{ .job = job.descriptor.job, .handle = job.handle, .generation = job.descriptor.generation, .transport_epoch = job.descriptor.transport_epoch };
                }
            }
            self.acceptanceHook(.after_job_state, index);
            if (state == .completed and (best == null or job.descriptor.job < best.?.descriptor.job)) {
                best = job;
                best_index = index;
            }
        }
        self.semanticBoundary(.control, .service_acceptance_scan, .after, self.jobs.len, 0, null);
        self.acceptanceHook(.after_scan, 0);
        const job = best orelse {
            if (observed) |value| value.outcome = .no_completion;
            return null;
        };
        self.semanticBoundary(.control, .service_acceptance_selected, .after, best_index, job.descriptor.job, null);
        if (observed) |value| value.selected = .{ .slot = @intCast(best_index), .handle = job.handle, .descriptor = job.descriptor, .ordinal = job.ordinal, .count = job.count, .outcome = job.outcome, .failure_code = @intFromEnum(job.failure), .content_hash = job.hash };
        var actual_position = position;
        var control_available: ?u64 = null;
        if (self.runtime_attached) {
            const slot = try self.get(job.handle);
            var cut: CompletedDspCutV1 = undefined;
            var deferred: ?LiveObservationDeferV1 = null;
            const available = self.controlAvailableCutObserved(slot, if (live) null else position.accepted_control_frame, if (observed) |value| &value.availability else null, .acceptance, if (live) &deferred else null, if (live) &cut else null) catch |err| {
                if (observed) |value| {
                    value.outcome = .availability_unavailable;
                    value.error_code = @intFromError(err);
                }
                if (live) {
                    if (deferred) |value| attempt.?.deferred = .{
                        .reason = switch (value.reason) {
                            .odd_sequence => .odd_sequence,
                            .sequence_changed => .sequence_changed,
                            .frame_mismatch => unreachable, // no expected frame in this acquire
                        },
                        .handle = value.handle,
                        .observed_frame = value.observed_frame,
                        .sequence_before = value.sequence_before,
                        .sequence_after = value.sequence_after,
                    };
                    // Odd/changed observations retain bounded no-accept. Ring
                    // corruption is not a progress deferral or a valid cut.
                    if (deferred == null) return @as(Error!?Accepted, err);
                }
                return null;
            };
            if (live) {
                attempt.?.cut = cut;
                // Before capacity counters, PCM, descriptors or job retirement.
                if (cut.frame < position.accepted_control_frame) return error.InvalidState;
                actual_position.accepted_control_frame = cut.frame;
                if (observed) |value| value.position = actual_position;
            }
            if (job.outcome == .ready) {
                const capacity = slot.pcm_ring.capacity_frames;
                if (observed) |value| value.ring_capacity = capacity;
                if (job.count > capacity - available) {
                    if (observed) |value| value.outcome = .ring_capacity;
                    return null;
                }
            }
            control_available = available;
        }
        if (self.runtime_attached) {
            const cut = self.publicationCut();
            if (observed) |value| value.publication_preflight = cut;
            if (cut.head - cut.tail == cut.capacity) {
                self.visibility_backpressure +|= 1;
                if (observed) |value| value.outcome = .publication_capacity;
                return null;
            }
        }
        self.acceptanceHook(.before_accept_job, best_index);
        defer self.acceptanceHook(.after_accept_job, best_index);
        const completed_job = job.descriptor.job;
        const completed_count = job.count;
        const completed_elapsed_ns = job.elapsed_ns;
        const accepted = try self.acceptJob(job, actual_position, null, batch_id, control_available, observed);
        const before_measurement: readiness_observation.ReadinessMeasurement = .{ .frames_per_second = self.throughput.frames_per_second, .version = self.throughput.version };
        const attempted = completed_elapsed_ns != 0 and accepted.input.payload.worker.state == .ready;
        if (attempted) {
            if (observed) |value| value.effects.throughput_observation_attempted = true;
            self.throughput.observe(completed_count, completed_elapsed_ns) catch {};
        }
        if (self.readiness_supply_sink) |sink| sink.throughput(sink.context, .{ .job = completed_job, .count = completed_count, .elapsed_ns = completed_elapsed_ns, .before = before_measurement, .after = .{ .frames_per_second = self.throughput.frames_per_second, .version = self.throughput.version }, .attempted = attempted });
        return accepted;
    }
    fn publicationCut(self: *Service) observation.PublicationCut {
        const head = self.publication_head.load(.monotonic);
        const tail = self.publication_tail.load(.acquire);
        return .{ .head = head, .tail = tail, .capacity = self.publications.len };
    }
    fn ringPoint(raw: *anyopaque, point: ring.OfflinePoint) void {
        const self: *Service = @ptrCast(@alignCast(raw));
        const site: OfflineSite = switch (point.site) {
            .stream_ring_consumed => .stream_ring_consumed,
            .stream_ring_produced => .stream_ring_produced,
            .stream_produced => .stream_produced,
            .stream_consumed_release => .stream_consumed_release,
        };
        if (comptime @import("builtin").is_test) if ((site == .stream_consumed_release or site == .stream_ring_consumed) and self.offline_causal_replay == null) if (self.test_consumed_hook) |hook| {
            hook.call(hook.context, .{ .site = site, .edge = if (point.edge == .before) .before else .after, .index = point.index, .generation = point.generation, .value = point.value });
        };
        if (self.live_semantic_hooks) |hooks| {
            const cut: live_semantic.Point = .{ .role = .control, .site = orderSite(site), .edge = if (point.edge == .before) .before else .after, .index = point.index, .generation = point.generation, .value = if (point.edge == .before and site != .stream_produced) null else point.value };
            if (live_semantic.allowedPoint(cut)) hooks.cuts.point(hooks.cuts.context, cut);
        }
        self.offline(site, if (point.edge == .before) .before else .after, point.index, point.generation, point.value);
    }
    fn ringOffline(self: *Service, handle: Handle) ?ring.OfflineHook {
        if (self.offline_causal_replay == null and self.live_semantic_hooks == null) {
            if (comptime @import("builtin").is_test) {
                if (self.test_consumed_hook == null) return null;
            } else return null;
        }
        return .{ .context = self, .index = handle.index, .generation = handle.generation, .checkpoint = ringPoint };
    }
    fn semanticConsumedPoint(raw: *anyopaque, point: ring.OfflinePoint) void {
        const self: *Service = @ptrCast(@alignCast(raw));
        const hooks = self.live_semantic_hooks orelse unreachable;
        const consume = hooks.consume orelse unreachable;
        std.debug.assert(point.site == .stream_consumed_release);
        consume.checkpoint(consume.context, point);
    }
    fn semanticConsumedNoop(_: *anyopaque, _: ring.Consumed) void {}
    fn consumedPublication(raw: *anyopaque, value: ring.Consumed) void {
        const self: *Service = @ptrCast(@alignCast(raw));
        if (self.public_causal_consumed_sink) |sink| sink.emit(sink.context, value);
    }
    /// Called only after genuine Render/Worker joins. Closed slots already
    /// cleared their observer; never inspect never-opened undefined PCM rings.
    pub fn detachConsumedObserverQuiescent(self: *Service) void {
        self.public_causal_consumed_sink = null;
        for (self.slots) |*slot| if (slot.occupied) {
            slot.pcm_ring.consume_observer = null;
        };
    }
    fn acceptanceHook(self: *Service, stage: AcceptanceStage, index: usize) void {
        if (@import("builtin").is_test) if (self.test_acceptance_hook) |hook| hook.call(hook.context, stage, index);
    }
    fn acceptJob(self: *Service, job: *Job, position: trace.schema.Position, recorded: ?trace.schema.Worker, batch_id: u64, control_available: ?u64, observed: ?*observation.Acceptance) Error!Accepted {
        if (observed) |value| value.next_snapshot = self.next_snapshot;
        if (self.next_snapshot == std.math.maxInt(u64)) return error.InvalidState;
        const slot = try self.get(job.handle);
        const available = control_available orelse (self.controlAvailableObserved(slot, if (self.runtime_attached) position.accepted_control_frame else null, if (observed) |value| &value.availability else null, .acceptance, null) catch return error.ReplayMismatch);
        if (self.runtime_attached) {
            if (observed) |value| value.last_batch_id = self.last_batch_id;
            if (batch_id <= self.last_batch_id) return error.JobCapacity;
            const cut = self.publicationCut();
            if (observed) |value| value.publication_commit = cut;
            if (cut.head - cut.tail == cut.capacity) return error.JobCapacity;
        }
        if (recorded) |external| if (external.state != .ready) {
            // Failure/cancellation is an external accepted fact, not a demand
            // that replay's current disk reproduce a historical outage. The
            // actual worker has acknowledged this job before its slot retires.
            if (external.state != .failed and external.state != .cancelled) return error.ReplayMismatch;
            if (!trace.schema.isZero(external.content_hash)) return error.ReplayMismatch;
            job.outcome = external.state;
            job.failure = if (external.state == .failed) std.enums.fromInt(Failure, external.failure_code) orelse return error.ReplayMismatch else .none;
            if (external.state == .failed and job.failure == .none) return error.ReplayMismatch;
            job.hash = @splat(0);
        };
        const stale = stale: {
            const cancelled = slot.cancel.load(.acquire);
            if (observed) |value| value.cancel = cancelled;
            if (cancelled) break :stale true;
            const stopped = slot.pcm_ring.stopped.load(.acquire);
            if (observed) |value| value.stopped = stopped;
            if (stopped) break :stale true;
            const generation = slot.options.generation;
            if (observed) |value| value.generation = generation;
            if (job.descriptor.generation != generation) break :stale true;
            const epoch = slot.options.transport_epoch;
            if (observed) |value| value.transport_epoch = epoch;
            break :stale job.descriptor.transport_epoch != epoch;
        };
        if (observed) |value| value.stale = stale;
        if (stale) {
            job.outcome = .cancelled;
            job.failure = .none;
            job.hash = @splat(0);
            self.stale_completions +|= 1;
            if (observed) |value| value.effects.stale_completion_counted = true;
        }
        const actual = self.event(job);
        if (observed) |value| value.actual_worker = actual;
        if (recorded) |expected| if (!std.meta.eql(actual, expected)) return error.ReplayMismatch;
        const input: trace.Input = .{ .position = position, .payload = .{ .worker = actual } };
        input.validate() catch return error.InvalidState;
        if (job.outcome == .ready) {
            const coordinate = slot.pcm_ring.coordinate(job.ordinal) orelse return error.InvalidWindow;
            if (observed) |value| value.coordinate = coordinate;
            const produced = slot.pcm_ring.produced.load(.monotonic);
            if (observed) |value| value.ring_produced = produced;
            if (produced != job.ordinal or coordinate.cursor != job.descriptor.target_cursor or coordinate.loop_epoch != job.descriptor.loop_epoch) return error.InvalidWindow;
            const capacity = slot.pcm_ring.capacity_frames;
            if (observed) |value| value.ring_capacity = capacity;
            if (job.count > capacity - available) return error.InvalidWindow;
            var cut: ring.ReadCut = .{};
            const writable = slot.pcm_ring.writableObservedReplay(if (observed != null) &cut else null, self.ringOffline(job.handle));
            if (observed) |value| value.ring_writable = cut;
            if (job.count > writable) return error.InvalidWindow;
            try slot.pcm_ring.publishObservedReplay(job.pcm[0 .. @as(usize, job.count) * slot.asset.info.channels], if (observed) |value| &value.ring_publish else null, self.ringOffline(job.handle));
            if (observed) |value| value.effects.pcm_published = true;
            if (self.runtime_attached) {
                const head = self.publication_head.load(.monotonic);
                const entry = &self.publications[@intCast(head % self.publications.len)];
                const d = job.descriptor;
                entry.descriptor = .{ .batch_id = batch_id, .stream_slot = job.handle.index, .stream_generation = job.handle.generation, .asset = d.asset, .asset_generation = d.generation, .transport_epoch = d.transport_epoch, .profile_id = self.profile.id, .profile_hash = self.profile.hash(), .publication_ordinal = head + 1, .worker_job = d.job, .job_descriptor_hash = actual.job_descriptor_hash, .prefix_start = job.ordinal, .prefix_end = job.ordinal + job.count, .target_cursor = d.target_cursor, .loop_epoch = d.loop_epoch, .channels = slot.asset.info.channels, .pcm_hash = job.hash };
                entry.canonical = visibility.encode(entry.descriptor);
                entry.hash = trace.replay.hashPcm(&entry.canonical);
                entry.ring = &slot.pcm_ring;
                entry.replay_prepared = .init(false);
                slot.visibility_refs += 1;
                if (observed) |value| value.publication = entry.descriptor;
                self.publicationHook(.before_publication_release, head + 1);
                self.offline(.publication_release, .before, 0, 0, head + 1);
                self.orderCheckpoint(.control, .publication_release, .before, 0, 0, head + 1);
                self.publication_head.store(head + 1, .release);
                self.orderCheckpoint(.control, .publication_release, .after, 0, 0, head + 1);
                self.offline(.publication_release, .after, 0, 0, head + 1);
                self.publicationHook(.after_publication_release, head + 1);
                if (observed) |value| value.effects.publication_published = true;
            }
        } else if (job.outcome == .failed) {
            slot.failed = job.failure;
            if (observed) |value| value.effects.stream_failed = true;
        } else if (job.outcome == .cancelled) {
            // A cancelled job in this service means its stream generation is
            // terminal. Restore that causal fact even on a healthy replay host.
            const cancelled_handle = job.handle;
            self.semanticBoundary(.control, .service_cancel_release, .before, cancelled_handle.index, cancelled_handle.generation, 1);
            slot.cancel.store(true, .release);
            self.semanticBoundary(.control, .service_cancel_release, .after, cancelled_handle.index, cancelled_handle.generation, 1);
            if (observed) |value| value.effects.stream_cancelled = true;
        }
        const handle = job.handle;
        const job_index = slot.pending_job.?;
        slot.pending_job = null;
        slot.snapshot_version = self.next_snapshot;
        self.next_snapshot +|= 1;
        slot.replay_readiness = null;
        self.accepted_count +|= 1;
        if (self.runtime_attached) self.last_batch_id = batch_id;
        const accepted: Accepted = .{ .input = input, .handle = handle, .stale = stale };
        if (observed) |value| value.accepted = accepted;
        const released_job = job.descriptor.job;
        self.offline(.job_free, .before, job_index, released_job, @intFromEnum(State.free));
        self.orderCheckpoint(.control, .job_free, .before, job_index, released_job, @intFromEnum(State.free));
        job.state.store(.free, .release);
        self.orderCheckpoint(.control, .job_free, .after, job_index, released_job, @intFromEnum(State.free));
        self.offline(.job_free, .after, job_index, released_job, @intFromEnum(State.free));
        self.free_indices[@as(usize, self.profile.max_streams) + self.free_job_count] = job_index;
        self.free_job_count += 1;
        if (observed) |value| {
            value.effects.job_released = true;
            value.outcome = .accepted;
        }
        return accepted;
    }
    pub fn readiness(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64) Error!trace.Input {
        return self.readinessObserved(handle, position, context, control_epoch, null, .{}, null);
    }
    /// Internal observation entry. The measurement seam is erased in shipping
    /// builds; ordinary readiness retains the same real local throughput.
    pub fn readinessObserved(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64, observed: ?*readiness_observation.QueryRead, key: readiness_observation.QueryKey, source: ?readiness_observation.MeasurementSource) Error!trace.Input {
        return self.readinessObservedWithLive(handle, position, context, control_epoch, observed, key, source, null, false);
    }
    /// Checked live callers supply fresh stack storage for this exact query.
    pub fn readinessLiveV1(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64, live: *?LiveObservationDeferV1) Error!trace.Input {
        return self.readinessLiveObservedV1(handle, position, context, control_epoch, null, .{}, live);
    }
    /// Internal owned observation entry. Scratch only receives actual reached
    /// reads; this route has no measurement substitution or additional acquire.
    pub fn readinessLiveObservedV1(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64, observed: ?*readiness_observation.QueryRead, key: readiness_observation.QueryKey, live: *?LiveObservationDeferV1) Error!trace.Input {
        live.* = null;
        if (self.replay_mode) return error.InvalidState;
        return self.readinessObservedWithLive(handle, position, context, control_epoch, observed, key, null, live, false);
    }
    pub fn readinessInitialEntryV1(self: *Service, tick_serial: u64, request_id: u64, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64) Error!trace.Input {
        const owner = self.initial_entry_owner orelse return error.InvalidState;
        const actual = try owner.validate(owner.context, self, tick_serial, request_id, handle);
        if (!std.meta.eql(position, actual.position) or context != actual.context or control_epoch != actual.control_epoch) return error.InvalidState;
        return self.readinessObservedWithLive(handle, position, context, control_epoch, null, .{}, null, null, true);
    }
    fn readinessObservedWithLive(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64, observed: ?*readiness_observation.QueryRead, key: readiness_observation.QueryKey, source: ?readiness_observation.MeasurementSource, live: ?*?LiveObservationDeferV1, initial: bool) Error!trace.Input {
        errdefer |err| if (observed) |value| {
            value.service_error = @intFromError(err);
        };
        self.readinessHook(.before_stopped_first, 0);
        const first_slot = try self.get(handle);
        self.offline(.readiness_stopped_first, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.control, .readiness_stopped_first, .before, handle.index, handle.generation, null);
        const stopped = first_slot.pcm_ring.stopped.load(.acquire);
        self.orderCheckpoint(.control, .readiness_stopped_first, .after, handle.index, handle.generation, @intFromBool(stopped));
        self.offline(.readiness_stopped_first, .after, handle.index, handle.generation, @intFromBool(stopped));
        if (observed) |value| {
            value.saw(.stopped_first);
            value.stopped_first = stopped;
        }
        self.readinessHook(.after_stopped_first, @intFromBool(stopped));
        if (stopped) return error.InvalidState;
        const replay = self.replay_mode;
        if (observed) |value| {
            value.saw(.mode);
            value.replay_mode = replay;
        }
        if (replay) {
            const cached = (try self.get(handle)).replay_readiness orelse return error.IncompleteTrace;
            const facts = cached.payload.readiness_snapshot.facts;
            if (cached.position.accepted_control_frame != position.accepted_control_frame or cached.position.control_tick != position.control_tick or facts.context != context or facts.control_epoch != control_epoch) return error.IncompleteTrace;
            return cached;
        }
        return self.observeReadinessObserved(handle, position, context, control_epoch, observed, key, source, live, initial);
    }
    /// Recompute the requested stream's facts at its real query site. Only the
    /// recorded external measurement is substituted; availability, queue and
    /// backlog stay owned by the reconstructed service.
    pub fn replayReadinessAt(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64, expected: trace.Input) Error!trace.Input {
        if (!self.replay_mode or expected.payload != .readiness_snapshot or !std.meta.eql(expected.position, position)) return error.ReplayMismatch;
        expected.validate() catch return error.ReplayMismatch;
        var actual = try self.observeReadiness(handle, position, context, control_epoch);
        const external = expected.payload.readiness_snapshot;
        const facts = &actual.payload.readiness_snapshot.facts;
        facts.throughput_pcm_frames_per_second = external.facts.throughput_pcm_frames_per_second;
        facts.measurement_version = external.facts.measurement_version;
        if (!std.meta.eql(facts.*, external.facts)) return error.ReplayMismatch;
        actual.payload.readiness_snapshot.expected = self.projected(try self.get(handle), position, facts.*);
        if (!std.meta.eql(actual.payload.readiness_snapshot.expected, external.expected)) return error.ReplayMismatch;
        return actual;
    }
    fn observeReadiness(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64) Error!trace.Input {
        return self.observeReadinessObserved(handle, position, context, control_epoch, null, .{}, null, null, false);
    }
    fn observeReadinessObserved(self: *Service, handle: Handle, position: trace.schema.Position, context: u64, control_epoch: u64, observed: ?*readiness_observation.QueryRead, key: readiness_observation.QueryKey, source: ?readiness_observation.MeasurementSource, live: ?*?LiveObservationDeferV1, initial: bool) Error!trace.Input {
        const slot = try self.get(handle);
        self.offline(.readiness_stopped_second, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.control, .readiness_stopped_second, .before, handle.index, handle.generation, null);
        const stopped = slot.pcm_ring.stopped.load(.acquire);
        self.orderCheckpoint(.control, .readiness_stopped_second, .after, handle.index, handle.generation, @intFromBool(stopped));
        self.offline(.readiness_stopped_second, .after, handle.index, handle.generation, @intFromBool(stopped));
        if (observed) |value| {
            value.saw(.stopped_second);
            value.stopped_second = stopped;
            value.attached = self.runtime_attached;
        }
        if (stopped) return error.InvalidState;
        const sequence: u64 = if (initial) 0 else blk: {
            self.offline(.readiness_sequence, .before, 0, 0, 0);
            self.orderCheckpoint(.control, .readiness_sequence, .before, 0, 0, null);
            const acquired_sequence = self.observation_sequence.load(.acquire);
            self.orderCheckpoint(.control, .readiness_sequence, .after, 0, 0, acquired_sequence);
            self.offline(.readiness_sequence, .after, 0, 0, acquired_sequence);
            if (observed) |value| {
                value.saw(.sequence_before);
                value.sequence_before = acquired_sequence;
            }
            self.readinessHook(.after_sequence, acquired_sequence);
            break :blk acquired_sequence;
        };
        var observed_frame: ?u64 = null;
        if (self.runtime_attached and !initial) {
            if (sequence & 1 != 0) {
                if (live) |value| value.* = .{ .reason = .odd_sequence, .operation = .readiness, .handle = handle, .requested_frame = position.accepted_control_frame, .sequence_before = sequence };
                return error.InvalidState;
            }
            self.offline(.readiness_frame, .before, 0, 0, 0);
            self.orderCheckpoint(.control, .readiness_frame, .before, 0, 0, null);
            const frame = self.observation_frame.load(.acquire);
            if (@import("builtin").is_test) self.testRetryWorkload(.{ .frame_loaded = frame });
            observed_frame = frame;
            self.orderCheckpoint(.control, .readiness_frame, .after, 0, 0, frame);
            self.offline(.readiness_frame, .after, 0, 0, frame);
            if (observed) |value| {
                value.saw(.observation_frame);
                value.frame = frame;
            }
            self.readinessHook(.after_frame, frame);
            if (frame != position.accepted_control_frame) {
                if (live) |value| value.* = .{ .reason = .frame_mismatch, .operation = .readiness, .handle = handle, .requested_frame = position.accepted_control_frame, .observed_frame = frame, .sequence_before = sequence };
                return error.InvalidState;
            }
        }
        const ordinal = if (initial) try self.initialEntryConsumed(slot) else blk: {
            self.offline(.readiness_consumed, .before, handle.index, handle.generation, 0);
            self.orderCheckpoint(.control, .readiness_consumed, .before, handle.index, handle.generation, null);
            const read_ordinal = if (self.runtime_attached) slot.pcm_ring.control_consumed.load(.acquire) else slot.pcm_ring.consumed.load(.acquire);
            if (@import("builtin").is_test) if (self.runtime_attached) self.testRetryWorkload(.{ .consumed_loaded = .{ .index = handle.index, .generation = handle.generation, .value = read_ordinal } });
            self.orderCheckpoint(.control, .readiness_consumed, .after, handle.index, handle.generation, read_ordinal);
            self.offline(.readiness_consumed, .after, handle.index, handle.generation, read_ordinal);
            break :blk read_ordinal;
        };
        if (observed) |value| {
            value.saw(.consumed);
            value.consumed = ordinal;
        }
        self.readinessHook(.after_consumed, ordinal);
        const coordinate = slot.pcm_ring.coordinate(ordinal) orelse return error.InvalidState;
        const end = if (slot.options.loop) |loop| loop.end else slot.asset.sound.frames;
        self.offline(.readiness_produced, .before, handle.index, handle.generation, 0);
        self.orderCheckpoint(.control, .readiness_produced, .before, handle.index, handle.generation, null);
        const produced = slot.pcm_ring.produced.load(.acquire);
        self.orderCheckpoint(.control, .readiness_produced, .after, handle.index, handle.generation, produced);
        self.offline(.readiness_produced, .after, handle.index, handle.generation, produced);
        if (observed) |value| {
            value.saw(.produced);
            value.produced = produced;
        }
        self.readinessHook(.after_produced, produced);
        if ((live != null or initial) and (ordinal > produced or produced - ordinal > slot.pcm_ring.capacity_frames)) return error.InvalidState;
        const available = @min(produced - ordinal, end - coordinate.cursor);
        var backlog: u64 = 0;
        var backlog_jobs: u32 = 0;
        if (observed) |value| {
            value.configured = @intCast(@min(self.jobs.len, 65535));
            if (self.jobs.len > 256) value.representation_complete = false;
        }
        // Semantic custody proof: this sole Control invocation cannot race
        // another Control free/queued transition or descriptor/count mutation.
        // Worker only moves queued -> running -> completed, all nonfree. Thus
        // the original backlog predicate below is invariant to Worker progress;
        // per-slot state labels remain optional diagnostic evidence, not replay
        // inputs. Keep every original load and calculation unchanged.
        for (self.jobs, 0..) |*job, i| {
            self.readinessHook(.before_job_state, i);
            self.offline(.readiness_job, .before, i, 0, 0);
            self.orderCheckpoint(.control, .readiness_job, .before, i, 0, null);
            const state = job.state.load(.acquire);
            self.orderCheckpoint(.control, .readiness_job, .after, i, 0, @intFromEnum(state));
            self.offline(.readiness_job, .after, i, 0, @intFromEnum(state));
            if (observed) |value| value.putState(i, state);
            self.readinessHook(.after_job_state, i);
            if (state != .free and job.handle.index != handle.index) {
                backlog += job.count;
                backlog_jobs += 1;
            }
        }
        const pending = slot.pending_job;
        const queued: u64 = if (pending) |i| self.jobs[i].count else 0;
        if (observed) |value| {
            value.saw(.pending);
            value.pending_job = pending;
            value.pending_count = @intCast(queued);
        }
        const local: readiness_observation.ReadinessMeasurement = .{ .frames_per_second = self.throughput.frames_per_second, .version = self.throughput.version };
        if (observed) |value| {
            value.saw(.measurement);
            value.local_measurement = local;
        }
        const selected = if (@import("builtin").is_test) (if (source) |measurement| try measurement.select(measurement.context, key) else local) else local;
        if (observed) |value| value.selected_measurement = selected;
        const facts: trace.schema.readiness.Facts = .{ .context = context, .asset = slot.asset.sound.key.id, .generation = slot.options.generation, .transport_epoch = slot.options.transport_epoch, .control_epoch = control_epoch, .snapshot_version = slot.snapshot_version, .profile = self.profile.id, .profile_hash = self.profile.hash(), .resident_chunk_first = 0, .resident_chunk_count = 0, .pcm_start = coordinate.cursor, .pcm_end = coordinate.cursor + available, .available_frames = available, .queued_bytes = queued * slot.asset.info.channels * 4, .queued_frames = queued, .backlog_frames = backlog, .backlog_jobs = backlog_jobs, .throughput_pcm_frames_per_second = selected.frames_per_second, .measurement_version = selected.version };
        const projection = self.projectedObserved(slot, position, facts, observed);
        const input: trace.Input = .{ .position = position, .payload = .{ .readiness_snapshot = .{ .facts = facts, .expected = projection } } };
        input.validate() catch return error.InvalidState;
        if (self.runtime_attached and !initial) {
            self.readinessHook(.before_final_sequence, 0);
            self.offline(.readiness_final_sequence, .before, 0, 0, 0);
            self.orderCheckpoint(.control, .readiness_final_sequence, .before, 0, 0, null);
            const after = self.observation_sequence.load(.acquire);
            self.orderCheckpoint(.control, .readiness_final_sequence, .after, 0, 0, after);
            self.offline(.readiness_final_sequence, .after, 0, 0, after);
            if (observed) |value| {
                value.saw(.sequence_after);
                value.sequence_after = after;
            }
            self.readinessHook(.after_final_sequence, after);
            if (sequence != after) {
                if (live) |value| value.* = .{ .reason = .sequence_changed, .operation = .readiness, .handle = handle, .requested_frame = position.accepted_control_frame, .observed_frame = observed_frame, .sequence_before = sequence, .sequence_after = after };
                return error.InvalidState;
            }
        }
        return input;
    }
    fn availabilityHook(self: *Service, stage: AvailabilityStage, value: u64) void {
        if (@import("builtin").is_test) if (self.test_availability_hook) |hook| hook.call(hook.context, stage, value);
    }
    pub fn readinessHook(self: *Service, stage: readiness_observation.ReadStage, value: u64) void {
        if (@import("builtin").is_test) if (self.test_readiness_hook) |hook| hook.call(hook.context, stage, value);
    }
    pub fn frontierHook(self: *Service, stage: readiness_observation.FrontierStage, value: u64) void {
        if (@import("builtin").is_test) if (self.test_frontier_hook) |hook| hook.call(hook.context, stage, value);
    }
    pub fn memory(self: *const Service) Memory {
        var owned = self.slot_guards.len * @sizeOf(std.atomic.Value(u8)) + self.publications.len * @sizeOf(visibility.Entry) + @sizeOf(Service) + self.free_indices.len * @sizeOf(u16) + self.slots.len * @sizeOf(Slot) + self.jobs.len * @sizeOf(Job) + self.rings_pcm.len * 4 + self.job_pcm.len * 4 + self.encoded_cache.len + self.decoder_zig_bytes.load(.acquire);
        for (self.slots) |*slot| if (slot.occupied) {
            owned += opus.max_page_bytes;
        };
        const native = self.native_bytes.load(.acquire);
        return .{ .owned_bytes = owned, .native_decoder_bytes = native, .peak_native_decoder_bytes = self.peak_native_bytes.load(.acquire), .total_requested_bytes = owned + native, .pcm_capacity_bytes = (self.rings_pcm.len + self.job_pcm.len) * 4 };
    }
    pub fn failure(self: *Service, handle: Handle) Error!Failure {
        return (try self.get(handle)).failed;
    }
    fn jobFor(self: *Service, id: u64) Error!*Job {
        for (self.jobs) |*job| if (job.state.load(.acquire) != .free and job.descriptor.job == id) return job;
        return error.ResourceNotPrepared;
    }
    pub fn computedJobDescriptor(self: *Service, id: u64) Error![]const u8 {
        const job = try self.jobFor(id);
        return job.descriptor_bytes[0..job.descriptor_len];
    }
    pub fn preparePcm(self: *Service, worker: trace.schema.Worker) Error!trace.replay.PreparedPcm {
        const job = try self.jobFor(worker.job);
        if (job.state.load(.acquire) != .completed or job.outcome != .ready) return error.ResourceNotPrepared;
        const slot = try self.get(job.handle);
        return .{ .job = job.descriptor.job, .asset = job.descriptor.asset, .generation = job.descriptor.generation, .transport_epoch = job.descriptor.transport_epoch, .pcm_start = job.descriptor.target_cursor, .pcm_end = job.descriptor.target_cursor + job.count, .available_frames = job.count, .channel_count = slot.asset.info.channels, .content_hash = job.hash, .pcm_bytes = std.mem.sliceAsBytes(job.pcm[0 .. @as(usize, job.count) * slot.asset.info.channels]), .job_descriptor_bytes = job.descriptor_bytes[0..job.descriptor_len] };
    }
    pub fn inject(self: *Service, input: trace.Input) Error!void {
        if (self.runtime_attached) return error.InvalidState;
        return self.injectWithBatch(input, 0);
    }
    pub fn injectWithBatch(self: *Service, input: trace.Input, batch_id: u64) Error!void {
        _ = try self.acceptReplayWithBatch(input, batch_id);
    }
    pub fn acceptReplayWithBatch(self: *Service, input: trace.Input, batch_id: u64) Error!Accepted {
        if (!self.replay_mode or input.payload != .worker) return error.ReplayMismatch;
        const job = try self.jobFor(input.payload.worker.job);
        if (job.state.load(.acquire) != .completed) return error.ResourceNotPrepared;
        return self.acceptJob(job, input.position, input.payload.worker, batch_id, null, null);
    }
    pub fn recomputeReadiness(self: *Service, position: trace.schema.Position, facts: trace.schema.readiness.Facts) Error!trace.schema.readiness.Projection {
        facts.validate() catch return error.ReplayMismatch;
        if (!self.replay_mode or facts.profile != self.profile.id or !std.mem.eql(u8, &facts.profile_hash, &self.profile.hash())) return error.ReplayMismatch;
        for (self.slots, 0..) |*slot, i| if (slot.occupied and slot.asset.sound.key.id == facts.asset and slot.options.generation == facts.generation and slot.options.transport_epoch == facts.transport_epoch and slot.snapshot_version == facts.snapshot_version) {
            // Recompute the availability facts from accepted completions; only
            // measured throughput/backlog observations are replay input.
            const observed = try self.observeReadiness(.{ .index = @intCast(i), .generation = slot.generation }, position, facts.context, facts.control_epoch);
            const own = observed.payload.readiness_snapshot.facts;
            if (facts.snapshot_version != own.snapshot_version or facts.queued_frames != own.queued_frames or facts.queued_bytes != own.queued_bytes or facts.backlog_frames != own.backlog_frames or facts.backlog_jobs != own.backlog_jobs) return error.ReplayMismatch;
            if (facts.pcm_start != own.pcm_start or facts.pcm_end != own.pcm_end or facts.available_frames != own.available_frames) return error.ReplayMismatch;
            const projection = self.projected(slot, position, facts);
            self.slots[i].replay_readiness = .{ .position = position, .payload = .{ .readiness_snapshot = .{ .facts = facts, .expected = projection } } };
            return projection;
        };
        return error.ResourceNotPrepared;
    }
    /// Collector-free capture registration, before any asset preparation or
    /// Worker/Render entry. The host must genuinely exclude every producer and
    /// consumer; counters/idle flags below are eligibility, never proof of it.
    /// No callback or context may be replaced, freed or moved until matching
    /// excluded detach after genuine joins. Capture cannot override clocks.
    pub fn attachLiveSemanticQuiescent(self: *Service, hooks: LiveSemanticHooks) Error!void {
        if (hooks.clock != null or hooks.consume != null) return error.InvalidState;
        try self.attachLiveSemanticBindingQuiescent(hooks);
    }
    /// Fresh offline owner only. Host independently establishes offline
    /// provenance and owns replay threads/cursors. This does not set replay_mode
    /// or enable any legacy expected-readiness/throughput/result substitution.
    /// Host must abort the pinned clock on any global comparison/cut failure
    /// before native cleanup. Clock failure never grants lifetime authority.
    pub fn attachLiveSemanticReplayQuiescent(self: *Service, hooks: LiveSemanticHooks) Error!void {
        if (@import("builtin").is_test) if (hooks.test_retry_workload != null) return error.InvalidState;
        const clock = hooks.clock orelse return error.InvalidState;
        clock.validateInitial() catch return error.InvalidState;
        try self.attachLiveSemanticBindingQuiescent(hooks);
    }
    /// No scheduling state is read from the engine by this callback path.
    pub fn testRetryWorkload(self: *Service, workload_event: TestRetryWorkloadEvent) void {
        if (@import("builtin").is_test) {
            if (self.live_semantic_hooks) |hooks| if (hooks.test_retry_workload) |workload|
                workload.call(workload.context, workload_event);
        }
    }
    fn attachLiveSemanticBindingQuiescent(self: *Service, hooks: LiveSemanticHooks) Error!void {
        if (self.live_semantic_hooks != null or self.prerequisite_order != null or
            self.prerequisite_order_mode != .prerequisite or self.offline_causal_replay != null or
            self.public_causal_worker_sink != null or self.public_causal_exclusion != null or
            self.public_causal_consumed_sink != null or self.readiness_supply_sink != null or
            self.readiness_lifecycle_sink != null or self.readiness_attached or self.replay_mode or
            self.live_slot_guard_points or self.live_availability_points or
            self.semantic_preparation_started or self.semantic_source_call != 0 or
            self.next_generation != 1 or self.next_job != 1 or self.accepted_count != 0 or
            self.worker_busy.load(.acquire) or self.publication_head.load(.acquire) != 0 or
            self.publication_read.load(.acquire) != 0 or self.publication_tail.load(.acquire) != 0 or
            self.observation_sequence.load(.acquire) != 0 or self.observation_frame.load(.acquire) != 0)
            return error.InvalidState;
        if (comptime @import("builtin").is_test) {
            if (self.test_checkpoint_hook != null or self.test_worker_clock_hook != null or self.test_worker_clock_observer != null or
                self.test_consumed_hook != null or self.test_readiness_hook != null or
                self.test_availability_hook != null or self.test_supply_hook != null or self.test_supply_return_hook != null or
                self.test_frontier_hook != null or self.test_worker_hook != null or
                self.test_worker_stage_hook != null or self.test_acceptance_hook != null or
                self.test_publication_hook != null) return error.InvalidState;
        }
        for (self.slots) |*slot| if (slot.occupied) return error.InvalidState;
        for (self.jobs) |*job| if (job.state.load(.acquire) != .free) return error.InvalidState;
        self.live_semantic_hooks = hooks;
    }
    /// Exact identity check only, never a join. The owner has already excluded
    /// all callers and joined producers/consumer, or is rolling back before any
    /// thread started. Preserve foreign bindings on every failure path.
    pub fn detachLiveSemanticQuiescent(self: *Service, expected: LiveSemanticHooks) Error!void {
        const actual = self.live_semantic_hooks orelse return error.InvalidState;
        if (!LiveSemanticHooks.same(actual, expected) or self.worker_busy.load(.acquire) or
            self.prerequisite_order != null or self.offline_causal_replay != null or self.replay_mode)
            return error.InvalidState;
        // Validate every borrowed observer before clearing any field. This is
        // identity validation only; the caller supplies genuine thread joins.
        for (self.slots, 0..) |*slot, index| if (slot.occupied) {
            if (actual.consume != null) {
                const observer = slot.pcm_ring.consume_observer orelse return error.InvalidState;
                if (observer.context != @as(*anyopaque, @ptrCast(self)) or observer.index != index or
                    observer.generation != slot.generation or observer.emit != semanticConsumedNoop or
                    observer.checkpoint != semanticConsumedPoint) return error.InvalidState;
            } else if (slot.pcm_ring.consume_observer != null) return error.InvalidState;
        };
        for (self.slots) |*slot| if (slot.occupied and actual.consume != null) {
            slot.pcm_ring.consume_observer = null;
        };
        self.live_semantic_hooks = null;
    }
    /// Binding mutation only. The caller has already parked the real Worker,
    /// excluded Control/Render entry and joined or excluded the consumer. None
    /// of these state checks establishes thread quiescence. Collectors and
    /// their backing storage stay pinned until detachment after genuine joins.
    pub fn attachOrderPrerequisiteQuiescent(self: *Service, roles: order.Roles) Error!void {
        return self.attachOrderQuiescent(roles, .prerequisite);
    }
    /// Explicit semantic-span attachment: retain finite Control Ring and all
    /// Service role observations, but never attach Ring's per-sample Render or
    /// consumed callbacks. This also opts installed offline hooks out of those
    /// callbacks; their finite checkpoints and raw clock calls are unchanged.
    /// The semantic profile's phase/lifecycle eligibility is checked elsewhere.
    /// No fresh-owner, real-join or pinned-storage requirement is relaxed.
    pub fn attachOrderSemanticSpanQuiescent(self: *Service, roles: order.Roles) Error!void {
        return self.attachOrderQuiescent(roles, .semantic_span);
    }
    /// Fresh offline owner only. The host validates its offline owner, parks
    /// every caller and installs the expected real offline hooks beforehand.
    /// Service has no owner-kind or thread-authentication authority. The roles,
    /// hooks and generated Ring bindings are borrowed and must remain unchanged
    /// until genuine producer/consumer joins and the matching detach. Idle flags
    /// do not prove those joins. Capture's semantic-span mode is unchanged.
    pub fn attachOrderSemanticReplayQuiescent(self: *Service, roles: order.Roles, expected_hooks: OfflineReplayHooks) Error!void {
        const hooks = self.offline_causal_replay orelse return error.InvalidState;
        if (hooks.context != expected_hooks.context or hooks.checkpoint != expected_hooks.checkpoint or
            hooks.clock != expected_hooks.clock or self.replay_mode or
            self.public_causal_consumed_sink != null) return error.InvalidState;
        return self.attachOrderQuiescent(roles, .semantic_replay);
    }
    /// Host must already exclude/join every producer and consumer. These are
    /// borrowed pinned bindings, not authentication or completeness tokens.
    /// Capture never installs an offline pacing callback; test-only hooks may
    /// observe the actual finite points. Existing attachments are unchanged.
    pub fn attachOrderLiveSpanQuiescent(self: *Service, roles: order.Roles) Error!void {
        if (self.offline_causal_replay != null) return error.InvalidState;
        try self.attachOrderSemanticSpanQuiescent(roles);
        self.live_slot_guard_points = true;
        self.live_availability_points = true;
    }
    /// Fresh-owner host custody and hook provenance are checked by the owner.
    /// Reuse the existing exact hook/binding checks; never set replay_mode.
    pub fn attachOrderLiveReplayQuiescent(self: *Service, roles: order.Roles, expected_hooks: OfflineReplayHooks) Error!void {
        try self.attachOrderSemanticReplayQuiescent(roles, expected_hooks);
        self.live_slot_guard_points = true;
        self.live_availability_points = true;
    }
    fn attachOrderQuiescent(self: *Service, roles: order.Roles, mode: OrderAttachmentMode) Error!void {
        if (self.live_semantic_hooks != null or self.prerequisite_order != null or self.prerequisite_order_mode != .prerequisite or
            self.live_slot_guard_points or self.live_availability_points or
            self.next_generation != 1 or !roles.pristine()) return error.InvalidState;
        if (mode == .semantic_span and self.public_causal_consumed_sink != null) return error.InvalidState;
        for (self.slots) |*slot| if (slot.occupied) return error.InvalidState;
        self.prerequisite_order = roles;
        self.prerequisite_order_mode = mode;
    }
    /// The caller has joined all producer/consumer users and excluded every
    /// new entry. Validate the entire borrowed set before clearing any binding;
    /// foreign ownership must never be silently discarded on an error path.
    pub fn detachOrderPrerequisiteQuiescent(self: *Service) Error!void {
        return self.detachOrderQuiescent(.prerequisite);
    }
    /// Matching semantic detach requires the same three pinned collectors.
    /// A foreign pointer, mixed mode or unexpected consumed callback fails
    /// before any binding/mode is changed. These checks do not establish joins.
    pub fn detachOrderSemanticSpanQuiescent(self: *Service, expected: order.Roles) Error!void {
        const roles = self.prerequisite_order orelse return error.InvalidState;
        if (roles.control != expected.control or roles.render != expected.render or
            roles.worker != expected.worker) return error.InvalidState;
        inline for (.{ order.Role.control, order.Role.render, order.Role.worker }) |role| {
            const lane = roles.get(role);
            if (lane.address != lane or lane.role != role) return error.InvalidState;
        }
        return self.detachOrderQuiescent(.semantic_span);
    }
    /// The host retains the original hook value; this is an identity check,
    /// not proof of offline provenance, ownership or thread quiescence. Validate
    /// all expected bindings before changing any field. Offline hooks themselves
    /// remain the host's borrow and are not cleared by this attachment's detach.
    pub fn detachOrderSemanticReplayQuiescent(self: *Service, expected: order.Roles, expected_hooks: OfflineReplayHooks) Error!void {
        const roles = self.prerequisite_order orelse return error.InvalidState;
        if (roles.control != expected.control or roles.render != expected.render or
            roles.worker != expected.worker) return error.InvalidState;
        inline for (.{ order.Role.control, order.Role.render, order.Role.worker }) |role| {
            const lane = roles.get(role);
            if (lane.address != lane or lane.role != role) return error.InvalidState;
        }
        const hooks = self.offline_causal_replay orelse return error.InvalidState;
        if (hooks.context != expected_hooks.context or hooks.checkpoint != expected_hooks.checkpoint or
            hooks.clock != expected_hooks.clock or self.replay_mode or
            self.public_causal_consumed_sink != null) return error.InvalidState;
        return self.detachOrderQuiescent(.semantic_replay);
    }
    fn detachOrderQuiescent(self: *Service, mode: OrderAttachmentMode) Error!void {
        const roles = self.prerequisite_order orelse return error.InvalidState;
        if (self.prerequisite_order_mode != mode or
            self.live_slot_guard_points != self.live_availability_points or
            (mode == .semantic_span and self.public_causal_consumed_sink != null)) return error.InvalidState;
        for (self.slots, 0..) |*slot, index| if (slot.occupied) {
            const control = slot.pcm_ring.order_control orelse return error.InvalidState;
            if (control.collector != roles.control or control.index != index or
                control.generation != slot.generation) return error.InvalidState;
            switch (mode) {
                .prerequisite => {
                    const render = slot.pcm_ring.order_render orelse return error.InvalidState;
                    if (render.collector != roles.render or render.index != index or
                        render.generation != slot.generation) return error.InvalidState;
                },
                .semantic_span => if (slot.pcm_ring.order_render != null or
                    slot.pcm_ring.consume_observer != null) return error.InvalidState,
                .semantic_replay => {
                    if (slot.pcm_ring.order_render != null) return error.InvalidState;
                    const observer = slot.pcm_ring.consume_observer orelse return error.InvalidState;
                    if (observer.context != @as(*anyopaque, @ptrCast(self)) or
                        observer.index != index or observer.generation != slot.generation or
                        observer.emit != consumedPublication or observer.checkpoint != ringPoint) return error.InvalidState;
                },
            }
        };
        for (self.slots) |*slot| if (slot.occupied) {
            slot.pcm_ring.order_control = null;
            slot.pcm_ring.order_render = null;
            if (mode == .semantic_replay) slot.pcm_ring.consume_observer = null;
        };
        self.prerequisite_order = null;
        self.prerequisite_order_mode = .prerequisite;
        self.live_slot_guard_points = false;
        self.live_availability_points = false;
    }
    /// Host-exclusive attachment. The service itself stays pinned even while
    /// there are no open streams because Renderer reads its gate ledger.
    pub fn attachRuntime(self: *Service) Error!void {
        if (self.runtime_attached or self.worker_busy.load(.acquire)) return error.InvalidState;
        for (self.slots) |*slot| if (slot.occupied and (slot.pending_job != null or slot.pcm_ring.references.load(.acquire) != 0 or slot.pcm_ring.produced.load(.acquire) != 0)) return error.InvalidState;
        for (self.slots) |*slot| if (slot.occupied) {
            slot.pcm_ring.gated = true;
        };
        self.initial_entry_owner = null;
        self.runtime_attached = true;
    }
    pub fn detachRuntimeQuiescent(self: *Service) Error!void {
        if (self.readiness_attached) return error.DrainPending;
        if (!self.runtime_attached or self.publication_tail.load(.acquire) != self.publication_head.load(.acquire)) return error.DrainPending;
        for (self.slots) |*slot| if (slot.occupied) {
            slot.pcm_ring.gated = false;
        };
        self.initial_entry_owner = null;
        self.runtime_attached = false;
    }
    /// Renderer only, once before any group claim at this gate. Fixed one-shot
    /// pins exclude close/reopen without waiting or touching native resources.
    pub fn beginRenderGate(self: *Service, gate: u64, frame: u64) void {
        self.last_render_gate.store(gate, .release);
        self.last_render_frame.store(frame, .release);
    }
    /// Publish one coherent completed-DSP observation before runtime advances
    /// its public frame. Control never advertises already consumed frames at a
    /// newer frontier. During the tiny cross-publication window it retries.
    pub fn endRenderSpan(self: *Service, frame: u64) void {
        self.offline(.render_sequence_odd, .before, 0, 0, 0);
        self.orderCheckpoint(.render, .render_sequence_odd, .before, 0, 0, null);
        const sequence_before = self.observation_sequence.fetchAdd(1, .acq_rel);
        self.orderCheckpoint(.render, .render_sequence_odd, .after, 0, 0, sequence_before +% 1);
        self.offline(.render_sequence_odd, .after, 0, 0, sequence_before +% 1);
        self.frontierHook(.after_odd, sequence_before +% 1);
        if (@import("builtin").is_test) self.testRetryWorkload(.{ .render_odd = sequence_before +% 1 });
        self.semanticBoundary(.render, .service_render_consumed_prefix, .before, frame, sequence_before +% 1, null);
        for (self.slot_guards, 0..) |*guard, i| {
            // A failed acquire owns no descriptor. Keep both CAS edges keyed
            // by slot index only, including closed/uninitialized slots.
            self.slotGuardPoint(.render, .slot_guard_render_claim, .before, i, 0, null);
            const guard_result = guard.cmpxchgStrong(0, 1, .acquire, .monotonic);
            self.slotGuardPoint(.render, .slot_guard_render_claim, .after, i, 0, guard_result orelse 0);
            if (guard_result != null) continue;
            const owned_generation = self.slots[i].generation;
            const pcm = &self.slots[i].pcm_ring;
            const consumed = pcm.consumed.load(.monotonic);
            self.offline(.render_consumed, .before, i, owned_generation, consumed);
            self.orderCheckpoint(.render, .render_consumed, .before, i, owned_generation, consumed);
            pcm.control_consumed.store(consumed, .release);
            self.orderCheckpoint(.render, .render_consumed, .after, i, owned_generation, consumed);
            self.offline(.render_consumed, .after, i, owned_generation, consumed);
            self.slotGuardPoint(.render, .slot_guard_render_release, .before, i, owned_generation, 0);
            guard.store(0, .release);
            // Close/reopen can run now; never consult the old descriptor again.
            self.slotGuardPoint(.render, .slot_guard_render_release, .after, i, owned_generation, 0);
        }
        self.semanticBoundary(.render, .service_render_consumed_prefix, .after, frame, sequence_before +% 1, null);
        self.frontierHook(.after_consumed_prefix, frame);
        self.offline(.stream_observation_frame, .before, 0, 0, frame);
        self.orderCheckpoint(.render, .stream_observation_frame, .before, 0, 0, frame);
        self.observation_frame.store(frame, .monotonic);
        self.orderCheckpoint(.render, .stream_observation_frame, .after, 0, 0, frame);
        self.offline(.stream_observation_frame, .after, 0, 0, frame);
        self.frontierHook(.after_frame, frame);
        self.offline(.render_sequence_even, .before, 0, 0, 0);
        self.orderCheckpoint(.render, .render_sequence_even, .before, 0, 0, null);
        const odd = self.observation_sequence.fetchAdd(1, .release);
        self.orderCheckpoint(.render, .render_sequence_even, .after, 0, 0, odd +% 1);
        self.offline(.render_sequence_even, .after, 0, 0, odd +% 1);
        self.frontierHook(.after_even, odd +% 1);
        if (@import("builtin").is_test) self.testRetryWorkload(.{ .render_even = odd +% 1 });
    }
    /// Host-quiesced scheduling query: Control is serialized and Render is
    /// parked. Only unread publications need another real Render gate; an
    /// admitted publication waiting for Control acknowledgement does not.
    /// Equality proves neither source retirement nor producer joins. This
    /// query never consumes publications or replaces the final drain checks.
    pub fn hasPendingRenderVisibility(self: *const Service) bool {
        const head = self.publication_head.load(.acquire);
        const read = self.publication_read.load(.acquire);
        return head != read;
    }
    pub fn publicationFrontier(self: *Service) u64 {
        return self.publicationFrontierObserved(null);
    }
    pub fn publicationFrontierObserved(self: *Service, observed: ?*render_observation.Frontier) u64 {
        self.publicationHook(.before_frontier, 0);
        self.offline(.publication_frontier, .before, 0, 0, 0);
        self.orderCheckpoint(.render, .publication_frontier, .before, 0, 0, null);
        const frontier = self.publication_head.load(.acquire);
        self.orderCheckpoint(.render, .publication_frontier, .after, 0, 0, frontier);
        self.offline(.publication_frontier, .after, 0, 0, frontier);
        self.publicationHook(.after_frontier, frontier);
        if (observed) |value| value.value = frontier;
        return frontier;
    }
    fn publicationHook(self: *Service, stage: PublicationStage, value: u64) void {
        if (@import("builtin").is_test) if (self.test_publication_hook) |hook_value| hook_value.call(hook_value.context, stage, value);
    }
    /// Actual bounded gate decision. Captured `frontier` makes publications
    /// arriving during claim/DSP invisible until a subsequent render gate.
    pub fn admitPublication(self: *Service, frontier: u64, gate: u64, frame: u64, gate_order: u32) Error!?trace.schema.Admission {
        return self.admitPublicationObserved(frontier, gate, frame, gate_order, null);
    }
    pub fn admitPublicationObserved(self: *Service, frontier: u64, gate: u64, frame: u64, gate_order: u32, observed: ?*render_observation.Attempt) Error!?trace.schema.Admission {
        if (observed) |value| value.* = .{ .frontier = frontier, .gate = gate, .frame = frame, .order = gate_order };
        errdefer |err| if (observed) |value| {
            value.result = .failed;
            value.error_code = @intFromError(err);
        };
        const read = self.publication_read.load(.monotonic);
        if (observed) |value| value.read = read;
        if (read >= frontier) {
            if (observed) |value| value.result = .empty;
            return null;
        }
        self.offline(.visibility_head, .before, 0, 0, 0);
        self.orderCheckpoint(.render, .visibility_head, .before, 0, 0, null);
        const head = self.publication_head.load(.acquire);
        self.orderCheckpoint(.render, .visibility_head, .after, 0, 0, head);
        self.offline(.visibility_head, .after, 0, 0, head);
        if (observed) |value| value.head = head;
        if (frontier > head) return error.InvalidState;
        const entry = &self.publications[@intCast(read % self.publications.len)];
        const d = entry.descriptor;
        if (observed) |value| {
            value.descriptor = d;
            value.content_hash = entry.hash;
        }
        const pcm = entry.ring;
        const generation = pcm.generation;
        if (observed) |value| value.generation = generation;
        if (generation != d.stream_generation) return error.ReplayMismatch;
        const visible_produced = pcm.visible_produced.load(.monotonic);
        if (observed) |value| value.visible_produced = visible_produced;
        if (visible_produced != d.prefix_start) return error.ReplayMismatch;
        self.offline(.visibility_produced, .before, d.stream_slot, d.stream_generation, 0);
        self.orderCheckpoint(.render, .visibility_produced, .before, d.stream_slot, d.stream_generation, null);
        const produced = pcm.produced.load(.acquire);
        self.orderCheckpoint(.render, .visibility_produced, .after, d.stream_slot, d.stream_generation, produced);
        self.offline(.visibility_produced, .after, d.stream_slot, d.stream_generation, produced);
        if (observed) |value| value.produced = produced;
        if (produced < d.prefix_end) return error.ReplayMismatch;
        self.offline(.visibility_stopped, .before, d.stream_slot, d.stream_generation, 0);
        self.orderCheckpoint(.render, .visibility_stopped, .before, d.stream_slot, d.stream_generation, null);
        const stopped = pcm.stopped.load(.acquire);
        self.orderCheckpoint(.render, .visibility_stopped, .after, d.stream_slot, d.stream_generation, @intFromBool(stopped));
        self.offline(.visibility_stopped, .after, d.stream_slot, d.stream_generation, @intFromBool(stopped));
        if (observed) |value| value.stopped = stopped;
        const disposition: trace.schema.AdmissionDisposition = if (stopped) .rejected else .admitted;
        if (observed) |value| value.disposition = disposition;
        // Traversal advances even on explicit stopped rejection; peek/ready
        // remain stopped. Later contiguous rejected prefixes still retire.
        pcm.visible_produced.store(d.prefix_end, .release);
        if (observed) |value| value.effects.visible_advanced = true;
        const admission: trace.schema.Admission = .{ .batch_id = d.batch_id, .content_hash = entry.hash, .kind = .stream_visibility, .gate = gate, .frame = frame, .commit_horizon = frame, .gate_order = gate_order, .disposition = disposition };
        entry.admission = admission;
        self.offline(.visibility_release, .before, 0, 0, read + 1);
        self.orderCheckpoint(.render, .visibility_release, .before, 0, 0, read + 1);
        self.publication_read.store(read + 1, .release);
        self.orderCheckpoint(.render, .visibility_release, .after, 0, 0, read + 1);
        self.offline(.visibility_release, .after, 0, 0, read + 1);
        if (observed) |value| {
            value.effects.read_advanced = true;
            value.result = if (stopped) .rejected else .admitted;
        }
        // Control may already acknowledge and reuse the entry after release.
        // Return the owned receipt, never reread the now-published ledger slot.
        return admission;
    }
    /// Control replay preparation uses actual reconstructed descriptor bytes.
    /// Only gate facts enter the calendar; expected outcomes are never read.
    pub fn prepareVisibilityReplay(self: *Service, input: trace.Input) Error!void {
        if (!self.replay_mode or input.payload != .admission or input.payload.admission.kind != .stream_visibility) return error.ReplayMismatch;
        input.validate() catch return error.ReplayMismatch;
        const admission = input.payload.admission;
        trace.replay.verifyBatch(admission, try self.computedBatch(admission.batch_id, .stream_visibility)) catch return error.ReplayMismatch;
        if (admission.gate <= self.last_render_gate.load(.acquire) or admission.frame < self.last_render_frame.load(.acquire) or input.position.accepted_control_frame < admission.frame) return error.ReplayMismatch;
        var cursor = self.publication_read.load(.acquire);
        const head = self.publication_head.load(.acquire);
        while (cursor < head) : (cursor += 1) {
            const entry = &self.publications[@intCast(cursor % self.publications.len)];
            if (entry.descriptor.batch_id != admission.batch_id) continue;
            if (entry.replay_prepared.load(.acquire)) return error.ReplayMismatch;
            entry.replay_release = .{ .position = input.position, .batch_id = admission.batch_id, .kind = admission.kind, .gate = admission.gate, .frame = admission.frame, .gate_order = admission.gate_order };
            entry.replay_prepared.store(true, .release);
            return;
        }
        return error.ResourceNotPrepared;
    }
    /// Match only currently reconstructed publications against future gate
    /// facts. Missing calendars fail before Render; no PCM or outcome is added.
    pub fn prepareAvailableVisibilityReplay(self: *Service, inputs: []const trace.Input) Error!void {
        if (!self.replay_mode) return error.InvalidState;
        var cursor = self.publication_read.load(.acquire);
        const head = self.publication_head.load(.acquire);
        while (cursor < head) : (cursor += 1) {
            const entry = &self.publications[@intCast(cursor % self.publications.len)];
            if (entry.replay_prepared.load(.acquire)) continue;
            const expected = for (inputs) |input| {
                if (input.payload == .admission and input.payload.admission.kind == .stream_visibility and input.payload.admission.batch_id == entry.descriptor.batch_id) break input;
            } else return error.IncompleteTrace;
            try self.prepareVisibilityReplay(expected);
        }
    }
    /// Offline/control-only bounded-memory lookahead. The independent cursor
    /// returns copied IndexedInput values and may perform I/O; never call this
    /// from Renderer. Publications and visibility receipts share strict FIFO.
    /// Already prepared entries consume no additional expected fact.
    pub fn prepareAvailableVisibilityReplayCursor(self: *Service, expected_visibility: anytype) !void {
        if (!self.replay_mode) return error.InvalidState;
        var cursor = self.publication_read.load(.acquire);
        const head = self.publication_head.load(.acquire);
        while (cursor < head) : (cursor += 1) {
            const entry = &self.publications[@intCast(cursor % self.publications.len)];
            if (entry.replay_prepared.load(.acquire)) continue;
            const row = (try expected_visibility.next()) orelse return error.IncompleteTrace;
            const input = row.value;
            if (input.payload != .admission or input.payload.admission.kind != .stream_visibility or
                input.payload.admission.batch_id != entry.descriptor.batch_id) return error.ReplayMismatch;
            // Uses actual Worker descriptor/hash and copies only external gate
            // facts. The recorded disposition never enters the audio decision.
            try self.prepareVisibilityReplay(input);
        }
    }
    /// Renderer executes a prepared external gate fact at the actual gate, not
    /// at the possibly much later Control receipt-drain position.
    pub fn admitReplayPublication(self: *Service, gate: u64, frame: u64, gate_order: u32) Error!?trace.schema.Admission {
        const read = self.publication_read.load(.monotonic);
        if (read == self.publication_head.load(.acquire)) return null;
        const entry = &self.publications[@intCast(read % self.publications.len)];
        if (!entry.replay_prepared.load(.acquire)) return null;
        const release = entry.replay_release;
        if (release.gate > gate) return null;
        if (release.gate != gate or release.frame != frame or release.gate_order != gate_order) return error.ReplayMismatch;
        return self.admitPublication(read + 1, gate, frame, gate_order);
    }
    pub fn observedVisibility(self: *Service, release: trace.replay.GateRelease) Error!trace.replay.GateObservation {
        const tail = self.publication_tail.load(.monotonic);
        if (tail == self.publication_read.load(.acquire)) return error.IncompleteTrace;
        const entry = &self.publications[@intCast(tail % self.publications.len)];
        const actual = entry.admission;
        if (!entry.replay_prepared.load(.acquire) or !std.meta.eql(release, entry.replay_release) or actual.batch_id != release.batch_id or actual.gate != release.gate or actual.frame != release.frame or actual.gate_order != release.gate_order) return error.ReplayMismatch;
        return .{ .commit_horizon = actual.commit_horizon, .disposition = actual.disposition };
    }
    /// Control-only proof from receipts already acquired by pollVisibility.
    /// Never reads a Render-owned counter or manufactures readiness.
    pub fn acknowledgedVisiblePrefix(self: *Service, handle: Handle) Error!u64 {
        const slot = try self.get(handle);
        if (self.acknowledged_visibility_invalid) return error.InvalidState;
        return slot.acknowledged_visible_prefix;
    }
    pub const VisibilityReceiptTests = if (@import("builtin").is_test) struct {
        // Isolated malformed-receipt negatives only; never a Live source.
        pub fn acknowledge(service: *Service, entry: *const visibility.Entry) bool {
            return service.noteAcknowledgedVisibility(entry);
        }
    } else struct {};
    fn noteAcknowledgedVisibility(self: *Service, entry: *const visibility.Entry) bool {
        const d = entry.descriptor;
        if (d.stream_slot >= self.slots.len) {
            self.acknowledged_visibility_invalid = true;
            return false;
        }
        const slot = &self.slots[d.stream_slot];
        if (!slot.occupied or slot.generation != d.stream_generation or entry.ring != &slot.pcm_ring) {
            self.acknowledged_visibility_invalid = true;
            return false;
        }
        if (entry.admission.disposition != .admitted) return true;
        if (entry.admission.kind != .stream_visibility or entry.admission.batch_id != d.batch_id or
            !std.mem.eql(u8, &entry.admission.content_hash, &entry.hash) or
            d.prefix_start != slot.acknowledged_visible_prefix or d.prefix_end <= d.prefix_start or
            d.prefix_end - d.prefix_start > self.profile.decode_chunk_frames)
        {
            self.acknowledged_visibility_invalid = true;
            return true; // Identity is valid; original ledger custody still retires.
        }
        slot.acknowledged_visible_prefix = d.prefix_end;
        return true;
    }
    /// Control receipt acknowledgement releases the ledger's stream lease.
    /// Recorder loss is handled by the caller after this live decision.
    pub fn pollVisibility(self: *Service) ?trace.schema.Admission {
        return self.pollVisibilityObserved(null);
    }
    pub fn pollVisibilityObserved(self: *Service, observed: ?*observation.Visibility) ?trace.schema.Admission {
        if (observed) |value| value.* = .{};
        self.acceptanceHook(.before_visibility_poll, 0);
        defer self.acceptanceHook(.after_visibility_poll, 0);
        const tail = self.publication_tail.load(.monotonic);
        self.offline(.visibility_poll, .before, 0, 0, 0);
        self.orderCheckpoint(.control, .visibility_poll, .before, 0, 0, null);
        const read = self.publication_read.load(.acquire);
        self.orderCheckpoint(.control, .visibility_poll, .after, 0, 0, read);
        self.offline(.visibility_poll, .after, 0, 0, read);
        if (observed) |value| {
            value.tail = tail;
            value.read = read;
        }
        if (tail == read) return null;
        const entry = &self.publications[@intCast(tail % self.publications.len)];
        // publication_read acquire above follows Render's actual visible store.
        // Derive before returning the ledger cell to its producer. A corrupt
        // generation must never grant credit to a reused stream slot.
        if (self.noteAcknowledgedVisibility(entry))
            self.slots[entry.descriptor.stream_slot].visibility_refs -= 1;
        const result = entry.admission;
        if (observed) |value| {
            value.admission = result;
            value.descriptor = entry.descriptor;
        }
        self.offline(.visibility_ack, .before, 0, 0, tail + 1);
        self.orderCheckpoint(.control, .visibility_ack, .before, 0, 0, tail + 1);
        self.publication_tail.store(tail + 1, .release);
        self.orderCheckpoint(.control, .visibility_ack, .after, 0, 0, tail + 1);
        self.offline(.visibility_ack, .after, 0, 0, tail + 1);
        if (observed) |value| value.acknowledged = true;
        return result;
    }
    /// Explicit host-quiesced disposal for cancelled plans never rendered.
    /// Cannot free a PCM ring still held by a prepared/rendering group.
    pub fn discardVisibilityQuiescent(self: *Service) Error!void {
        for (self.slots) |*slot| if (slot.occupied and slot.pcm_ring.references.load(.acquire) != 0) return error.DrainPending;
        const head = self.publication_head.load(.acquire);
        var tail = self.publication_tail.load(.monotonic);
        if (tail != head) self.visibility_discarded = true;
        while (tail < head) : (tail += 1) self.slots[self.publications[@intCast(tail % self.publications.len)].descriptor.stream_slot].visibility_refs -= 1;
        self.publication_read.store(head, .release);
        self.publication_tail.store(head, .release);
    }
    pub fn computedBatch(self: *Service, id: u64, kind: trace.schema.BatchKind) Error!trace.replay.ComputedBatch {
        if (kind != .stream_visibility) return error.ReplayMismatch;
        var cursor = self.publication_tail.load(.monotonic);
        const head = self.publication_head.load(.acquire);
        while (cursor < head) : (cursor += 1) {
            const entry = &self.publications[@intCast(cursor % self.publications.len)];
            if (entry.descriptor.batch_id == id) return .{ .batch_id = id, .kind = kind, .content_hash = entry.hash, .canonical_bytes = &entry.canonical };
        }
        return error.ResourceNotPrepared;
    }
    pub fn releaseBatch(_: *Service, _: trace.replay.GateRelease) error{UnsupportedOperation}!trace.replay.GateObservation {
        return error.UnsupportedOperation; // RuntimeRenderer owns the actual gate.
    }
    pub fn verifyReplayComplete(self: *Service) Error!void {
        if (self.runtime_attached and self.publication_tail.load(.acquire) != self.publication_head.load(.acquire)) return error.IncompleteTrace;
        for (self.jobs) |*job| if (job.state.load(.acquire) != .free) return error.IncompleteTrace;
    }
};
/// Exhaustive namespace conversion only. Ring aliases are emitted by Ring's
/// direct bindings; forwarding ringPoint here would duplicate their records.
/// render_frame is dormant in the legacy source enum and has no fake emitter.
fn orderSite(site: OfflineSite) order.Site {
    return switch (site) {
        .availability_readiness_sequence_before => .service_availability_readiness_sequence_before,
        .availability_readiness_frame => .service_availability_readiness_frame,
        .availability_readiness_control_consumed => .service_availability_readiness_control_consumed,
        .availability_readiness_produced => .service_availability_readiness_produced,
        .availability_readiness_sequence_after => .service_availability_readiness_sequence_after,
        .availability_acceptance_sequence_before => .service_availability_acceptance_sequence_before,
        .availability_acceptance_frame => .service_availability_acceptance_frame,
        .availability_acceptance_control_consumed => .service_availability_acceptance_control_consumed,
        .availability_acceptance_produced => .service_availability_acceptance_produced,
        .availability_acceptance_sequence_after => .service_availability_acceptance_sequence_after,
        .stream_ring_consumed => .ring_consumed,
        .stream_ring_produced => .ring_produced,
        .stream_produced => .produced_release,
        .stream_observation_frame => .service_stream_observation_frame,
        .worker_claim => .service_worker_claim,
        .worker_scan => .service_worker_scan,
        .worker_running => .service_worker_running,
        .worker_completed => .service_worker_completed,
        .worker_idle => .service_worker_idle,
        .job_queued => .service_job_queued,
        .job_free => .service_job_free,
        .worker_cancel => .service_worker_cancel,
        .worker_stopped => .service_worker_stopped,
        .acceptance_scan => .service_acceptance_scan,
        .publication_release => .service_publication_release,
        .publication_frontier => .service_publication_frontier,
        .visibility_head => .service_visibility_head,
        .visibility_produced => .service_visibility_produced,
        .visibility_stopped => .service_visibility_stopped,
        .visibility_release => .service_visibility_release,
        .visibility_poll => .service_visibility_poll,
        .visibility_ack => .service_visibility_ack,
        .initial_entry_consumed => .service_initial_entry_consumed,
        .initial_entry_cancel => .service_initial_entry_cancel,
        .readiness_stopped_first => .service_readiness_stopped_first,
        .readiness_stopped_second => .service_readiness_stopped_second,
        .readiness_sequence => .service_readiness_sequence,
        .readiness_frame => .service_readiness_frame,
        .readiness_consumed => .service_readiness_consumed,
        .readiness_produced => .service_readiness_produced,
        .readiness_job => .service_readiness_job,
        .readiness_final_sequence => .service_readiness_final_sequence,
        .render_sequence_odd => .service_render_sequence_odd,
        .render_consumed => .service_render_consumed,
        .render_frame => .service_render_frame,
        .render_sequence_even => .service_render_sequence_even,
        .stream_close_claim => .service_stream_close_claim,
        .stream_close_pending => .service_stream_close_pending,
        .stream_close_idle => .service_stream_close_idle,
        .service_prepare_claim => .service_service_prepare_claim,
        .service_prepare_idle => .service_service_prepare_idle,
        .stream_consumed_release => .consumed_release,
        .stream_close_visibility => .service_stream_close_visibility,
        .stream_close_stopped => .service_stream_close_stopped,
        .worker_release_progress => .service_worker_release_progress,
        .control_release_progress => .service_control_release_progress,
        .slot_guard_open => .service_slot_guard_open,
        .slot_guard_close => .service_slot_guard_close,
        .slot_guard_render_claim => .service_slot_guard_render_claim,
        .slot_guard_render_release => .service_slot_guard_render_release,
    };
}
/// Hash canonical little-endian float bits, independent of host endian.
pub fn hashPcm(pcm: []const f32) [32]u8 {
    var state = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [4]u8 = undefined;
    for (pcm) |sample| {
        std.mem.writeInt(u32, &bytes, @bitCast(sample), .little);
        state.update(&bytes);
    }
    var result: [32]u8 = undefined;
    state.final(&result);
    return result;
}
