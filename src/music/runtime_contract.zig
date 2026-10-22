//! Versioned public values for the implemented lifecycle. Status/receipts are
//! pointer-free; construction binding slices are copied before Worker publication.
//! Streaming, graph bootstrap and save/restore are separate gates.
const ids = @import("ids.zig");
const contract = @import("contract.zig");
pub const version: u16 = 1;
/// Partial production fill profile. No graph/controller composition, tails,
/// overlaps or nonzero entries are admitted. Streaming uses its explicit mode.
/// Resume after an executed fill replans its suffix; the resume request terminates at
/// the actual resume receipt. Automatic suffix execution has no public ticket.
pub const resident_fill_hard_cut_v1 = .{
    .max_fill_steps = @as(u8, 2),
    .direct_resident_only = true,
    .phase_receipt_slots = @as(u16, 256),
};
pub const CapacityV1 = struct {
    request_slots: u32 = 4096,
    reserved_request_slots: u32 = 128,
    receipt_slots: u32 = 16384,
    load_slots: u32 = 1,
    snapshot_slots: u32 = 3,
    /// One pre-reserved return cell per actual single-use borrowed PCM lease.
    borrowed_sound_lease_slots: u32 = 1024,
    trace_input_slots: u32 = 4096,
    trace_event_slots: u32 = 4096,
    /// Retained compatibility capacity for ordinary plus interruption slots.
    /// The independent subordinate layer lane may coexist with both; every
    /// owned ticket retains its own two receipt credits until its terminal.
    max_in_flight_requests: u32 = 2,
    music_request_drain: u32 = 512,
    max_bank_bytes: u64 = 256 * 1024 * 1024,
    pub fn validate(self: CapacityV1) !void {
        const expected: CapacityV1 = .{};
        inline for (@import("std").meta.fields(CapacityV1)) |field| {
            if (@field(self, field.name) != @field(expected, field.name)) return error.UnsupportedCapacity;
        }
    }
};
/// Explicit partial support; this is not complete capability13 admission.
pub const PolicySupportV1 = enum(u8) { disabled = 0, duck_v1 = 1, resident_stinger_v1 = 2, _ };
pub const DuckLifetimeV1 = struct {
    begin_ticket: RequestTicketV1,
    external_id: u64,
    incarnation: u64,
    begin_phase: ?contract.PhaseReceipt = null,
    terminal: ?struct {
        reason: enum { expired, ended, graph_retired, begin_rejected },
        frame: u64,
        release_frontier: u64,
    } = null,
    preparation_failure: ?FailureV1 = null,
    physical_drained: bool = false,
};
/// One trigger's action phase and later independently drained group lifetime.
pub const StingerLifetimeV1 = struct {
    trigger_ticket: RequestTicketV1,
    stinger_id: u64,
    incarnation: u64,
    accepted: @import("sme-trace").schema.Position,
    last_retry: ?@import("sme-trace").schema.Position = null,
    start_phase: ?contract.PhaseReceipt = null,
    terminal: ?struct {
        reason: enum { natural, stopped, underrun, stolen, shutdown },
        boundary_frame: u64,
        last_sample_frame: ?u64,
    } = null,
    preparation_failure: ?FailureV1 = null,
    policy_reason: ?enum { deadline, repeat_window, polyphony, platform_limit, media_unready, no_replaceable_victim } = null,
    physical_drained: bool = false,
};
/// Explicit bounded save-state semantics. The wire envelope stays at v1.
pub const SnapshotProfileV1 = enum(u16) { resident_v1 = 1, stream_direct_v1 = 2, stream_fill_v1 = 3, _ };
/// Full-span admission is unchanged by default. Rolling mode proves only a
/// genuine high-watermark entry window; later supply can fail or underrun.
pub const StreamedFillModeV1 = enum(u8) { full_span = 0, rolling_high_watermark = 1, _ };
/// Explicit boundary for MusicStopMode.next_boundary. The existing stop ramp
/// begins at this beat/bar; this is not a promise of silence at that frame.
pub const BoundaryStopV1 = enum(u8) { next_beat = 1, next_bar = 2, _ };
/// Hard-cut tool audition of the current looping streamed segment. Logical
/// history never rewinds; forward audition can advance hold/cooldown bars.
pub const PreviewSeekModeV1 = enum(u8) { stream_same_segment_v1 = 1, _ };
pub const ConfigV1 = struct {
    version: u16 = version,
    context: u64 = 1,
    kind: contract.MusicContextKind = .shipping_game,
    seed: u64 = 1,
    quantum_frames: u32 = 256,
    capacity: CapacityV1 = .{},
    policy_support: PolicySupportV1 = .disabled,
    snapshot_profile: SnapshotProfileV1 = .resident_v1,
    /// Explicit copied main-group linear gain bindings; no complete layer capability.
    layer_gain: @import("runtime_layer_contract.zig").ConfigV1 = .{},
    /// Explicit copied host bindings for bounded DIRECT linear/equal-power overlap.
    /// Empty keeps nonzero fades unsupported; no bank-authored curve is inferred.
    crossfade: @import("sme-runtime-crossfade-contract").ConfigV1 = .{},
    /// Explicit fixed source-generation envelope allocation. Untracked preserves
    /// existing construction/asset behavior and cannot certify reload inventory.
    sfx_generation_custody: enum { untracked, bounded_v1 } = .untracked,
    /// Explicit host driver; choosing integrated prevents split pumping.
    control_driver: enum { resident_split, integrated } = .resident_split,
    /// Optional real context allocation, attached only during construction.
    /// The default preserves initial-bank-only allocation behavior. The fixed
    /// release profile is shared across generations and is charged only once.
    streaming_reservation: enum { initial_bank_only, release_profile } = .initial_bank_only,
    /// Opt-in bounded rolling supply for zero-entry hard-cut streamed fills.
    /// Requires the integrated Worker/Control/Render owner and does not expand
    /// save-state or general fill composition support.
    streamed_fill_mode: StreamedFillModeV1 = .full_span,
    /// Copied for this owner's lifetime. Null keeps next_boundary unsupported.
    /// The narrow integrated profile supports one stable looping source only;
    /// no rolling-fill, gain, crossfade, policy, recording or snapshot composition.
    boundary_stop: ?BoundaryStopV1 = null,
    /// Fixed lifetime opt-in. Null retains unsupported seek_preview behavior.
    /// Integrated authoring/offline/debug only; shipping rejects at submission.
    preview_seek: ?PreviewSeekModeV1 = null,
    pub fn validate(self: ConfigV1) !void {
        if (self.version != version) return error.UnsupportedVersion;
        if (self.preview_seek) |mode| {
            if (mode != .stream_same_segment_v1) return error.UnsupportedCapability;
            if (self.control_driver != .integrated) return error.InvalidMode;
        }
        if (self.context == 0 or self.quantum_frames == 0) return error.InvalidState;
        if (self.boundary_stop) |boundary| {
            switch (boundary) {
                .next_beat, .next_bar => {},
                _ => return error.UnsupportedCapability,
            }
            if (self.control_driver != .integrated) return error.InvalidMode;
            if (self.policy_support != .disabled or self.layer_gain.bindings.len != 0 or
                self.crossfade.bindings.len != 0 or self.snapshot_profile != .resident_v1 or
                self.streamed_fill_mode != .full_span) return error.UnsupportedCapability;
        }
        if (self.streaming_reservation == .release_profile and self.control_driver != .integrated) return error.InvalidMode;
        switch (self.streamed_fill_mode) {
            .full_span => {},
            .rolling_high_watermark => if (self.control_driver != .integrated) return error.InvalidMode,
            _ => return error.UnsupportedCapability,
        }
        switch (self.snapshot_profile) {
            .resident_v1 => {},
            .stream_direct_v1, .stream_fill_v1 => if (self.control_driver != .integrated) return error.InvalidMode,
            _ => return error.UnsupportedCapability,
        }
        try self.capacity.validate();
        try self.layer_gain.validate();
        try self.crossfade.validate();
        if (self.crossfade.bindings.len != 0) {
            if (self.control_driver != .integrated or self.streaming_reservation != .release_profile or
                self.policy_support != .disabled or self.snapshot_profile != .resident_v1) return error.UnsupportedCapability;
            if (self.layer_gain.bindings.len != 0) {
                if (self.layer_gain.parameter_sampling != .accepted_only) return error.UnsupportedCapability;
                for (self.layer_gain.bindings) |binding| {
                    inline for (.{ binding.ramps.attack, binding.ramps.release }) |duration| switch (duration) {
                        .frames => {},
                        .quarter_beats => return error.UnsupportedCapability,
                    };
                }
            }
        }
        if (self.layer_gain.bindings.len != 0 and self.control_driver != .integrated) return error.UnsupportedCapability;
        if (self.sfx_generation_custody == .bounded_v1 and self.control_driver != .integrated) return error.UnsupportedCapability;
        switch (self.policy_support) {
            .disabled => {},
            .duck_v1, .resident_stinger_v1 => if (self.control_driver != .integrated) return error.UnsupportedCapability,
            _ => return error.UnsupportedCapability,
        }
    }
};
pub const LoadProgressV1 = struct {
    version: u16 = version,
    stage: enum { queued, worker_preparation, control_admission, bootstrap, ready, failed, retiring },
    render_permitted: bool,
};
pub const LoadTicketV1 = struct { context: u64, sequence: u64 };
/// The full generation and context travel with the slot incarnation. No u64
/// asset generation is truncated into the u32 public handle incarnation.
pub const BankRefV1 = struct { context: u64, handle: ids.MusicBankHandle, asset_generation: u64 };
pub const RequestTicketV1 = struct { context: u64, request_id: u64, bank: BankRefV1 };
pub const FailureV1 = enum(u8) {
    invalid_bank,
    unsupported_capability,
    invalid_state,
    invalid_order,
    wrong_context,
    stale_bank,
    out_of_memory,
    resource_limit,
    cancelled,
    runtime_stopped,
    command_queue_full,
    transition_not_found,
    voice_budget_exceeded,
    internal_failure,
    request_in_progress,
    source_unavailable,
    source_io,
    source_close,
    stream_underrun,
};
pub const LoadStatusV1 = union(enum) {
    pending,
    ready: struct { bank: BankRefV1, content_hash: [32]u8 },
    failed: FailureV1,
};
pub const ReceiptV1 = struct {
    version: u16 = version,
    ticket: RequestTicketV1,
    event: union(enum) {
        accepted: struct { control_tick: u64, render_frame: u64 },
        terminal: union(enum) {
            executed: contract.PhaseReceipt,
            unchanged,
            rejected: FailureV1,
            /// The cancellation receipt refers to the abandoned original phase.
            /// No active group existed, so no pause/stop execution is invented.
            cancelled_before_entry: contract.PhaseReceipt,
            /// Logical Control application, never a Render execution or phase.
            /// Appended to preserve the previous terminal tag ordinals.
            control_applied: struct { control_tick: u64, render_frame: u64, input_order: u64 },
        },
    },
};
/// Pointer-free playback lifetime evidence. This never replaces a request's
/// already published terminal. Optional source details can be lost independently
/// of the durable Render group terminal used for retirement.
pub const StreamFaultV1 = struct {
    group_index: u32,
    group_incarnation: u64,
    asset_generation: u64,
    segment: ids.SegmentId,
    boundary_frame: u64,
    last_sample_frame: ?u64,
    cursor: ?u64 = null,
    loop_epoch: ?u64 = null,
    layer: ?u16 = null,
};
/// Durable Render replacement evidence, separate from request/phase terminals.
/// The original Director commitment remains unchanged by an emergency leaf.
pub const SourceSwitchV1 = struct {
    group_index: u32,
    group_incarnation: u64,
    asset_generation: u64,
    original_segment: ids.SegmentId,
    fallback_segment: ids.SegmentId,
    frame: u64,
    cursor: u64,
    loop_epoch: u64,
    layer: u16,
    source_incarnation: u64,
};
/// Copied retained prefixes. These ordinals count successfully retained records,
/// not lost offers. Drop counters are lifetime-sticky and never reset by consumption.
pub const RetainedTraceBatchV1 = struct {
    input_begin: u64,
    input_count: usize,
    schedule_begin: u64,
    schedule_count: usize,
    inputs_dropped: u64,
    schedule_dropped: u64,
    counter_exhausted: bool,
};

/// Lifetime history requirement, not a certificate of replay completeness.
/// existing_contract leaves all original completeness/unsupported checks in
/// force. Live chronology requires a separate protocol even for an empty drain.
pub const HistoryRequirementsV1 = struct {
    replay_contract: enum { existing_contract, live_chronology_v1 },
    /// No qualified Live sidecar/session is integrated in this runtime yet.
    /// Do not infer capture success from diagnostic retention or a sink hook.
    live_capture: enum { not_applicable, unavailable },
};
/// Prefix and provenance sampled under the SAME owner Control guard. The
/// original RetainedTraceBatchV1 layout and diagnostic drain stay unchanged.
pub const RetainedTraceWithProvenanceV1 = struct {
    batch: RetainedTraceBatchV1,
    requirements: HistoryRequirementsV1,
};

pub const StatusV1 = struct {
    version: u16 = version,
    context: u64,
    kind: contract.MusicContextKind,
    state: contract.MusicRuntimeState,
    bank: ?BankRefV1,
    bank_content_hash: [32]u8,
    committed_state: ids.MusicStateId,
    committed_segment: ids.SegmentId,
    render_frame: u64,
    transport_epoch: u64,
    pending: bool,
    /// Capture/restore/audition ownership, including audition window retirement.
    /// Logical status may lag Render until its real install receipt is collected.
    resident_transaction_pending: bool = false,
    outstanding_sample_leases: u64,
    observation_sequence: u64,
    /// Conservative legacy recording/observation conjunction. Explicit trace
    /// consumption or unsupported replay never becomes a complete recording.
    complete: bool,
    /// No actual/unknown diagnostic failure; does not claim replay support.
    diagnostics_complete: bool = false,
    replay_unsupported: bool = false,
    trace_inputs_dropped: u64 = 0,
    trace_schedule_dropped: u64 = 0,
    trace_counter_exhausted: bool = false,
    dropped_observations: u64,
    /// Latest observed main-group underrun, retained across stop/unload.
    stream_fault: ?StreamFaultV1 = null,
    stream_fault_count: u64 = 0,
    stream_fault_details_dropped: u64 = 0,
    stream_fault_group_retirement_pending: bool = false,
    /// Current main playback, not a fabricated Director commitment.
    degraded: bool = false,
    rendering_segment: ids.SegmentId = @enumFromInt(0),
    source_incarnation: u64 = 0,
    /// Latest physical switch boundary, independent of collection order.
    /// Equal-frame ties use group incarnation then index. Persists without a bank lease.
    source_switch: ?SourceSwitchV1 = null,
    source_switch_count: u64 = 0,
    source_switch_retirement_pending: bool = false,
};
/// Control-owned post-Stop progress only. Does not sample Worker ownership,
/// source retirement, Render pins, or external producer/borrower counters.
pub const StopProgressV1 = struct {
    /// Same last-published state source as snapshotV1, not current mutable state.
    state: contract.MusicRuntimeState,
    active_music_groups: u32,
    retired_music_groups: u32,
    live_instances: u32,
};
pub const DrainStatusV1 = struct {
    layer_controller_lifetimes: u32 = 0,
    version: u16 = version,
    shutting_down: bool,
    unloading: bool,
    queued_requests: u32,
    active_producers: u32,
    in_flight_requests: u32,
    load_transactions: u32,
    worker_active: bool,
    event_instances: u32 = 0,
    event_terminal_credits: u32 = 0,
    prepared_stream_windows: u32 = 0,
    source_continuity_descriptors: u32 = 0,
    provider_sources: u32 = 0,
    source_close_pending: bool = false,
    policy_request_slots: u32 = 0,
    policy_occupied_slots: u32 = 0,
    policy_retained_results: u32 = 0,
    policy_physical_lifetimes: u32 = 0,
    policy_graph_retained: bool = false,
    pending_plans: u32,
    active_music_groups: u32,
    retired_music_groups: u32,
    sample_leases: u64,
    /// Explicit borrow credits, including actual releases awaiting Control.
    borrowed_sound_leases: u32 = 0,
    borrowed_sound_returns_pending: u32 = 0,
    /// Source-owned pre-funded envelopes, including unused reservations. These
    /// stay nonzero until closed producer acquisition and all actual roles drain.
    play_envelope_reservations: u64 = 0,
    play_active_producers: u64 = 0,
    live_instances: u32,
    snapshot_readers: u32,
    control_drained: bool,
    last_error: ?FailureV1,
    /// Owned Control observation, including terminal results awaiting ack.
    /// This field is not part of the versioned debug or trace wire formats.
    resident_state_transactions: u32 = 0,
    /// Owned reload result slot; separate from load/preparation and old history.
    resident_reload_transactions: u32 = 0,
    /// Includes terminal audition cleanup until transient windows really drain.
    preview_seek_transactions: u32 = 0,
};

/// Retained allocations of this owner only. Ingress/status/trace are labeled
/// subsets of owner_storage_bytes, not extra allocations. Worker loader/codec
/// scratch is not inspected while it is being mutated. ControlRuntime, Renderer
/// and backend storage are host-owned and deliberately outside this ledger.
pub const MemoryUsageV1 = struct {
    version: u16 = version,
    owner_storage_bytes: u64 = 0,
    /// Heap-owned logical baseline, staging and exact snapshot; owner subset.
    resident_state_storage_bytes: u64 = 0,
    /// Subset of owner_storage_bytes; only an accepted audition allocates it.
    preview_seek_storage_bytes: u64 = 0,
    /// Host lower transaction slot, excluded from observedRetainedBytes.
    resident_transaction_host_bytes: u64 = 0,
    /// Subset of owner_storage_bytes; allocated only for explicit duck_v1.
    policy_owner_storage_bytes: u64 = 0,
    /// Loaded adapter allocation belongs to the generation. The independent
    /// Control Manager copy remains outside this owner's retained byte total.
    loaded_graph_storage_bytes: u64 = 0,
    ingress_receipt_storage_bytes: u64 = 0,
    /// Subset of owner_storage_bytes: primary, pending and interrupt identities.
    request_ownership_storage_bytes: u64 = 0,
    /// Host ControlRuntime subset, outside observedRetainedBytes() owner sum.
    control_tick_storage_bytes: u64 = 0,
    snapshot_storage_bytes: u64 = 0,
    /// Subset of owner_storage_bytes, not an additional allocation.
    observer_attachment_bytes: u64 = 0,
    /// Host-owned allocation, excluded from observedRetainedBytes().
    observer_host_storage_bytes: u64 = 0,
    trace_storage_bytes: u64 = 0,
    compiled_input_bytes: u64 = 0,
    generation_storage_bytes: u64 = 0,
    bank_metadata_bytes: u64 = 0,
    encoded_blob_bytes: u64 = 0,
    resident_pcm_bytes: u64 = 0,
    source_storage_bytes: u64 = 0,
    stream_service_bytes: u64 = 0,
    stream_native_bytes: u64 = 0,
    /// Attached caller-owned adapter allocation, outside the owner total below.
    event_adapter_bytes: u64 = 0,
    control_state_bytes: u64 = 0,
    source_continuity_bytes: u64 = 0, // Actual heap manager ABI.
    source_binding_storage_bytes: u64 = 0, // Fixed Control subset outside owner total.
    group_terminal_storage_bytes: u64 = 0, // Fixed Control subset, not an extra owner allocation.
    group_terminal_render_storage_bytes: u64 = 0, // Fixed Renderer subset, outside owner sum.
    source_binding_render_bytes: u64 = 0, // Borrowed current-source pointers in host Mixer.
    /// Separate fixed heap anchor, counted once through the final actual return.
    borrowed_sound_storage_bytes: u64 = 0,
    /// Queued/preparing/retiring Worker allocations may remain unobserved.
    /// A byte sample is not a reservation or a linearizable total.
    worker_allocations_unobserved: bool = false,
    pub fn observedRetainedBytes(self: MemoryUsageV1) u64 {
        return self.owner_storage_bytes + self.compiled_input_bytes + self.generation_storage_bytes + self.bank_metadata_bytes + self.encoded_blob_bytes + self.resident_pcm_bytes + self.control_state_bytes + self.source_storage_bytes + self.stream_service_bytes + self.stream_native_bytes + self.source_continuity_bytes + self.borrowed_sound_storage_bytes + self.loaded_graph_storage_bytes;
    }
};

test "stream fill snapshot semantics require explicit integrated construction" {
    const t = @import("std").testing;
    try t.expectEqual(@as(u16, 1), @intFromEnum(SnapshotProfileV1.resident_v1));
    try t.expectEqual(@as(u16, 2), @intFromEnum(SnapshotProfileV1.stream_direct_v1));
    try t.expectEqual(@as(u16, 3), @intFromEnum(SnapshotProfileV1.stream_fill_v1));
    try t.expectError(error.InvalidMode, ConfigV1.validate(.{ .snapshot_profile = .stream_fill_v1 }));
    try ConfigV1.validate(.{ .snapshot_profile = .stream_fill_v1, .control_driver = .integrated });
    try t.expectError(error.UnsupportedCapability, ConfigV1.validate(.{ .snapshot_profile = @enumFromInt(4), .control_driver = .integrated }));
}

test "preview seek requires an explicit integrated construction" {
    const t = @import("std").testing;
    try t.expectEqual(@as(?PreviewSeekModeV1, null), (ConfigV1{}).preview_seek);
    try t.expectError(error.InvalidMode, ConfigV1.validate(.{ .preview_seek = .stream_same_segment_v1 }));
    try ConfigV1.validate(.{ .control_driver = .integrated, .preview_seek = .stream_same_segment_v1 });
    try t.expectError(error.UnsupportedCapability, ConfigV1.validate(.{ .control_driver = .integrated, .preview_seek = @enumFromInt(2) }));
}
