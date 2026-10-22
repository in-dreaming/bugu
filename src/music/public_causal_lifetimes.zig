//! Normal-DIRECT Control ownership accounting, not a causal proof by itself.
//! The mandatory sink shares the caller's aggregate pending/work budget and
//! connects preparation/return actions to its actual Prefix/checkpoint proof.
//! It MUST reject an unproved retire action. Missing queued/prepared/partial
//! state cuts, cancellation, and source switching are deliberately unsupported.
//! One serialized validator owns this value. No allocation or engine access.
const std = @import("std");
const rt = @import("bugu_audio").runtime;
pub const SourceFinal = struct { key: format.OperationKey, value: rt.GroupSourceFinal };
pub const format = @import("causal_recording_format.zig");
pub const scheduler = @import("bugu_audio").runtime.scheduler;
pub const Reconciliation = format.readiness.Reconciliation;
pub const QueryKey = format.readiness.observation.QueryKey;
pub const Handle = scheduler.Handle;
pub const slots: usize = scheduler.block_capacity;
pub const command_slots: usize = scheduler.commands_per_block;
pub const operation_slots: usize = 8;
pub const Error = error{ InvalidEvidence, StaleReference, MissingPreparation, MissingReturn, DuplicatePublication, DependencyCapacity, UnrepresentedCut, Incomplete, InvalidLimits };

pub const PendingKind = enum { group, block, plan, preparation, command, operation, publication, deferred_control, source_final };
pub const Pending = struct { kind: PendingKind, index: u64, generation: u64, ordinal: u16 = 0 };
pub const PreparedBlock = struct { block: Handle, plan: Handle, command_count: u16, first_phase: u16, phase_count: u16, total_phases: u16, key: QueryKey };
pub const Publication = struct { key: format.OperationKey, value: scheduler.CausalPublication };
pub const Action = union(enum) {
    reserve: Pending,
    release: Pending,
    charge: u32,
    prepare_block: PreparedBlock,
    prepare_plan: struct { plan: Handle, total_phases: u16, key: QueryKey },
    bind_publication: Publication,
    // Sink must extract/match the actual existing checkpoints. In particular
    // nonfree scans with absent prepared/queued/partial cuts remain rejected.
    source_switch_empty_cut: struct { key: QueryKey, group: Handle },
    source_final_cut: struct { key: QueryKey, fact: SourceFinal },
    terminal_scan_cut: struct { key: QueryKey, index: u16, generation: u64, state: scheduler.State },
    control_cut: struct { key: QueryKey, value: scheduler.ControlObservation },
    schedule_release_cut: struct { key: QueryKey, value: Reconciliation },
    // These are proof obligations, NOT unconditional permission to close a
    // Prefix. Sink must bind actual terminal/return cuts and pending reads.
    retire_block: struct { block: Handle, plan: Handle, command_count: u16, key: QueryKey },
    retire_plan: struct { plan: Handle, total_phases: u16, key: QueryKey },
    retire_group_references: struct { group: Handle, key: QueryKey },
};
pub const Sink = struct { context: *anyopaque, emit: *const fn (*anyopaque, Action) anyerror!void };

const Group = struct { generation: u64 = 0, live: bool = false, references: u16 = 0, empty_source_polled: bool = false };
const Command = struct { group: Handle, command_id: u64, input_ordinal: u16, bound: bool = false, returned: bool = false, token: Pending };
const Preparation = struct { key: QueryKey, count: u16, horizon_seen: bool = false, block: ?Handle = null, commands: [command_slots]?Command = @splat(null) };
const Release = struct { key: QueryKey };
const Block = struct {
    generation: u64 = 0,
    live: bool = false,
    plan: Handle = .{ .index = 0, .generation = 0 },
    batch: u64 = 0,
    count: u16 = 0,
    prepared: bool = false,
    published: bool = false,
    release: ?Release = null,
    ack_valid: u64 = 0,
    ack_ready: u64 = 0,
    commands: [command_slots]?Command = @splat(null),
};
const Plan = struct { generation: u64 = 0, live: bool = false, refs: u16 = 0, total: u16 = 0, prepared_phases: u16 = 0, fence: u16 = 0 };
const Operation = struct { value: scheduler.ControlOperation, key: QueryKey, scanned: u16 = 0, selected_free: ?u16 = null };
const DeferredValue = union(enum) { reconciliation: Reconciliation, control: scheduler.ControlObservation, source_switch_empty: Handle };
const Deferred = struct { key: QueryKey, value: DeferredValue, id: u64 };

pub const Ledger = struct {
    sink: Sink,
    bank_generation: u64,
    failed: bool,
    finished: bool,
    groups: [slots]Group,
    blocks: [slots]Block,
    plans: [slots]Plan,
    fence_refs: [slots]u16,
    operations: [operation_slots]?Operation,
    depth: usize,
    last_operation: u64,
    preparation: ?Preparation,
    // At most one publication per physical slot may arrive before its Control
    // witness. Never overwrite it for a future incarnation; reject capacity.
    publications: [slots]?Publication,
    source_finals: [slots]?SourceFinal,
    deferred: [slots]?Deferred,
    deferred_count: usize,
    deferred_serial: u64,
    pending: usize,

    pub fn initInto(self: *Ledger, bank_generation: u64, sink: Sink) Error!void {
        if (bank_generation == 0) return error.InvalidLimits;
        self.sink = sink;
        self.bank_generation = bank_generation;
        self.failed = false;
        self.finished = false;
        for (&self.groups) |*g| g.* = .{};
        for (&self.blocks) |*b| b.* = .{};
        for (&self.plans) |*p| p.* = .{};
        @memset(&self.fence_refs, 0);
        @memset(&self.operations, null);
        @memset(&self.publications, null);
        @memset(&self.source_finals, null);
        @memset(&self.deferred, null);
        self.deferred_count = 0;
        self.deferred_serial = 0;
        self.depth = 0;
        self.last_operation = 0;
        self.preparation = null;
        self.pending = 0;
    }
    fn emit(self: *Ledger, action: Action) anyerror!void {
        try self.sink.emit(self.sink.context, action);
    }
    fn reserve(self: *Ledger, held: Pending) anyerror!void {
        try self.emit(.{ .reserve = held });
        self.pending += 1;
    }
    fn release(self: *Ledger, held: Pending) anyerror!void {
        if (self.pending == 0) return error.InvalidEvidence;
        try self.emit(.{ .release = held });
        self.pending -= 1;
    }
    fn enter(self: *Ledger) anyerror!void {
        if (self.failed or self.finished) return error.Incomplete;
        try self.emit(.{ .charge = 1 });
    }
    fn group(self: *Ledger, h: Handle) Error!*Group {
        if (!valid(h) or !self.groups[h.index].live or self.groups[h.index].generation != h.generation) return error.StaleReference;
        return &self.groups[h.index];
    }
    fn block(self: *Ledger, h: Handle) Error!*Block {
        if (!valid(h) or !self.blocks[h.index].live or self.blocks[h.index].generation != h.generation) return error.StaleReference;
        return &self.blocks[h.index];
    }
    fn plan(self: *Ledger, h: Handle) Error!*Plan {
        if (!valid(h) or !self.plans[h.index].live or self.plans[h.index].generation != h.generation) return error.StaleReference;
        return &self.plans[h.index];
    }
    fn operation(self: *Ledger, id: u64, kind: scheduler.ControlOperationKind, key: QueryKey) Error!*Operation {
        if (self.depth == 0) return error.InvalidEvidence;
        const op = &self.operations[self.depth - 1].?;
        if (op.value.operation_id != id or op.value.kind != kind or !sameTick(op.key, key)) return error.InvalidEvidence;
        return op;
    }
    fn preparedAttempt(self: *Ledger, record: Reconciliation, key: QueryKey) Error!*Preparation {
        const p = if (self.preparation) |*value| value else return error.MissingPreparation;
        if (record.parent_attempt != p.key.attempt_ordinal or !sameTick(p.key, key)) return error.InvalidEvidence;
        return p;
    }

    /// Feed the Control readiness lane in its original producer order. Existing
    /// owner validates group instances/pins/leases separately; this ledger owns
    /// only exact scheduler references to already witnessed prepared groups.
    pub fn reconciliation(self: *Ledger, key: QueryKey, r: Reconciliation) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        if (self.deferred_count != 0 or try self.needsPublication(r)) {
            try self.deferControl(key, .{ .reconciliation = r });
            return;
        }
        try self.applyReconciliation(key, r);
    }
    fn applyReconciliation(self: *Ledger, key: QueryKey, r: Reconciliation) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        if (key.tick_serial == 0 or key.attempt_ordinal == 0 or r.error_code != 0) return error.UnrepresentedCut;
        switch (r.kind) {
            .terminal_scan => {
                if (r.scanned == 0 or @as(usize, r.first_slot) + r.scanned > slots) return error.InvalidEvidence;
                try self.emit(.{ .charge = r.scanned });
                var terminal_seen = false;
                for (0..r.scanned) |offset| {
                    const index: u16 = r.first_slot + @as(u16, @intCast(offset));
                    const raw = (r.states[offset / 2] >> @as(u3, @intCast((offset % 2) * 4))) & 15;
                    if (raw > @intFromEnum(scheduler.State.terminal)) return error.InvalidEvidence;
                    const state: scheduler.State = @enumFromInt(raw);
                    const b = &self.blocks[index];
                    var generation: u64 = 0;
                    switch (state) {
                        .free => {
                            // This Control FIFO contains every prepare/return.
                            // Render never publishes into an unowned free slot;
                            // only a later Control prepare can grant that right.
                            // live becomes false only on the actual slot return.
                            if (b.live) return error.InvalidEvidence;
                        },
                        .published, .acquired, .terminal => {
                            if (!b.live or !b.prepared or !b.published) return error.MissingPreparation;
                            generation = b.generation;
                            if (state == .terminal) {
                                if (offset + 1 != r.scanned or !same(r.handle, .{ .index = index, .generation = generation })) return error.StaleReference;
                                terminal_seen = true;
                            }
                        },
                        .prepared, .queued, .partially_executed => return error.UnrepresentedCut,
                    }
                    try self.emit(.{ .terminal_scan_cut = .{ .key = key, .index = index, .generation = generation, .state = state } });
                }
                if (!terminal_seen and (r.handle.index != 0 or r.handle.generation != 0)) return error.InvalidEvidence;
            },
            .group_prepare => {
                if (!valid(r.handle) or !r.returned or r.bank_generation != self.bank_generation or r.voice_count == 0 or r.voice_count > 16) return error.InvalidEvidence;
                const g = &self.groups[r.handle.index];
                if (g.live or r.handle.generation <= g.generation) return error.StaleReference;
                try self.reserve(token(.group, r.handle));
                g.* = .{ .live = true, .generation = r.handle.generation };
            },
            .schedule_prepare => {
                if (r.command_count == 0 or r.command_count > command_slots) return error.InvalidEvidence;
                if (!r.returned) {
                    if (self.preparation != null or r.parent_attempt != 0 or r.block != null) return error.InvalidEvidence;
                    try self.reserve(attemptToken(key));
                    self.preparation = .{ .key = key, .count = r.command_count };
                } else {
                    const p = try self.preparedAttempt(r, key);
                    const h = p.block orelse return error.MissingPreparation;
                    if (!same(h, r.handle) or r.block == null or !same(h, r.block.?) or r.command_count != p.count) return error.InvalidEvidence;
                    try self.emit(.{ .charge = @intCast(command_slots) });
                    for (p.commands) |entry| if (entry) |c| if (!c.bound) return error.MissingPreparation;
                    const b = try self.block(h);
                    if (b.prepared) return error.InvalidEvidence;
                    b.prepared = true;
                    const saved_key = p.key;
                    self.preparation = null;
                    try self.release(attemptToken(saved_key));
                    try self.flushPublication(h);
                }
            },
            .schedule_group_retain => {
                const p = try self.preparedAttempt(r, key);
                if (!r.returned or r.block != null or p.block != null or p.horizon_seen or r.ordinal >= p.count or r.input_ordinal != r.ordinal or r.command_id == 0 or p.commands[r.ordinal] != null) return error.InvalidEvidence;
                const g = try self.group(r.handle);
                if (r.references != g.references or r.references_after == null or @as(u32, g.references) + 1 != r.references_after.?) return error.InvalidEvidence;
                const held: Pending = .{ .kind = .command, .index = key.tick_serial, .generation = r.parent_attempt, .ordinal = r.ordinal };
                try self.reserve(held);
                g.references = r.references_after.?;
                p.commands[r.ordinal] = .{ .group = r.handle, .command_id = r.command_id, .input_ordinal = r.ordinal, .token = held };
            },
            .schedule_group_bind => {
                const p = try self.preparedAttempt(r, key);
                const h = p.block orelse return error.MissingPreparation;
                const input = r.input_ordinal orelse return error.InvalidEvidence;
                if (!r.returned or r.block == null or !same(h, r.block.?) or input >= p.count or r.ordinal >= p.count) return error.InvalidEvidence;
                // Copy then replace the optional; never retain a pointer to a
                // by-value optional payload or change its reservation token.
                var copied = p.commands[input] orelse return error.MissingPreparation;
                const b = try self.block(h);
                if (copied.bound or !same(copied.group, r.handle) or copied.command_id != r.command_id or b.commands[r.ordinal] != null) return error.InvalidEvidence;
                copied.bound = true;
                p.commands[input] = copied;
                b.commands[r.ordinal] = copied;
            },
            .schedule_release => {
                const b = try self.block(r.handle);
                if (!b.prepared or !b.published or b.release != null or r.validation_state != .terminal or r.terminal_state != .terminal or r.invalidation_refs != 0 or r.queue_refs != 0) return error.InvalidEvidence;
                try self.emit(.{ .schedule_release_cut = .{ .key = key, .value = r } });
                b.release = .{ .key = key };
            },
            .schedule_group_return => {
                const h = r.block orelse return error.InvalidEvidence;
                const b = try self.block(h);
                const released = b.release orelse return error.MissingReturn;
                if (!sameTick(released.key, key) or r.parent_attempt != released.key.attempt_ordinal or r.ordinal >= b.count or !r.returned) return error.InvalidEvidence;
                var c = b.commands[r.ordinal] orelse return error.MissingPreparation;
                if (c.returned or !same(c.group, r.handle) or c.command_id != r.command_id or r.input_ordinal != c.input_ordinal) return error.InvalidEvidence;
                const g = try self.group(r.handle);
                if (g.references == 0 or r.references != g.references or r.references_after == null or @as(u32, r.references_after.?) + 1 != g.references) return error.InvalidEvidence;
                g.references = r.references_after.?;
                c.returned = true;
                b.commands[r.ordinal] = c;
                try self.release(c.token);
            },
            .group_release => {
                // The outer GroupPins/desired/stream-lease ledger must have
                // proved the complete release before accepting this action.
                if (!r.returned or r.pin_mask != null or r.references != null or r.parent_attempt == 0 or r.bank_generation != self.bank_generation) return error.UnrepresentedCut;
                const g = try self.group(r.handle);
                if (g.references != 0) return error.MissingReturn;
                const final = self.source_finals[r.handle.index] orelse return error.MissingReturn;
                if (final.value.group.index != r.handle.index or final.value.group.generation != r.handle.generation or final.value.bank_generation != self.bank_generation) return error.StaleReference;
                if (final.value.published) return error.UnrepresentedCut;
                try self.emit(.{ .source_final_cut = .{ .key = key, .fact = final } });
                try self.emit(.{ .retire_group_references = .{ .group = r.handle, .key = key } });
                g.live = false;
                self.source_finals[r.handle.index] = null;
                try self.release(token(.source_final, r.handle));
                try self.release(token(.group, r.handle));
            },
            else => return error.UnrepresentedCut,
        }
    }

    pub fn control(self: *Ledger, key: QueryKey, event: scheduler.ControlObservation) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        if (self.deferred_count != 0) {
            try self.deferControl(key, .{ .control = event });
            return;
        }
        try self.applyControl(key, event);
    }
    fn applyControl(self: *Ledger, key: QueryKey, event: scheduler.ControlObservation) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        if (key.tick_serial == 0) return error.InvalidEvidence;
        switch (event) {
            .operation => |v| {
                if (v.sequence_exhausted or v.operation_id == 0) return error.InvalidEvidence;
                const held: Pending = .{ .kind = .operation, .index = v.operation_id, .generation = 1 };
                if (v.result) |result| {
                    const op = try self.operation(v.operation_id, v.kind, key);
                    if (result != .success or v.parent_operation_id != op.value.parent_operation_id or !std.meta.eql(v.target, op.value.target)) return error.UnrepresentedCut;
                    if (v.kind == .reconcile and op.scanned != slots) return error.InvalidEvidence;
                    if (v.kind == .prepare and (self.preparation == null or self.preparation.?.block == null)) return error.MissingPreparation;
                    self.depth -= 1;
                    self.operations[self.depth] = null;
                    try self.release(held);
                } else {
                    if (self.depth == operation_slots or self.last_operation == std.math.maxInt(u64) or v.operation_id != self.last_operation + 1 or v.parent_operation_id != (if (self.depth == 0) @as(u64, 0) else self.operations[self.depth - 1].?.value.operation_id)) return error.InvalidEvidence;
                    try self.reserve(held);
                    self.operations[self.depth] = .{ .value = v, .key = key };
                    self.depth += 1;
                    self.last_operation = v.operation_id;
                }
            },
            .slot_scan => |v| {
                if (self.depth == 0) return error.InvalidEvidence;
                const op = &self.operations[self.depth - 1].?;
                if (v.operation_id != op.value.operation_id or !sameTick(op.key, key) or (op.value.kind != .prepare and op.value.kind != .reconcile) or v.count == 0 or v.count > scheduler.ControlScan.slots_per_chunk or v.first_slot != op.scanned or @as(u32, v.first_slot) + v.count > slots) return error.InvalidEvidence;
                if (op.value.kind == .prepare) {
                    if (op.selected_free != null) return error.InvalidEvidence;
                    try self.emit(.{ .charge = v.count });
                    for (0..v.count) |i| if (v.state(i) == .free) {
                        if (i + 1 != v.count) return error.InvalidEvidence;
                        op.selected_free = v.first_slot + @as(u16, @intCast(i));
                    };
                }
                // Owner separately validates each actual acquire cut. In
                // particular this does NOT accept prepared/queued observations.
                try self.emit(.{ .control_cut = .{ .key = key, .value = event } });
                op.scanned += v.count;
            },
            .prepare_horizon => |v| {
                _ = try self.operation(v.operation_id, .prepare, key);
                const p = if (self.preparation) |*value| value else return error.MissingPreparation;
                if (!sameTick(p.key, key) or p.horizon_seen or p.block != null or v.command_count != p.count or v.observation_only or v.start >= v.end) return error.InvalidEvidence;
                try self.emit(.{ .control_cut = .{ .key = key, .value = event } });
                p.horizon_seen = true;
            },
            .prepared => |v| {
                const op = try self.operation(v.operation_id, .prepare, key);
                const p = if (self.preparation) |*value| value else return error.MissingPreparation;
                if (!sameTick(p.key, key) or !p.horizon_seen or p.block != null or !valid(v.block) or !valid(v.plan) or v.fence_index >= slots or v.batch_id == 0 or v.phase_count == 0 or v.total_phases == 0 or @as(u32, v.first_phase) + v.phase_count > v.total_phases) return error.InvalidEvidence;
                if (op.scanned != @as(u32, v.block.index) + 1 or op.selected_free != v.block.index) return error.InvalidEvidence;
                const b = &self.blocks[v.block.index];
                if (b.live or v.block.generation <= b.generation) return error.StaleReference;
                const plan_value = &self.plans[v.plan.index];
                if (v.existing_plan) {
                    if (!plan_value.live or plan_value.generation != v.plan.generation or plan_value.total != v.total_phases or plan_value.fence != v.fence_index) return error.StaleReference;
                } else {
                    if (plan_value.live or v.plan.generation <= plan_value.generation or v.first_phase != 0 or @as(u32, self.fence_refs[v.fence_index]) + 1 != v.fence_refs) return error.StaleReference;
                    try self.reserve(token(.plan, v.plan));
                    plan_value.* = .{ .live = true, .generation = v.plan.generation, .total = v.total_phases, .fence = v.fence_index };
                    self.fence_refs[v.fence_index] = v.fence_refs;
                    try self.emit(.{ .prepare_plan = .{ .plan = v.plan, .total_phases = v.total_phases, .key = key } });
                }
                if (plan_value.prepared_phases != v.first_phase or @as(u32, plan_value.refs) + 1 != v.plan_block_refs or self.fence_refs[v.fence_index] != v.fence_refs) return error.InvalidEvidence;
                try self.reserve(token(.block, v.block));
                plan_value.refs = v.plan_block_refs;
                plan_value.prepared_phases += v.phase_count;
                b.* = .{ .live = true, .generation = v.block.generation, .plan = v.plan, .batch = v.batch_id, .count = p.count };
                p.block = v.block;
                try self.emit(.{ .prepare_block = .{ .block = v.block, .plan = v.plan, .command_count = p.count, .first_phase = v.first_phase, .phase_count = v.phase_count, .total_phases = v.total_phases, .key = key } });
            },
            .acknowledge_validation => |v| {
                const op = try self.operation(v.operation_id, .acknowledge, key);
                const b = try self.block(v.target);
                if (op.value.target == null or !same(op.value.target.?, v.target) or !v.valid or v.state != .terminal or v.generation != v.target.generation or b.release == null or b.ack_valid != 0) return error.InvalidEvidence;
                try self.emit(.{ .control_cut = .{ .key = key, .value = event } });
                b.ack_valid = v.operation_id;
            },
            .acknowledge_terminal => |v| {
                _ = try self.operation(v.operation_id, .acknowledge, key);
                const b = try self.block(v.block);
                if (b.ack_valid != v.operation_id or b.ack_ready != 0 or !v.eligible or v.state != .terminal or v.invalidation_refs != 0 or v.queue_refs != 0) return error.InvalidEvidence;
                try self.emit(.{ .control_cut = .{ .key = key, .value = event } });
                b.ack_ready = v.operation_id;
            },
            .slot_return => |v| {
                _ = try self.operation(v.operation_id, .acknowledge, key);
                const b = try self.block(v.block);
                const p = try self.plan(v.plan);
                if (!same(b.plan, v.plan) or b.release == null or b.ack_ready != v.operation_id or p.refs == 0 or v.plan_block_refs_before != p.refs or @as(u32, v.plan_block_refs_after) + 1 != p.refs) return error.InvalidEvidence;
                try self.emit(.{ .charge = @intCast(command_slots) });
                for (b.commands) |entry| if (entry) |c| if (!c.returned) return error.MissingReturn;
                try self.emit(.{ .retire_block = .{ .block = v.block, .plan = v.plan, .command_count = b.count, .key = key } });
                p.refs = v.plan_block_refs_after;
                b.live = false;
                @memset(&b.commands, null);
                try self.release(token(.block, v.block));
            },
            .plan_reap => |v| {
                const op = try self.operation(v.operation_id, .reap, key);
                const p = try self.plan(v.plan);
                if (op.value.target == null or !same(op.value.target.?, v.plan) or v.cancelled or v.block_refs != 0 or p.refs != 0 or v.intent_refs != 0 or v.transaction_refs != 0 or v.total_phases != p.total or v.executed_count == null or v.executed_count.? > p.total) return error.UnrepresentedCut;
                try self.emit(.{ .control_cut = .{ .key = key, .value = event } });
                if (!v.returned) {
                    if (v.fence_index != null or v.fence_refs_before != null or v.fence_refs_after != null) return error.InvalidEvidence;
                    if (v.executed_count.? < p.total) {
                        if (v.readers_cas_reached or v.readers_cas_failure != null) return error.InvalidEvidence;
                    } else if (!v.readers_cas_reached or v.readers_cas_failure == null) return error.InvalidEvidence;
                    return;
                }
                if (p.refs != 0 or p.prepared_phases != p.total or v.executed_count.? != p.total or !v.readers_cas_reached or v.readers_cas_failure != null or v.fence_index != p.fence or v.fence_refs_before != self.fence_refs[p.fence] or v.fence_refs_after == null or self.fence_refs[p.fence] == 0 or @as(u32, v.fence_refs_after.?) + 1 != self.fence_refs[p.fence]) return error.InvalidEvidence;
                try self.emit(.{ .retire_plan = .{ .plan = v.plan, .total_phases = p.total, .key = key } });
                self.fence_refs[p.fence] = v.fence_refs_after.?;
                p.live = false;
                try self.release(token(.plan, v.plan));
            },
            .prepared_cancellation => |v| {
                _ = try self.operation(v.operation_id, .reconcile, key);
                const b = try self.block(v.block);
                if (!same(b.plan, v.plan) or v.cancelled or v.terminal_stored or v.cancel_frame != null or v.cancel_requested != null or v.cancel_horizon != null or v.cancel_before != null or v.cancel_reason != null or v.receipt_executed_count != null or v.disposition_executed_count != null) return error.UnrepresentedCut;
            },
        }
    }

    /// Only this independent lane may arrive before its preparation witness.
    /// Same-Control-lane releases/retains cannot borrow future owner identity.
    pub fn publication(self: *Ledger, value: Publication) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        const h = value.value.block;
        if (value.key.role != .control or value.key.ordinal == 0 or !valid(h) or value.value.batch_id == 0 or value.value.sequence == 0 or std.mem.allEqual(u8, &value.value.content_hash, 0)) return error.InvalidEvidence;
        const b = &self.blocks[h.index];
        if ((b.live and b.generation != h.generation) or (!b.live and h.generation <= b.generation)) return error.StaleReference;
        if (self.publications[h.index] != null or (b.live and b.published)) return error.DuplicatePublication;
        try self.reserve(token(.publication, h));
        self.publications[h.index] = value;
        if (b.live and b.prepared) try self.flushPublication(h);
        try self.flushDeferred();
    }
    fn flushPublication(self: *Ledger, h: Handle) anyerror!void {
        const queued = self.publications[h.index] orelse return;
        const b = try self.block(h);
        if (!same(queued.value.block, h) or queued.value.batch_id != b.batch or !b.prepared or b.published) return error.InvalidEvidence;
        try self.emit(.{ .bind_publication = queued });
        b.published = true;
        self.publications[h.index] = null;
        try self.release(token(.publication, h));
    }
    pub fn sourceSwitchEmpty(self: *Ledger, key: QueryKey, handle: Handle) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        if (self.deferred_count != 0) {
            try self.deferControl(key, .{ .source_switch_empty = handle });
            return;
        }
        try self.applySourceSwitchEmpty(key, handle);
    }
    fn applySourceSwitchEmpty(self: *Ledger, key: QueryKey, handle: Handle) anyerror!void {
        if (key.tick_serial == 0 or key.attempt_ordinal == 0) return error.InvalidEvidence;
        const g = try self.group(handle);
        // Initial false belongs to the genuine prepared group. Every empty
        // poll remains conditional on the exact final false retirement read.
        g.empty_source_polled = true;
        try self.emit(.{ .source_switch_empty_cut = .{ .key = key, .group = handle } });
    }
    pub fn sourceFinal(self: *Ledger, fact: SourceFinal) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        const h: Handle = .{ .index = fact.value.group.index, .generation = fact.value.group.generation };
        if (fact.key.role != .control or fact.key.ordinal == 0 or !valid(h) or fact.value.bank_generation != self.bank_generation) return error.InvalidEvidence;
        const g = &self.groups[h.index];
        if ((g.live and g.generation != h.generation) or (!g.live and h.generation <= g.generation)) return error.StaleReference;
        if (self.source_finals[h.index] != null) return error.DuplicatePublication;
        try self.reserve(token(.source_final, h));
        self.source_finals[h.index] = fact;
        try self.flushDeferred();
    }
    fn needsPublication(self: *Ledger, r: Reconciliation) anyerror!bool {
        if (r.kind == .group_release and r.returned) {
            if (!valid(r.handle)) return error.InvalidEvidence;
            return self.source_finals[r.handle.index] == null;
        }
        if (r.kind == .terminal_scan) {
            if (r.scanned == 0 or @as(usize, r.first_slot) + r.scanned > slots) return error.InvalidEvidence;
            try self.emit(.{ .charge = r.scanned });
            for (0..r.scanned) |offset| {
                const raw = (r.states[offset / 2] >> @as(u3, @intCast((offset % 2) * 4))) & 15;
                if (raw == @intFromEnum(scheduler.State.published) or raw == @intFromEnum(scheduler.State.acquired) or raw == @intFromEnum(scheduler.State.terminal)) {
                    const b = &self.blocks[r.first_slot + offset];
                    if (!b.live or !b.prepared) return error.MissingPreparation;
                    if (!b.published) return true;
                }
            }
            return false;
        }
        if (r.kind != .schedule_release) return false;
        const b = try self.block(r.handle);
        return !b.published;
    }
    fn deferControl(self: *Ledger, key: QueryKey, value: DeferredValue) anyerror!void {
        if (self.deferred_count == slots or self.deferred_serial == std.math.maxInt(u64)) return error.DependencyCapacity;
        const id = self.deferred_serial + 1;
        try self.reserve(.{ .kind = .deferred_control, .index = id, .generation = 1 });
        self.deferred[self.deferred_count] = .{ .key = key, .value = value, .id = id };
        self.deferred_count += 1;
        self.deferred_serial = id;
    }
    fn flushDeferred(self: *Ledger) anyerror!void {
        while (self.deferred_count != 0) {
            const next = self.deferred[0].?;
            if (next.value == .reconciliation and try self.needsPublication(next.value.reconciliation)) break;
            switch (next.value) {
                .reconciliation => |r| try self.applyReconciliation(next.key, r),
                .control => |v| try self.applyControl(next.key, v),
                .source_switch_empty => |h| try self.applySourceSwitchEmpty(next.key, h),
            }
            try self.emit(.{ .charge = @intCast(self.deferred_count) });
            for (1..self.deferred_count) |i| self.deferred[i - 1] = self.deferred[i];
            self.deferred_count -= 1;
            self.deferred[self.deferred_count] = null;
            try self.release(.{ .kind = .deferred_control, .index = next.id, .generation = 1 });
        }
    }
    pub fn finish(self: *Ledger) anyerror!void {
        errdefer self.failed = true;
        try self.enter();
        try self.emit(.{ .charge = @intCast(slots) });
        if (self.depth != 0 or self.preparation != null or self.pending != 0 or self.deferred_count != 0) return error.MissingReturn;
        for (0..slots) |i| if (self.blocks[i].live or self.plans[i].live or self.groups[i].live or self.publications[i] != null or self.source_finals[i] != null or self.fence_refs[i] != 0) return error.MissingReturn;
        self.finished = true;
    }
};
fn valid(h: Handle) bool {
    return h.index < slots and h.generation != 0;
}
fn same(a: Handle, b: Handle) bool {
    return a.index == b.index and a.generation == b.generation;
}
fn sameTick(a: QueryKey, b: QueryKey) bool {
    return a.interval_id == b.interval_id and a.tick_serial == b.tick_serial and a.context == b.context;
}
fn token(kind: PendingKind, h: Handle) Pending {
    return .{ .kind = kind, .index = h.index, .generation = h.generation };
}
fn attemptToken(key: QueryKey) Pending {
    return .{ .kind = .preparation, .index = key.tick_serial, .generation = key.attempt_ordinal };
}
pub const fixed_bytes: usize = @sizeOf(Ledger);
