//! The sole public SME façade. Only implemented contracts/components are exported.
/// TASK026 resident slice; TASK014 extends this same owner to full v1.
pub const capabilities = .{ .value_contract = true, .runtime = true, .resident_runtime = true, .full_runtime = false, .streaming_runtime = false, .fill_runtime = false, .resident_fill_hard_cut_v1 = true, .save_restore = false, .resident_lifecycle_v1 = true, .integrated_tick = true };
pub const PublicReplayV1 = @import("public_replay.zig");
/// Isolated transport only; framing validity does not certify replay admission.
pub const LiveSemanticFormat = @import("live_semantic_format.zig");
pub const ChunkRecordingV1 = trace.chunk_recording;
pub const RuntimeObserverV1 = @import("runtime_observer.zig");
pub const DeviceRecoveryV1 = @import("device_recovery.zig");
pub const RuntimeDebugBridgeV1 = @import("debug_bridge.zig");
pub const RuntimeDebugWireV1 = @import("debug_wire_v1.zig");
pub const RuntimeDebugLocalProviderV1 = @import("debug_local_endpoint.zig");
pub const ResidentReloadV1 = @import("resident_reload_contract.zig");
pub const MusicReloadPollV1 = ResidentReloadV1.Poll;
pub const MusicReloadOptionsV1 = ResidentReloadV1.Options;
pub const MusicRetainedGenerationV1 = ResidentReloadV1.Retained;
pub const MusicRuntime = @import("resident_runtime.zig").MusicRuntime;
pub const MusicRuntimeConfig = @import("resident_runtime.zig").Config;
pub const MusicRuntimeSnapshot = @import("resident_runtime.zig").Snapshot;
const runtime_contract = @import("runtime_contract.zig");
pub const MusicRuntimeConfigV1 = runtime_contract.ConfigV1;
pub const MusicBoundaryStopV1 = runtime_contract.BoundaryStopV1;
pub const MusicPreviewSeekModeV1 = runtime_contract.PreviewSeekModeV1;
pub const resident_fill_hard_cut_v1 = runtime_contract.resident_fill_hard_cut_v1;
pub const MusicLayerGainConfigV1 = @import("runtime_layer_contract.zig").ConfigV1;
pub const MusicLayerGainBindingV1 = @import("runtime_layer_contract.zig").BindingV1;
pub const MusicPolicySupportV1 = runtime_contract.PolicySupportV1;
pub const MusicDuckLifetimeV1 = runtime_contract.DuckLifetimeV1;
pub const MusicStingerLifetimeV1 = runtime_contract.StingerLifetimeV1;
pub const MusicRuntimeCapacityV1 = runtime_contract.CapacityV1;
pub const MusicRuntimeMemoryUsageV1 = runtime_contract.MemoryUsageV1;
pub const MusicRuntimeStatusV1 = runtime_contract.StatusV1;
pub const MusicRetainedTraceBatchV1 = runtime_contract.RetainedTraceBatchV1;
pub const MusicHistoryRequirementsV1 = runtime_contract.HistoryRequirementsV1;
pub const MusicRetainedTraceWithProvenanceV1 = runtime_contract.RetainedTraceWithProvenanceV1;
pub const MusicRuntimeReceiptV1 = runtime_contract.ReceiptV1;
pub const MusicRuntimeStopProgressV1 = runtime_contract.StopProgressV1;
pub const MusicRuntimeDrainStatusV1 = runtime_contract.DrainStatusV1;
pub const MusicRuntimeFailureV1 = runtime_contract.FailureV1;
pub const MusicBankRefV1 = runtime_contract.BankRefV1;
pub const MusicLoadTicketV1 = runtime_contract.LoadTicketV1;
pub const MusicLoadStatusV1 = runtime_contract.LoadStatusV1;
pub const MusicLoadProgressV1 = runtime_contract.LoadProgressV1;
pub const MusicRequestTicketV1 = runtime_contract.RequestTicketV1;
const ids = @import("ids.zig");
pub const hashName = ids.hashName;
pub const Domain = ids.Domain;
pub const MusicStateId = ids.MusicStateId;
pub const ThemeId = ids.ThemeId;
pub const SegmentId = ids.SegmentId;
pub const LayerId = ids.LayerId;
pub const MusicParameterId = ids.MusicParameterId;
pub const MusicContextId = ids.MusicContextId;
pub const MusicContextValueId = ids.MusicContextValueId;
pub const StingerId = ids.StingerId;
pub const DuckRequestId = ids.DuckRequestId;
pub const DuckPresetId = ids.DuckPresetId;
pub const CueId = ids.CueId;
pub const FillRouteId = ids.FillRouteId;
pub const SegmentSelectorId = ids.SegmentSelectorId;
pub const LogicProgramId = ids.LogicProgramId;
pub const MusicVoiceGroupId = ids.MusicVoiceGroupId;
pub const TempoSpanId = ids.TempoSpanId;
pub const TempoMapId = ids.TempoMapId;
pub const HarmonyTagId = ids.HarmonyTagId;
pub const PhraseTagId = ids.PhraseTagId;
pub const EnergyTagId = ids.EnergyTagId;
pub const MusicBusId = ids.MusicBusId;
pub const PlatformProfileId = ids.PlatformProfileId;
pub const CounterDomain = ids.CounterDomain;
pub const RuntimeContextId = ids.RuntimeContextId;
pub const PlanId = ids.PlanId;
pub const CommandId = ids.CommandId;
pub const PhaseId = ids.PhaseId;
pub const PlanEpoch = ids.PlanEpoch;
pub const TransportEpoch = ids.TransportEpoch;
pub const DeviceEpoch = ids.DeviceEpoch;
pub const AssetGeneration = ids.AssetGeneration;
pub const MusicRuntimeHandle = ids.MusicRuntimeHandle;
pub const MusicInstanceHandle = ids.MusicInstanceHandle;
pub const MusicBankHandle = ids.MusicBankHandle;
const errors = @import("errors.zig");
pub const MusicError = errors.MusicError;
const contract = @import("contract.zig");
pub const ApiThread = contract.ApiThread;
pub const ApiOperation = contract.ApiOperation;
pub const requiredThread = contract.requiredThread;
pub const ProductionOwnership = contract.ProductionOwnership;
pub const ProductionBaseline = contract.ProductionBaseline;
pub const MusicRuntimeState = contract.MusicRuntimeState;
pub const MusicContextKind = contract.MusicContextKind;
pub const MusicContextValue = contract.MusicContextValue;
pub const MusicStopMode = contract.MusicStopMode;
pub const DuckRequest = contract.DuckRequest;
pub const MusicRequestPayload = contract.MusicRequestPayload;
pub const MusicRequest = contract.MusicRequest;
pub const ControlAcceptedInput = contract.ControlAcceptedInput;
pub const PlanExecutionState = contract.PlanExecutionState;
pub const CancellationScope = contract.CancellationScope;
pub const PhaseToken = contract.PhaseToken;
pub const PlanReceipt = contract.PlanReceipt;
pub const PhaseOutcome = contract.PhaseOutcome;
pub const PhaseReceipt = contract.PhaseReceipt;
pub const CancellationDisposition = contract.CancellationDisposition;
pub const CancellationReceipt = contract.CancellationReceipt;
pub const MusicReceipt = contract.MusicReceipt;
pub const FrameRange = contract.FrameRange;
pub const DeliveredFrames = contract.DeliveredFrames;
pub const DeliveryObservation = contract.DeliveryObservation;
pub const PendingPcmRange = contract.PendingPcmRange;
pub const DeviceFlushRecord = contract.DeviceFlushRecord;
pub const DeviceRecoveryPolicy = contract.DeviceRecoveryPolicy;
pub const RecordingHeaderV2 = contract.RecordingHeaderV2;
pub const ReplayInputV2 = contract.ReplayInputV2;
pub const ScheduleTraceV2 = contract.ScheduleTraceV2;

/// Implemented observation and fact-injection primitives used by the bounded
/// resident owner as well as the complete runtime integration to follow.
pub const trace = @import("sme-trace");
pub const replay = trace.replay;
pub const telemetry = trace.metrics;

/// Implemented musical query and control components. The bounded resident owner
/// above is extended by TASK014 without introducing a second public runtime.
pub const clock = @import("sme-clock");
pub const Clock = clock.Clock;
pub const TempoMap = clock.Map;
pub const logic = @import("sme-logic");
pub const selectors = @import("sme-selector");
pub const director = @import("sme-director");
pub const Director = director.Director;
pub const TransitionIntent = director.TransitionIntent;
pub const DirectorSelectorSnapshotV1 = director.DirectorSelectorSnapshotV1;

pub const MusicSourceProviderV1 = @import("source_provider.zig").V1;
pub const MusicSourceProviderV2 = @import("source_provider.zig").V2;
pub const SourceIdentityV2 = @import("source_provider.zig").IdentityV2;
pub const SourceBindingTokenV2 = @import("source_provider.zig").TokenV2;
pub const BankSourceProviderV2 = @import("bank_source_provider_v2.zig").Provider;
pub const RuntimeEventAdapterV1 = @import("bugu_audio").events.RuntimeAdapterV1;
pub const RuntimeEventV1 = @import("bugu_audio").events.runtime_adapter.Event;
pub const RuntimeEventChoiceV1 = @import("bugu_audio").events.runtime_adapter.Choice;

/// Bounded resident_v1 or explicit stream_direct_v1 envelope. Full save_restore
/// remains false; both profiles use this existing owned snapshot/API.
pub const MusicSnapshotProfileV1 = @import("runtime_contract.zig").SnapshotProfileV1;
pub const MusicResidentSnapshotV1 = @import("save_state.zig").SnapshotV1;
pub const MusicCaptureTicketV1 = @import("save_state.zig").TicketV1;
pub const MusicCapturePollV1 = @import("save_state.zig").PollV1;
pub const MusicRestorePollV1 = @import("save_state.zig").RestorePollV1;

/// Canonical envelope inspection for persisted resident resources.
pub const ResidentStateCodecV1 = @import("save_state.zig");

pub const PublicChunkReplayV1 = @import("public_chunk_replay.zig");

/// Additive direct-host, final-quiescent causal recording profile.
pub const CausalRecordingV1 = @import("public_causal_recording.zig");
pub const CausalRecordingFormatV1 = @import("causal_recording_format.zig");
pub const CausalReplayV1 = @import("public_causal_replay.zig");

/// Unpublished Control-only capture adapter; not semantic replay.
pub const live_tick_capture = @import("live_tick_capture.zig");

// Keep these source-local suites in the music module's single identity. A
// second root at live_chronology_format.zig conflicts with trace -> music.
// Deliberately reference only these suites, not every public facade export.
test "Live chronology source suites" {
    const testing = @import("std").testing;
    testing.refAllDecls(@import("live_chronology.zig"));
    testing.refAllDecls(@import("live_chronology_format.zig"));
}
