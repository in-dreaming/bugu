//! Replay fact injection only. The consumer runs its actual Director/Planner/
//! Scheduler/Renderer; this driver never accepts execution/cancellation outcomes.
const std = @import("std");
const schema = @import("trace_schema.zig");
const codec = @import("trace_codec.zig");
const life = schema.lifecycle;
pub const Input = schema.Input;
pub const Header = schema.Header;
pub fn validateSequence(inputs: []const Input) schema.Error!void {
    if (inputs.len > schema.max_events) return error.InvalidEvent;
    var previous: ?schema.Position = null;
    var gate: ?schema.Admission = null;
    for (inputs) |input| {
        try input.validate();
        if (previous) |p| {
            if (!schema.before(p, input.position) or input.position.accepted_control_frame < p.accepted_control_frame) return error.InvalidOrder;
        }
        previous = input.position;
        switch (input.payload) {
            // This generic retained-envelope route has no profile-7 contract.
            .context_host_operation => return error.UnknownVersion,
            .runtime_step => |step| if (step.profile == .stream_context_serial_v1) return error.UnknownVersion,
            .admission => |a| {
                if (gate) |g| {
                    if (a.gate < g.gate or a.frame < g.frame or (a.gate == g.gate and (a.frame != g.frame or a.gate_order <= g.gate_order or a.commit_horizon != g.commit_horizon))) return error.InvalidOrder;
                }
                gate = a;
            },
            .acoustic_observation => |v| if (v.hasLoss()) return error.IncompleteTrace,
            else => {},
        }
    }
}
pub const PreparedPcm = struct { job: u64, asset: u64, generation: u64, transport_epoch: u64, pcm_start: u64, pcm_end: u64, available_frames: u64, channel_count: u16, content_hash: schema.Hash, pcm_bytes: []const u8, job_descriptor_bytes: []const u8 };
pub const ComputedBatch = struct { batch_id: u64, kind: schema.BatchKind, content_hash: schema.Hash, canonical_bytes: []const u8 };
pub fn hashPcm(bytes: []const u8) schema.Hash {
    var hash: schema.Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}
pub fn verifyPcm(event: schema.Worker, prepared: PreparedPcm) !void {
    try event.validateWindow();
    if (event.job != prepared.job or event.asset != prepared.asset or event.generation != prepared.generation or event.transport_epoch != prepared.transport_epoch or event.pcm_start != prepared.pcm_start or event.pcm_end != prepared.pcm_end or event.available_frames != prepared.available_frames or event.channel_count != prepared.channel_count) return error.ResourceNotPrepared;
    if (@as(u128, prepared.available_frames) * prepared.channel_count * @sizeOf(f32) != prepared.pcm_bytes.len) return error.ResourceNotPrepared;
    try verifyJobDescriptor(event, prepared.job_descriptor_bytes);
    const actual_hash = hashPcm(prepared.pcm_bytes);
    if (!std.mem.eql(u8, &actual_hash, &prepared.content_hash) or !std.mem.eql(u8, &event.content_hash, &actual_hash)) return error.HashMismatch;
}
pub fn verifyBatch(event: schema.Admission, actual: ComputedBatch) schema.Error!void {
    if (event.batch_id != actual.batch_id or event.kind != actual.kind) return error.MissingAdmission;
    if (actual.canonical_bytes.len == 0) return error.MissingAdmission;
    const actual_hash = hashPcm(actual.canonical_bytes);
    if (!std.mem.eql(u8, &actual_hash, &actual.content_hash) or !std.mem.eql(u8, &event.content_hash, &actual_hash)) return error.HashMismatch;
}
pub const GateRelease = struct { position: schema.Position, batch_id: u64, kind: schema.BatchKind, gate: u64, frame: u64, gate_order: u32 };
pub const GateObservation = struct { commit_horizon: u64, disposition: schema.AdmissionDisposition };
pub const Driver = struct {
    inputs: []const Input,
    cursor: usize = 0,
    last_tick: ?u64 = null,
    poisoned: bool = false,
    pub fn init(header: Header, expected: Header, inputs: []const Input) !Driver {
        try header.requireCompatible(expected);
        try validateSequence(inputs);
        return .{ .inputs = inputs };
    }
    /// Consumer requirements:
    /// preparePcm(worker) -> !PreparedPcm: actual predecoded bytes, not a fixed hash.
    /// computedBatch(batch_id, kind) -> !ComputedBatch: batch from real planning.
    /// releaseBatch(GateRelease) -> !GateObservation: recompute gate admission;
    /// expected disposition is deliberately NOT passed to the consumer.
    /// verifyReplayComplete() -> !void: reject pending batches lacking gates,
    /// unreconciled worker tickets, and load/restore/generation intents missing
    /// preparation/readiness facts at this recording's declared completion.
    /// recomputeReadiness(position, facts) receives accepted ordering/frontier,
    /// never the expected estimate/watermark/deadline/ready projection.
    /// inject(input) -> !void: apply at this tick/gate and recompute outcomes.
    /// Errors poison the driver to prevent repeating partially applied inputs.
    pub fn injectTick(self: *Driver, tick: u64, consumer: anytype) !usize {
        if (self.poisoned) return error.InvalidState;
        if (self.last_tick) |last| if (tick <= last) return error.InvalidOrder;
        if (self.cursor < self.inputs.len and self.inputs[self.cursor].position.control_tick < tick) return error.InvalidOrder;
        errdefer self.poisoned = true;
        var count: usize = 0;
        while (self.cursor < self.inputs.len and self.inputs[self.cursor].position.control_tick == tick) {
            const input = self.inputs[self.cursor];
            switch (input.payload) {
                // Public runtime chronology must use the profile-aware real
                // runtime driver; a generic fact consumer cannot certify it.
                .runtime_step, .state_host_operation, .context_host_operation => return error.UnsupportedOperation,
                .worker => |w| {
                    if (comptime hasMethod(@TypeOf(consumer), "computedJobDescriptor")) {
                        try verifyJobDescriptor(w, try consumer.computedJobDescriptor(w.job));
                    } else return error.UnsupportedOperation;
                    if (w.state == .ready) try verifyPcm(w, try consumer.preparePcm(w));
                },
                .admission => |a| {
                    try verifyBatch(a, try consumer.computedBatch(a.batch_id, a.kind));
                    const observed = try consumer.releaseBatch(GateRelease{ .position = input.position, .batch_id = a.batch_id, .kind = a.kind, .gate = a.gate, .frame = a.frame, .gate_order = a.gate_order });
                    if (observed.commit_horizon != a.commit_horizon or observed.disposition != a.disposition) return error.AdmissionMismatch;
                },
                .lifecycle => |v| if (v.payload == .restore_state) {
                    if (comptime hasMethod(@TypeOf(consumer), "prepareRestore") and hasMethod(@TypeOf(consumer), "validateRestore")) {
                        const resources = try consumer.prepareRestore(v.payload.restore_state);
                        try verifyRestore(v.payload.restore_state, resources);
                        try consumer.validateRestore(v.payload.restore_state, resources);
                    } else return error.UnsupportedOperation;
                },
                .generation_preparation => |v| {
                    if (comptime hasMethod(@TypeOf(consumer), "computedGenerationTicket")) {
                        if (!std.meta.eql(preparationTicket(v), try consumer.computedGenerationTicket(v.job))) return error.ResourceNotPrepared;
                    } else return error.UnsupportedOperation;
                    if (v.state == .ready) {
                        if (comptime hasMethod(@TypeOf(consumer), "prepareGeneration") and hasMethod(@TypeOf(consumer), "validateGeneration")) {
                            const resources = try consumer.prepareGeneration(v);
                            try verifyGeneration(v, resources);
                            // Actual consumers validate bank/snapshot/map semantics
                            // and metadata-only allowlists using immutable bytes.
                            try consumer.validateGeneration(v, resources);
                        } else return error.UnsupportedOperation;
                    }
                },
                .acoustic_observation => |v| {
                    if (v.hasLoss()) return error.IncompleteTrace;
                    if (comptime hasMethod(@TypeOf(consumer), "observeAcoustic")) {
                        _ = try consumer.observeAcoustic(input.position, v);
                    } else return error.UnsupportedOperation;
                },
                .readiness_snapshot => |v| {
                    if (comptime hasMethod(@TypeOf(consumer), "recomputeReadiness")) {
                        const projection = try consumer.recomputeReadiness(input.position, v.facts);
                        if (!std.meta.eql(projection, v.expected)) return error.ReadinessMismatch;
                    } else return error.UnsupportedOperation;
                },
                else => {},
            }
            if (input.payload != .admission and input.payload != .readiness_snapshot and input.payload != .acoustic_observation) try consumer.inject(input);
            self.cursor += 1;
            count += 1;
        }
        self.last_tick = tick;
        return count;
    }
    pub fn finish(self: Driver, consumer: anytype) !void {
        if (self.poisoned or self.cursor != self.inputs.len) return error.IncompleteTrace;
        try consumer.verifyReplayComplete();
    }
};
/// A request-only legacy file cannot be upgraded to production replay: it lacks
/// renderer visibility gates. Explicit migration only extracts resident requests
/// for inspection/re-recording, and returns non-production evidence unconditionally.
pub const LegacySubset = struct { requests: []const Input, production_replay: bool = false, needs_admission_recording: bool = true };
pub fn migrateLegacyResident(inputs: []const Input, resident_only: bool, no_discontinuity: bool) !LegacySubset {
    if (!resident_only or !no_discontinuity) return error.UnsupportedMigration;
    for (inputs) |input| if (input.payload != .request) return error.UnsupportedMigration;
    try validateSequence(inputs);
    return .{ .requests = inputs };
}

pub fn jobDescriptor(w: schema.Worker) schema.readiness.JobDescriptor {
    return .{ .job = w.job, .asset = w.asset, .generation = w.generation, .transport_epoch = w.transport_epoch, .operation = w.operation, .group = w.group, .layer = w.layer, .loop_epoch = w.loop_epoch, .target_cursor = w.target_cursor, .realize_frame = w.realize_frame };
}
pub fn encodeJobDescriptor(bytes: []u8, job: schema.readiness.JobDescriptor) ![]const u8 {
    var e: codec.Encoder = .{ .bytes = bytes };
    try e.put(job);
    return bytes[0..e.offset];
}
pub fn PreparedResource(comptime Reference: type) type {
    return struct { reference: Reference, bytes: []const u8 };
}
pub const PreparedBank = PreparedResource(life.BankResource);
pub const PreparedMigration = PreparedResource(life.MigrationResource);
pub const PreparedSnapshot = PreparedResource(life.SnapshotResource);
pub const PreparedGeneration = struct { bank: PreparedBank, migration: ?PreparedMigration, snapshot: ?PreparedSnapshot };
pub const PreparedRestore = struct { snapshot: PreparedSnapshot, migration: ?PreparedMigration };
fn verifyResource(expected: anytype, actual: PreparedResource(@TypeOf(expected))) !void {
    if (!std.meta.eql(expected, actual.reference) or actual.bytes.len != expected.byte_size) return error.ResourceNotPrepared;
    const digest = hashPcm(actual.bytes);
    if (!std.mem.eql(u8, &digest, &expected.bytes_hash)) return error.HashMismatch;
}
pub fn verifyRestore(event: life.Restore, resources: PreparedRestore) !void {
    try verifyResource(event.snapshot, resources.snapshot);
    if ((event.migration == null) != (resources.migration == null)) return error.ResourceNotPrepared;
    if (event.migration) |m| try verifyResource(m, resources.migration.?);
}
pub fn verifyGeneration(event: life.GenerationPreparation, resources: PreparedGeneration) !void {
    try verifyResource(event.bank, resources.bank);
    if ((event.migration == null) != (resources.migration == null) or (event.snapshot == null) != (resources.snapshot == null)) return error.ResourceNotPrepared;
    if (event.migration) |m| try verifyResource(m, resources.migration.?);
    if (event.snapshot) |v| try verifyResource(v, resources.snapshot.?);
}

fn hasMethod(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(if (@typeInfo(T) == .pointer) @typeInfo(T).pointer.child else T, name);
}
pub fn verifyJobDescriptor(event: schema.Worker, bytes: []const u8) !void {
    const hash = hashPcm(bytes);
    if (!std.mem.eql(u8, &hash, &event.job_descriptor_hash)) return error.HashMismatch;
    var decoder: codec.Decoder = .{ .bytes = bytes };
    const actual = try decoder.get(schema.readiness.JobDescriptor);
    try decoder.finish();
    if (!std.meta.eql(actual, jobDescriptor(event))) return error.ResourceNotPrepared;
}
pub const PreparationTicket = struct {
    operation_id: u64,
    context: u64,
    job: u64,
    control_epoch: u64,
    transport_epoch: u64,
    kind: life.PreparationKind,
    bank: life.BankResource,
    migration: ?life.MigrationResource,
    snapshot: ?life.SnapshotResource,
};
pub fn preparationTicket(event: life.GenerationPreparation) PreparationTicket {
    return .{ .operation_id = event.operation_id, .context = event.context, .job = event.job, .control_epoch = event.control_epoch, .transport_epoch = event.transport_epoch, .kind = event.kind, .bank = event.bank, .migration = event.migration, .snapshot = event.snapshot };
}
