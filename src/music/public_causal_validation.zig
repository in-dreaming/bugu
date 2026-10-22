//! Bounded semantic obligations for public causal v1. This module never writes
//! engine state and never treats serialized merge order as happens-before.
//! A structural Cursor, an empty dependency queue, or a terminal digest alone
//! is not a causal proof. Unsupported acquire cuts are rejected explicitly.
pub const Lifetimes = @import("public_causal_lifetimes.zig");
pub const ExclusionTickets = @import("service_exclusion_validation.zig").TicketProof(Point, Error, struct {
    pub const charge = Dependencies.charge;
    pub const reserve = Dependencies.reservePending;
    pub const release = Dependencies.releasePending;
    pub const emit = Dependencies.emit;
});
const std = @import("std");
pub const format = @import("causal_recording_format.zig");
const rt = @import("bugu_audio").runtime;
const stream = rt.streaming.stream;
const trace = @import("sme-trace").schema;

pub const max_pending: usize = format.max_dependencies;
pub const partition_compiled = format.compiled_resource_profile == .partitioned544;
pub const PendingClass = enum { shared, stop_identity, consumed_identity, live_stream, live_job };
const Partition = struct {
    counts: [5]usize = @splat(0),
    job_reads: [2][48]bool = @splat(@splat(false)),
    job_read_count: usize = 0,
};
const PartitionStorage = if (partition_compiled) Partition else void;
const JobReadCredit = if (partition_compiled) bool else void;
fn localLimit(capacity: u32) u32 {
    return @min(capacity, max_pending);
}
pub const max_resource_slots: usize = 256;
pub const max_operation_bindings: usize = 256;
pub const Limits = format.Limits;
pub const Error = format.Error || error{
    InvalidEvidence,
    MissingPublication,
    MissingAcquisition,
    DuplicatePublication,
    DuplicateAcquisition,
    FutureReference,
    StaleReference,
    DependencyCapacity,
    UnrepresentedCut,
    UnboundOperation,
    IncompleteCoverage,
};
pub const Edge = enum { before, after };
pub const Site = enum {
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
    operation,
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
    stream_observation_frame,
    render_sequence_even,
    completion_enqueue,
    completion_space,
    completion_return,
    completion_pop,
    group_pin_publish,
    group_pin_return,
    group_pin_read,
    group_terminal_publish,
    group_terminal_read,
    scheduler_scan,
    scheduler_publication,
    scheduler_validate,
    scheduler_control_scan,
    scheduler_ack_terminal,
    scheduler_reap_phase,
    scheduler_reap_readers,
    scheduler_slot_return,
    schedule_release,
    terminal_scan,
    group_source_switch_read,
    group_source_switch_final,
    group_event_space,
    group_event_publish,
    group_event_pop,
    group_event_return,
    stream_consumed_release,
    stream_ring_consumed,
    stream_ring_produced,
    stream_produced,
    scheduler_acquisition,
    scheduler_acquired,
    scheduler_phase,
    scheduler_terminal,
    scheduler_receipt,
    scheduler_horizon,
    render_commit_horizon,
    collection_frame,
    control_collect_frame,
    plan_phase,
    execution_receipt,
    schedule_admission,
    schedule_result,
    control_horizon,
    control_accept_frame,
    control_acquisition,
    scheduler_prepare_horizon,
    group_desired_active,
    group_desired_start,
    group_desired_reservation,
    stream_close_claim,
    stream_close_pending,
    stream_close_idle,
    service_prepare_claim,
    service_prepare_idle,
    stream_close_visibility,
    stream_stop_publish,
    stream_close_stopped,
    worker_release_progress,
    control_release_progress,
};
/// occurrence is the per-site occurrence within an actual typed invocation.
/// An acquire is bracketed by .before/.after; .after contains no replacement
/// value. Expected atomic values remain comparators in the replay executor.
pub const Point = struct {
    role: format.Role,
    operation: u64,
    site: Site,
    index: u64 = 0,
    generation: u64 = 0,
    occurrence: u32 = 0,
    edge: Edge = .before,
};
pub const Dependency = struct { before: Point, after: Point };
// Only one actual role's program order can transfer an unresolved upper
// bound. Per-site occurrences are comparable only for the same full identity.
fn laterSameRead(prior: Point, later: Point) bool {
    return prior.edge == .before and later.edge == .before and
        prior.role == later.role and prior.site == later.site and
        prior.index == later.index and prior.generation == later.generation and
        (later.operation > prior.operation or
            (later.operation == prior.operation and later.occurrence > prior.occurrence));
}
pub const Check = struct { point: Point, value: u64 };
pub const CheckSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, Check) error{DependencyCapacity}!void };
pub const DependencySink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, Dependency) error{DependencyCapacity}!void,
};
/// One exact lifetime, not a slot address alone. The generation must increase
/// when a physical slot is reused. Domains have independent lifetimes.
pub const Domain = enum {
    job_selected,
    job_completed,
    publication_admitted,
    publication_acknowledged,
    completion_consumed,
    pins_returned,
    scheduler_acquired,
    scheduler_returned,
};
pub const Identity = struct { domain: Domain, index: u16, generation: u64 };
const domain_count = std.meta.fields(Domain).len;
const Relation = struct {
    identity: Identity,
    publication: ?Point = null,
    acquisition: ?Point = null,
    reads: u32 = 0,
};
const PendingRead = struct { identity: Identity, point: Point, emitted: bool = false };
const ReadMode = enum { unset, generic, ordered };
// The two supported streams imply role/site/generation. Operation zero is the
// unused marker; this fixed duplicate frontier survives relation retirement.
const OrderedReadWatermark = struct { operation: u64 = 0, occurrence: u32 = 0 };

/// The public low-level ledger is useful for testing the dependency protocol
/// separately from parsing. publish/read/consume accept only extracted actual
/// facts. A read may precede its publication in FILE order, and remains pending;
/// a same-role publication logically after that read is rejected on resolution.
/// consume is the unique ownership handoff and retires the exact generation.
pub const Dependencies = struct {
    capacity: usize = max_pending,
    work_limit: u64 = 1024 * 1024,
    work: u64 = 0,
    sink: ?DependencySink = null,
    relations: [max_pending]?Relation = @splat(null),
    pending: [max_pending]?PendingRead = @splat(null),
    read_mode: ReadMode = .unset,
    ordered_watermarks: [2][max_resource_slots]OrderedReadWatermark = @splat(@splat(.{})),
    retired: [domain_count][max_resource_slots]u64 = @splat(@splat(0)),
    live: usize = 0,
    pending_reads: usize = 0,
    /// One shared cap for every unresolved obligation, including nested cuts.
    /// Fixed retained publication/identity history is not a pending obligation.
    pending_total: usize = 0,
    partition: PartitionStorage = if (partition_compiled) .{} else {},
    high_water: usize = 0,
    emitted: u64 = 0,
    matched: u64 = 0,
    failed: bool = false,

    pub fn init(capacity: u32, work_limit: u64, sink: ?DependencySink) Error!Dependencies {
        if (capacity == 0 or work_limit == 0 or
            (capacity > max_pending and !(partition_compiled and capacity == 544))) return error.InvalidLimits;
        return .{ .capacity = capacity, .work_limit = work_limit, .sink = sink };
    }
    pub fn partitioned(self: *const Dependencies) bool {
        return partition_compiled and self.capacity == 544;
    }
    fn localCapacity(self: *const Dependencies) usize {
        return @min(self.capacity, max_pending);
    }
    fn charge(self: *Dependencies) Error!void {
        if (self.failed) return error.Incomplete;
        if (self.work >= self.work_limit) return error.WorkBudget;
        self.work += 1;
    }
    fn reservePending(self: *Dependencies) Error!void {
        return self.reserveClass(.shared);
    }
    fn releasePending(self: *Dependencies) void {
        self.releaseClass(.shared);
    }
    /// Strict independent quotas. No unused category can lend to shared work.
    pub fn reserveClass(self: *Dependencies, class: PendingClass) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (self.pending_total >= self.capacity) return error.DependencyCapacity;
        if (comptime partition_compiled) {
            if (self.partitioned()) {
                const index = @intFromEnum(class);
                const limit: usize = if (class == .shared) 256 else 48;
                if (self.partition.counts[index] >= limit) return error.DependencyCapacity;
                self.partition.counts[index] += 1;
            }
        }
        self.pending_total += 1;
        self.high_water = @max(self.high_water, self.pending_total);
    }
    pub fn releaseClass(self: *Dependencies, class: PendingClass) void {
        std.debug.assert(self.pending_total != 0);
        if (comptime partition_compiled) {
            if (self.partitioned()) {
                const index = @intFromEnum(class);
                std.debug.assert(self.partition.counts[index] != 0);
                self.partition.counts[index] -= 1;
            }
        }
        self.pending_total -= 1;
    }
    fn jobRole(role: format.Role) ?usize {
        return switch (role) {
            .control => 0,
            .worker => 1,
            .render => null,
        };
    }
    fn reserveJobRead(self: *Dependencies, index: u16, role: format.Role) Error!JobReadCredit {
        if (comptime partition_compiled) {
            if (self.partitioned() and index < 48) {
                if (jobRole(role)) |r| {
                    if (!self.partition.job_reads[r][index]) {
                        if (self.failed) return error.Incomplete;
                        if (self.pending_total >= self.capacity) {
                            self.failed = true;
                            return error.DependencyCapacity;
                        }
                        self.partition.job_reads[r][index] = true;
                        self.partition.job_read_count += 1;
                        self.pending_total += 1;
                        self.high_water = @max(self.high_water, self.pending_total);
                        return true;
                    }
                }
            }
            try self.reservePending();
            return false;
        } else {
            try self.reservePending();
            return {};
        }
    }
    fn releaseJobRead(self: *Dependencies, value: JobRead) void {
        if (comptime partition_compiled) {
            if (value.credit) {
                std.debug.assert(self.partitioned() and value.index < 48);
                const r = jobRole(value.at.role).?;
                std.debug.assert(self.partition.job_reads[r][value.index]);
                self.partition.job_reads[r][value.index] = false;
                self.partition.job_read_count -= 1;
                self.pending_total -= 1;
                return;
            }
        }
        self.releasePending();
    }
    /// Test/diagnostic conservation check; does not scan retained proof rows.
    pub fn partitionConserved(self: *const Dependencies) bool {
        if (comptime partition_compiled) {
            if (self.partitioned()) {
                var total = self.partition.job_read_count;
                var marked: usize = 0;
                for (self.partition.counts) |count| total += count;
                for (self.partition.job_reads) |row| for (row) |held| {
                    marked += @intFromBool(held);
                };
                return total == self.pending_total and marked == self.partition.job_read_count;
            }
        }
        return true;
    }
    fn validateIdentity(self: *Dependencies, id: Identity) Error!void {
        if (id.index >= max_resource_slots or id.generation == 0) return error.InvalidEvidence;
        if (id.generation <= self.retired[@intFromEnum(id.domain)][id.index]) return error.StaleReference;
    }
    fn find(self: *Dependencies, id: Identity) Error!?usize {
        for (self.relations[0..self.localCapacity()], 0..) |entry, index| {
            try self.charge();
            if (entry) |value| if (std.meta.eql(value.identity, id)) return index;
        }
        return null;
    }
    fn relation(self: *Dependencies, id: Identity) Error!usize {
        try self.validateIdentity(id);
        if (try self.find(id)) |index| return index;
        for (self.relations[0..self.localCapacity()], 0..) |entry, index| if (entry == null) {
            try self.reservePending();
            self.relations[index] = .{ .identity = id };
            self.live += 1;
            return index;
        };
        return error.DependencyCapacity;
    }
    fn emit(self: *Dependencies, publication: Point, acquired: Point) Error!void {
        try self.charge();
        if (publication.operation == 0 or acquired.operation == 0) return error.UnboundOperation;
        if (publication.edge != .after or acquired.edge != .before) return error.InvalidEvidence;
        // Inter-role ordinals are incomparable. For same-role calls only the
        // actual invocation identity orders them, never their merge position.
        if (publication.role == acquired.role and publication.operation > acquired.operation) return error.FutureReference;
        if (publication.role == acquired.role and publication.operation == acquired.operation and publication.site == acquired.site and publication.index == acquired.index and publication.occurrence >= acquired.occurrence) return error.FutureReference;
        if (self.sink) |sink| try sink.emit(sink.context, .{ .before = publication, .after = acquired });
        self.emitted += 1;
    }
    fn selectReadMode(self: *Dependencies, mode: ReadMode) Error!void {
        // Once an ordered representative replaced a read, generic duplicate
        // lookup cannot recover that old point. Never mix either direction,
        // even on a different identity or after the relation was consumed.
        if (self.read_mode != .unset and self.read_mode != mode) return error.InvalidOrder;
        self.read_mode = mode;
    }
    fn compactOrderedReads(self: *Dependencies, id: Identity) Error!void {
        if (self.read_mode != .ordered) return;
        var keep: ?usize = null;
        for (self.pending[0..self.localCapacity()], 0..) |item, index| if (item) |sample| {
            if (!sample.emitted or !std.meta.eql(sample.identity, id)) continue;
            try self.charge();
            if (keep) |previous| {
                const prior = self.pending[previous].?;
                const discard = if (laterSameRead(prior.point, sample.point)) blk: {
                    keep = index;
                    break :blk previous;
                } else if (laterSameRead(sample.point, prior.point)) index else return error.InvalidEvidence;
                self.pending[discard] = null;
                self.pending_reads -= 1;
                self.releasePending();
            } else keep = index;
        };
    }
    fn settle(self: *Dependencies, index: usize) Error!void {
        const entry = self.relations[index].?;
        const publication = entry.publication orelse return;
        for (&self.pending) |*item| if (item.*) |sample| {
            try self.charge();
            if (std.meta.eql(sample.identity, entry.identity) and !sample.emitted) {
                try self.emit(publication, sample.point);
                item.*.?.emitted = true;
            }
        };
        // A delayed publication must prove EVERY original lower first. Only
        // emitted duplicate-history representatives may then be compacted.
        try self.compactOrderedReads(entry.identity);
        const acquired = entry.acquisition orelse return;
        try self.emit(publication, acquired);
        const id = entry.identity;
        const retired = &self.retired[@intFromEnum(id.domain)][id.index];
        // Advancing over another unresolved generation would conceal a missing
        // observation. Reuse is admitted only after every old handoff matched.
        for (self.relations[0..self.localCapacity()], 0..) |other, other_index| if (other) |value| {
            try self.charge();
            if (other_index != index and value.identity.domain == id.domain and value.identity.index == id.index and value.identity.generation < id.generation) return error.UnrepresentedCut;
        };
        if (retired.* >= id.generation) return error.StaleReference;
        retired.* = id.generation;
        for (&self.pending) |*item| if (item.*) |sample| {
            if (std.meta.eql(sample.identity, id)) {
                item.* = null;
                self.pending_reads -= 1;
                self.releasePending();
            }
        };
        self.relations[index] = null;
        self.live -= 1;
        self.releasePending();
        self.matched += 1;
    }
    pub fn publish(self: *Dependencies, id: Identity, point: Point) Error!void {
        errdefer self.failed = true;
        try self.charge();
        if (point.edge != .after or point.operation == 0) return error.InvalidEvidence;
        const index = try self.relation(id);
        if (self.relations[index].?.publication != null) return error.DuplicatePublication;
        self.relations[index].?.publication = point;
        try self.settle(index);
    }
    pub fn read(self: *Dependencies, id: Identity, point: Point) Error!void {
        errdefer self.failed = true;
        try self.charge();
        try self.selectReadMode(.generic);
        if (point.edge != .before or point.operation == 0) return error.InvalidEvidence;
        const index = try self.relation(id);
        if (self.relations[index].?.acquisition != null) return error.DuplicateAcquisition;
        for (self.pending) |item| if (item) |prior| if (std.meta.eql(prior.point, point)) return error.DuplicateAcquisition;
        var emitted = false;
        if (self.relations[index].?.publication) |published| {
            try self.emit(published, point);
            emitted = true;
        }
        for (&self.pending) |*item| if (item.* == null) {
            try self.reservePending();
            item.* = .{ .identity = id, .point = point, .emitted = emitted };
            self.pending_reads += 1;
            break;
        };
        self.relations[index].?.reads += 1;
    }
    /// Only the two actual FIFO scan streams use this path. Dependencies
    /// proves publication -> read; JobCuts independently retains both sides of
    /// the observed state interval. Every actual read keeps its lower edge,
    /// total Relation.reads count and the caller's exact value comparator.
    pub fn orderedRead(self: *Dependencies, id: Identity, point: Point) Error!void {
        errdefer self.failed = true;
        try self.charge();
        try self.selectReadMode(.ordered);
        if (id.index >= max_resource_slots or point.index != id.index or point.generation != 0 or
            point.edge != .before or point.operation == 0 or point.occurrence == 0) return error.InvalidEvidence;
        const stream_index: usize = switch (id.domain) {
            .job_selected => if (point.role == .worker and point.site == .worker_scan) 0 else return error.InvalidEvidence,
            .job_completed => if (point.role == .control and point.site == .acceptance_scan) 1 else return error.InvalidEvidence,
            else => return error.InvalidEvidence,
        };
        const watermark = &self.ordered_watermarks[stream_index][id.index];
        if (watermark.operation != 0) {
            if (point.operation == watermark.operation and point.occurrence == watermark.occurrence) return error.DuplicateAcquisition;
            if (point.operation < watermark.operation or
                (point.operation == watermark.operation and point.occurrence < watermark.occurrence)) return error.InvalidOrder;
        }
        const index = try self.relation(id);
        if (self.relations[index].?.acquisition != null) return error.DuplicateAcquisition;
        const reads = std.math.add(u32, self.relations[index].?.reads, 1) catch return error.WorkBudget;
        var emitted = false;
        if (self.relations[index].?.publication) |published| {
            // Failure here leaves every existing representative and credit.
            try self.emit(published, point);
            emitted = true;
        }
        var reuse: ?usize = null;
        if (emitted) for (self.pending[0..self.localCapacity()], 0..) |item, pending_index| if (item) |prior| {
            if (prior.emitted and std.meta.eql(prior.identity, id)) {
                reuse = pending_index;
                break;
            }
        };
        if (reuse) |pending_index| {
            self.pending[pending_index] = .{ .identity = id, .point = point, .emitted = true };
        } else {
            var inserted = false;
            for (self.pending[0..self.localCapacity()]) |*item| if (item.* == null) {
                try self.reservePending();
                item.* = .{ .identity = id, .point = point, .emitted = emitted };
                self.pending_reads += 1;
                inserted = true;
                break;
            };
            if (!inserted) return error.DependencyCapacity;
        }
        self.relations[index].?.reads = reads;
        watermark.* = .{ .operation = point.operation, .occurrence = point.occurrence };
    }
    pub fn consume(self: *Dependencies, id: Identity, point: Point) Error!void {
        errdefer self.failed = true;
        try self.charge();
        if (point.edge != .before or point.operation == 0) return error.InvalidEvidence;
        const index = try self.relation(id);
        if (self.relations[index].?.acquisition != null) return error.DuplicateAcquisition;
        self.relations[index].?.acquisition = point;
        try self.settle(index);
    }
    pub fn finish(self: *const Dependencies) Error!void {
        if (self.failed) return error.Incomplete;
        for (self.relations) |entry| if (entry) |value| {
            if (value.publication == null) return error.MissingPublication;
            if (value.acquisition == null) return error.MissingAcquisition;
        };
        if (self.pending_reads != 0 or self.live != 0 or self.pending_total != 0) return error.Incomplete;
    }
};

pub const Summary = struct {
    records: u64,
    operations: [3]u64,
    witness_events: [4]u64,
    matched_handoffs: u64,
    dependencies: u64,
    pending_high_water: usize,
    work: u64,
    /// Validation is necessary evidence only; real replay/PCM qualification is
    /// owned by ReplaySession, and is never promoted by this summary.
    replay_qualified: bool = false,
};

/// Actual monotonic atomic prefixes need both sides of a cut: the observed
/// release precedes the load, and the load precedes the next release. Missing
/// upper bounds are permitted only after the source terminal confirms there is
/// no later release. File order is never used to choose either side.
pub const Prefix = struct {
    const Published = struct { value: u64, point: Point };
    const Read = struct { value: u64, before: Point, lower: bool = false, upper: bool = false };
    initial: u64,
    latest: u64,
    capacity: usize,
    publications: [max_pending]?Published = @splat(null),
    reads: [max_pending]?Read = @splat(null),
    publication_count: u64 = 0,
    closed: bool = false,
    failed: bool = false,
    pub fn init(initial: u64, capacity: u32) Error!Prefix {
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        return .{ .initial = initial, .latest = initial, .capacity = capacity };
    }
    /// Pinned callers avoid the fixed publication/read arrays as return-value
    /// temporaries, including when several Prefix values share one owner.
    pub fn initInto(self: *Prefix, initial: u64, capacity: u32) Error!void {
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        self.initial = initial;
        self.latest = initial;
        self.capacity = capacity;
        for (&self.publications) |*entry| entry.* = null;
        for (&self.reads) |*entry| entry.* = null;
        self.publication_count = 0;
        self.closed = false;
        self.failed = false;
    }
    fn resolve(self: *Prefix, deps: *Dependencies, index: usize) Error!void {
        var read = self.reads[index] orelse return;
        var lower: ?Published = null;
        var upper: ?Published = null;
        for (self.publications[0..self.capacity]) |item| if (item) |p| {
            try deps.charge();
            if (p.value == read.value) lower = p;
            if (p.value > read.value and (upper == null or p.value < upper.?.value)) upper = p;
        };
        if (!read.lower) {
            if (read.value == self.initial) read.lower = true else if (lower) |p| {
                try deps.emit(p.point, read.before);
                read.lower = true;
            } else if (read.value <= self.latest and upper != null) return error.MissingPublication;
        }
        if (!read.upper) if (upper) |p| {
            var after_read = read.before;
            after_read.edge = .after;
            var before_publish = p.point;
            before_publish.edge = .before;
            try deps.emit(after_read, before_publish);
            read.upper = true;
        };
        if (read.lower and (read.upper or self.closed)) {
            self.reads[index] = null;
            deps.releasePending();
        } else self.reads[index] = read;
    }
    pub fn publish(self: *Prefix, deps: *Dependencies, value: u64, point: Point) Error!void {
        errdefer self.failed = true;
        if (self.closed or value <= self.latest or point.edge != .after) return error.DuplicatePublication;
        const index: usize = @intCast(self.publication_count % self.capacity);
        if (self.publications[index]) |old| {
            // Never silently overwrite the lower end of an unresolved cut.
            for (self.reads) |item| if (item) |read| if (!read.lower and read.value <= old.value) return error.DependencyCapacity;
        }
        self.publications[index] = .{ .value = value, .point = point };
        self.publication_count += 1;
        self.latest = value;
        for (0..self.capacity) |i| try self.resolve(deps, i);
    }
    pub fn acquire(self: *Prefix, deps: *Dependencies, value: u64, point: Point) Error!void {
        errdefer self.failed = true;
        if (point.edge != .before or value < self.initial) return error.InvalidEvidence;
        for (self.reads) |item| if (item) |read| if (std.meta.eql(read.before, point)) return error.DuplicateAcquisition;
        for (self.reads[0..self.capacity], 0..) |item, index| if (item) |prior| {
            if (prior.value == value and prior.lower and !prior.upper and laterSameRead(prior.before, point)) {
                // The old lower edge is already emitted (or initial). Its
                // upper wait follows from old read < later read < next store.
                // Resolve the new lower independently; keep every comparator.
                self.reads[index] = .{ .value = value, .before = point };
                try self.resolve(deps, index);
                return;
            }
        };
        for (self.reads[0..self.capacity], 0..) |item, index| if (item == null) {
            try deps.reservePending();
            self.reads[index] = .{ .value = value, .before = point };
            try self.resolve(deps, index);
            return;
        };
        return error.DependencyCapacity;
    }
    /// Only for one independently established global atomic in one Service/
    /// session. Checkpoint site/index/generation do not partition that atomic.
    /// Later same-role operations order every earlier load, whereas same-call
    /// cross-site loads retain their independent upper obligations.
    pub fn acquireGlobal(self: *Prefix, deps: *Dependencies, value: u64, point: Point) Error!void {
        errdefer self.failed = true;
        if (point.operation == 0) return error.UnboundOperation;
        if (point.edge != .before or value < self.initial) return error.InvalidEvidence;
        for (self.reads) |item| if (item) |read| if (std.meta.eql(read.before, point)) return error.DuplicateAcquisition;
        var reuse: ?usize = null;
        for (self.reads[0..self.capacity], 0..) |*item, index| if (item.*) |prior| {
            if (prior.before.operation == 0 or prior.value != value or !prior.lower or prior.upper or prior.before.role != point.role) continue;
            if (point.operation <= prior.before.operation and !laterSameRead(prior.before, point)) continue;
            // Each discarded upper wait follows from old load < new load <
            // next store. Keep one existing credit and return every extra one.
            item.* = null;
            if (reuse == null) reuse = index else deps.releasePending();
        };
        if (reuse) |index| {
            // Never borrow an old lower edge: resolve this actual load anew.
            // Callers still emit its exact value comparator independently.
            self.reads[index] = .{ .value = value, .before = point };
            try self.resolve(deps, index);
            return;
        }
        return self.acquire(deps, value, point);
    }
    pub fn close(self: *Prefix, deps: *Dependencies, final_value: u64) Error!void {
        errdefer self.failed = true;
        if (self.closed or final_value != self.latest) return error.InvalidEvidence;
        self.closed = true;
        for (0..self.capacity) |index| try self.resolve(deps, index);
        for (self.reads) |item| if (item != null) return error.MissingPublication;
    }
    pub fn finish(self: *const Prefix) Error!void {
        if (self.failed or !self.closed) return error.Incomplete;
        for (self.reads) |item| if (item != null) return error.MissingPublication;
    }
};

/// The two independently acquired completion queue cursors. A successful pop
/// observes the entire write prefix, not just the cell it consumes. Empty pops
/// and producer space reads need upper bounds too.
/// Public v1 has no queue prelude: both cursors start at zero, as do the existing
/// Validator completion counters. A nonzero first cursor is not a seed value.
pub const CompletionCuts = struct {
    writes: Prefix,
    returns: Prefix,
    enqueued: u64 = 0,
    consumed: u64 = 0,
    failed: bool = false,

    pub fn init(capacity: u32) Error!CompletionCuts {
        return .{ .writes = try Prefix.init(0, capacity), .returns = try Prefix.init(0, capacity) };
    }
    pub fn initInto(self: *CompletionCuts, capacity: u32) Error!void {
        try self.writes.initInto(0, capacity);
        try self.returns.initInto(0, capacity);
        self.enqueued = 0;
        self.consumed = 0;
        self.failed = false;
    }
    pub fn enqueue(self: *CompletionCuts, deps: *Dependencies, read: u64, write: u64, after: u64, space: Point, release: Point) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (!validPoint(space, .completion_space, .before, .render) or !validPoint(release, .completion_enqueue, .after, .render) or space.operation != release.operation) return error.InvalidEvidence;
        if (write != self.enqueued or after != try add(write, 1) or read > write or write - read >= rt.max_instances) return error.InvalidEvidence;
        try self.returns.acquire(deps, read, space);
        try self.writes.publish(deps, after, release);
        self.enqueued = after;
    }
    pub fn pop(self: *CompletionCuts, deps: *Dependencies, read: u64, write: u64, after: u64, present: bool, acquired: Point, returned: ?Point) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (!validPoint(acquired, .completion_pop, .before, .control)) return error.InvalidEvidence;
        if (returned) |release| if (!validPoint(release, .completion_return, .after, .control) or acquired.operation != release.operation) return error.InvalidEvidence;
        if (read != self.consumed or write < read or write - read > rt.max_instances or present != (write > read) or after != try add(read, @intFromBool(present)) or present != (returned != null)) return error.InvalidEvidence;
        try self.writes.acquire(deps, write, acquired);
        if (returned) |release| try self.returns.publish(deps, after, release);
        self.consumed = after;
    }
    pub fn finish(self: *CompletionCuts, deps: *Dependencies) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (self.enqueued != self.consumed) return error.MissingAcquisition;
        try self.writes.close(deps, self.enqueued);
        try self.returns.close(deps, self.consumed);
        try self.writes.finish();
        try self.returns.finish();
    }
    fn validPoint(at: Point, site: Site, edge: Edge, role: format.Role) bool {
        return at.site == site and at.edge == edge and at.role == role and at.operation != 0 and at.occurrence != 0 and at.index == 0 and at.generation == 0;
    }
};

/// Exact one-shot pin lifetime: initial zero, one full-mask release, then one
/// bit returned per release. Mask values are not monotonic atomic prefixes.
/// The caller must establish initial versus returned zero from real ownership
/// facts; observing zero alone cannot select a side of the lifetime.
pub const PinCuts = struct {
    pub const Zero = enum { initial, returned };
    const Store = struct { mask: u16, at: Point };
    const Read = struct { mask: u16, zero: Zero, at: Point, lower: bool = false, upper: bool = false };
    index: u16,
    generation: u64,
    capacity: usize,
    stores: [17]Store = undefined,
    store_count: usize = 0,
    reads: [max_pending]?Read = @splat(null),
    closed: bool = false,
    failed: bool = false,

    pub fn init(index: u16, generation: u64, capacity: u32) Error!PinCuts {
        if (index >= max_resource_slots or generation == 0) return error.InvalidEvidence;
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        return .{ .index = index, .generation = generation, .capacity = capacity };
    }
    fn identityMatches(self: *const PinCuts, at: Point) bool {
        return at.index == self.index and at.generation == self.generation and at.operation != 0 and at.occurrence != 0;
    }
    fn resolve(self: *PinCuts, deps: *Dependencies) Error!void {
        for (&self.reads) |*item| if (item.*) |sample| {
            item.* = try resolveRead(deps, self.stores[0..self.store_count], self.closed, sample);
            if (item.* == null) deps.releasePending();
        };
    }
    /// Shared by the standalone cut tests and the bounded group-lifetime
    /// ledger. Storage order here is the one Render producer's actual order.
    fn resolveRead(deps: *Dependencies, stores: []const Store, closed: bool, sample: Read) Error!?Read {
        var read = sample;
        const initial = read.mask == 0 and read.zero == .initial;
        var source: ?usize = null;
        if (!initial) for (stores, 0..) |store, i| {
            try deps.charge();
            if (store.mask == read.mask) source = i;
        };
        if (!read.lower) {
            if (initial) read.lower = true else if (source) |i| {
                try deps.emit(stores[i].at, read.at);
                read.lower = true;
            } else if (closed) return error.MissingPublication;
        }
        const next: ?usize = if (initial) (if (stores.len != 0) 0 else null) else if (source) |i| (if (i + 1 < stores.len) i + 1 else null) else null;
        if (!read.upper) if (next) |i| {
            var after = read.at;
            after.edge = .after;
            var before = stores[i].at;
            before.edge = .before;
            try deps.emit(after, before);
            read.upper = true;
        };
        return if (read.lower and (read.upper or closed)) null else read;
    }
    pub fn publish(self: *PinCuts, deps: *Dependencies, mask: u16, at: Point) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (self.closed or self.store_count != 0 or mask == 0 or !self.identityMatches(at) or at.role != .render or at.edge != .after or at.site != .group_pin_publish) return error.InvalidEvidence;
        self.stores[0] = .{ .mask = mask, .at = at };
        self.store_count = 1;
        try self.resolve(deps);
    }
    pub fn release(self: *PinCuts, deps: *Dependencies, before: u16, after: u16, at: Point) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (self.closed or self.store_count == 0 or self.store_count == self.stores.len or !self.identityMatches(at) or at.edge != .after or at.site != .group_pin_return) return error.InvalidEvidence;
        const previous = self.stores[self.store_count - 1];
        if (previous.mask != before or after & ~before != 0 or @popCount(before ^ after) != 1 or previous.at.role != at.role or at.operation < previous.at.operation) return error.InvalidEvidence;
        if (at.operation == previous.at.operation and at.site == previous.at.site and at.occurrence <= previous.at.occurrence) return error.InvalidEvidence;
        self.stores[self.store_count] = .{ .mask = after, .at = at };
        self.store_count += 1;
        try self.resolve(deps);
    }
    pub fn acquire(self: *PinCuts, deps: *Dependencies, mask: u16, zero: Zero, at: Point) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (!self.identityMatches(at) or at.role != .control or at.edge != .before or at.site != .group_pin_read) return error.InvalidEvidence;
        for (self.reads) |item| if (item) |read| if (std.meta.eql(read.at, at)) return error.DuplicateAcquisition;
        for (self.reads[0..self.capacity]) |*item| if (item.* == null) {
            try deps.reservePending();
            item.* = .{ .mask = mask, .zero = zero, .at = at };
            try self.resolve(deps);
            return;
        };
        return error.DependencyCapacity;
    }
    /// Actual group retirement, never source EOF, closes the final upper cut.
    pub fn close(self: *PinCuts, deps: *Dependencies) Error!void {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (self.closed or self.store_count == 0 or self.stores[self.store_count - 1].mask != 0) return error.MissingAcquisition;
        self.closed = true;
        try self.resolve(deps);
    }
    pub fn finish(self: *const PinCuts) Error!void {
        if (self.failed or !self.closed) return error.Incomplete;
        for (self.reads) |item| if (item != null) return error.MissingPublication;
    }
};

/// Created only from the actual frontier collect_frame load and its checked
/// render_frames acquisition, never from accepted-frame/readiness metadata.
pub const CollectFrameProof = struct {
    frame: u64,
    at: Point,
    control_tick: u64,
    tick_serial: u64,
    sequence: u64,
};
pub const CollectFrameRead = struct {
    control_tick: u64 = 0,
    tick_serial: u64 = 0,
    plan_sequence: u64 = 0,
};
/// One bounded row per actual prepared-group lifetime and a shared read queue.
/// Group/instance preparation and Render resources may arrive in either lane
/// order. Every live row and every unresolved read uses the aggregate cap.
/// Returned zero requires a prior exact Control completion/nonzero prefix or
/// this invocation's frozen collect-frame acquire proving pin publication.
/// Late Render facts may resolve a frozen proof, but never supply a new one.
pub const GroupPins = struct {
    const Instance = struct { index: u16, generation: u64, reservation: u64 };
    const Release = struct { operation: u64, attempt: u64, refs_seen: bool = false, zero_proven: bool = false, zero_bound: bool = false, desired: u16 = 0 };
    const Consumed = struct { queue: u64, start_order: u64, reason: u8, pending: bool };
    const Group = struct {
        index: u16,
        generation: u64,
        bank_generation: u64 = 0,
        prepared: bool = false,
        voice_count: u16 = 0,
        instances: [16]?Instance = @splat(null),
        instance_mask: u16 = 0,
        start_order: u64 = 0,
        stores: [17]PinCuts.Store = undefined,
        store_count: usize = 0,
        publication_start_frame: ?u64 = null,
        completions: [16]?format.render.ResourceEvent = @splat(null),
        returned: u16 = 0,
        release_attempt: ?Release = null,
        consumed: [16]?Consumed = @splat(null),
        consumed_mask: u16 = 0,
        // Set only by this Control FIFO's accepted nonzero acquisition for
        // this exact generation. Not inferred from merged Render stores.
        nonzero_control_prefix: bool = false,
        leases: [16]u64 = @splat(0),
        lease_mask: u16 = 0,
        lease_seen: u16 = 0,
        lease_returned: u16 = 0,
        retired: bool = false,
    };
    const Pending = struct {
        index: u16,
        generation: u64,
        read: PinCuts.Read,
        // Immutable across desiredPending, later reads and completion pops.
        collect: ?CollectFrameProof = null,
        publication_bound: bool = false,
    };
    capacity: usize,
    groups: [max_pending]?Group = @splat(null),
    reads: [max_pending]?Pending = @splat(null),
    failed: bool = false,
    retired: [max_resource_slots]u64 = @splat(0),

    pub fn initInto(self: *GroupPins, capacity: u32) Error!void {
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        self.capacity = capacity;
        for (&self.groups) |*entry| entry.* = null;
        for (&self.reads) |*entry| entry.* = null;
        self.failed = false;
        @memset(&self.retired, 0);
    }
    fn group(self: *GroupPins, deps: *Dependencies, index: u16, generation: u64) Error!*Group {
        if (self.failed) return error.Incomplete;
        if (index >= max_resource_slots or generation == 0 or generation <= self.retired[index]) return error.StaleIdentity;
        for (self.groups[0..self.capacity]) |*entry| if (entry.*) |*value| {
            try deps.charge();
            if (value.index == index) {
                if (value.generation != generation) return error.UnrepresentedCut;
                return value;
            }
        };
        for (self.groups[0..self.capacity]) |*entry| if (entry.* == null) {
            try deps.reservePending();
            entry.* = .{ .index = index, .generation = generation };
            return &entry.*.?;
        };
        return error.DependencyCapacity;
    }
    fn maskFor(count: u16) u16 {
        return @intCast((@as(u32, 1) << @intCast(count)) - 1);
    }
    fn validateGroup(value: *const Group) Error!void {
        if (!value.prepared) return;
        const mask = maskFor(value.voice_count);
        if (value.instance_mask != mask or (value.store_count != 0 and value.stores[0].mask != mask)) return error.InvalidEvidence;
        for (value.completions, 0..) |completion, i| if (completion) |record| {
            const prepared_instance = value.instances[i] orelse return error.MissingPublication;
            if (prepared_instance.index != record.instance_index or prepared_instance.generation != record.instance_generation or prepared_instance.reservation != record.reservation or record.start_order != value.start_order) return error.StaleIdentity;
        };
    }
    pub fn instance(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation) Error!void {
        errdefer self.failed = true;
        if (record.kind != .instance_prepare or !record.returned or record.error_code != 0 or record.ordinal >= 16 or record.instance.index >= rt.max_instances or record.instance.generation == 0 or record.instance.generation > std.math.maxInt(u16) or record.reservation == 0) return error.InvalidEvidence;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        if (value.prepared or value.instances[record.ordinal] != null) return error.DuplicatePublication;
        for (self.groups[0..self.capacity]) |*entry| if (entry.*) |*other| {
            for (other.instances) |item| if (item) |prior| if (prior.index == record.instance.index) return error.StaleReference;
        };
        value.instances[record.ordinal] = .{ .index = record.instance.index, .generation = record.instance.generation, .reservation = record.reservation };
        value.instance_mask |= @as(u16, 1) << @intCast(record.ordinal);
    }
    pub fn prepare(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation) Error!void {
        errdefer self.failed = true;
        if (record.kind != .group_prepare or !record.returned or record.error_code != 0 or record.voice_count == 0 or record.voice_count > 16 or record.bank_generation == 0) return error.InvalidEvidence;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        if (value.prepared) return error.DuplicatePublication;
        if (value.bank_generation != 0 and value.bank_generation != record.bank_generation) return error.StaleIdentity;
        value.bank_generation = record.bank_generation;
        value.voice_count = record.voice_count;
        value.prepared = true;
        try validateGroup(value);
    }
    pub fn resource(self: *GroupPins, deps: *Dependencies, record: format.render.ResourceEvent, at: ?Point) Error!void {
        try self.resourceWithPublicationFrame(deps, record, at, null);
    }
    /// The Validator supplies both the outer event frame and its independently
    /// validated current Render span. Only in-gate publication precedes that
    /// span's frame store; after-gate pin returns have no such implication.
    pub fn publicationInGate(self: *GroupPins, deps: *Dependencies, record: format.render.ResourceEvent, at: Point, event_frame: u64, current_frame: u64) Error!void {
        errdefer self.failed = true;
        if (record.kind != .group_pin_publish or record.substage != .in_gate or event_frame != current_frame) return error.InvalidEvidence;
        try self.resourceWithPublicationFrame(deps, record, at, current_frame);
    }
    fn resourceWithPublicationFrame(self: *GroupPins, deps: *Dependencies, record: format.render.ResourceEvent, at: ?Point, publication_frame: ?u64) Error!void {
        errdefer self.failed = true;
        const value = try self.group(deps, record.group_index, record.group_generation);
        if (record.bank_generation == 0 or (value.bank_generation != 0 and value.bank_generation != record.bank_generation)) return error.StaleIdentity;
        value.bank_generation = record.bank_generation;
        switch (record.kind) {
            .group_pin_publish => {
                const p = at orelse return error.InvalidEvidence;
                if (value.store_count != 0 or record.mask_before != 0 or record.mask_after == 0 or record.start_order == 0 or (@as(u32, record.mask_after) & (@as(u32, record.mask_after) + 1)) != 0 or !pinPoint(value, p, .group_pin_publish)) return error.InvalidEvidence;
                value.start_order = record.start_order;
                value.publication_start_frame = publication_frame;
                value.stores[0] = .{ .mask = record.mask_after, .at = p };
                value.store_count = 1;
            },
            .completion_enqueue => {
                if (at != null or record.play_index >= 16 or value.store_count == 0 or record.instance_index >= rt.max_instances or record.instance_generation == 0 or record.reservation == 0 or record.start_order != value.start_order) return error.InvalidEvidence;
                const bit = @as(u16, 1) << @intCast(record.play_index);
                if (value.completions[record.play_index] != null or value.stores[value.store_count - 1].mask & bit == 0) return error.InvalidEvidence;
                value.completions[record.play_index] = record;
            },
            .group_pin_return => {
                const p = at orelse return error.InvalidEvidence;
                if (record.play_index >= 16 or value.store_count == 0 or value.store_count == value.stores.len or !pinPoint(value, p, .group_pin_return)) return error.InvalidEvidence;
                const completion = value.completions[record.play_index] orelse return error.MissingPublication;
                var expected = completion;
                expected.kind = .group_pin_return;
                expected.mask_before = record.mask_before;
                expected.mask_after = record.mask_after;
                if (!std.meta.eql(expected, record)) return error.StaleIdentity;
                const bit = @as(u16, 1) << @intCast(record.play_index);
                const previous = value.stores[value.store_count - 1];
                if (value.returned & bit != 0 or previous.mask != record.mask_before or record.mask_before & bit == 0 or record.mask_after != (record.mask_before & ~bit) or p.operation < previous.at.operation or (p.operation == previous.at.operation and p.site == previous.at.site and p.occurrence <= previous.at.occurrence)) return error.InvalidEvidence;
                value.returned |= bit;
                value.stores[value.store_count] = .{ .mask = record.mask_after, .at = p };
                value.store_count += 1;
            },
        }
        try validateGroup(value);
        try self.resolve(deps, value);
        try self.resolveConsumed(deps, value);
        try self.retireReady(deps);
    }
    fn pinPoint(value: *const Group, at: Point, site: Site) bool {
        return at.role == .render and at.site == site and at.edge == .after and at.index == value.index and at.generation == value.generation and at.operation != 0 and at.occurrence != 0;
    }
    fn resolve(self: *GroupPins, deps: *Dependencies, value: *const Group) Error!void {
        const all_pins_returned = value.store_count != 0 and value.stores[value.store_count - 1].mask == 0;
        for (self.reads[0..self.capacity]) |*entry| if (entry.*) |sample| {
            if (sample.index != value.index or sample.generation != value.generation) continue;
            try deps.charge();
            if (sample.collect) |collect| if (!sample.publication_bound) {
                if (value.store_count == 0) continue;
                const start_frame = value.publication_start_frame orelse return error.UnrepresentedCut;
                // Strictly later excludes the pre-publication/initial-zero
                // side. The existing Prefix still proves the actual frame
                // value, including its lower and upper bounds independently.
                if (collect.frame <= start_frame) return error.UnrepresentedCut;
                try deps.emit(value.stores[0].at, collect.at);
                entry.*.?.publication_bound = true;
            };
            // This separately requires the actual final pin return. A frame
            // acquire cannot prove any after-gate return precedes the pin read.
            if (try PinCuts.resolveRead(deps, value.stores[0..value.store_count], all_pins_returned, sample.read)) |pending| {
                entry.*.?.read = pending;
            } else {
                entry.* = null;
                deps.releasePending();
            }
        };
    }
    pub fn acquireNonzero(self: *GroupPins, deps: *Dependencies, bank_generation: u64, mask: u16, at: Point) Error!void {
        errdefer self.failed = true;
        if (mask == 0 or bank_generation == 0 or at.role != .control or at.site != .group_pin_read or at.edge != .before or at.index >= max_resource_slots or at.operation == 0 or at.occurrence == 0) return error.InvalidEvidence;
        const value = try self.group(deps, @intCast(at.index), at.generation);
        // These are one Control producer's records. A later release attempt
        // cannot supply the missing preparation of its own group generation.
        if (!value.prepared) return error.MissingPublication;
        if (mask & ~maskFor(value.voice_count) != 0) return error.InvalidEvidence;
        if (value.bank_generation != 0 and value.bank_generation != bank_generation) return error.StaleIdentity;
        value.bank_generation = bank_generation;
        for (self.reads[0..self.capacity]) |entry| if (entry) |sample| if (std.meta.eql(sample.read.at, at)) return error.DuplicateAcquisition;
        for (self.reads[0..self.capacity]) |*entry| if (entry.*) |sample| {
            if (sample.index == value.index and sample.generation == value.generation and sample.read.mask == mask and sample.read.lower and !sample.read.upper and laterSameRead(sample.read.at, at)) {
                entry.*.?.read = .{ .mask = mask, .zero = .returned, .at = at };
                try self.resolve(deps, value);
                value.nonzero_control_prefix = true;
                return;
            }
        };
        for (self.reads[0..self.capacity]) |*entry| if (entry.* == null) {
            try deps.reservePending();
            entry.* = .{ .index = value.index, .generation = value.generation, .read = .{ .mask = mask, .zero = .returned, .at = at } };
            try self.resolve(deps, value);
            value.nonzero_control_prefix = true;
            return;
        };
        return error.DependencyCapacity;
    }
    /// Freeze only proof already present in this Control producer prefix.
    /// A later nonzero read or completion never retroactively authorizes zero.
    pub fn beginRelease(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation, operation: u64, attempt: u64) Error!void {
        errdefer self.failed = true;
        const expected: format.readiness.Reconciliation = .{ .kind = .group_release, .handle = record.handle, .bank_generation = record.bank_generation, .pin_mask = 0 };
        if (operation == 0 or attempt == 0 or !std.meta.eql(record, expected)) return error.InvalidEvidence;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        if (!value.prepared or record.bank_generation != value.bank_generation) return error.StaleIdentity;
        if (value.release_attempt != null) return error.MissingAcquisition;
        try deps.reservePending();
        value.release_attempt = .{ .operation = operation, .attempt = attempt, .zero_proven = value.consumed_mask != 0 or value.nonzero_control_prefix };
    }
    /// Authorization is fixed at this Control read. A later completion pop can
    /// never turn an ambiguous earlier initial-zero observation into returned0.
    pub fn acquireReturnedZero(self: *GroupPins, deps: *Dependencies, handle: rt.scheduler.Handle, at: Point) Error!bool {
        return self.acquireReturnedZeroWithCollect(deps, handle, at, null, .{});
    }
    pub fn acquireReturnedZeroWithCollect(self: *GroupPins, deps: *Dependencies, handle: rt.scheduler.Handle, at: Point, collect: ?CollectFrameProof, prefix: CollectFrameRead) Error!bool {
        errdefer self.failed = true;
        const value = try self.group(deps, handle.index, handle.generation);
        const release = value.release_attempt orelse return error.MissingAcquisition;
        if (at.role != .control or at.edge != .before or at.site != .group_pin_read or at.index != handle.index or at.generation != handle.generation or at.occurrence == 0 or at.operation != release.operation or release.zero_bound) return error.InvalidEvidence;
        // Only a collect load already in this exact Control producer prefix
        // can classify zero. Later processed reads cannot repair an old cut.
        const frozen = if (release.zero_proven) null else collect;
        if (!release.zero_proven) {
            const proof = frozen orelse return false;
            if (proof.at.role != .control or proof.at.operation != at.operation or proof.at.site != .control_collect_frame or proof.at.edge != .before or proof.at.index != 0 or proof.at.generation != 0 or proof.at.occurrence != 1 or proof.control_tick == 0 or proof.control_tick != prefix.control_tick or proof.tick_serial == 0 or proof.tick_serial != prefix.tick_serial or proof.sequence == 0 or proof.sequence > prefix.plan_sequence) return error.InvalidEvidence;
        }
        for (self.reads[0..self.capacity]) |*entry| if (entry.* == null) {
            try deps.reservePending();
            entry.* = .{ .index = handle.index, .generation = handle.generation, .read = .{ .mask = 0, .zero = .returned, .at = at }, .collect = frozen };
            // The charged Pending row remains until both publication proof
            // and returned-zero cut resolve, even after release cleanup.
            value.release_attempt.?.zero_proven = true;
            value.release_attempt.?.zero_bound = true;
            try self.resolve(deps, value);
            return true;
        };
        return error.DependencyCapacity;
    }
    fn resolveConsumed(_: *GroupPins, deps: *Dependencies, value: *Group) Error!void {
        for (&value.consumed, 0..) |*entry, ordinal| if (entry.*) |consumed| {
            try deps.charge();
            const completion = value.completions[ordinal] orelse continue;
            if (completion.queue_write != consumed.queue or completion.start_order != consumed.start_order or completion.completion_reason != consumed.reason) return error.StaleIdentity;
            if (consumed.pending) {
                entry.*.?.pending = false;
                deps.releasePending();
            }
        };
    }
    pub fn consumeCompletion(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation) Error!void {
        errdefer self.failed = true;
        if (!record.present) return;
        if (!record.returned or record.error_code != 0 or record.instance_current != true or record.desired_active != true or record.instance_matches != true or !record.release_attempted or record.release_cas != null or record.start_order == null or record.desired_start_order != record.start_order) return error.UnrepresentedCut;
        if (record.instance.generation > std.math.maxInt(u16) or record.instance_state != ((@as(u32, 1) << 31) | @as(u32, @intCast(record.instance.generation)))) return error.InvalidEvidence;
        var found = false;
        for (self.groups[0..self.capacity]) |*entry| if (entry.*) |*value| {
            try deps.charge();
            for (value.instances, 0..) |instance_value, ordinal| if (instance_value) |prepared_instance| {
                if (prepared_instance.index != record.instance.index or prepared_instance.generation != record.instance.generation) continue;
                if (found or !value.prepared or prepared_instance.reservation != record.reservation or value.consumed[ordinal] != null) return error.StaleIdentity;
                found = true;
                const pending = value.completions[ordinal] == null;
                if (pending) try deps.reservePending();
                value.consumed[ordinal] = .{ .queue = record.read_position, .start_order = record.start_order.?, .reason = record.completion_reason, .pending = pending };
                value.consumed_mask |= @as(u16, 1) << @intCast(ordinal);
                try self.resolveConsumed(deps, value);
            };
        };
        if (!found) return error.MissingPublication;
    }
    pub fn lease(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation) Error!void {
        errdefer self.failed = true;
        if (record.ordinal >= 16 or record.stream.generation == 0 or !record.returned or record.error_code != 0) return error.InvalidEvidence;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        const bit = @as(u16, 1) << @intCast(record.ordinal);
        switch (record.kind) {
            .initial_stream_retain => {
                if (value.prepared or value.lease_seen & bit != 0) return error.DuplicatePublication;
                try deps.reservePending();
                value.leases[record.ordinal] = record.stream.generation;
                value.lease_seen |= bit;
                value.lease_mask |= bit;
            },
            .initial_stream_return => {
                const release = value.release_attempt orelse return error.MissingAcquisition;
                if (!release.zero_proven or !release.refs_seen or record.bank_generation != value.bank_generation or value.lease_mask & bit == 0 or value.leases[record.ordinal] != record.stream.generation or value.lease_returned & bit != 0) return error.StaleIdentity;
                value.lease_mask &= ~bit;
                value.lease_returned |= bit;
                deps.releasePending();
            },
            else => return error.InvalidEvidence,
        }
    }
    pub fn desiredInactive(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation, operation: u64) Error!void {
        errdefer self.failed = true;
        if (record.ordinal >= 16 or record.start_scheduled != true or record.desired_active != false or record.reservation_matches != null or record.error_code != 0) return error.UnrepresentedCut;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        const release = value.release_attempt orelse return error.MissingAcquisition;
        if (!release.zero_proven or !release.refs_seen or release.operation != operation or release.attempt != record.parent_attempt) return error.InvalidEvidence;
        const bit = @as(u16, 1) << @intCast(record.ordinal);
        const prepared_instance = value.instances[record.ordinal] orelse return error.MissingPublication;
        if (record.ordinal >= value.voice_count or prepared_instance.index != record.instance.index or prepared_instance.generation != record.instance.generation or prepared_instance.reservation != record.reservation or value.consumed_mask & bit == 0 or release.desired & bit != 0) return error.StaleIdentity;
        value.release_attempt.?.desired |= bit;
    }
    pub fn returnGroup(self: *GroupPins, deps: *Dependencies, handle: rt.scheduler.Handle, operation: u64) Error!void {
        errdefer self.failed = true;
        const value = try self.group(deps, handle.index, handle.generation);
        const release = value.release_attempt orelse return error.MissingAcquisition;
        const all = maskFor(value.voice_count);
        if (!value.prepared or value.retired or release.operation != operation or !release.zero_proven or !release.zero_bound or !release.refs_seen or release.desired != all or value.consumed_mask != all or value.lease_mask != 0 or value.lease_seen != all or value.lease_returned != all) return error.MissingAcquisition;
        // Keep the aggregate-charged row if Render resources are still late.
        value.retired = true;
        try self.retireReady(deps);
    }
    pub fn validateReturn(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation, operation: u64) Error!void {
        errdefer self.failed = true;
        const expected: format.readiness.Reconciliation = .{ .kind = .group_release, .handle = record.handle, .parent_attempt = record.parent_attempt, .bank_generation = record.bank_generation, .returned = true };
        if (!std.meta.eql(expected, record)) return error.InvalidEvidence;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        const release = value.release_attempt orelse return error.MissingAcquisition;
        if (release.operation != operation or release.attempt != record.parent_attempt or value.bank_generation != record.bank_generation) return error.StaleIdentity;
    }
    fn retireReady(self: *GroupPins, deps: *Dependencies) Error!void {
        for (self.groups[0..self.capacity]) |*entry| if (entry.*) |*value| {
            try deps.charge();
            if (!value.retired or value.store_count == 0 or value.returned != maskFor(value.voice_count) or value.stores[value.store_count - 1].mask != 0) continue;
            var pending = false;
            for (value.consumed) |consumed| if (consumed) |v| if (v.pending) {
                pending = true;
            };
            for (self.reads[0..self.capacity]) |read| if (read) |v| if (v.index == value.index and v.generation == value.generation) {
                pending = true;
            };
            if (pending) continue;
            self.retired[value.index] = value.generation;
            if (value.release_attempt != null) deps.releasePending();
            deps.releasePending();
            entry.* = null;
        };
    }
    pub fn releaseRefs(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation, operation: u64) Error!void {
        errdefer self.failed = true;
        const expected: format.readiness.Reconciliation = .{ .kind = .group_release, .handle = record.handle, .parent_attempt = record.parent_attempt, .references = 0 };
        if (!std.meta.eql(record, expected)) return error.InvalidEvidence;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        const release = value.release_attempt orelse return error.MissingAcquisition;
        if (release.operation != operation or release.attempt != record.parent_attempt or release.refs_seen) return error.InvalidEvidence;
        value.release_attempt.?.refs_seen = true;
    }
    /// This minimal observed failure is the first play's early return. Later
    /// ordinal failures still require matching their preceding desired reads.
    pub fn desiredPending(self: *GroupPins, deps: *Dependencies, record: format.readiness.Reconciliation, operation: u64) Error!void {
        errdefer self.failed = true;
        if (!format.groupDesiredPending(record)) return error.UnrepresentedCut;
        const value = try self.group(deps, record.handle.index, record.handle.generation);
        if (!value.prepared or record.ordinal != 0) return error.UnrepresentedCut;
        const release = value.release_attempt orelse return error.MissingAcquisition;
        if (release.operation != operation or release.attempt != record.parent_attempt or !release.refs_seen) return error.InvalidEvidence;
        const instance_value = value.instances[record.ordinal] orelse return error.MissingPublication;
        if (instance_value.index != record.instance.index or instance_value.generation != record.instance.generation or instance_value.reservation != record.reservation) return error.StaleIdentity;
        value.release_attempt = null;
        deps.releasePending();
    }
    pub fn finish(self: *const GroupPins) Error!void {
        if (self.failed) return error.Incomplete;
        for (self.groups) |entry| if (entry) |value| {
            if (!value.prepared or value.store_count == 0) return error.MissingPublication;
            // No final group ownership return is inferred by this slice.
            return error.MissingAcquisition;
        };
    }
};

pub const JobStage = enum(u2) { queued, running, completed, free };
/// Actual Control positions, independent of the acceptance/readiness merge.
pub const JobOwnerPosition = struct { operation: u64, attempt: u64, acceptance_sequence: u64 };
pub const JobOwnerFree = struct { operation: u64, acceptance_sequence: u64 };
const JobTransition = struct {
    index: u16,
    job: u64,
    points: [4]?Point = @splat(null),
    pending: bool = true,
    owner: ?stream.readiness_observation.Handle = null,
    requested: ?JobOwnerPosition = null,
    freed: ?JobOwnerFree = null,
    owner_binding_closed: bool = false,
};
pub const JobReadOrder = union(enum) { acceptance: u64, readiness: u64 };
const JobRead = struct { credit: JobReadCredit = if (partition_compiled) false else {}, seen_sites: [2]?Point = @splat(null), order: ?JobReadOrder = null, index: u16, job: u64, state: JobStage, at: Point, lower: bool = false, upper: bool = false, owner_position: ?JobOwnerPosition = null };
/// A slot address never identifies a state lifetime. Actual queued/completed
/// descriptors and each role's own prior ownership select the job generation.
/// A missing transition cannot be repaired by a later all-free snapshot.
pub const JobCuts = struct {
    capacity: usize,
    rows: [max_pending]?JobTransition = @splat(null),
    reads: [max_pending]?JobRead = @splat(null),
    worker_selected: [max_resource_slots]u64 = @splat(0),
    retired: [max_resource_slots]u64 = @splat(0),
    pub fn init(capacity: u32) Error!JobCuts {
        var result: JobCuts = undefined;
        try result.initInto(capacity);
        return result;
    }
    pub fn initInto(self: *JobCuts, capacity: u32) Error!void {
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        self.capacity = capacity;
        for (&self.rows) |*entry| entry.* = null;
        for (&self.reads) |*entry| entry.* = null;
        for (&self.worker_selected) |*entry| entry.* = 0;
        for (&self.retired) |*entry| entry.* = 0;
    }
    fn row(self: *JobCuts, deps: *Dependencies, index: u16, job: u64) Error!usize {
        if (index >= max_resource_slots or job == 0) return error.StaleReference;
        for (self.rows[0..self.capacity], 0..) |item, i| if (item) |v| {
            if (v.index == index and v.job == job) return i;
        };
        if (job <= self.retired[index]) return error.StaleReference;
        for (self.rows[0..self.capacity], 0..) |item, i| if (item == null) {
            try deps.reservePending();
            self.rows[i] = .{ .index = index, .job = job };
            return i;
        };
        return error.DependencyCapacity;
    }
    fn complete(value: JobTransition) bool {
        for (value.points) |at| if (at == null) return false;
        return value.owner == null or (value.requested != null and value.freed != null and value.owner_binding_closed);
    }
    fn releaseCredit(deps: *Dependencies, value: *JobTransition) void {
        if (value.pending and complete(value.*)) {
            value.pending = false;
            deps.releasePending();
        }
    }
    fn requestBefore(requested: JobOwnerPosition, observed: JobOwnerPosition) bool {
        return requested.operation < observed.operation or (requested.operation == observed.operation and requested.attempt < observed.attempt);
    }
    fn freeBefore(freed: JobOwnerFree, observed: JobOwnerPosition) bool {
        return freed.operation < observed.operation or (freed.operation == observed.operation and freed.acceptance_sequence <= observed.acceptance_sequence);
    }
    fn owner(self: *JobCuts, deps: *Dependencies, index: u16, job: u64, handle: stream.readiness_observation.Handle) Error!*JobTransition {
        if (handle.index >= max_resource_slots or handle.generation == 0) return error.StaleIdentity;
        const value = &self.rows[try self.row(deps, index, job)].?;
        if (value.owner) |known| {
            if (!std.meta.eql(known, handle)) return error.StaleIdentity;
        } else {
            // Usually the row still has its original credit. Even a late
            // metadata attachment must never create an uncharged hold.
            if (!value.pending) {
                try deps.reservePending();
                value.pending = true;
            }
            value.owner = handle;
        }
        return value;
    }
    pub fn publishQueued(self: *JobCuts, deps: *Dependencies, index: u16, job: u64, handle: stream.readiness_observation.Handle, requested: JobOwnerPosition, at: Point) Error!void {
        if (requested.operation == 0 or requested.attempt == 0 or requested.acceptance_sequence == 0 or at.role != .control or at.site != .job_queued or at.operation != requested.operation or at.index != index or at.generation != job or at.edge != .after or at.occurrence == 0) return error.InvalidEvidence;
        const value = try self.owner(deps, index, job, handle);
        if (value.requested != null) return error.DuplicatePublication;
        if (value.freed) |freed| if (freeBefore(freed, requested)) return error.StaleReference;
        // A queued successor may coexist with held history, but cannot borrow
        // that older slot or stream before its actual acceptance freed it.
        for (self.rows[0..self.capacity]) |entry| if (entry) |prior| {
            try deps.charge();
            if (prior.job == job and prior.index == index) continue;
            const same_owner = if (prior.owner) |known| std.meta.eql(known, handle) else false;
            if (prior.index != index and !same_owner) continue;
            if (prior.job >= job) {
                // Worker facts may run ahead of both Control rings. A future
                // row without its request is not a claimed prior owner.
                if (prior.requested == null) continue;
                return error.FutureReference;
            }
            const freed = prior.freed orelse return error.MissingAcquisition;
            if (!freeBefore(freed, requested)) return error.StaleReference;
        };
        value.requested = requested;
        try self.publish(deps, index, job, .queued, at);
    }
    pub fn publishFree(self: *JobCuts, deps: *Dependencies, index: u16, job: u64, handle: stream.readiness_observation.Handle, freed: JobOwnerFree, at: Point) Error!void {
        if (freed.operation == 0 or freed.acceptance_sequence == 0 or at.role != .control or at.site != .job_free or at.operation != freed.operation or at.index != index or at.generation != job or at.edge != .after or at.occurrence == 0) return error.InvalidEvidence;
        const value = try self.owner(deps, index, job, handle);
        if (value.freed != null) return error.DuplicatePublication;
        if (value.requested) |requested| if (freeBefore(freed, requested)) return error.StaleReference;
        value.freed = freed;
        try self.publish(deps, index, job, .free, at);
    }
    /// Called only after all three real Control producer closes have arrived.
    /// The row's existing credit protects late readiness reads of this owner.
    pub fn closeOwnerBinding(self: *JobCuts, deps: *Dependencies, operation: u64) Error!void {
        if (operation == 0) return error.UnboundOperation;
        for (self.rows[0..self.capacity]) |*entry| if (entry.*) |*value| {
            try deps.charge();
            const freed = value.freed orelse continue;
            if (freed.operation != operation) continue;
            if (value.owner_binding_closed) return error.DuplicateAcquisition;
            if (value.requested == null) return error.MissingPublication;
            value.owner_binding_closed = true;
            releaseCredit(deps, value);
        };
        try self.resolve(deps, false);
    }
    fn source(self: *const JobCuts, index: u16, job: u64, state: JobStage) ?Point {
        for (self.rows[0..self.capacity]) |item| if (item) |v| {
            if (v.index == index and v.job == job) return v.points[@intFromEnum(state)];
        };
        return null;
    }
    fn nextQueue(self: *const JobCuts, index: u16, job: u64) ?Point {
        var next: ?JobTransition = null;
        for (self.rows[0..self.capacity]) |item| if (item) |v| {
            if (v.index == index and v.job > job and (next == null or v.job < next.?.job)) next = v;
        };
        return if (next) |v| v.points[0] else null;
    }
    fn resolveRead(self: *JobCuts, deps: *Dependencies, index: usize, final: bool) Error!void {
        var value = self.reads[index] orelse return;
        try deps.charge();
        if (value.owner_position) |observed| {
            const owned = self.rows[try self.row(deps, value.index, value.job)].?;
            const requested = owned.requested orelse return error.MissingPublication;
            if (!requestBefore(requested, observed)) return error.FutureReference;
            if (!value.lower) if (owned.points[@intFromEnum(JobStage.queued)]) |at| {
                try deps.emit(at, value.at);
                value.lower = true;
            };
            if (!value.upper) if (owned.freed) |freed| {
                if (freeBefore(freed, observed)) return error.StaleReference;
                if (owned.points[@intFromEnum(JobStage.free)]) |at| {
                    var after = value.at;
                    after.edge = .after;
                    var before = at;
                    before.edge = .before;
                    try deps.emit(after, before);
                    value.upper = true;
                }
            };
            if (value.lower and value.upper) {
                self.reads[index] = null;
                deps.releaseJobRead(value);
            } else self.reads[index] = value;
            return;
        }
        if (!value.lower) {
            if (value.state == .free and value.job == 0) value.lower = true else if (self.source(value.index, value.job, value.state)) |p| {
                try deps.emit(p, value.at);
                value.lower = true;
            }
        }
        if (!value.upper) {
            const next = if (value.state == .free) self.nextQueue(value.index, value.job) else self.source(value.index, value.job, @enumFromInt(@intFromEnum(value.state) + 1));
            if (next) |p| {
                var after_load = value.at;
                after_load.edge = .after;
                var before_store = p;
                before_store.edge = .before;
                try deps.emit(after_load, before_store);
                value.upper = true;
            } else if (final and value.state == .free) value.upper = true;
        }
        if (value.lower and value.upper) {
            self.reads[index] = null;
            deps.releaseJobRead(value);
        } else self.reads[index] = value;
    }
    fn resolve(self: *JobCuts, deps: *Dependencies, final: bool) Error!void {
        for (0..self.capacity) |index| try self.resolveRead(deps, index, final);
        // Worker selecting a newer generation proves its prior scans occurred.
        // Control queued that newer generation only after its own prior free.
        for (&self.rows) |*item| if (item.*) |value| {
            if (value.job >= self.worker_selected[value.index]) continue;
            if (value.pending or !complete(value)) continue;
            var held = false;
            for (self.reads) |sample| if (sample) |r| if (r.index == value.index and r.job == value.job) {
                held = true;
                break;
            };
            if (!held) {
                self.retired[value.index] = @max(self.retired[value.index], value.job);
                item.* = null;
            }
        };
    }
    pub fn publish(self: *JobCuts, deps: *Dependencies, index: u16, job: u64, state: JobStage, at: Point) Error!void {
        const i = try self.row(deps, index, job);
        if (at.edge != .after or self.rows[i].?.points[@intFromEnum(state)] != null) return error.DuplicatePublication;
        self.rows[i].?.points[@intFromEnum(state)] = at;
        releaseCredit(deps, &self.rows[i].?);
        if (state == .running) {
            if (job <= self.worker_selected[index]) return error.StaleReference;
            self.worker_selected[index] = job;
        }
        try self.resolve(deps, false);
    }
    fn seenSite(at: Point) ?usize {
        if (at.role != .control) return null;
        return switch (at.site) {
            .acceptance_scan => 0,
            .readiness_job => 1,
            else => null,
        };
    }
    fn mergeSeen(keep: JobRead, remove: JobRead, incoming: Point) ?[2]?Point {
        var seen = keep.seen_sites;
        for (remove.seen_sites, 0..) |candidate, index| if (candidate) |at| {
            if (seen[index]) |known| {
                if (std.meta.eql(known, at)) continue;
                // Only a newly received, strictly later SAME-site read may
                // advance that site's identity marker: this is the existing
                // base same-site compression boundary. Cross-site dominance
                // alone cannot erase either distinct protected identity.
                if ((seenSite(incoming) orelse 2) == index and
                    (std.meta.eql(known, incoming) or laterSameRead(known, incoming)) and
                    (std.meta.eql(at, incoming) or laterSameRead(at, incoming)))
                {
                    seen[index] = incoming;
                } else return null;
            } else seen[index] = at;
        };
        return seen;
    }
    fn beforeRead(prior: JobRead, later: JobRead) bool {
        if (prior.at.role != later.at.role or prior.at.index != later.at.index or prior.at.generation != later.at.generation) return false;
        if (prior.at.operation != later.at.operation) return prior.at.operation < later.at.operation;
        if (laterSameRead(prior.at, later.at)) return true;
        if (prior.at.role != .control) return false;
        const first = prior.order orelse return false;
        const second = later.order orelse return false;
        // Both numbers are actual producer facts. Readiness snapshots the
        // latest acceptance event counter before its query loads. A completed
        // acceptance event is safely earlier. The reverse inequality does NOT
        // order the loads: acceptance emits only after its whole call returns.
        return switch (first) {
            .acceptance => |sequence| switch (second) {
                .readiness => |anchor| sequence <= anchor,
                else => false,
            },
            .readiness => false,
        };
    }
    pub fn acquire(self: *JobCuts, deps: *Dependencies, index: u16, job: u64, state: JobStage, at: Point) Error!void {
        return self.acquireOrdered(deps, index, job, state, at, null);
    }
    pub fn acquireOrdered(self: *JobCuts, deps: *Dependencies, index: u16, job: u64, state: JobStage, at: Point, order: ?JobReadOrder) Error!void {
        if (index >= max_resource_slots or at.edge != .before or (job == 0 and state != .free)) return error.InvalidEvidence;
        if (order) |position| {
            if (at.role != .control) return error.InvalidEvidence;
            switch (position) {
                .acceptance => |sequence| if (at.site != .acceptance_scan or sequence == 0) return error.InvalidEvidence,
                .readiness => if (at.site != .readiness_job) return error.InvalidEvidence,
            }
        }
        if (job != 0 and job <= self.retired[index]) return error.StaleReference;
        for (self.reads) |sample| if (sample) |r| {
            if (std.meta.eql(r.at, at)) return error.DuplicateAcquisition;
            for (r.seen_sites) |seen| if (seen) |known| if (std.meta.eql(known, at)) return error.DuplicateAcquisition;
        };
        var incoming: JobRead = .{ .index = index, .job = job, .state = state, .at = at, .order = order };
        if (seenSite(at)) |site| incoming.seen_sites[site] = at;
        // Every read independently proves its lower, including reverse-arrival
        // reads whose upper will be covered by an already retained later read.
        if (state == .free and job == 0) incoming.lower = true else if (self.source(index, job, state)) |lower| {
            try deps.emit(lower, at);
            incoming.lower = true;
        }
        var reuse: ?usize = null;
        if (incoming.lower) {
            for (self.reads[0..self.capacity]) |*entry| if (entry.*) |prior| {
                if (prior.owner_position != null or prior.index != index or prior.job != job or prior.state != state or !prior.lower or prior.upper) continue;
                try deps.charge();
                if (beforeRead(incoming, prior)) {
                    const seen = mergeSeen(prior, incoming, at) orelse continue;
                    entry.*.?.seen_sites = seen;
                    return;
                }
            };
            for (self.reads[0..self.capacity], 0..) |*entry, read_index| if (entry.*) |prior| {
                if (prior.owner_position != null or prior.index != index or prior.job != job or prior.state != state or !prior.lower or prior.upper) continue;
                try deps.charge();
                if (!beforeRead(prior, incoming)) continue;
                const seen = mergeSeen(incoming, prior, at) orelse continue;
                incoming.seen_sites = seen;
                entry.* = null;
                if (reuse == null) {
                    reuse = read_index;
                    incoming.credit = prior.credit;
                } else {
                    // Keep the unique same-slot/role baseline token if present.
                    if (comptime partition_compiled) {
                        if (prior.credit and !incoming.credit) {
                            deps.releasePending();
                            incoming.credit = true;
                        } else deps.releaseJobRead(prior);
                    } else deps.releaseJobRead(prior);
                }
            };
        }
        if (reuse) |read_index| {
            self.reads[read_index] = incoming;
            try self.resolveRead(deps, read_index, false);
            return;
        }
        for (self.reads[0..self.capacity], 0..) |*item, read_index| if (item.* == null) {
            incoming.credit = try deps.reserveJobRead(index, at.role);
            item.* = incoming;
            try self.resolveRead(deps, read_index, false);
            return;
        };
        return error.DependencyCapacity;
    }
    pub fn acquirePendingOwner(self: *JobCuts, deps: *Dependencies, index: u16, handle: stream.readiness_observation.Handle, observed: JobOwnerPosition, at: Point) Error!void {
        if (index >= max_resource_slots or handle.index >= max_resource_slots or handle.generation == 0 or observed.operation == 0 or observed.attempt == 0 or observed.acceptance_sequence == 0 or at.role != .control or at.site != .stream_close_pending or at.operation != observed.operation or at.index != handle.index or at.generation != handle.generation or at.edge != .before or at.occurrence == 0) return error.InvalidEvidence;
        var selected: ?u64 = null;
        for (self.rows[0..self.capacity]) |entry| if (entry) |value| {
            try deps.charge();
            const known = value.owner orelse continue;
            if (value.index != index or !std.meta.eql(known, handle)) continue;
            const requested = value.requested orelse continue;
            if (!requestBefore(requested, observed)) continue;
            if (value.freed) |freed| if (freeBefore(freed, observed)) continue;
            if (selected != null) return error.InvalidEvidence;
            selected = value.job;
        };
        const job = selected orelse return error.MissingPublication;
        for (self.reads) |entry| if (entry) |prior| if (std.meta.eql(prior.at, at)) return error.DuplicateAcquisition;
        for (self.reads[0..self.capacity], 0..) |*entry, read_index| if (entry.*) |prior| {
            if (prior.owner_position != null and prior.index == index and prior.job == job and prior.lower and !prior.upper and laterSameRead(prior.at, at)) {
                if (!requestBefore(prior.owner_position.?, observed) or observed.acceptance_sequence < prior.owner_position.?.acceptance_sequence) return error.InvalidEvidence;
                entry.* = .{ .credit = prior.credit, .index = index, .job = job, .state = .queued, .at = at, .owner_position = observed };
                try self.resolveRead(deps, read_index, false);
                return;
            }
        };
        for (self.reads[0..self.capacity], 0..) |*entry, read_index| if (entry.* == null) {
            try deps.reservePending();
            entry.* = .{ .index = index, .job = job, .state = .queued, .at = at, .owner_position = observed };
            try self.resolveRead(deps, read_index, false);
            return;
        };
        return error.DependencyCapacity;
    }
    /// pending_job is owned by Control. Its empty read must use the actual
    /// readiness/acceptance position, never a later merged job-free snapshot.
    pub fn requireEmptyOwner(self: *JobCuts, deps: *Dependencies, handle: stream.readiness_observation.Handle, observed: JobOwnerPosition) Error!void {
        if (handle.index >= max_resource_slots or handle.generation == 0 or observed.operation == 0 or observed.attempt == 0 or observed.acceptance_sequence == 0) return error.InvalidEvidence;
        for (self.rows[0..self.capacity]) |entry| if (entry) |value| {
            try deps.charge();
            const known = value.owner orelse continue;
            if (!std.meta.eql(known, handle)) continue;
            const requested = value.requested orelse continue;
            if (!requestBefore(requested, observed)) continue;
            const freed = value.freed orelse return error.InvalidEvidence;
            if (!freeBefore(freed, observed)) return error.InvalidEvidence;
        };
    }
    pub fn finish(self: *JobCuts, deps: *Dependencies) Error!void {
        try self.resolve(deps, true);
        for (self.reads) |sample| if (sample != null) return error.MissingPublication;
        for (self.rows) |item| if (item) |value| for (value.points) |p| if (p == null) return error.MissingPublication;
        for (self.rows) |item| if (item) |value| if (!complete(value)) return error.MissingAcquisition;
    }
};

/// The supported direct profile stops a retained source at its authenticated
/// initial-lease return, or closes a never-retained stream after visibility
/// acknowledgement. Keep both exact stores distinct: close cannot justify a
/// true Render read while that read's publication still owns a visibility ref.
/// Like ConsumedCuts, this slice retains at most48 full stream identities.
pub const StreamStopCuts = struct {
    const Life = struct {
        handle: stream.Handle,
        opened: bool = false,
        stopped: ?Point = null,
        closed: ?Point = null,
        last_read: ?Point = null,
        last_value: bool = false,
    };
    const Read = struct { handle: stream.Handle, value: bool, at: Point };
    lives: [48]?Life = @splat(null),
    reads: [max_pending]?Read = @splat(null),
    capacity: usize = 0,
    failed: bool = false,

    pub fn initInto(self: *StreamStopCuts, capacity: u32) Error!void {
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        for (&self.lives) |*entry| entry.* = null;
        for (&self.reads) |*entry| entry.* = null;
        self.capacity = capacity;
        self.failed = false;
    }
    fn life(self: *StreamStopCuts, deps: *Dependencies, handle: stream.Handle) Error!*Life {
        if (self.failed) return error.Incomplete;
        if (handle.index >= 48 or handle.generation == 0) return error.StaleIdentity;
        for (&self.lives) |*entry| if (entry.*) |*value| {
            try deps.charge();
            if (value.handle.generation != handle.generation) continue;
            // One Service issues globally unique generations. A placeholder
            // index or a different physical slot cannot adopt this identity.
            if (value.handle.index != handle.index) return error.StaleIdentity;
            return value;
        };
        for (&self.lives) |*entry| if (entry.* == null) {
            try deps.reserveClass(.stop_identity);
            entry.* = .{ .handle = handle };
            return &entry.*.?;
        };
        return error.DependencyCapacity;
    }
    pub fn handleForGeneration(self: *StreamStopCuts, deps: *Dependencies, generation: u64) Error!stream.Handle {
        if (self.failed) return error.Incomplete;
        for (self.lives) |entry| if (entry) |value| {
            try deps.charge();
            if (value.handle.generation == generation and value.opened and value.closed == null) return value.handle;
        };
        return error.StaleReference;
    }
    fn resolve(self: *StreamStopCuts, deps: *Dependencies, index: usize) Error!void {
        const sample = self.reads[index] orelse return;
        const owned = try self.life(deps, sample.handle);
        if (!owned.opened) return;
        if (sample.value) {
            const stopped = owned.stopped orelse {
                if (owned.closed != null) return error.MissingPublication;
                return;
            };
            try deps.emit(stopped, sample.at);
        } else {
            const stopped = owned.stopped orelse owned.closed orelse return;
            var after = sample.at;
            after.edge = .after;
            var before = stopped;
            before.edge = .before;
            try deps.emit(after, before);
        }
        self.reads[index] = null;
        deps.releasePending();
    }
    fn resolveAll(self: *StreamStopCuts, deps: *Dependencies) Error!void {
        for (0..self.capacity) |index| try self.resolve(deps, index);
    }
    pub fn open(self: *StreamStopCuts, deps: *Dependencies, handle: stream.Handle) Error!void {
        errdefer self.failed = true;
        for (self.lives) |entry| if (entry) |value| {
            try deps.charge();
            if (value.handle.index == handle.index and value.handle.generation != handle.generation and value.opened and value.closed == null) return error.StaleReference;
        };
        const owned = try self.life(deps, handle);
        if (owned.opened or owned.closed != null) return error.DuplicatePublication;
        owned.opened = true;
        try self.resolveAll(deps);
    }
    pub fn publish(self: *StreamStopCuts, deps: *Dependencies, handle: stream.Handle, at: Point) Error!void {
        errdefer self.failed = true;
        const owned = try self.life(deps, handle);
        if (!owned.opened or owned.closed != null) return error.StaleReference;
        if (owned.stopped != null) return error.DuplicatePublication;
        if (at.role != .control or at.site != .stream_stop_publish or at.edge != .after or at.index != 0 or at.generation != handle.generation or at.operation == 0 or at.occurrence == 0) return error.InvalidEvidence;
        owned.stopped = at;
        try self.resolveAll(deps);
    }
    pub fn close(self: *StreamStopCuts, deps: *Dependencies, handle: stream.Handle, at: Point) Error!void {
        errdefer self.failed = true;
        const owned = try self.life(deps, handle);
        if (!owned.opened or owned.closed != null) return error.StaleReference;
        if (at.role != .control or at.site != .stream_close_stopped or at.edge != .after or at.index != handle.index or at.generation != handle.generation or at.operation == 0 or at.occurrence == 0) return error.InvalidEvidence;
        if (owned.stopped) |stopped| if (stopped.operation > at.operation) return error.FutureReference;
        owned.closed = at;
        try self.resolveAll(deps);
    }
    pub fn acquire(self: *StreamStopCuts, deps: *Dependencies, handle: stream.Handle, value: bool, at: Point) Error!void {
        errdefer self.failed = true;
        const owned = try self.life(deps, handle);
        if (at.role != .render or at.site != .visibility_stopped or at.edge != .before or at.index != handle.index or at.generation != handle.generation or at.operation == 0 or at.occurrence == 0) return error.InvalidEvidence;
        if (owned.last_read) |previous| {
            if (std.meta.eql(previous, at)) return error.DuplicateAcquisition;
            if (!laterSameRead(previous, at)) return error.InvalidOrder;
            if (owned.last_value and !value) return error.InvalidEvidence;
        }
        owned.last_read = at;
        owned.last_value = value;
        // Only same-identity Render program order carries a false read's
        // pending upper bound. Every read still has its own actual comparator.
        if (!value) for (self.reads[0..self.capacity], 0..) |*entry, index| if (entry.*) |sample| {
            if (!sample.value and std.meta.eql(sample.handle, handle) and laterSameRead(sample.at, at)) {
                entry.* = .{ .handle = handle, .value = value, .at = at };
                return self.resolve(deps, index);
            }
        };
        for (self.reads[0..self.capacity], 0..) |*entry, index| if (entry.* == null) {
            try deps.reservePending();
            entry.* = .{ .handle = handle, .value = value, .at = at };
            return self.resolve(deps, index);
        };
        return error.DependencyCapacity;
    }
    pub fn finish(self: *StreamStopCuts, deps: *Dependencies) Error!void {
        if (self.failed) return error.Incomplete;
        try self.resolveAll(deps);
        for (self.reads) |entry| if (entry != null) return error.MissingPublication;
        for (&self.lives) |*entry| if (entry.*) |value| {
            if (!value.opened or value.closed == null) return error.MissingAcquisition;
            entry.* = null;
            deps.releaseClass(.stop_identity);
        };
    }
    pub fn observedValue(attempt: stream.render_observation.Attempt) Error!bool {
        const value = attempt.stopped orelse return error.InvalidEvidence;
        const disposition = attempt.disposition orelse return error.InvalidEvidence;
        if (value) {
            if (disposition != .rejected or attempt.result != .rejected) return error.InvalidEvidence;
        } else if (disposition != .admitted or attempt.result != .admitted) return error.InvalidEvidence;
        return value;
    }
};

/// One Control-owned lease per accepted visibility descriptor. Render only
/// admits the descriptor; the later Control acknowledgment releases the lease.
/// Readiness may lag acceptance in assembler order, so both endpoints retain
/// their real Control positions until all three Control witnesses close.
pub const VisibilityOwners = struct {
    pub const Descriptor = rt.streaming.visibility.Descriptor;
    pub const Position = struct { operation: u64, acceptance_sequence: u64 };
    const Endpoint = struct { position: Position, at: Point };
    const Row = struct {
        descriptor: Descriptor,
        published: ?Endpoint = null,
        admitted: ?Point = null,
        acknowledged: ?Endpoint = null,
        // The row already owns one pending credit. Same-role later reads can
        // carry its unresolved upper bound without retaining every poll.
        last_read: ?struct { position: Position, at: Point } = null,
    };
    capacity: usize,
    rows: [max_pending]?Row = @splat(null),
    published: u64 = 0,
    admitted: u64 = 0,
    acknowledged: u64 = 0,
    closed_operation: u64 = 0,
    failed: bool = false,

    pub fn initInto(self: *VisibilityOwners, capacity: u32) Error!void {
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        self.capacity = capacity;
        for (&self.rows) |*entry| entry.* = null;
        self.published = 0;
        self.admitted = 0;
        self.acknowledged = 0;
        self.closed_operation = 0;
        self.failed = false;
    }
    fn begin(self: *VisibilityOwners, deps: *Dependencies) Error!void {
        if (self.failed) return error.Incomplete;
        try deps.charge();
    }
    fn beforeOrAt(left: Position, right: Position) bool {
        return left.operation < right.operation or (left.operation == right.operation and left.acceptance_sequence <= right.acceptance_sequence);
    }
    fn endpoint(position: Position, at: Point, site: Site) Error!Endpoint {
        if (position.operation == 0 or position.acceptance_sequence == 0 or at.role != .control or at.operation != position.operation or at.site != site or at.index != 0 or at.generation != 0 or at.occurrence == 0 or at.edge != .after) return error.InvalidEvidence;
        return .{ .position = position, .at = at };
    }
    fn row(self: *VisibilityOwners, deps: *Dependencies, descriptor: Descriptor) Error!*Row {
        if (descriptor.version != 1 or descriptor.publication_ordinal == 0 or descriptor.stream_slot >= max_resource_slots or descriptor.stream_generation == 0 or descriptor.worker_job == 0) return error.StaleIdentity;
        for (self.rows[0..self.capacity]) |*entry| if (entry.*) |*value| {
            try deps.charge();
            if (value.descriptor.publication_ordinal != descriptor.publication_ordinal) continue;
            if (!std.meta.eql(value.descriptor, descriptor)) return error.StaleIdentity;
            return value;
        };
        for (self.rows[0..self.capacity]) |*entry| if (entry.* == null) {
            try deps.reservePending();
            entry.* = .{ .descriptor = descriptor };
            return &entry.*.?;
        };
        return error.DependencyCapacity;
    }
    fn upper(deps: *Dependencies, value: *Row) Error!void {
        const read = value.last_read orelse return;
        const ack = value.acknowledged orelse return;
        if (beforeOrAt(ack.position, read.position)) return error.StaleReference;
        var after = read.at;
        after.edge = .after;
        var before = ack.at;
        before.edge = .before;
        try deps.emit(after, before);
        value.last_read = null;
    }
    fn retire(self: *VisibilityOwners, deps: *Dependencies) Error!void {
        for (self.rows[0..self.capacity]) |*entry| if (entry.*) |value| {
            try deps.charge();
            const ack = value.acknowledged orelse continue;
            if (value.published == null or value.admitted == null or ack.position.operation > self.closed_operation) continue;
            if (value.last_read != null) return error.MissingAcquisition;
            entry.* = null;
            deps.releasePending();
        };
    }
    pub fn publish(self: *VisibilityOwners, deps: *Dependencies, descriptor: Descriptor, position: Position, at: Point) Error!void {
        errdefer self.failed = true;
        try self.begin(deps);
        if (descriptor.publication_ordinal != try add(self.published, 1) or position.operation <= self.closed_operation) return error.InvalidEvidence;
        const released = try endpoint(position, at, .publication_release);
        const value = try self.row(deps, descriptor);
        if (value.published != null) return error.DuplicatePublication;
        value.published = released;
        self.published = descriptor.publication_ordinal;
        try self.retire(deps);
    }
    pub fn admit(self: *VisibilityOwners, deps: *Dependencies, descriptor: Descriptor, at: Point) Error!void {
        errdefer self.failed = true;
        try self.begin(deps);
        if (descriptor.publication_ordinal != try add(self.admitted, 1) or at.role != .render or at.operation == 0 or at.site != .visibility_release or at.index != 0 or at.generation != 0 or at.occurrence == 0 or at.edge != .after) return error.InvalidEvidence;
        const value = try self.row(deps, descriptor);
        if (value.admitted != null) return error.DuplicateAcquisition;
        value.admitted = at;
        self.admitted = descriptor.publication_ordinal;
        try self.retire(deps);
    }
    pub fn acknowledge(self: *VisibilityOwners, deps: *Dependencies, descriptor: Descriptor, position: Position, at: Point) Error!void {
        errdefer self.failed = true;
        try self.begin(deps);
        if (descriptor.publication_ordinal != try add(self.acknowledged, 1) or position.operation <= self.closed_operation) return error.InvalidEvidence;
        const returned = try endpoint(position, at, .visibility_ack);
        const value = try self.row(deps, descriptor);
        const released = value.published orelse return error.MissingPublication;
        if (beforeOrAt(position, released.position)) return error.FutureReference;
        if (value.acknowledged != null) return error.DuplicateAcquisition;
        value.acknowledged = returned;
        try upper(deps, value);
        self.acknowledged = descriptor.publication_ordinal;
        try self.retire(deps);
    }
    pub fn acquire(self: *VisibilityOwners, deps: *Dependencies, handle: stream.Handle, observed: Position, count: u32, at: Point) Error!void {
        errdefer self.failed = true;
        try self.begin(deps);
        if (handle.index >= max_resource_slots or handle.generation == 0 or observed.operation <= self.closed_operation or observed.acceptance_sequence == 0 or at.role != .control or at.operation != observed.operation or at.site != .stream_close_visibility or at.index != handle.index or at.generation != handle.generation or at.occurrence == 0 or at.edge != .before) return error.InvalidEvidence;
        var actual: u32 = 0;
        for (self.rows[0..self.capacity]) |entry| if (entry) |value| {
            try deps.charge();
            if (value.descriptor.stream_slot != handle.index or value.descriptor.stream_generation != handle.generation) continue;
            const released = value.published orelse continue;
            if (!beforeOrAt(released.position, observed)) continue;
            if (value.acknowledged) |ack| if (beforeOrAt(ack.position, observed)) continue;
            actual = std.math.add(u32, actual, 1) catch return error.WorkBudget;
        };
        if (actual != count) return if (actual == 0 and count != 0) error.MissingPublication else error.InvalidEvidence;
        for (self.rows[0..self.capacity]) |*entry| if (entry.*) |*value| {
            try deps.charge();
            if (value.descriptor.stream_slot != handle.index or value.descriptor.stream_generation != handle.generation) continue;
            const released = value.published orelse continue;
            if (!beforeOrAt(released.position, observed)) continue;
            if (value.acknowledged) |ack| if (beforeOrAt(ack.position, observed)) continue;
            try deps.emit(released.at, at);
            if (value.last_read) |previous| if (!laterSameRead(previous.at, at) or !beforeOrAt(previous.position, observed)) return error.InvalidOrder;
            value.last_read = .{ .position = observed, .at = at };
            try upper(deps, value);
        };
    }
    pub fn closeOperation(self: *VisibilityOwners, deps: *Dependencies, operation: u64) Error!void {
        errdefer self.failed = true;
        try self.begin(deps);
        if (operation <= self.closed_operation) return error.InvalidOrder;
        self.closed_operation = operation;
        try self.retire(deps);
    }
    pub fn finish(self: *VisibilityOwners, deps: *Dependencies) Error!void {
        try self.begin(deps);
        try self.retire(deps);
        if (self.published != self.admitted or self.published != self.acknowledged) return error.MissingAcquisition;
        for (self.rows[0..self.capacity]) |entry| if (entry != null) return error.MissingAcquisition;
    }
};

/// Affine ranges summarize actual successive release callbacks, never inferred
/// DSP samples. Fixed history bounds lookup; every unresolved read/identity is
/// charged to the same Dependencies budget as the other public ledgers.
/// This first slice admits at most48 distinct stream generations per recording;
/// retired identities are not silently reused before the joined lane seal.
/// The256-range lookup history is not the replay comparator table: replay stores
/// one compressed comparator per range against its existing65536 shared limit.
pub const ConsumedCuts = struct {
    pub const Range = @FieldType(format.Record, "stream_consumed_range");
    const Life = struct { index: u16, generation: u64, latest: u64 = 0, opened: bool = false, retired: bool = false };
    const Call = struct { ordinal: u64, frames: ?u32 = null, ranges: u16 = 0, publications: u64 = 0, maximum: u32 = 0, sealed: bool = false };
    const Read = struct { index: u16, generation: u64, value: u64, at: Point, lower: bool = false, upper: bool = false };
    calls: [max_pending]?Call = @splat(null),
    lives: [48]?Life = @splat(null),
    ranges: [max_pending]?Range = @splat(null),
    reads: [max_pending]?Read = @splat(null),
    ranges_count: u64 = 0,
    capacity: usize = 0,
    pub fn initInto(self: *ConsumedCuts, capacity: u32) Error!void {
        if (capacity == 0 or capacity > max_pending) return error.InvalidLimits;
        for (&self.calls) |*item| item.* = null;
        for (&self.lives) |*item| item.* = null;
        for (&self.ranges) |*item| item.* = null;
        for (&self.reads) |*item| item.* = null;
        self.ranges_count = 0;
        self.capacity = capacity;
    }
    fn call(self: *ConsumedCuts, deps: *Dependencies, ordinal: u64) Error!*Call {
        if (ordinal == 0) return error.InvalidOrder;
        for (&self.calls) |*item| if (item.*) |*value| {
            try deps.charge();
            if (value.ordinal == ordinal) return value;
        };
        for (self.calls[0..self.capacity]) |*item| if (item.* == null) {
            try deps.reservePending();
            item.* = .{ .ordinal = ordinal };
            return &item.*.?;
        };
        return error.DependencyCapacity;
    }
    fn resolveCalls(self: *ConsumedCuts, deps: *Dependencies) Error!void {
        for (&self.calls) |*item| if (item.*) |value| {
            try deps.charge();
            const frames = value.frames orelse continue;
            if (value.maximum > frames or value.publications > @as(u64, frames) * 48) return error.InvalidEvidence;
            if (value.sealed) {
                item.* = null;
                deps.releasePending();
            }
        };
    }
    pub fn callBegin(self: *ConsumedCuts, deps: *Dependencies, ordinal: u64, frames: u32) Error!void {
        const value = try self.call(deps, ordinal);
        if (value.frames != null or frames == 0 or frames > 64) return error.InvalidEvidence;
        value.frames = frames;
        try self.resolveCalls(deps);
    }
    pub fn callRange(self: *ConsumedCuts, deps: *Dependencies, range: Range) Error!void {
        const value = try self.call(deps, range.key.ordinal);
        if (value.sealed or value.ranges == 48) return error.InvalidOrder;
        value.ranges += 1;
        value.publications = try add(value.publications, range.count);
        value.maximum = @max(value.maximum, range.count);
        try self.publish(deps, range);
        try self.resolveCalls(deps);
    }
    pub fn callEnd(self: *ConsumedCuts, deps: *Dependencies, ordinal: u64, ranges: u16, publications: u32) Error!void {
        const value = try self.call(deps, ordinal);
        if (value.sealed or value.ranges != ranges or value.publications != publications) return error.InvalidEvidence;
        value.sealed = true;
        try self.resolveCalls(deps);
    }
    fn life(self: *ConsumedCuts, deps: *Dependencies, index: u16, generation: u64) Error!*Life {
        if (index >= 48 or generation == 0) return error.StaleIdentity;
        for (&self.lives) |*item| if (item.*) |*value| {
            try deps.charge();
            if (value.index == index and value.generation == generation) return value;
        };
        for (&self.lives) |*item| if (item.* == null) {
            try deps.reserveClass(.consumed_identity);
            item.* = .{ .index = index, .generation = generation };
            return &item.*.?;
        };
        return error.DependencyCapacity;
    }
    pub fn open(self: *ConsumedCuts, deps: *Dependencies, index: u16, generation: u64) Error!void {
        const owned = try self.life(deps, index, generation);
        if (owned.opened or owned.retired) return error.StaleReference;
        owned.opened = true;
        try self.resolveIdentity(deps, index, generation);
    }
    pub fn retire(self: *ConsumedCuts, deps: *Dependencies, index: u16, generation: u64) Error!void {
        const owned = try self.life(deps, index, generation);
        if (!owned.opened or owned.retired) return error.StaleReference;
        // Real close proves no remaining ring references. Delayed Render-lane
        // ranges may still arrive; only the joined complete call tape seals it.
        owned.retired = true;
    }
    fn lookup(self: *ConsumedCuts, deps: *Dependencies, index: u16, generation: u64, value: u64) Error!?Point {
        for (self.ranges[0..self.capacity]) |item| if (item) |range| {
            try deps.charge();
            if (range.index != index or range.generation != generation or value < range.first or value > range.last) continue;
            return .{ .role = .render, .operation = range.key.ordinal, .site = .stream_consumed_release, .index = index, .generation = generation, .occurrence = std.math.cast(u32, value - range.first + 1) orelse return error.InvalidEvidence, .edge = .after };
        };
        return null;
    }
    fn resolve(self: *ConsumedCuts, deps: *Dependencies, index: usize, final: bool) Error!void {
        var sample = self.reads[index] orelse return;
        const owned = try self.life(deps, sample.index, sample.generation);
        if (!owned.opened) return;
        if (!sample.lower) {
            if (sample.value == 0) sample.lower = true else if (sample.value <= owned.latest) {
                const at = (try self.lookup(deps, sample.index, sample.generation, sample.value)) orelse return error.MissingPublication;
                try deps.emit(at, sample.at);
                sample.lower = true;
            }
        }
        if (!sample.upper) {
            // Contiguous actual publications prove that an endpoint beyond
            // latest is absent. Preserve overflow rejection even while waiting.
            const next = try add(sample.value, 1);
            if (next <= owned.latest) {
                const at = (try self.lookup(deps, sample.index, sample.generation, next)) orelse return error.MissingPublication;
                var upper = at;
                upper.edge = .before;
                var after = sample.at;
                after.edge = .after;
                try deps.emit(after, upper);
                sample.upper = true;
            } else if (final and owned.retired and sample.value == owned.latest) sample.upper = true;
        }
        if (sample.lower and sample.upper) {
            self.reads[index] = null;
            deps.releasePending();
        } else self.reads[index] = sample;
    }
    fn resolveIdentity(self: *ConsumedCuts, deps: *Dependencies, index: u16, generation: u64) Error!void {
        // Only this lifetime changed. Other reads keep their exact pending
        // obligations; finish still resolves every identity against its seal.
        for (self.reads[0..self.capacity], 0..) |item, i| if (item) |sample| {
            if (sample.index == index and sample.generation == generation) try self.resolve(deps, i, false);
        };
    }
    pub fn publish(self: *ConsumedCuts, deps: *Dependencies, range: Range) Error!void {
        if (range.key.role != .render or range.key.ordinal == 0 or range.count == 0 or range.count > 64 or range.first == 0 or range.last < range.first or range.last - range.first != range.count - 1) return error.InvalidEvidence;
        const owned = try self.life(deps, range.index, range.generation);
        if (range.first != try add(owned.latest, 1)) return error.InvalidOrder;
        const position: usize = @intCast(self.ranges_count % self.capacity);
        if (self.ranges[position]) |old| for (self.reads) |item| if (item) |sample| {
            if (sample.index == old.index and sample.generation == old.generation and ((!sample.lower and sample.value >= old.first and sample.value <= old.last) or (!sample.upper and sample.value < old.last))) return error.DependencyCapacity;
        };
        self.ranges[position] = range;
        self.ranges_count += 1;
        owned.latest = range.last;
        try self.resolveIdentity(deps, range.index, range.generation);
    }
    pub fn acquire(self: *ConsumedCuts, deps: *Dependencies, index: u16, generation: u64, value: u64, at: Point) Error!void {
        const owned = try self.life(deps, index, generation);
        if (!owned.opened or owned.retired or at.role != .control or at.edge != .before or at.index != index or at.generation != generation) return error.StaleReference;
        for (self.reads) |item| if (item) |sample| if (std.meta.eql(sample.at, at)) return error.DuplicateAcquisition;
        for (&self.reads, 0..) |*item, i| if (item.*) |sample| {
            if (sample.index == index and sample.generation == generation and sample.value == value and sample.lower and !sample.upper and laterSameRead(sample.at, at)) {
                item.* = .{ .index = index, .generation = generation, .value = value, .at = at };
                return self.resolve(deps, i, false);
            }
        };
        for (self.reads[0..self.capacity], 0..) |*item, i| if (item.* == null) {
            try deps.reservePending();
            item.* = .{ .index = index, .generation = generation, .value = value, .at = at };
            return self.resolve(deps, i, false);
        };
        return error.DependencyCapacity;
    }
    pub fn finish(self: *ConsumedCuts, deps: *Dependencies) Error!void {
        for (self.calls) |item| if (item != null) return error.MissingTerminal;
        for (0..self.capacity) |i| try self.resolve(deps, i, true);
        for (self.reads) |item| if (item != null) return error.MissingPublication;
        for (&self.lives) |*item| if (item.*) |owned| {
            if (!owned.opened or !owned.retired) return error.MissingAcquisition;
            item.* = null;
            deps.releaseClass(.consumed_identity);
        };
    }
};

const UnsupportedReason = enum { acceptance_changed_sequence, readiness_unstable_snapshot, supply_changed_sequence, stream_close_other_prefix, source_switch_nonempty, cancellation_poll, group_zero_without_prefix, group_pin_other_result, group_references_other_result, render_scan_other_state };
const ProgressKind = enum { block_state, block_receipt, plan_phase, group_terminal };
const progress_capacity: usize = 256;
const ProgressTrack = struct {
    kind: ProgressKind,
    index: u16,
    generation: u64,
    prefix: Prefix,
    expected_count: u16 = 0,
    // Borrowed Render FIFO identity, charged with this existing progress row.
    render_scan_selected: bool = false,
    retired: bool = false,
    prepared: bool = false,
    pending: bool = true,
};
const ProgressFact = struct { kind: ProgressKind, index: u16, generation: u64, value: u64, at: Point };
const Occurrence = struct { site: Site, index: u64, next: u32 };
const occurrence_capacity: usize = 640;
const Occurrences = struct {
    count: usize = 0,
    entries: [occurrence_capacity]Occurrence = undefined,
    fn next(self: *Occurrences, site: Site, index: u64) Error!u32 {
        for (self.entries[0..self.count]) |*entry| if (entry.site == site and entry.index == index) {
            if (entry.next == std.math.maxInt(u32)) return error.WorkBudget;
            entry.next += 1;
            return entry.next;
        };
        if (self.count == self.entries.len) return error.DependencyCapacity;
        self.entries[self.count] = .{ .site = site, .index = index, .next = 1 };
        self.count += 1;
        return 1;
    }
};

const Binding = struct {
    key: format.OperationKey,
    serial: u64,
    control_tick: u64 = 0,
    args: format.OperationArgs,
    result: format.OperationResult,
    finished: u8 = 0,
    occurrences: Occurrences = .{},
    acceptance_calls: u32 = 0,
    visibility_polls: u32 = 0,
    completion_pops: u32 = 0,
    acquisition_counts: [10]u32 = @splat(0),
    accepted_frame: ?u64 = null,
    collect_frame: ?CollectFrameProof = null,
    availability_failure: ?stream.readiness_observation.QueryKey = null,
    pending_prefetch: ?struct { attempt: u64, handle: stream.readiness_observation.Handle } = null,
};
const Anchor = struct { sequence: u64, tick: u64, control_tick: u64, ordinal: u64, phase: u8, closed: bool };
const Peer = struct { open: bool = false, serial: u64 = 0, control_tick: u64 = 0, ordinal: u64 = 0, ticks: u64 = 0 };
const Worker = struct {
    key: ?format.OperationKey = null,
    scanned: u16 = 0,
    queued: [max_resource_slots]u64 = @splat(0),
    selected: u64 = 0,
    slot: u16 = 0,
    clocks: u2 = 0,
    completed: bool = false,
    idle: bool = false,
};
const StreamLife = struct { generation: u64 = 0, live: bool = false, produced: u64 = 0, admitted: u64 = 0 };
const JobLife = struct { job: u64 = 0, handle: stream.readiness_observation.Handle = .{ .index = 0, .generation = 0 }, ordinal: u64 = 0, count: u32 = 0, live: bool = false };
const RenderCall = struct { open: bool = false, gate_open: bool = false, gate_done: bool = false, service_live: bool = false, frontier: ?u64 = null, read: u64 = 0, frame: u64 = 0, sequence: u64 = 0, scanned: u16 = 0, spans: u32 = 0, admission_calls: u32 = 0 };

/// Witness association is exact and bounded. Three Control witnesses bind via
/// the actual admitted tick serial; Render binds via the actual odd call
/// sequence. A late host end can release queued witnesses without making that
/// arrival order an execution schedule.
pub const Validator = struct {
    header: format.Header,
    limits: Limits,
    check_sink: ?CheckSink = null,
    checks: u64 = 0,
    cursor: format.Cursor,
    dependencies: Dependencies,
    render_frames: Prefix,
    commit_horizons: Prefix,
    horizon_gate_open: bool = false,
    stream_frontier: Prefix,
    stream_admissions: Prefix,
    visibility_owners: VisibilityOwners,
    stream_stop_cuts: StreamStopCuts,
    visibility_observed_read: u64 = 0,
    observation_sequences: Prefix,
    observation_frames: Prefix,
    completion_cuts: CompletionCuts,
    group_pins: GroupPins,
    exclusion_tickets: ExclusionTickets,
    lifetimes: Lifetimes.Ledger,
    bindings: [max_operation_bindings]?Binding = @splat(null),
    pending: [max_pending]format.Record = undefined,
    pending_count: usize = 0,
    pending_high_water: usize = 0,
    peers: [3]Peer = @splat(.{}),
    anchors: [2][max_pending]?Anchor = @splat(@splat(null)),
    semantic_sequences: [4]u64 = @splat(0),
    worker: Worker = .{},
    job_cuts: JobCuts,
    consumed_cuts: ConsumedCuts,
    worker_last: [max_resource_slots]u64 = @splat(0),
    worker_slots: ?u16 = null,
    jobs: [max_resource_slots]JobLife = @splat(.{}),
    streams: [max_resource_slots]StreamLife = @splat(.{}),
    render_call: RenderCall = .{},
    render_calls: u64 = 0,
    render_gates: u64 = 0,
    service_gates: u64 = 0,
    render_terminal: ?format.render.Terminal = null,
    readiness_terminal: ?format.readiness.Terminal = null,
    group_event_writes: Prefix = undefined,
    group_event_returns: Prefix = undefined,
    group_event_head: u64 = 0,
    group_event_tail: u64 = 0,
    group_event_seen_head: u64 = 0,
    group_event_seen_tail: u64 = 0,
    group_event_pending: ?format.OperationKey = null,
    group_event_terminal: bool = false,
    scheduler_publications: u64 = 0,
    progress_tracks: [progress_capacity]?ProgressTrack = @splat(null),
    progress_facts: [max_pending]?ProgressFact = @splat(null),
    progress_retired: [4][64]u64 = @splat(@splat(0)),
    keyed_occurrences: [3]Occurrences = @splat(.{}),
    keyed_operations: [3]u64 = @splat(0),
    render_ended: u64 = 0,
    closed_sources: [max_pending]u64 = @splat(0),
    closed_source_count: usize = 0,
    source_unbound: bool = false,
    preparation_count: u16 = 0,
    render_frame: u64,
    render_sequence: u64,
    publication_ordinal: u64 = 0,
    admission_ordinal: u64 = 0,
    acknowledgement_ordinal: u64 = 0,
    completion_write: u64 = 0,
    completion_read: u64 = 0,
    last_job: u64 = 0,
    last_readiness_attempt: u64 = 0,
    query: ?stream.readiness_observation.QueryKey = null,
    unsupported_cuts: u64 = 0,
    test_unsupported_reasons: [@typeInfo(UnsupportedReason).@"enum".fields.len]u64 = @splat(0),
    test_scheduler_cuts_seen: u64 = 0,
    proved_failed_ticks: u64 = 0,
    saw_retirement: bool = false,
    retirement_request: ?Point = null,
    retirement_worker: ?Point = null,
    retirement_linked: bool = false,
    retirement_pending: bool = false,
    saw_retirement_ack: bool = false,
    failed: bool = false,
    finished: bool = false,

    /// Compatibility value constructor. Large pinned owners should use
    /// initInto so Debug builds do not materialize a Validator on the stack.
    pub fn init(header: format.Header, limits: Limits) Error!Validator {
        var value: Validator = undefined;
        try value.initInto(header, limits);
        return value;
    }
    /// Initialize caller-owned pinned storage directly. In particular, do not
    /// assign a whole Validator/Storage literal: progress tables are fixed but
    /// intentionally larger than an ordinary thread's stack.
    pub fn initInto(self: *Validator, header: format.Header, limits: Limits) Error!void {
        try header.validate();
        try limits.validate();
        if (limits.pending_dependencies > header.limits.pending_dependencies or limits.checkpoint_steps > header.limits.checkpoint_steps or limits.producer_events > header.limits.producer_events or limits.operations_per_role > header.limits.operations_per_role) return error.InvalidLimits;
        if (!header.bindings.readiness_manifest.capture_acquisitions or !header.bindings.readiness_manifest.capture_reconciliation or !header.bindings.render_manifest.capture_reconciliation) return error.IncompleteCoverage;
        self.header = header;
        self.limits = limits;
        self.check_sink = null;
        self.checks = 0;
        self.cursor = try format.Cursor.init(header);
        self.dependencies = try Dependencies.init(limits.pending_dependencies, limits.checkpoint_steps, null);
        const local_pending = localLimit(limits.pending_dependencies);
        try self.job_cuts.initInto(local_pending);
        try self.consumed_cuts.initInto(local_pending);
        try self.render_frames.initInto(header.bindings.render_manifest.initial_frame, local_pending);
        try self.commit_horizons.initInto(header.bindings.render_manifest.initial_frame, local_pending);
        self.horizon_gate_open = false;
        try self.stream_frontier.initInto(0, local_pending);
        try self.stream_admissions.initInto(0, local_pending);
        try self.visibility_owners.initInto(local_pending);
        try self.stream_stop_cuts.initInto(local_pending);
        self.visibility_observed_read = 0;
        try self.observation_sequences.initInto(header.bindings.readiness_manifest.initial_observation_sequence, local_pending);
        try self.observation_frames.initInto(header.bindings.readiness_manifest.initial_frame, local_pending);
        try self.group_event_writes.initInto(0, local_pending);
        try self.group_event_returns.initInto(0, local_pending);
        self.group_event_head = 0;
        self.group_event_tail = 0;
        self.group_event_seen_head = 0;
        self.group_event_seen_tail = 0;
        self.group_event_pending = null;
        self.group_event_terminal = false;
        try self.completion_cuts.initInto(local_pending);
        try self.group_pins.initInto(local_pending);
        try self.exclusion_tickets.initIntoRules(local_pending, header.identity.rules_version);
        self.lifetimes.initInto(header.identity.generation, .{ .context = self, .emit = lifetimeAction }) catch |err| {
            const mapped = lifetimeError(err);
            return mapped;
        };
        for (&self.bindings) |*entry| entry.* = null;
        // pending/Occurrence payloads remain uninitialized beyond their count.
        self.pending_count = 0;
        self.pending_high_water = 0;
        for (&self.peers) |*entry| entry.* = .{};
        for (&self.anchors) |*row| {
            for (row) |*entry| entry.* = null;
        }
        self.semantic_sequences = @splat(0);
        self.worker = .{};
        self.worker_last = @splat(0);
        self.worker_slots = null;
        for (&self.jobs) |*entry| entry.* = .{};
        for (&self.streams) |*entry| entry.* = .{};
        self.render_call = .{};
        self.render_calls = 0;
        self.render_gates = 0;
        self.service_gates = 0;
        self.render_terminal = null;
        self.readiness_terminal = null;
        self.scheduler_publications = 0;
        for (&self.progress_tracks) |*entry| entry.* = null;
        for (&self.progress_facts) |*entry| entry.* = null;
        for (&self.progress_retired) |*row| row.* = @splat(0);
        for (&self.keyed_occurrences) |*entry| entry.count = 0;
        self.keyed_operations = @splat(0);
        self.render_ended = 0;
        self.closed_sources = @splat(0);
        self.closed_source_count = 0;
        self.source_unbound = false;
        self.preparation_count = 0;
        self.render_frame = header.bindings.render_manifest.initial_frame;
        self.render_sequence = header.bindings.render_manifest.initial_call_sequence;
        self.publication_ordinal = 0;
        self.admission_ordinal = 0;
        self.acknowledgement_ordinal = 0;
        self.completion_write = 0;
        self.completion_read = 0;
        self.last_job = 0;
        self.last_readiness_attempt = 0;
        self.query = null;
        self.unsupported_cuts = 0;
        self.test_unsupported_reasons = @splat(0);
        self.test_scheduler_cuts_seen = 0;
        self.proved_failed_ticks = 0;
        self.saw_retirement = false;
        self.retirement_request = null;
        self.retirement_worker = null;
        self.retirement_linked = false;
        self.retirement_pending = false;
        self.saw_retirement_ack = false;
        self.failed = false;
        self.finished = false;
    }
    pub fn setDependencySink(self: *Validator, sink: ?DependencySink) Error!void {
        if (self.cursor.records != 0 or self.failed or self.finished) return error.InvalidOrder;
        self.dependencies.sink = sink;
    }
    pub fn setCheckSink(self: *Validator, sink: ?CheckSink) Error!void {
        if (self.cursor.records != 0 or self.failed or self.finished) return error.InvalidOrder;
        self.check_sink = sink;
    }
    fn check(self: *Validator, observed: Point, value: u64) Error!void {
        try self.dependencies.charge();
        if (observed.edge != .after or observed.operation == 0) return error.InvalidEvidence;
        if (self.check_sink) |sink| try sink.emit(sink.context, .{ .point = observed, .value = value });
        self.checks += 1;
    }
    fn point(key: format.OperationKey, site: Site, index: u64, generation: u64, occurrence: u64, edge: Edge) Error!Point {
        return .{ .role = key.role, .operation = key.ordinal, .site = site, .index = index, .generation = generation, .occurrence = std.math.cast(u32, try add(occurrence, 1)) orelse return error.WorkBudget, .edge = edge };
    }
    fn slot(value: u64) u16 {
        return @intCast(value % max_resource_slots);
    }
    fn identity(domain: Domain, index: u16, generation: u64) Identity {
        return .{ .domain = domain, .index = index, .generation = generation };
    }
    fn bind(self: *Validator, begin: format.OperationBegin, end: format.OperationEnd) Error!void {
        const serial = switch (end.result) {
            .ticked => |v| v.frontier_tick_serial,
            .tick_failed => |v| blk: {
                if (v.failure != .invalid_state) return error.IncompleteCoverage;
                break :blk v.frontier_tick_serial;
            },
            .rendered => |v| try add(v.call_sequence_begin, 1),
            else => return,
        };
        if (serial == 0) return error.UnboundOperation;
        for (self.bindings) |entry| if (entry) |value| if (value.key.role == begin.key.role and value.serial == serial) return error.DuplicatePublication;
        for (self.bindings[0..localLimit(self.limits.pending_dependencies)]) |*entry| if (entry.* == null) {
            try self.dependencies.reservePending();
            entry.* = .{ .key = begin.key, .serial = serial, .args = begin.args, .result = end.result, .control_tick = switch (end.result) {
                .ticked => |v| v.control_tick,
                .tick_failed => |v| v.control_tick,
                else => 0,
            } };
            return;
        };
        return error.DependencyCapacity;
    }
    fn witnessIndex(record: format.Record) ?usize {
        return switch (record) {
            .frontier => 0,
            .acceptance => 1,
            .readiness => 2,
            .render => 3,
            else => null,
        };
    }
    fn bound(self: *const Validator, record: format.Record) ?usize {
        const role: format.Role = if (record == .render) .render else .control;
        const serial = switch (record) {
            .frontier => |v| v.tick_serial,
            .acceptance => |v| v.tick_serial,
            .readiness => |v| v.key.tick_serial,
            .render => |v| v.render_call_sequence,
            else => return null,
        };
        for (self.bindings, 0..) |entry, index| if (entry) |value| if (value.key.role == role and value.serial == serial) return index;
        return null;
    }
    pub const PendingControlEnd = struct { key: format.OperationKey, tick_serial: u64 };
    /// Consumer scheduling hint only. An unbound witness supplies the exact
    /// serial; the assembler must still find the matching published host end.
    /// This never binds an operation or advances any semantic frontier.
    pub fn pendingControlEnd(self: *const Validator) ?PendingControlEnd {
        if (self.failed or self.finished) return null;
        const active = self.cursor.active[@intFromEnum(format.Role.control)] orelse return null;
        if (active.args != .tick) return null;
        for (self.pending[0..self.pending_count]) |record| {
            const serial = switch (record) {
                .frontier => |v| v.tick_serial,
                .acceptance => |v| v.tick_serial,
                .readiness => |v| v.key.tick_serial,
                else => continue,
            };
            if (self.bound(record) == null) return .{ .key = active.key, .tick_serial = serial };
        }
        return null;
    }
    fn ready(self: *Validator, record: format.Record) bool {
        if (self.bound(record) == null) return false;
        if (record == .acceptance and record.acceptance.kind == .tick_open and self.peers[1].ticks > self.peers[2].ticks) return false;
        if (record == .readiness) {
            const a = record.readiness.anchors;
            if (a.plan_sequence > self.semantic_sequences[0] or a.acceptance_sequence > self.semantic_sequences[1]) return false;
        }
        return true;
    }
    fn flush(self: *Validator) Error!void {
        var index: usize = 0;
        while (index < self.pending_count) {
            try self.dependencies.charge();
            const record = self.pending[index];
            const producer = witnessIndex(record).?;
            var earlier = false;
            for (self.pending[0..index]) |previous| if (witnessIndex(previous) == producer) {
                earlier = true;
                break;
            };
            if (earlier or !self.ready(record)) {
                index += 1;
                continue;
            }
            var move = index;
            while (move + 1 < self.pending_count) : (move += 1) self.pending[move] = self.pending[move + 1];
            self.pending_count -= 1;
            self.dependencies.releasePending();
            try self.witness(record);
            index = 0;
        }
    }
    fn queue(self: *Validator, record: format.Record) Error!void {
        // A ready record is consumed directly, without retaining a temporary
        // queue obligation. Earlier records of its own producer still win.
        var earlier = false;
        for (self.pending[0..self.pending_count]) |previous| if (witnessIndex(previous) == witnessIndex(record)) {
            earlier = true;
            break;
        };
        if (!earlier and self.ready(record)) {
            try self.witness(record);
            return self.flush();
        }
        if (self.pending_count >= localLimit(self.limits.pending_dependencies)) return error.DependencyCapacity;
        try self.dependencies.reservePending();
        self.pending[self.pending_count] = record;
        self.pending_count += 1;
        self.pending_high_water = @max(self.pending_high_water, self.pending_count);
        try self.flush();
    }
    pub fn feed(self: *Validator, record: format.Record) Error!void {
        return self.feedImpl(record) catch |err| {
            if (@import("builtin").is_test and !self.failed) {
                std.debug.print("causal validator feed failed: error={s} record={s} records={d} work={d}/{d} pending={d}/{d} checks={d} unsupported_cuts={d}\n", .{ @errorName(err), @tagName(record), self.cursor.records, self.dependencies.work, self.dependencies.work_limit, self.dependencies.pending_total, self.dependencies.capacity, self.checks, self.unsupported_cuts });
                if (@errorReturnTrace()) |error_trace| std.debug.dumpErrorReturnTrace(error_trace);
            }
            // Bounded first-failure inventory only; no successful-feed scan.
            // Validation/assembly is non-RT and the first cause stays visible
            // in normal offline builds without enabling test pacing probes.
            if (!self.failed and (err == error.DependencyCapacity or err == error.WorkBudget)) self.diagnosePending(record);
            self.failed = true;
            return err;
        };
    }
    fn feedImpl(self: *Validator, record: format.Record) Error!void {
        if (self.failed or self.finished) return error.Incomplete;
        try self.dependencies.charge();
        if (self.group_event_pending != null) {
            const host_key: ?format.OperationKey = switch (record) {
                .begin => |v| v.key,
                .end => |v| v.key,
                .input => |v| v.key,
                .schedule => |v| v.key,
                .scheduler_publication => |v| v.key,
                .group_source_final => |v| v.key,
                .service_exclusion => |v| v.key,
                .service_claim => |v| v.key,
                .service_worker_release => |v| v.key,
                .service_release_observation => |v| v.key,
                .group_event_queue => |v| v.key,
                else => null,
            };
            if (host_key) |key| if (key.role == .control and record != .schedule) return error.MissingAcquisition;
        }
        const previous = if (record == .end) self.cursor.active[@intFromEnum(record.end.key.role)] else null;
        try self.cursor.accept(record);
        switch (record) {
            .begin => |value| {
                try self.dependencies.reservePending();
                const role = @intFromEnum(value.key.role);
                if (value.key.role == .render) try self.consumed_cuts.callBegin(&self.dependencies, value.key.ordinal, value.args.render.frames);
                // Render progress has its own FIFO. A later Host/PCM begin
                // cannot reset occurrences of still-arriving earlier facts.
                if (value.key.role != .render) {
                    self.keyed_operations[role] = value.key.ordinal;
                    self.keyed_occurrences[role].count = 0;
                }
                if (value.key.role == .worker) {
                    if (self.worker.key != null) return error.InvalidEvidence;
                    self.worker = .{ .key = value.key };
                }
            },
            .end => |value| {
                self.dependencies.releasePending();
                if (value.result == .failed) return error.IncompleteCoverage;
                if (value.key.role == .worker) try self.endWorker(value);
                if (value.key.role == .render) self.render_ended = value.key.ordinal;
                if (value.result == .retirement_requested) {
                    if (self.retirement_request != null) return error.DuplicatePublication;
                    if (!self.retirement_pending) {
                        try self.dependencies.reservePending();
                        self.retirement_pending = true;
                    }
                    self.saw_retirement = true;
                    self.retirement_request = .{ .role = .control, .operation = value.key.ordinal, .site = .operation, .edge = .after };
                    try self.linkRetirement();
                }
                try self.bind(previous orelse return error.UnboundOperation, value);
                try self.flush();
            },
            .worker => |value| try self.workerFact(value.key, value.value),
            .service_exclusion => |value| try self.exclusion_tickets.observeFact(&self.dependencies, value.key, value.value),
            .service_claim => |value| try self.exclusion_tickets.observeClaim(&self.dependencies, value.key, value.value),
            .service_worker_release => |value| {
                const at = try point(value.key, .worker_release_progress, value.value.token, value.value.ticket, 0, .after);
                try self.exclusion_tickets.observeWorkerRelease(&self.dependencies, value.key, value.value, at);
                try self.check(at, value.value.token);
            },
            .service_release_observation => |value| {
                const at = try point(value.key, .control_release_progress, 0, 0, 0, .before);
                try self.exclusion_tickets.observeReleaseRead(&self.dependencies, value.key, value.token, value.after_claims, at);
                var after = at;
                after.edge = .after;
                try self.check(after, value.token);
            },
            .group_source_final => |value| {
                const at = try self.keyedPoint(value.key, .group_source_switch_final, value.value.group.index, value.value.group.generation);
                try self.check(at, @intFromBool(value.value.published));
                self.lifetimeLedger().sourceFinal(.{ .key = value.key, .value = value.value }) catch |err| return lifetimeError(err);
                try self.releaseClosedLifetimeBindings();
            },
            .frontier, .acceptance, .readiness, .render => try self.queue(record),
            .input => |value| switch (value.value.payload) {
                .request, .worker, .admission, .readiness_snapshot => {},
                // These are outside the stated public v1 operation set even
                // if an old general-purpose trace parser recognizes the tag.
                else => return error.UnsupportedOperation,
            },
            .schedule => |value| try self.groupEventSchedule(value.key, value.value),
            .group_event_queue => |value| try self.groupEventQueue(value.key, value.epoch, value.observation),
            .group_event_queue_terminal => |value| try self.groupEventTerminal(value.epoch, value.head, value.tail),
            .scheduler_publication => |value| {
                const v = value.value;
                if (v.block.index >= rt.scheduler.block_capacity or v.block.generation == 0 or v.batch_id == 0 or format.zero(v.content_hash)) return error.InvalidEvidence;
                const p = try self.keyedPoint(value.key, .scheduler_publication, v.block.index, v.block.generation);
                try self.dependencies.publish(identity(.scheduler_acquired, v.block.index, v.block.generation), p);
                try self.progressPublish(.block_state, v.block.index, v.block.generation, @intFromEnum(rt.scheduler.State.published), p);
                try self.check(p, @intFromEnum(rt.scheduler.State.published));
                self.scheduler_publications += 1;
                self.lifetimeLedger().publication(.{ .key = value.key, .value = v }) catch |err| {
                    const mapped = lifetimeError(err);
                    return mapped;
                };
                try self.releaseClosedLifetimeBindings();
            },
            .stream_consumed_range => |value| try self.consumed_cuts.callRange(&self.dependencies, value),
            .stream_consumed_call_end => |value| try self.consumed_cuts.callEnd(&self.dependencies, value.key.ordinal, value.ranges, value.publications),
            .scheduler_progress => |value| {
                const v = value.value;
                if (v.generation == 0 or v.index >= rt.scheduler.block_capacity) return error.InvalidEvidence;
                const site: Site = switch (v.site) {
                    .scheduler_acquired => .scheduler_acquired,
                    .scheduler_phase => .scheduler_phase,
                    .scheduler_receipt => .scheduler_receipt,
                    .scheduler_terminal => .scheduler_terminal,
                };
                const kind: ProgressKind = switch (v.site) {
                    .scheduler_acquired, .scheduler_terminal => .block_state,
                    .scheduler_phase => .plan_phase,
                    .scheduler_receipt => .block_receipt,
                };
                if (v.site == .scheduler_acquired and v.value != @intFromEnum(rt.scheduler.State.acquired)) return error.InvalidEvidence;
                if (v.site == .scheduler_terminal and v.value != @intFromEnum(rt.scheduler.State.terminal)) return error.InvalidEvidence;
                if ((kind == .plan_phase or kind == .block_receipt) and v.value == 0) return error.InvalidEvidence;
                const p = try self.keyedPoint(value.key, site, v.index, v.generation);
                try self.progressPublish(kind, @intCast(v.index), v.generation, v.value, p);
                try self.check(p, v.value);
            },
            .group_terminal => |value| {
                const v = value.value;
                if (v.group.index >= rt.scheduler.block_capacity or v.group.generation == 0 or v.bank_generation != self.header.identity.generation) return error.StaleIdentity;
                const p = try self.keyedPoint(value.key, .group_terminal_publish, v.group.index, v.group.generation);
                try self.progressPublish(.group_terminal, v.group.index, v.group.generation, 1, p);
                try self.check(p, 1);
            },
            .render_terminal => |value| self.render_terminal = value,
            .readiness_terminal => |value| self.readiness_terminal = value,
            .frontier_terminal, .acceptance_terminal, .pcm => {},
        }
    }
    // Failure-only assembler diagnostics. No successful-feed scan, retained
    // accounting, producer access, admission change, or proof retirement.
    fn diagnosticCount(items: anytype) usize {
        var count: usize = 0;
        for (items) |item| if (item != null) {
            count += 1;
        };
        return count;
    }
    fn diagnosePending(self: *const Validator, record: format.Record) void {
        std.debug.print("causal cumulative work evidence: emitted_dependencies={d} consumed_ranges={d} host_operations(control/render/worker)={any}\n", .{
            self.dependencies.emitted, self.consumed_cuts.ranges_count, self.cursor.operations,
        });
        var prefixes: [10]usize = @splat(0);
        for ([_]*const Prefix{
            &self.render_frames,          &self.commit_horizons,         &self.stream_frontier,
            &self.observation_sequences,  &self.observation_frames,      &self.stream_admissions,
            &self.completion_cuts.writes, &self.completion_cuts.returns, &self.group_event_writes,
            &self.group_event_returns,
        }, 0..) |prefix, index| prefixes[index] = diagnosticCount(&prefix.reads);
        var counts = std.mem.zeroes(struct {
            relations: usize,
            ownership_reads: usize,
            hosts: usize,
            bindings: usize,
            queued: usize,
            retirement: usize,
            query: usize,
            group_event_schedule: usize,
            prefetches: usize,
            prefix_reads: usize,
            job_rows: usize,
            job_reads: usize,
            streams: usize,
            jobs: usize,
            visibility_owners: usize,
            stop_lives: usize,
            stop_reads: usize,
            consumed_calls: usize,
            consumed_lives: usize,
            consumed_reads: usize,
            groups: usize,
            group_reads: usize,
            group_releases: usize,
            group_consumed: usize,
            group_leases: usize,
            exclusion_holders: usize,
            exclusion_claims: usize,
            exclusion_reads: usize,
            lifetime_credits: usize,
            progress_tracks: usize,
            progress_reads: usize,
            progress_facts: usize,
        });
        counts.relations = self.dependencies.live;
        counts.ownership_reads = self.dependencies.pending_reads;
        counts.hosts = diagnosticCount(&self.cursor.active);
        counts.bindings = diagnosticCount(&self.bindings);
        counts.queued = self.pending_count;
        counts.retirement = @intFromBool(self.retirement_pending);
        counts.query = @intFromBool(self.query != null);
        counts.group_event_schedule = @intFromBool(self.group_event_pending != null);
        for (&self.bindings) |*entry| if (entry.*) |*binding| {
            if (binding.pending_prefetch != null) counts.prefetches += 1;
        };
        for (prefixes) |count| counts.prefix_reads += count;
        for (&self.job_cuts.rows) |*entry| if (entry.*) |*row| {
            // Completed rows can retain uncharged duplicate-detection history.
            if (row.pending) counts.job_rows += 1;
        };
        counts.job_reads = diagnosticCount(&self.job_cuts.reads);
        // Failure-only bounded inventory, not an additional proof pass. At
        // most max_pending^2 comparisons; no retained rows or per-read output.
        // Matrix columns: queued/running/completed/free, each with flags
        // lower + 2*upper = 0(neither),1(lower),2(upper),3(both).
        var job_read_matrix: [3][16]usize = @splat(@splat(0));
        var job_owner_reads: [3]usize = @splat(0);
        var job_initial_free: [3]usize = @splat(0);
        var job_distinct_pairs: usize = 0;
        var job_role_distinct: [3]usize = @splat(0);
        var job_role_max_endpoints: [3]usize = @splat(0);
        for (self.job_cuts.reads, 0..) |entry, sample_index| if (entry) |sample| {
            const role_index = @intFromEnum(sample.at.role);
            const flags: usize = @as(usize, @intFromBool(sample.lower)) + 2 * @as(usize, @intFromBool(sample.upper));
            job_read_matrix[role_index][@as(usize, @intFromEnum(sample.state)) * 4 + flags] += 1;
            job_owner_reads[role_index] += @intFromBool(sample.owner_position != null);
            job_initial_free[role_index] += @intFromBool(sample.state == .free and sample.job == 0);
            var prior_pair = false;
            var prior_role_pair = false;
            var role_endpoints: usize = 0;
            for (self.job_cuts.reads, 0..) |other_entry, other_index| if (other_entry) |other| {
                if (other.index != sample.index or other.job != sample.job) continue;
                if (other_index < sample_index) prior_pair = true;
                if (other.at.role == sample.at.role) {
                    role_endpoints += 1;
                    if (other_index < sample_index) prior_role_pair = true;
                }
            };
            job_distinct_pairs += @intFromBool(!prior_pair);
            job_role_distinct[role_index] += @intFromBool(!prior_role_pair);
            job_role_max_endpoints[role_index] = @max(job_role_max_endpoints[role_index], role_endpoints);
        };
        for (self.streams) |entry| if (entry.live) {
            counts.streams += 1;
        };
        for (self.jobs) |entry| if (entry.live) {
            counts.jobs += 1;
        };
        counts.visibility_owners = diagnosticCount(&self.visibility_owners.rows);
        counts.stop_lives = diagnosticCount(&self.stream_stop_cuts.lives);
        counts.stop_reads = diagnosticCount(&self.stream_stop_cuts.reads);
        counts.consumed_calls = diagnosticCount(&self.consumed_cuts.calls);
        counts.consumed_lives = diagnosticCount(&self.consumed_cuts.lives);
        counts.consumed_reads = diagnosticCount(&self.consumed_cuts.reads);
        counts.groups = diagnosticCount(&self.group_pins.groups);
        counts.group_reads = diagnosticCount(&self.group_pins.reads);
        for (&self.group_pins.groups) |*entry| if (entry.*) |*group| {
            counts.group_releases += @intFromBool(group.release_attempt != null);
            counts.group_leases += @popCount(group.lease_mask);
            for (group.consumed) |consumed| if (consumed) |value| {
                counts.group_consumed += @intFromBool(value.pending);
            };
        };
        counts.exclusion_holders = self.exclusion_tickets.count;
        counts.exclusion_claims = self.exclusion_tickets.claim_count;
        counts.exclusion_reads = self.exclusion_tickets.release_read_count;
        // Ledger.pending is the exact sum of its reserve/release actions,
        // all routed to this same Dependencies; do not also count its rows.
        counts.lifetime_credits = self.lifetimes.pending;
        for (&self.progress_tracks) |*entry| if (entry.*) |*track| {
            if (track.pending) counts.progress_tracks += 1;
            counts.progress_reads += diagnosticCount(&track.prefix.reads);
        };
        counts.progress_facts = diagnosticCount(&self.progress_facts);
        var accounted: usize = 0;
        inline for (std.meta.fields(@TypeOf(counts))) |field| accounted += @field(counts, field.name);
        // The observed queue-reservation failure occurs before insertion and
        // should reconcile exactly. Other failures may interrupt row updates;
        // expose either residual rather than inventing ownership or asserting.
        std.debug.print("causal capacity: record={s} records={d} pending={d}/{d} high_water={d} accounted={d} unclassified={d} overcount={d}\n", .{
            @tagName(record),             self.cursor.records, self.dependencies.pending_total,              self.dependencies.capacity,
            self.dependencies.high_water, accounted,           self.dependencies.pending_total -| accounted, accounted -| self.dependencies.pending_total,
        });
        std.debug.print("causal charged inventory: {any}\n", .{counts});
        if (comptime partition_compiled) {
            if (self.dependencies.partitioned()) std.debug.print("causal partition: shared/stop_history/consumed_history/live_stream/live_job={any} job_base={d}/96 conserved={} local_table={d}\n", .{ self.dependencies.partition.counts, self.dependencies.partition.job_read_count, self.dependencies.partitionConserved(), max_pending });
        }
        for (job_read_matrix, 0..) |matrix, role_index| {
            std.debug.print("causal job reads role={d} states(queued,running,completed,free)*flags(lower+2upper)={any} owner_position={d} initial_free={d} distinct_slot_job={d} max_same_role_slot_job_endpoints={d}\n", .{
                role_index, matrix, job_owner_reads[role_index], job_initial_free[role_index], job_role_distinct[role_index], job_role_max_endpoints[role_index],
            });
        }
        std.debug.print("causal job reads distinct_slot_job_all_roles={d}\n", .{job_distinct_pairs});
        std.debug.print("causal prefix reads(frame/horizon/frontier/sequence/observation_frame/admissions/completion_write/completion_return/group_write/group_return)={any}\n", .{prefixes});
        var stop_closed: usize = 0;
        for (self.stream_stop_cuts.lives) |entry| if (entry) |life| {
            stop_closed += @intFromBool(life.closed != null);
        };
        var consumed_retired: usize = 0;
        for (self.consumed_cuts.lives) |entry| if (entry) |life| {
            consumed_retired += @intFromBool(life.retired);
        };
        std.debug.print("causal retained generations: stop_closed={d}/{d} consumed_retired={d}/{d}; exclusion publication={d} read_floor={d} paired_control={d} control_watermark={d}\n", .{
            stop_closed,                                 counts.stop_lives,                         consumed_retired,                      counts.consumed_lives,
            self.exclusion_tickets.release_publications, self.exclusion_tickets.release_read_floor, self.exclusion_tickets.paired_control, self.exclusion_tickets.control_watermark,
        });
        var queued: [4]usize = @splat(0);
        var oldest: [4]?usize = @splat(null);
        for (self.pending[0..self.pending_count], 0..) |pending, index| {
            const producer = witnessIndex(pending) orelse continue;
            queued[producer] += 1;
            if (oldest[producer] == null) oldest[producer] = index;
        }
        var lag: [4]u64 = undefined;
        for (&lag, self.cursor.events, self.semantic_sequences) |*value, received, consumed| value.* = received -| consumed;
        // Cursor includes the incoming record when grammar admission succeeded;
        // queued excludes a record whose reservation failed. Neither sequence
        // is a producer-ring snapshot or an inter-role execution clock.
        std.debug.print("causal witness delay(frontier/acceptance/readiness/render): cursor_received={any} semantic_consumed={any} lag={any} queued={any} peer_ticks={d}/{d}/{d}; producer_ring_backlog=unavailable\n", .{
            self.cursor.events, self.semantic_sequences, lag, queued, self.peers[0].ticks, self.peers[1].ticks, self.peers[2].ticks,
        });
        for (oldest) |index| if (index) |i| self.diagnoseQueued("oldest", self.pending[i]);
        if (witnessIndex(record) != null) self.diagnoseQueued("incoming", record);
    }
    fn diagnoseQueued(self: *const Validator, label: []const u8, record: format.Record) void {
        const producer = witnessIndex(record) orelse return;
        const role: format.Role = if (record == .render) .render else .control;
        const sequence: u64 = switch (record) {
            .frontier => |v| v.sequence,
            .acceptance => |v| v.sequence,
            .readiness => |v| v.sequence,
            .render => |v| v.sequence,
            else => unreachable,
        };
        const serial: u64 = switch (record) {
            .frontier => |v| v.tick_serial,
            .acceptance => |v| v.tick_serial,
            .readiness => |v| v.key.tick_serial,
            .render => |v| v.render_call_sequence,
            else => unreachable,
        };
        const kind = switch (record) {
            .frontier => |v| @tagName(v.kind),
            .acceptance => |v| @tagName(v.kind),
            .readiness => |v| @tagName(v.payload),
            .render => |v| @tagName(v.payload),
            else => unreachable,
        };
        var bound_operation: ?u64 = null;
        for (&self.bindings) |*entry| if (entry.*) |*binding| {
            if (binding.key.role == role and binding.serial == serial) bound_operation = binding.key.ordinal;
        };
        const active = self.cursor.active[@intFromEnum(role)];
        const active_operation: ?u64 = if (active) |value| value.key.ordinal else null;
        const required: [2]u64 = if (record == .readiness)
            .{ record.readiness.anchors.plan_sequence, record.readiness.anchors.acceptance_sequence }
        else
            .{ 0, 0 };
        const waiting_semantic = [2]u64{ required[0] -| self.semantic_sequences[0], required[1] -| self.semantic_sequences[1] };
        const not_received = [2]u64{ required[0] -| self.cursor.events[0], required[1] -| self.cursor.events[1] };
        const acceptance_tick_gate = record == .acceptance and record.acceptance.kind == .tick_open and self.peers[1].ticks > self.peers[2].ticks;
        std.debug.print("causal queued {s}: producer={d} kind={s} sequence={d} serial={d} bound_operation={?d} active_role_operation={?d} acceptance_tick_gate={any} required(plan/acceptance)={any} waiting_semantic={any} not_received={any}\n", .{
            label,                producer, kind,             sequence,     serial, bound_operation, active_operation,
            acceptance_tick_gate, required, waiting_semantic, not_received,
        });
    }
    fn workerFact(self: *Validator, key: format.OperationKey, fact: format.WorkerFact) Error!void {
        if (self.worker.key == null or !std.meta.eql(self.worker.key.?, key) or self.worker.idle) return error.InvalidEvidence;
        switch (fact) {
            .scan => |v| {
                if (self.worker.selected != 0 or v.index != self.worker.scanned or v.index >= max_resource_slots) return error.InvalidEvidence;
                if (self.dependencies.partitioned() and v.index >= 48) return error.InvalidEvidence;
                self.worker.scanned += 1;
                if (v.state == .queued) {
                    if (v.job == 0 or v.handle.generation == 0 or v.generation != self.header.identity.generation or v.transport_epoch != self.header.bindings.render_manifest.transport_epoch) return error.StaleIdentity;
                    self.worker.queued[v.index] = v.job;
                    // Actual Service.jobs[index].state scan in Worker FIFO;
                    // the watermark belongs only to this bound Service/session.
                    try self.dependencies.orderedRead(identity(.job_selected, v.index, v.job), try point(key, .worker_scan, v.index, 0, 0, .before));
                } else if (v.job != 0 or v.handle.generation != 0 or v.generation != 0 or v.transport_epoch != 0) return error.InvalidEvidence;
                const observed_job = if (v.state == .queued) v.job else self.worker_last[v.index];
                try self.job_cuts.acquire(&self.dependencies, v.index, observed_job, switch (v.state) {
                    .free => .free,
                    .queued => .queued,
                    .completed => .completed,
                    .running => return error.InvalidEvidence,
                }, try point(key, .worker_scan, v.index, 0, 0, .before));
                // A running slot is impossible under one persistent Worker.
                if (v.state == .running) return error.InvalidEvidence;
                try self.check(try point(key, .worker_scan, v.index, 0, 0, .after), @intFromEnum(v.state));
            },
            .selected => |v| {
                if (self.worker.selected != 0 or self.worker.scanned == 0 or v.slot >= self.worker.scanned or v.job == 0 or self.worker.queued[v.slot] != v.job) return error.InvalidEvidence;
                self.worker.selected = v.job;
                self.worker.slot = v.slot;
                self.worker_last[v.slot] = v.job;
                try self.job_cuts.publish(&self.dependencies, v.slot, v.job, .running, try point(key, .worker_running, v.slot, v.job, 0, .after));
                try self.dependencies.consume(identity(.job_selected, v.slot, v.job), try point(key, .worker_running, v.slot, v.job, 0, .before));
                try self.check(try point(key, .worker_running, v.slot, v.job, 0, .after), @intFromEnum(stream.observation.JobState.running));
            },
            .clock => |v| {
                if (v.job != self.worker.selected or v.job == 0 or self.worker.completed or v.error_code != 0 or (!v.available and v.value != 0)) return error.InvalidEvidence;
                switch (v.stage) {
                    .begin => {
                        if (self.worker.clocks != 0) return error.InvalidEvidence;
                        self.worker.clocks = 1;
                    },
                    .end => {
                        if (self.worker.clocks != 1) return error.InvalidEvidence;
                        self.worker.clocks = 2;
                    },
                }
            },
            .source_read => |v| {
                if (self.worker.selected == 0 or self.worker.clocks != 1 or self.worker.completed or v.asset == 0 or format.zero(v.asset_hash) or v.generation == 0 or v.length == 0 or v.error_code != 0) return error.InvalidEvidence;
                _ = try add(v.offset, v.length);
            },
            .completed => |v| {
                if (v.job != self.worker.selected or v.slot != self.worker.slot or v.job == 0 or self.worker.completed or self.worker.clocks != 2) return error.InvalidEvidence;
                self.worker.completed = true;
                try self.job_cuts.publish(&self.dependencies, v.slot, v.job, .completed, try point(key, .worker_completed, v.slot, v.job, 0, .after));
                try self.dependencies.publish(identity(.job_completed, v.slot, v.job), try point(key, .worker_completed, v.slot, v.job, 0, .after));
                try self.check(try point(key, .worker_completed, v.slot, v.job, 0, .after), @intFromEnum(stream.observation.JobState.completed));
            },
            .idle => |v| {
                if (v.job != self.worker.selected or (v.job != 0 and !self.worker.completed) or self.worker.scanned == 0) return error.InvalidEvidence;
                self.worker.idle = true;
                const claim = try point(key, .worker_claim, 0, 0, 0, .before);
                var claimed = claim;
                claimed.edge = .after;
                const released = try point(key, .worker_idle, 0, v.job, 0, .after);
                try self.check(claimed, 0);
                try self.check(released, 0);
                // A real idle fact covers every successful Worker invocation,
                // including empty job0 pumps. The ticket alone is insufficient.
                try self.exclusion_tickets.expectScope(&self.dependencies, .{
                    .key = key,
                    .owner = .{ .worker = .{ .job = v.job } },
                    .claim = claim,
                    .release = released,
                });
            },
        }
    }
    fn endWorker(self: *Validator, end: format.OperationEnd) Error!void {
        if (end.result != .worked or self.worker.key == null or !std.meta.eql(self.worker.key.?, end.key)) return error.InvalidEvidence;
        const result = end.result.worked;
        // The captured profile retains its context Service throughout source
        // retirement. workerOneV1 first scans/decodes that Service, then may
        // close one actual source or unbind the provider on the same Worker.
        if (self.worker.scanned == 0 or !self.worker.idle) return error.MissingAcquisition;
        const retired_work = result.closed_source != null or result.unbound;
        if (result.worked != (self.worker.selected != 0 or retired_work)) return error.MissingAcquisition;
        if (self.worker_slots) |slots| {
            if (slots != self.worker.scanned) return error.InvalidEvidence;
        } else self.worker_slots = self.worker.scanned;
        if (self.worker.selected == 0) for (self.worker.queued[0..self.worker.scanned]) |job| if (job != 0) return error.InvalidEvidence;
        if (self.saw_retirement_ack and (!result.retirement_acknowledged or retired_work)) return error.InvalidEvidence;
        if (result.closed_source) |asset| {
            if (asset == 0 or result.unbound or self.source_unbound) return error.InvalidEvidence;
            for (self.closed_sources[0..self.closed_source_count]) |previous_asset| if (previous_asset == asset) return error.DuplicateAcquisition;
            if (self.closed_source_count == localLimit(self.limits.pending_dependencies)) return error.DependencyCapacity;
            self.closed_sources[self.closed_source_count] = asset;
            self.closed_source_count += 1;
        }
        if (result.unbound) {
            if (self.source_unbound or !result.retirement_acknowledged) return error.InvalidEvidence;
            self.source_unbound = true;
        }
        if ((result.retirement_acknowledged or result.closed_source != null or result.unbound) and self.retirement_worker == null) {
            if (!self.retirement_pending) {
                try self.dependencies.reservePending();
                self.retirement_pending = true;
            }
            self.retirement_worker = .{ .role = .worker, .operation = end.key.ordinal, .site = .operation, .edge = .before };
        }
        if (result.retirement_acknowledged) {
            // Host lanes may arrive in either order. The typed retirement
            // request is required by finish, not guessed from arrival order.
            self.saw_retirement_ack = true;
        }
        try self.linkRetirement();
        try self.exclusion_tickets.closeOperation(&self.dependencies, end.key);
        self.worker.key = null;
    }
    fn linkRetirement(self: *Validator) Error!void {
        if (!self.retirement_linked) {
            const released = self.retirement_request orelse return;
            const acquired = self.retirement_worker orelse return;
            if (!self.retirement_pending) return error.InvalidEvidence;
            try self.dependencies.emit(released, acquired);
            self.retirement_linked = true;
        }
        // Pairing the request with the first close does not prove that all
        // retirement work completed. Keep its one credit until the real ack.
        if (self.retirement_pending and self.saw_retirement_ack) {
            self.dependencies.releasePending();
            self.retirement_pending = false;
        }
    }
    fn witness(self: *Validator, record: format.Record) Error!void {
        const index = self.bound(record) orelse return error.UnboundOperation;
        const binding = self.bindings[index].?;
        const producer = witnessIndex(record).?;
        const sequence = switch (record) {
            .frontier => |v| v.sequence,
            .acceptance => |v| v.sequence,
            .readiness => |v| v.sequence,
            .render => |v| v.sequence,
            else => unreachable,
        };
        if (sequence != self.semantic_sequences[producer] + 1) return error.InvalidOrder;
        switch (record) {
            .frontier => |v| try self.frontier(binding, v),
            .acceptance => |v| try self.acceptance(binding, v),
            .readiness => |v| try self.readiness(binding, v),
            .render => |v| try self.render(binding, v),
            else => unreachable,
        }
        self.semantic_sequences[producer] = sequence;
        const closed = switch (record) {
            .frontier => |v| v.kind == .tick_close,
            .acceptance => |v| v.kind == .tick_close,
            .readiness => |v| v.payload == .tick_close,
            .render => |v| v.payload == .call_end,
            else => false,
        };
        if (closed) {
            self.bindings[index].?.finished |= @as(u8, 1) << @as(u3, @intCast(producer));
            if (self.bindings[index].?.finished == (if (binding.key.role == .render) @as(u8, 8) else 7)) {
                const complete = self.bindings[index].?;
                if (complete.pending_prefetch != null) return error.MissingAcquisition;
                if (complete.result == .tick_failed) {
                    // All three real close paths must agree with one actual
                    // same-tick failed supply. No host error class alone proves
                    // a raced cut or undoes work already done by this tick.
                    const cause = complete.availability_failure orelse return error.IncompleteCoverage;
                    if (complete.accepted_frame == null or cause.position.accepted_control_frame != complete.accepted_frame.? or cause.position.control_tick != complete.control_tick or cause.tick_serial != complete.serial) return error.InvalidEvidence;
                    self.proved_failed_ticks += 1;
                } else if (complete.availability_failure != null) return error.InvalidEvidence;
                if (complete.key.role == .control) {
                    try self.job_cuts.closeOwnerBinding(&self.dependencies, complete.key.ordinal);
                    try self.visibility_owners.closeOperation(&self.dependencies, complete.key.ordinal);
                    // All three actual Control witness closes have arrived.
                    // Close once here, even if lifetime work retains binding.
                    try self.exclusion_tickets.closeOperation(&self.dependencies, complete.key);
                }
                if (!try self.lifetimeBindingPending(complete)) {
                    self.bindings[index] = null;
                    self.dependencies.releasePending();
                }
            }
        }
    }
    fn peer(self: *Validator, index: usize, binding: Binding, value: anytype) Error!void {
        const state = &self.peers[index];
        if (value.control_tick != binding.control_tick or value.tick_serial != binding.serial) return error.StaleIdentity;
        if (value.kind == .tick_open) {
            if (state.open or value.tick_serial <= state.serial or value.control_tick <= state.control_tick) return error.InvalidEvidence;
            state.open = true;
            state.serial = value.tick_serial;
            state.control_tick = value.control_tick;
            state.ordinal = 0;
        }
        if (!state.open or state.serial != value.tick_serial) return error.InvalidEvidence;
        if (comptime @TypeOf(value) == format.frontier.Event) {
            if (value.kind == .plan_query) {
                if (value.query_ordinal != state.ordinal + 1) return error.InvalidEvidence;
                state.ordinal += 1;
            }
        } else if (value.kind == .visibility_poll or value.kind == .acceptance) {
            if (value.attempt_ordinal != state.ordinal + 1) return error.InvalidEvidence;
            state.ordinal += 1;
        }
        self.anchors[index][@intCast((value.sequence - 1) % max_pending)] = .{ .sequence = value.sequence, .tick = value.tick_serial, .control_tick = value.control_tick, .ordinal = state.ordinal, .phase = @intCast(@intFromEnum(value.phase)), .closed = value.kind == .tick_close };
        if (value.kind == .tick_close) {
            if (binding.result == .tick_failed) {
                if (value.outcome != .failed or value.error_code != format.observed_invalid_state or value.phase != .publish or value.exit_phase != .publish) {
                    // Non-RT validation first-cause evidence only. Keep the
                    // supported failed-tick admission predicate unchanged.
                    std.debug.print("causal failed close mismatch: peer={d} role={s} operation={d} tick={d} serial={d} sequence={d} outcome={s} error_code={d} expected_error={d} phase={s} exit_phase={s} finished={d} supply_failure={} accepted_frame={?d}\n", .{
                        index,                                @tagName(binding.key.role), binding.key.ordinal,           binding.control_tick,  binding.serial,             value.sequence,
                        @tagName(value.outcome),              value.error_code,           format.observed_invalid_state, @tagName(value.phase), @tagName(value.exit_phase), binding.finished,
                        binding.availability_failure != null, binding.accepted_frame,
                    });
                    return error.InvalidEvidence;
                }
            } else if (value.outcome != .success or value.error_code != 0) return error.InvalidEvidence;
            state.open = false;
            state.ticks += 1;
        }
    }
    fn frontier(self: *Validator, binding: Binding, value: format.frontier.Event) Error!void {
        // The phase alone cannot tell whether publishSnapshot independently
        // replaced the preparation error. This marker is written only after
        // both mandatory catch-path operations really succeeded, immediately
        // before the runtime returns the original preparation failure.
        if (value.kind == .tick_close and binding.result == .tick_failed) {
            if (value.return_path != .prepare_failure_after_control_publication) return error.IncompleteCoverage;
        } else if (value.return_path != .ordinary) return error.InvalidEvidence;
        try self.peer(0, binding, value);
        switch (value.kind) {
            .collect_frame => {
                const index = self.bound(.{ .frontier = value }).?;
                if (value.phase != .collect or self.bindings[index].?.collect_frame != null) return error.InvalidEvidence;
                // This first load precedes collect(); the later readiness
                // collection_frame is an independent acquire and may be newer.
                const at = try self.controlCollectFrame(binding.key, value.frame);
                self.bindings[index].?.collect_frame = .{ .frame = value.frame, .at = at, .control_tick = value.control_tick, .tick_serial = value.tick_serial, .sequence = value.sequence };
            },
            .accept_frame => {
                const index = self.bound(.{ .frontier = value }).?;
                if (self.bindings[index].?.accepted_frame != null or value.phase != .accept) return error.InvalidEvidence;
                self.bindings[index].?.accepted_frame = value.frame;
                const p = try point(binding.key, .control_accept_frame, 0, 0, 0, .before);
                try self.render_frames.acquire(&self.dependencies, value.frame, p);
                var after = p;
                after.edge = .after;
                try self.check(after, value.frame);
            },
            .plan_query => {
                if (value.plan_result != .frame or value.error_code != 0) return error.InvalidEvidence;
                try self.planHorizon(binding.key, value.horizon, value.min_plan_lead_frames, value.late_race_budget_frames, value.frame);
            },
            else => {},
        }
    }
    fn horizonRead(self: *Validator, key: format.OperationKey, site: Site, horizon: u64) Error!void {
        var at = try self.boundPoint(key, site, 0, 0, .before);
        try self.commit_horizons.acquire(&self.dependencies, horizon, at);
        at.edge = .after;
        try self.check(at, horizon);
    }
    fn planHorizon(self: *Validator, key: format.OperationKey, horizon: u64, lead: u64, budget: u64, frame: u64) Error!void {
        if (lead != rt.scheduler.default_profile.min_plan_lead_frames or budget != rt.scheduler.default_profile.late_race_budget_frames or frame != try add(horizon, try add(lead, budget))) return error.InvalidEvidence;
        try self.horizonRead(key, .control_horizon, horizon);
    }
    fn horizonBegin(self: *Validator, key: format.OperationKey, occurrence: u32, frame: u64) Error!void {
        // Same Render FIFO: beginGate repeats exactly the preceding span's
        // endpoint (initial frame for the first gate). This actual same-value
        // release has its own comparator, but creates no new value interval.
        if (self.horizon_gate_open or frame != self.commit_horizons.latest) return error.InvalidEvidence;
        try self.check(try point(key, .scheduler_horizon, 0, 0, occurrence, .after), frame);
        self.horizon_gate_open = true;
    }
    fn horizonEnd(self: *Validator, key: format.OperationKey, occurrence: u32, frame: u64) Error!void {
        if (!self.horizon_gate_open or frame <= self.commit_horizons.latest) return error.InvalidEvidence;
        // gate_end records the real next endpoint. Its release occurred BEFORE
        // DSP at this distinct checkpoint, not at the later render_frame store.
        const at = try point(key, .render_commit_horizon, 0, 0, occurrence, .after);
        try self.commit_horizons.publish(&self.dependencies, frame, at);
        try self.check(at, frame);
        self.horizon_gate_open = false;
    }
    fn controlCollectFrame(self: *Validator, key: format.OperationKey, frame: u64) Error!Point {
        const at = try self.boundPoint(key, .control_collect_frame, 0, 0, .before);
        try self.render_frames.acquire(&self.dependencies, frame, at);
        var after = at;
        after.edge = .after;
        try self.check(after, frame);
        return at;
    }
    fn acceptance(self: *Validator, binding: Binding, value: format.acceptance.Event) Error!void {
        try self.peer(1, binding, value);
        const binding_index = self.bound(.{ .acceptance = value }).?;
        const counters = &self.bindings[binding_index].?;
        if (value.visibility) |v| {
            if (value.kind != .visibility_poll or value.acceptance != null or v.tail != self.acknowledgement_ordinal or v.read < v.tail) return error.InvalidEvidence;
            const acquired = try self.visibilityPollRead(binding.key, v.read);
            if (v.descriptor) |descriptor| {
                if (!v.acknowledged or v.tail >= v.read or descriptor.publication_ordinal != self.acknowledgement_ordinal + 1) return error.InvalidEvidence;
                const id = descriptor.publication_ordinal;
                try self.dependencies.consume(identity(.publication_acknowledged, slot(id), id), acquired);
                const acknowledged = try self.boundPoint(binding.key, .visibility_ack, 0, 0, .after);
                try self.check(acknowledged, id);
                try self.visibility_owners.acknowledge(&self.dependencies, descriptor, .{ .operation = binding.key.ordinal, .acceptance_sequence = value.sequence }, acknowledged);
                self.acknowledgement_ordinal = id;
            } else if (v.acknowledged or v.admission != null or v.tail != v.read) return error.InvalidEvidence;
        }
        if (value.acceptance) |v| {
            if (self.dependencies.partitioned() and v.job_slots > 48) return error.InvalidEvidence;
            const scan_ordinal = counters.acceptance_calls;
            counters.acceptance_calls += 1;
            const availability_changed = format.acceptanceAvailabilityChanged(v);
            if (value.kind != .acceptance or value.visibility != null or !v.representation_complete or v.job_slots == 0 or v.job_slots > max_resource_slots or v.scanned != v.job_slots or (v.error_code != 0 and !availability_changed) or v.replay_mode) return error.InvalidEvidence;
            if (v.outcome == .availability_unavailable and !availability_changed) return error.InvalidEvidence;
            if (availability_changed and (value.phase != .accept or counters.accepted_frame == null or v.position.accepted_control_frame != counters.accepted_frame.? or v.availability.requested_frame != counters.accepted_frame)) return error.InvalidEvidence;
            if (self.worker_slots) |count| if (count != v.job_slots) return error.InvalidEvidence;
            for (v.states[0..v.scanned], 0..) |state, index| {
                const p = try point(binding.key, .acceptance_scan, index, 0, scan_ordinal, .before);
                if (state == .completed) {
                    const completed = v.completed[index];
                    if (completed.job == 0 or completed.handle.generation == 0 or completed.generation != self.header.identity.generation or completed.transport_epoch != self.header.bindings.render_manifest.transport_epoch) return error.StaleIdentity;
                    // The acceptance producer and deferred flush preserve its
                    // FIFO scans of this same Service.jobs[index].state field.
                    try self.dependencies.orderedRead(identity(.job_completed, @intCast(index), completed.job), p);
                } else if (v.completed[index].job != 0) return error.InvalidEvidence;
                const known = self.jobs[index];
                const observed_job = if (state == .completed) v.completed[index].job else known.job;
                if (state != .free and (!known.live or known.job != observed_job)) return error.MissingPublication;
                try self.job_cuts.acquireOrdered(&self.dependencies, @intCast(index), observed_job, switch (state) {
                    .free => .free,
                    .queued => .queued,
                    .running => .running,
                    .completed => .completed,
                }, p, .{ .acceptance = value.sequence });
                var after = p;
                after.edge = .after;
                try self.check(after, @intFromEnum(state));
            }
            if (v.selected) |selected| {
                if (selected.slot >= v.scanned or v.states[selected.slot] != .completed or v.completed[selected.slot].job != selected.descriptor.job) return error.InvalidEvidence;
                try self.availabilityReads(binding.key, selected.handle, v.availability, .acceptance);
                if (v.ring_writable) |cut| try self.ringReadCut(binding.key, selected.handle, cut);
                {
                    const publication = v.ring_publish;
                    if (publication.availability) |cut| try self.ringReadCut(binding.key, selected.handle, cut);
                    if (publication.end) |end| {
                        const at = try self.boundPoint(binding.key, .stream_produced, selected.handle.index, selected.handle.generation, .after);
                        try self.check(at, end);
                    }
                }
                // Preserve the actual longer-prefix comparators, but its
                // per-stream consumed/produced publications are not yet bound.
                if (availability_changed and v.availability.sequence_after != null) self.noteUnsupported(.acceptance_changed_sequence);
                const job = &self.jobs[selected.slot];
                // Readiness and acceptance rings have independent drain order.
                // Full identity matching is also enforced by the two exact
                // request/complete obligations, never by an inferred job slot.
                if (job.live and job.job == selected.descriptor.job) {
                    if (!std.meta.eql(job.handle, selected.handle) or job.ordinal != selected.ordinal or job.count != selected.count) return error.InvalidEvidence;
                }
                if (v.effects.job_released) {
                    if (v.accepted == null or v.actual_worker == null or v.actual_worker.?.job != selected.descriptor.job or v.accepted.?.input.payload != .worker or !std.meta.eql(v.actual_worker.?, v.accepted.?.input.payload.worker)) return error.InvalidEvidence;
                    try self.dependencies.consume(identity(.job_completed, selected.slot, selected.descriptor.job), try point(binding.key, .job_free, selected.slot, selected.descriptor.job, 0, .before));
                    try self.job_cuts.publishFree(&self.dependencies, selected.slot, selected.descriptor.job, selected.handle, .{ .operation = binding.key.ordinal, .acceptance_sequence = value.sequence }, try point(binding.key, .job_free, selected.slot, selected.descriptor.job, 0, .after));
                    if (job.job == selected.descriptor.job and job.live) {
                        job.live = false;
                        self.dependencies.releaseClass(.live_job);
                    }
                }
                if (v.publication) |publication| {
                    if (!v.effects.job_released or !v.effects.pcm_published or !v.effects.publication_published or publication.publication_ordinal != self.publication_ordinal + 1 or publication.worker_job != selected.descriptor.job or publication.stream_slot != selected.handle.index or publication.stream_generation != selected.handle.generation or publication.prefix_start != selected.ordinal or publication.prefix_end != try add(selected.ordinal, selected.count)) return error.InvalidEvidence;
                    const released = try self.publicationRelease(binding.key, publication.publication_ordinal);
                    try self.visibility_owners.publish(&self.dependencies, publication, .{ .operation = binding.key.ordinal, .acceptance_sequence = value.sequence }, released);
                }
            } else if (v.accepted != null or v.publication != null or v.actual_worker != null or v.effects.job_released) return error.InvalidEvidence;
        }
    }
    fn visibilityPollRead(self: *Validator, key: format.OperationKey, observed: u64) Error!Point {
        if (observed < self.visibility_observed_read) return error.InvalidEvidence;
        const before = try self.boundPoint(key, .visibility_poll, 0, 0, .before);
        try self.stream_admissions.acquire(&self.dependencies, observed, before);
        var after = before;
        after.edge = .after;
        try self.check(after, observed);
        self.visibility_observed_read = observed;
        return before;
    }
    fn visibilityRelease(self: *Validator, at: Point, ordinal: u64) Error!void {
        if (ordinal != try add(self.admission_ordinal, 1)) return error.InvalidEvidence;
        try self.stream_admissions.publish(&self.dependencies, ordinal, at);
        try self.check(at, ordinal);
        self.admission_ordinal = ordinal;
    }
    fn finishVisibilityReads(self: *Validator) Error!void {
        // Genuine closed producer/lifetime obligations and exact admission/ack
        // counts are required by finish; no EOF-only synthetic publication.
        if (self.admission_ordinal != self.publication_ordinal or self.acknowledgement_ordinal != self.publication_ordinal) return error.MissingAcquisition;
        try self.stream_admissions.close(&self.dependencies, self.admission_ordinal);
        try self.stream_admissions.finish();
    }
    fn groupEventQueue(self: *Validator, key: format.OperationKey, epoch: u64, observation: @import("sme-trace").QueueObservation) Error!void {
        if (epoch != 1 or self.group_event_terminal) return error.StaleIdentity;
        switch (observation) {
            .push => |v| {
                if (key.role != .render or !v.enabled or !v.accepted) return error.UnrepresentedCut;
                const head = v.head_before orelse return error.InvalidEvidence;
                const tail = v.tail_acquired orelse return error.InvalidEvidence;
                const after = v.head_after orelse return error.InvalidEvidence;
                if (head != self.group_event_head or tail < self.group_event_seen_tail or tail > head or head - tail >= trace.default_ring_capacity or after != try add(head, 1)) return error.InvalidEvidence;
                var space = try self.keyedPoint(key, .group_event_space, 0, epoch);
                try self.check(space, tail);
                space.edge = .before;
                try self.group_event_returns.acquire(&self.dependencies, tail, space);
                const published = try self.keyedPoint(key, .group_event_publish, 0, epoch);
                try self.check(published, after);
                try self.group_event_writes.publish(&self.dependencies, after, published);
                self.group_event_head = after;
                self.group_event_seen_tail = tail;
            },
            .pop => |v| {
                if (key.role != .control or self.group_event_pending != null or v.tail_before != self.group_event_tail or v.head_acquired < self.group_event_seen_head or v.head_acquired < v.tail_before or v.head_acquired - v.tail_before > trace.default_ring_capacity or v.present != (v.head_acquired != v.tail_before) or v.tail_after != try add(v.tail_before, @intFromBool(v.present))) return error.InvalidEvidence;
                var acquired = try self.keyedPoint(key, .group_event_pop, 0, epoch);
                try self.check(acquired, v.head_acquired);
                acquired.edge = .before;
                try self.group_event_writes.acquire(&self.dependencies, v.head_acquired, acquired);
                if (v.present) {
                    const returned = try self.keyedPoint(key, .group_event_return, 0, epoch);
                    try self.check(returned, v.tail_after);
                    try self.group_event_returns.publish(&self.dependencies, v.tail_after, returned);
                    try self.dependencies.reservePending();
                    self.group_event_pending = key;
                }
                self.group_event_tail = v.tail_after;
                self.group_event_seen_head = v.head_acquired;
            },
        }
    }
    fn groupEventSchedule(self: *Validator, key: format.OperationKey, value: trace.ScheduleEntry) Error!void {
        if (self.group_event_pending) |expected| {
            if (!std.meta.eql(expected, key)) return error.StaleReference;
            // The producer emits the pop fact before returning its one payload;
            // its caller appends that actual schedule in the same Control FIFO.
            self.group_event_pending = null;
            self.dependencies.releasePending();
        } else if (value == .event and value.event.kind == .group) return error.MissingAcquisition;
    }
    fn groupEventTerminal(self: *Validator, epoch: u64, head: u64, tail: u64) Error!void {
        if (epoch != 1 or self.group_event_terminal) return error.StaleIdentity;
        if (self.group_event_pending != null or head != tail or head != self.group_event_head or tail != self.group_event_tail) return error.MissingAcquisition;
        try self.group_event_writes.close(&self.dependencies, head);
        try self.group_event_returns.close(&self.dependencies, tail);
        try self.group_event_writes.finish();
        try self.group_event_returns.finish();
        self.group_event_terminal = true;
    }
    fn publicationRelease(self: *Validator, key: format.OperationKey, ordinal: u64) Error!Point {
        if (ordinal != try add(self.publication_ordinal, 1)) return error.InvalidEvidence;
        // Service uses index/generation 0. The ordinal is the stored value;
        // multiple releases in one invocation advance this site's occurrence.
        const released = try self.boundPoint(key, .publication_release, 0, 0, .after);
        try self.check(released, ordinal);
        try self.dependencies.publish(identity(.publication_admitted, slot(ordinal), ordinal), released);
        try self.stream_frontier.publish(&self.dependencies, ordinal, released);
        self.publication_ordinal = ordinal;
        return released;
    }
    fn readiness(self: *Validator, binding: Binding, event: format.readiness.Event) Error!void {
        const key = event.key;
        if (key.tick_serial != binding.serial or key.position.control_tick != binding.control_tick or key.interval_id != self.header.session.interval_id) return error.StaleIdentity;
        inline for (.{ .{ @as(usize, 0), event.anchors.plan_sequence, event.anchors.plan_ordinal }, .{ @as(usize, 1), event.anchors.acceptance_sequence, event.anchors.acceptance_ordinal } }) |item| {
            if (item[1] == 0) return error.MissingPublication;
            const anchor = self.anchors[item[0]][@intCast((item[1] - 1) % max_pending)] orelse return error.MissingPublication;
            if (anchor.sequence != item[1] or anchor.tick != key.tick_serial or anchor.control_tick != key.position.control_tick or anchor.ordinal != item[2] or anchor.closed or anchor.phase > key.phase) return error.StaleReference;
        }
        const state = &self.peers[2];
        if (event.payload == .tick_open) {
            if (state.open or key.tick_serial <= state.serial or self.query != null) return error.InvalidEvidence;
            state.open = true;
            state.serial = key.tick_serial;
            state.control_tick = key.position.control_tick;
            self.last_readiness_attempt = 0;
        }
        if (!state.open or state.serial != key.tick_serial) return error.InvalidEvidence;
        switch (event.payload) {
            .tick_open, .tick_close, .throughput, .query_output => {},
            else => {
                if (key.attempt_ordinal != self.last_readiness_attempt + 1) return error.InvalidEvidence;
                self.last_readiness_attempt = key.attempt_ordinal;
            },
        }
        switch (event.payload) {
            .tick_open => {},
            .tick_close => |code| {
                const expected: u32 = if (binding.result == .tick_failed) format.observed_invalid_state else 0;
                if (code != expected or self.query != null or key.phase != @intFromEnum(format.frontier.Phase.publish)) return error.InvalidEvidence;
                state.open = false;
                state.ticks += 1;
            },
            .query_reads => |v| {
                if (self.query != null or !v.representation_complete or v.error_code != 0 or v.service_error != 0 or v.scanned > max_resource_slots) return error.InvalidEvidence;
                try self.dependencies.reservePending();
                self.query = key;
                // Torn outer/inner cuts are real observations, but are outside
                // the first exact snapshot-cut executor. They are never repaired.
                if ((v.has(.outer_before) and v.has(.outer_after) and v.outer_before != v.outer_after) or (v.has(.sequence_before) and v.sequence_before & 1 != 0) or (v.has(.sequence_after) and v.sequence_before != v.sequence_after)) self.noteUnsupported(.readiness_unstable_snapshot);
                try self.readinessReads(binding.key, key, v, event.anchors.acceptance_sequence);
            },
            .query_output => {
                if (self.query == null or !std.meta.eql(self.query.?, key)) return error.MissingAcquisition;
                self.query = null;
                self.dependencies.releasePending();
            },
            .supply => |v| {
                const binding_index = self.bound(.{ .readiness = event }).?;
                const counters = &self.bindings[binding_index].?;
                if (counters.availability_failure != null) return error.InvalidEvidence;
                if (v.kind == .prefetch) {
                    if (v.parent_attempt != 0 or counters.pending_prefetch != null) return error.InvalidEvidence;
                } else if (v.parent_attempt != 0) {
                    const parent = counters.pending_prefetch orelse return error.MissingAcquisition;
                    if (parent.attempt != v.parent_attempt or !std.meta.eql(parent.handle, key.handle)) return error.StaleReference;
                    counters.pending_prefetch = null;
                    self.dependencies.releasePending();
                } else if (counters.pending_prefetch != null) return error.MissingAcquisition;
                try self.availabilityReads(binding.key, key.handle, v.availability, .readiness);
                if (v.error_code != 0) {
                    if (binding.result != .tick_failed or !format.availabilityChanged(v) or counters.availability_failure != null or key.phase != @intFromEnum(format.frontier.Phase.prepare) or key.context != self.header.identity.context or key.transport_epoch != self.header.bindings.readiness_manifest.transport_epoch or counters.accepted_frame == null or key.position.accepted_control_frame != counters.accepted_frame.?) return error.InvalidEvidence;
                    if (key.handle.index >= self.streams.len or !self.streams[key.handle.index].live or self.streams[key.handle.index].generation != key.handle.generation) return error.StaleReference;
                    if (v.kind == .prefetch and v.availability.requested_frame != counters.accepted_frame) return error.InvalidEvidence;
                    // A changed final sequence reads a potentially torn per-
                    // stream consumed value. The current Render witness does
                    // not publish those reached per-slot values, so retain the
                    // real comparators but do not certify that longer cut.
                    if (v.availability.sequence_after != null) self.noteUnsupported(.supply_changed_sequence);
                    counters.availability_failure = key;
                } else if (v.invokes_request) {
                    if (v.kind != .prefetch or v.result_job != null or v.descriptor != null) return error.InvalidEvidence;
                    try self.dependencies.reservePending();
                    counters.pending_prefetch = .{ .attempt = key.attempt_ordinal, .handle = key.handle };
                }
                if (v.descriptor) |d| {
                    const request_reads = stream.readiness_observation.bit(.request_cancel) | stream.readiness_observation.bit(.request_stopped) | stream.readiness_observation.bit(.request_failed) | stream.readiness_observation.bit(.request_pending) | stream.readiness_observation.bit(.request_ordinal);
                    if (v.kind != .request or v.invokes_request or v.error_code != 0 or v.reached & request_reads != request_reads or v.cancel or v.stopped or v.failure_code != 0 or v.pending_job != null) return error.InvalidEvidence;
                    if (d.generation != self.header.identity.generation or d.transport_epoch != self.header.bindings.readiness_manifest.transport_epoch) return error.StaleIdentity;
                    const index = v.job_slot orelse return error.InvalidEvidence;
                    if (index >= self.jobs.len or d.job <= self.last_job or v.result_job != d.job or v.count == 0 or key.handle.index >= self.streams.len) return error.InvalidEvidence;
                    const life = self.streams[key.handle.index];
                    if (!life.live or life.generation != key.handle.generation or self.jobs[index].live) return error.StaleReference;
                    if (self.dependencies.partitioned() and index >= 48) return error.InvalidEvidence;
                    try self.dependencies.reserveClass(.live_job);
                    self.jobs[index] = .{ .job = d.job, .handle = key.handle, .ordinal = v.ordinal, .count = v.count, .live = true };
                    self.last_job = d.job;
                    const p = try point(binding.key, .job_queued, index, d.job, 0, .after);
                    try self.dependencies.publish(identity(.job_selected, index, d.job), p);
                    try self.job_cuts.publishQueued(&self.dependencies, index, d.job, key.handle, .{ .operation = binding.key.ordinal, .attempt = key.attempt_ordinal, .acceptance_sequence = event.anchors.acceptance_sequence }, p);
                    try self.check(p, @intFromEnum(stream.observation.JobState.queued));
                } else if (v.job_slot != null) return error.InvalidEvidence;
            },
            .throughput => |v| {
                if (v.job == 0 or v.count == 0 or (v.attempted and v.elapsed_ns == 0)) return error.InvalidEvidence;
                // Measurement numbers are comparator/external clock facts only.
            },
            .stream_lifecycle => |v| switch (v) {
                .open => |opened| if (opened.result) |handle| {
                    if (handle.index >= self.streams.len or handle.generation == 0 or opened.error_code != 0 or opened.selected_index != handle.index) return error.InvalidEvidence;
                    if (self.dependencies.partitioned() and handle.index >= 48) return error.InvalidEvidence;
                    const life = &self.streams[handle.index];
                    if (life.live or handle.generation <= life.generation) return error.StaleReference;
                    try self.dependencies.reserveClass(.live_stream);
                    life.* = .{ .generation = handle.generation, .live = true };
                    try self.consumed_cuts.open(&self.dependencies, handle.index, handle.generation);
                    try self.stream_stop_cuts.open(&self.dependencies, handle);
                },
                .close => |closed| {
                    var claim_point: ?Point = null;
                    var pending_point: ?Point = null;
                    var idle_point: ?Point = null;
                    if (closed.worker_busy) |busy| {
                        const at = try self.boundPoint(binding.key, .stream_close_claim, closed.handle.index, closed.handle.generation, .before);
                        claim_point = at;
                        var after = at;
                        after.edge = .after;
                        try self.check(after, @intFromBool(busy));
                    }
                    if (closed.pending_job_reached) {
                        const at = try self.boundPoint(binding.key, .stream_close_pending, closed.handle.index, closed.handle.generation, .before);
                        pending_point = at;
                        var after = at;
                        after.edge = .after;
                        try self.check(after, if (closed.pending_job) |index| @as(u64, index) + 1 else 0);
                    }
                    if (closed.worker_idle_published) {
                        const at = try self.boundPoint(binding.key, .stream_close_idle, closed.handle.index, closed.handle.generation, .after);
                        idle_point = at;
                        try self.check(at, 0);
                    }
                    if (closed.visibility_refs) |refs| {
                        if (closed.worker_busy != false or !closed.pending_job_reached or closed.pending_job != null or closed.handle.index >= self.streams.len or !self.streams[closed.handle.index].live or self.streams[closed.handle.index].generation != closed.handle.generation) return error.StaleReference;
                        try self.job_cuts.requireEmptyOwner(&self.dependencies, closed.handle, .{ .operation = binding.key.ordinal, .attempt = key.attempt_ordinal, .acceptance_sequence = event.anchors.acceptance_sequence });
                        const at = try self.boundPoint(binding.key, .stream_close_visibility, closed.handle.index, closed.handle.generation, .before);
                        try self.visibility_owners.acquire(&self.dependencies, closed.handle, .{ .operation = binding.key.ordinal, .acceptance_sequence = event.anchors.acceptance_sequence }, refs, at);
                        var after = at;
                        after.edge = .after;
                        try self.check(after, refs);
                    }
                    if (!closed.returned) {
                        if (self.header.identity.rules_version == 2 and format.streamCloseBusy(closed)) {
                            if (closed.parent_attempt >= key.attempt_ordinal or closed.handle.index >= self.streams.len or !self.streams[closed.handle.index].live or self.streams[closed.handle.index].generation != closed.handle.generation) return error.StaleReference;
                            try self.exclusion_tickets.expectBusyClose(&self.dependencies, binding.key, .{ .stream_close = .{ .handle = closed.handle, .parent_attempt = closed.parent_attempt } }, claim_point.?);
                            return;
                        }
                        if (format.streamClosePendingJob(closed) or format.streamCloseVisibilityPending(closed)) {
                            if (closed.parent_attempt >= key.attempt_ordinal or closed.handle.index >= self.streams.len or !self.streams[closed.handle.index].live or self.streams[closed.handle.index].generation != closed.handle.generation) return error.StaleReference;
                            if (closed.pending_job) |pending| try self.job_cuts.acquirePendingOwner(&self.dependencies, pending, closed.handle, .{ .operation = binding.key.ordinal, .attempt = key.attempt_ordinal, .acceptance_sequence = event.anchors.acceptance_sequence }, pending_point.?);
                            try self.exclusion_tickets.expectScope(&self.dependencies, .{
                                .key = binding.key,
                                .owner = .{ .stream_close = .{ .handle = closed.handle, .parent_attempt = closed.parent_attempt } },
                                .claim = claim_point.?,
                                .release = idle_point.?,
                            });
                            return;
                        }
                        // Other reached prefixes still lack their own proof.
                        self.noteUnsupported(.stream_close_other_prefix);
                        return;
                    }
                    if (closed.handle.index >= self.streams.len or closed.worker_busy != false or !closed.pending_job_reached or closed.pending_job != null or closed.visibility_refs != 0 or closed.ring_references != 0 or closed.guard != 0 or !closed.worker_idle_published or !closed.stopped_published) return error.InvalidEvidence;
                    const life = &self.streams[closed.handle.index];
                    if (!life.live or life.generation != closed.handle.generation) return error.StaleReference;
                    for (self.jobs) |job| if (job.live and std.meta.eql(job.handle, closed.handle)) return error.MissingAcquisition;
                    try self.exclusion_tickets.expectScope(&self.dependencies, .{
                        .key = binding.key,
                        .owner = .{ .stream_close = .{ .handle = closed.handle, .parent_attempt = closed.parent_attempt } },
                        .claim = claim_point.?,
                        .release = idle_point.?,
                    });
                    try self.consumed_cuts.retire(&self.dependencies, closed.handle.index, closed.handle.generation);
                    const stopped = try self.boundPoint(binding.key, .stream_close_stopped, closed.handle.index, closed.handle.generation, .after);
                    try self.check(stopped, 1);
                    try self.stream_stop_cuts.close(&self.dependencies, closed.handle, stopped);
                    life.live = false;
                    self.dependencies.releaseClass(.live_stream);
                },
                .window_return => |returned| {
                    if (returned.handle.index >= self.streams.len or self.streams[returned.handle.index].live or self.streams[returned.handle.index].generation != returned.handle.generation) return error.InvalidEvidence;
                },
                .cancel, .window, .stream_lease => {},
            },
            .acquisition => |v| {
                const binding_index = self.bound(.{ .readiness = event }).?;
                const kind: usize = @intFromEnum(v.kind);
                const occurrence = self.bindings[binding_index].?.acquisition_counts[kind];
                self.bindings[binding_index].?.acquisition_counts[kind] += 1;
                switch (v.kind) {
                    .collect_frame, .receipts_frame, .phase_frame => if (v.reached) {
                        const p = try point(binding.key, .collection_frame, kind, 0, occurrence, .before);
                        try self.render_frames.acquire(&self.dependencies, v.observed, p);
                        var after = p;
                        after.edge = .after;
                        try self.check(after, v.observed);
                    },
                    .schedule_result, .schedule_admission, .execution_receipt, .plan_phase => {
                        if (v.validation_state) |validation_state| {
                            if (validation_state != .published and validation_state != .acquired and validation_state != .terminal) return error.UnrepresentedCut;
                            try self.lifetimeRead(binding.key, .block_state, v.handle, .scheduler_validate, @intFromEnum(validation_state));
                        }
                        if (v.reached) {
                            const site: Site = switch (v.kind) {
                                .schedule_result => .schedule_result,
                                .schedule_admission => .schedule_admission,
                                .execution_receipt => .execution_receipt,
                                .plan_phase => .plan_phase,
                                else => unreachable,
                            };
                            const track_kind: ProgressKind = switch (v.kind) {
                                .schedule_result, .schedule_admission => .block_state,
                                .execution_receipt => .block_receipt,
                                .plan_phase => .plan_phase,
                                else => unreachable,
                            };
                            if (track_kind == .block_state and v.observed < @intFromEnum(rt.scheduler.State.published)) return error.UnrepresentedCut;
                            const p = try self.boundPoint(binding.key, site, v.handle.index, v.handle.generation, .before);
                            const track = try self.progressTrack(track_kind, v.handle.index, v.handle.generation);
                            try track.prefix.acquire(&self.dependencies, v.observed, p);
                            var after = p;
                            after.edge = .after;
                            try self.check(after, v.observed);
                            if (v.returned and (v.kind == .execution_receipt or v.kind == .plan_phase) and (v.cursor_after != v.cursor_before + 1 or v.cursor_after > v.observed)) return error.InvalidEvidence;
                        }
                    },
                    .group_terminal => {
                        if (v.reached) {
                            if (v.error_code != 0 or v.observed > 1 or v.returned != (v.observed == 1) or (v.returned and v.cell != .group_terminal) or (!v.returned and v.cell != .none)) return error.InvalidEvidence;
                            try self.lifetimeRead(binding.key, .group_terminal, v.handle, .group_terminal_read, v.observed);
                        } else if (v.returned) return error.InvalidEvidence;
                    },
                    .source_switch => {
                        if (v.reached and !v.returned and v.observed == 0) {
                            const expected: format.readiness.Acquisition = .{ .kind = .source_switch, .handle = v.handle, .reached = true };
                            if (!std.meta.eql(expected, v)) return error.InvalidEvidence;
                            self.lifetimeLedger().sourceSwitchEmpty(event.key, v.handle) catch |err| return lifetimeError(err);
                        } else if (v.reached or v.returned) self.noteUnsupported(.source_switch_nonempty);
                    },
                    .cancellation_result => {
                        if (v.reached or v.returned) self.noteUnsupported(.cancellation_poll);
                    },
                }
            },
            .reconciliation => |v| switch (v.kind) {
                .instance_prepare => try self.group_pins.instance(&self.dependencies, v),
                .group_prepare => {
                    if (v.bank_generation != self.header.identity.generation) return error.StaleIdentity;
                    try self.group_pins.prepare(&self.dependencies, v);
                    self.lifetimeLedger().reconciliation(event.key, v) catch |err| {
                        const mapped = lifetimeError(err);
                        return mapped;
                    };
                    try self.prepareLifetimeTrack(.group_terminal, v.handle, 1);
                },
                .initial_stream_retain, .initial_stream_return => {
                    try self.group_pins.lease(&self.dependencies, v);
                    const handle = try self.stream_stop_cuts.handleForGeneration(&self.dependencies, v.stream.generation);
                    if (v.stream_index_known and !std.meta.eql(v.stream, handle)) return error.StaleIdentity;
                    if (v.kind == .initial_stream_return) {
                        const stopped = try self.boundPoint(binding.key, .stream_stop_publish, 0, handle.generation, .after);
                        try self.check(stopped, 1);
                        try self.stream_stop_cuts.publish(&self.dependencies, handle, stopped);
                    }
                },
                .schedule_prepare, .schedule_group_retain, .schedule_group_bind, .schedule_release, .schedule_group_return => self.lifetimeLedger().reconciliation(event.key, v) catch |err| {
                    const mapped = lifetimeError(err);
                    return mapped;
                },
                .group_release => {
                    if (v.pin_mask) |mask| {
                        const at = try self.boundPoint(binding.key, .group_pin_read, v.handle.index, v.handle.generation, .before);
                        var after = at;
                        after.edge = .after;
                        try self.check(after, mask);
                        if (format.groupReleasePinsPending(v)) {
                            if (v.bank_generation != self.header.identity.generation) return error.StaleIdentity;
                            try self.group_pins.acquireNonzero(&self.dependencies, v.bank_generation, mask, at);
                        } else {
                            if (mask == 0 and v.error_code == 0) {
                                try self.group_pins.beginRelease(&self.dependencies, v, binding.key.ordinal, event.key.attempt_ordinal);
                                if (!try self.group_pins.acquireReturnedZeroWithCollect(&self.dependencies, v.handle, at, binding.collect_frame, .{ .control_tick = event.key.position.control_tick, .tick_serial = event.key.tick_serial, .plan_sequence = event.anchors.plan_sequence })) {
                                    self.diagnoseGroupZero(binding.key, event, at);
                                    self.noteUnsupported(.group_zero_without_prefix);
                                }
                            } else self.noteUnsupported(.group_pin_other_result);
                        }
                    } else {
                        if (v.returned) {
                            try self.group_pins.validateReturn(&self.dependencies, v, binding.key.ordinal);
                            self.lifetimeLedger().reconciliation(event.key, v) catch |err| {
                                const mapped = lifetimeError(err);
                                return mapped;
                            };
                        } else if (v.references == 0 and v.error_code == 0) {
                            try self.group_pins.releaseRefs(&self.dependencies, v, binding.key.ordinal);
                        } else self.noteUnsupported(.group_references_other_result);
                    }
                },
                .group_desired => {
                    self.diagnoseGroupZeroDesired(binding.key, event);
                    // The desired slot is copied before start_scheduled is
                    // tested, including its short-circuited false branch.
                    const active = try self.boundPoint(binding.key, .group_desired_active, v.instance.index, v.instance.generation, .after);
                    const started = v.start_scheduled orelse return error.InvalidEvidence;
                    if (v.desired_active) |observed| try self.check(active, @intFromBool(observed));
                    try self.check(try self.boundPoint(binding.key, .group_desired_start, v.handle.index, v.handle.generation, .after), @intFromBool(started));
                    if (started) {
                        const observed = v.desired_active orelse return error.InvalidEvidence;
                        if (observed) {
                            const matches = v.reservation_matches orelse return error.InvalidEvidence;
                            try self.check(try self.boundPoint(binding.key, .group_desired_reservation, v.instance.index, v.instance.generation, .after), @intFromBool(matches));
                        } else if (v.reservation_matches != null) return error.InvalidEvidence;
                    } else if (v.desired_active != null or v.reservation_matches != null) return error.InvalidEvidence;
                    if (format.groupDesiredPending(v)) {
                        try self.group_pins.desiredPending(&self.dependencies, v, binding.key.ordinal);
                    } else try self.group_pins.desiredInactive(&self.dependencies, v, binding.key.ordinal);
                },
                .completion_pop => {
                    const i = self.bound(.{ .readiness = event }).?;
                    const occurrence = self.bindings[i].?.completion_pops;
                    self.bindings[i].?.completion_pops += 1;
                    if (v.read_position != self.completion_read or v.cursor_after != try add(v.read_position, @intFromBool(v.present)) or v.write_position < v.read_position) return error.InvalidEvidence;
                    if (v.present) {
                        if (v.write_position <= v.read_position or !v.returned or v.error_code != 0) return error.InvalidEvidence;
                        const id = try add(v.read_position, 1);
                        try self.dependencies.consume(identity(.completion_consumed, slot(id), id), try point(binding.key, .completion_pop, 0, 0, occurrence, .before));
                        try self.group_pins.consumeCompletion(&self.dependencies, v);
                    }
                    const returned: ?Point = if (v.present) try self.boundPoint(binding.key, .completion_return, 0, 0, .after) else null;
                    try self.completion_cuts.pop(&self.dependencies, v.read_position, v.write_position, v.cursor_after, v.present, try point(binding.key, .completion_pop, 0, 0, occurrence, .before), returned);
                    if (returned) |at| try self.check(at, v.cursor_after);
                    self.completion_read = v.cursor_after;
                    try self.check(try point(binding.key, .completion_pop, 0, 0, occurrence, .after), v.write_position);
                },
                .terminal_scan => self.lifetimeLedger().reconciliation(event.key, v) catch |err| return lifetimeError(err),
            },
            .scheduler_control => |v| self.lifetimeLedger().control(event.key, v) catch |err| {
                const mapped = lifetimeError(err);
                return mapped;
            },
            .invalidation_publication => return error.UnsupportedOperation,
        }
    }
    /// Match every reached availability load to its own actual checkpoint.
    /// Sequence and frame have independent two-sided publication cuts; an
    /// accepted frame does not authorize substituting either atomic value.
    fn ringReadCut(self: *Validator, key: format.OperationKey, handle: stream.readiness_observation.Handle, cut: @typeInfo(@FieldType(stream.observation.Acceptance, "ring_writable")).optional.child) Error!void {
        var consumed = try self.boundPoint(key, .stream_ring_consumed, handle.index, handle.generation, .before);
        try self.consumed_cuts.acquire(&self.dependencies, handle.index, handle.generation, cut.consumed, consumed);
        consumed.edge = .after;
        try self.check(consumed, cut.consumed);
        const produced = try self.boundPoint(key, .stream_ring_produced, handle.index, handle.generation, .after);
        try self.check(produced, cut.produced);
    }
    fn availabilityReads(self: *Validator, key: format.OperationKey, handle: stream.readiness_observation.Handle, a: stream.observation.Availability, origin: enum { readiness, acceptance }) Error!void {
        const sites: [5]Site = switch (origin) {
            .readiness => .{ .availability_readiness_sequence_before, .availability_readiness_frame, .availability_readiness_control_consumed, .availability_readiness_produced, .availability_readiness_sequence_after },
            .acceptance => .{ .availability_acceptance_sequence_before, .availability_acceptance_frame, .availability_acceptance_control_consumed, .availability_acceptance_produced, .availability_acceptance_sequence_after },
        };
        const values = [_]?u64{ a.sequence_before, a.frame, a.consumed, a.produced, a.sequence_after };
        for (sites, values, 0..) |site, value, index| if (value) |observed| {
            if (!a.attached) return error.InvalidEvidence;
            const p = try self.boundPoint(key, site, handle.index, handle.generation, .before);
            // Service.observation_sequence/frame are shared across handles;
            // these Prefixes are scoped to this exact bound Service/session.
            if (index == 0 or index == 4) try self.observation_sequences.acquireGlobal(&self.dependencies, observed, p);
            if (index == 1) try self.observation_frames.acquireGlobal(&self.dependencies, observed, p);
            var after = p;
            after.edge = .after;
            try self.check(after, observed);
        };
    }
    fn render(self: *Validator, binding: Binding, event: format.render.Event) Error!void {
        const call = &self.render_call;
        if (event.payload == .call_begin) {
            const v = event.payload.call_begin;
            if (call.open or !v.valid or binding.args != .render or v.requested_frames != binding.args.render.frames or v.channels != binding.args.render.channels or event.frame != self.render_frame or event.render_call_sequence != self.render_sequence + 1) return error.InvalidEvidence;
            call.* = .{ .open = true, .frame = event.frame, .sequence = event.render_call_sequence };
        }
        if (!call.open or event.render_call_sequence != call.sequence) return error.InvalidEvidence;
        switch (event.payload) {
            .call_begin => {},
            .gate_begin => |mode| {
                if (call.gate_open or mode == .replay or event.frame != call.frame or event.gate != self.header.bindings.render_manifest.initial_gate + self.render_gates + 1) return error.InvalidEvidence;
                try self.horizonBegin(binding.key, call.spans, event.frame);
                call.gate_open = true;
                call.gate_done = false;
                call.service_live = mode == .live;
                call.frontier = null;
                call.scanned = 0;
                self.render_gates += 1;
            },
            .frontier => |v| {
                if (!call.gate_open or call.frontier != null) return error.InvalidEvidence;
                call.frontier = v.value;
                const p = try point(binding.key, .publication_frontier, 0, 0, call.spans, .before);
                try self.stream_frontier.acquire(&self.dependencies, v.value, p);
                var after = p;
                after.edge = .after;
                try self.check(after, v.value);
            },
            .stream_attempt => |v| {
                if (!call.gate_open or call.frontier == null or v.frontier != call.frontier.? or v.read != self.admission_ordinal or v.error_code != 0) return error.InvalidEvidence;
                if (v.descriptor) |d| {
                    if (d.publication_ordinal != self.admission_ordinal + 1 or d.publication_ordinal > v.frontier or !v.effects.read_advanced or !v.effects.visible_advanced or v.generation != d.stream_generation or v.visible_produced != d.prefix_start or v.produced == null or v.produced.? < d.prefix_end or (v.result != .admitted and v.result != .rejected)) return error.InvalidEvidence;
                    const id = d.publication_ordinal;
                    const stopped_value = try StreamStopCuts.observedValue(v);
                    const stopped = try self.boundPoint(binding.key, .visibility_stopped, d.stream_slot, d.stream_generation, .before);
                    var stopped_after = stopped;
                    stopped_after.edge = .after;
                    try self.check(stopped_after, @intFromBool(stopped_value));
                    try self.stream_stop_cuts.acquire(&self.dependencies, .{ .index = d.stream_slot, .generation = d.stream_generation }, stopped_value, stopped);
                    const read = try point(binding.key, .visibility_head, 0, 0, call.admission_calls, .before);
                    try self.dependencies.consume(identity(.publication_admitted, slot(id), id), read);
                    const published = try point(binding.key, .visibility_release, 0, 0, call.admission_calls, .after);
                    try self.dependencies.publish(identity(.publication_acknowledged, slot(id), id), published);
                    try self.visibilityRelease(published, id);
                    try self.visibility_owners.admit(&self.dependencies, d, published);
                    call.admission_calls += 1;
                } else if (v.result != .empty or v.read != v.frontier or v.head != null or v.effects.read_advanced or v.effects.visible_advanced) return error.InvalidEvidence;
            },
            .scan_chunk => |v| {
                if (!call.gate_open) return error.InvalidEvidence;
                for (v.reads) |read| {
                    if (read.slot_index != call.scanned or call.scanned >= rt.scheduler.block_capacity) return error.InvalidEvidence;
                    call.scanned += 1;
                    const p = try point(binding.key, .scheduler_scan, read.slot_index, 0, call.spans, .before);
                    if (read.state == .published) {
                        if (read.generation == 0 or read.batch_id == 0 or format.zero(read.content_hash) or read.command_count == 0) return error.InvalidEvidence;
                        try self.dependencies.consume(identity(.scheduler_acquired, read.slot_index, read.generation), p);
                        try self.bindRenderPublishedScan(.{ .index = read.slot_index, .generation = read.generation });
                    } else if (read.state == .acquired) {
                        // Nonpublished reads carry no generation. Only this
                        // Render producer's prior published scan selects it.
                        if (read.generation != 0) return error.InvalidEvidence;
                        try self.acquireRenderScan(read.slot_index, p);
                    } else if (read.state != .free) {
                        self.noteSchedulerCut(.scheduler_scan, read.state);
                        self.noteUnsupported(.render_scan_other_state);
                    }
                    var after = p;
                    after.edge = .after;
                    try self.check(after, @intFromEnum(read.state));
                }
            },
            .gate_end => |frame| {
                if (!call.gate_open or frame <= call.frame or frame > binding.result.rendered.frame_end or call.scanned != rt.scheduler.block_capacity) return error.InvalidEvidence;
                try self.horizonEnd(binding.key, call.spans, frame);
                if (call.service_live) {
                    const odd = try add(self.observation_sequences.latest, 1);
                    const even = try add(odd, 1);
                    const odd_point = try point(binding.key, .render_sequence_odd, 0, 0, call.spans, .after);
                    const frame_point = try point(binding.key, .stream_observation_frame, 0, 0, call.spans, .after);
                    const even_point = try point(binding.key, .render_sequence_even, 0, 0, call.spans, .after);
                    try self.observation_sequences.publish(&self.dependencies, odd, odd_point);
                    try self.observation_frames.publish(&self.dependencies, frame, frame_point);
                    try self.observation_sequences.publish(&self.dependencies, even, even_point);
                    try self.check(odd_point, odd);
                    try self.check(frame_point, frame);
                    try self.check(even_point, even);
                    self.service_gates += 1;
                }
                const p = try point(binding.key, .render_frame, 0, 0, call.spans, .after);
                try self.render_frames.publish(&self.dependencies, frame, p);
                try self.check(p, frame);
                call.frame = frame;
                call.spans += 1;
                call.gate_open = false;
                call.gate_done = true;
            },
            .resource => |v| {
                if (v.context != self.header.identity.context or v.bank_generation != self.header.identity.generation or v.group_generation == 0) return error.StaleIdentity;
                const substage: format.render.CallSubstage = if (call.gate_open) .in_gate else if (call.gate_done) .after_gate else .before_gate;
                if (v.substage != substage) return error.InvalidEvidence;
                if (v.kind == .completion_enqueue) {
                    if (v.queue_write != self.completion_write or v.queue_after != try add(v.queue_write, 1) or v.queue_read > v.queue_write) return error.InvalidEvidence;
                    const id = v.queue_after;
                    const space = try self.boundPoint(binding.key, .completion_space, 0, 0, .before);
                    const released = try self.boundPoint(binding.key, .completion_enqueue, 0, 0, .after);
                    try self.completion_cuts.enqueue(&self.dependencies, v.queue_read, v.queue_write, v.queue_after, space, released);
                    var after_space = space;
                    after_space.edge = .after;
                    try self.check(after_space, v.queue_read);
                    try self.check(released, v.queue_after);
                    try self.dependencies.publish(identity(.completion_consumed, slot(id), id), released);
                    self.completion_write = id;
                    try self.group_pins.resource(&self.dependencies, v, null);
                } else {
                    const site: Site = if (v.kind == .group_pin_publish) .group_pin_publish else .group_pin_return;
                    const at = try self.boundPoint(binding.key, site, v.group_index, v.group_generation, .after);
                    if (v.kind == .group_pin_publish) {
                        try self.group_pins.publicationInGate(&self.dependencies, v, at, event.frame, call.frame);
                    } else try self.group_pins.resource(&self.dependencies, v, at);
                    try self.check(at, v.mask_after);
                }
            },
            .call_end => |v| {
                const result = binding.result.rendered;
                if (call.gate_open or !call.gate_done or !v.completed or v.error_code != 0 or v.frame_end != result.frame_end or call.frame != v.frame_end or result.frame_begin != self.render_frame or result.call_sequence_begin != self.render_sequence or result.call_sequence_end != try add(self.render_sequence, 2)) return error.InvalidEvidence;
                self.render_frame = result.frame_end;
                self.render_sequence = result.call_sequence_end;
                self.render_calls += 1;
                call.open = false;
            },
            .invalidation_poll => |v| {
                if (v.identity != null or v.read_cursor != v.write_prefix) return error.UnsupportedOperation;
            },
            .invalidation_result => return error.UnsupportedOperation,
        }
    }
    // First unsupported zero only. Render fields below are a MERGED assembler
    // snapshot, never proof that their publications preceded this Control read.
    fn diagnoseGroupZero(self: *const Validator, key: format.OperationKey, event: format.readiness.Event, at: Point) void {
        if (!@import("builtin").is_test or self.test_unsupported_reasons[@intFromEnum(UnsupportedReason.group_zero_without_prefix)] != 0) return;
        const v = event.payload.reconciliation;
        std.debug.print("causal group zero actual read: operation={any} key={any} anchors={any} point={any} record={any}\n", .{ key, event.key, event.anchors, at, v });
        for (self.group_pins.groups[0..self.group_pins.capacity]) |entry| if (entry) |group| {
            if (group.index != v.handle.index or group.generation != v.handle.generation) continue;
            std.debug.print("causal group zero assembler snapshot only: prepared={any} bank={d} voices={d} instance_mask={d} start_order={d} stores={d} returned={d} consumed_mask={d} nonzero_control_prefix={any} release={any} retired={any} completion_read={d} completion_write={d}\n", .{ group.prepared, group.bank_generation, group.voice_count, group.instance_mask, group.start_order, group.store_count, group.returned, group.consumed_mask, group.nonzero_control_prefix, group.release_attempt, group.retired, self.completion_read, self.completion_write });
            for (group.instances, 0..) |instance, ordinal| if (instance) |value| {
                std.debug.print("causal group zero instance snapshot: ordinal={d} instance={any} consumed={any} completion={any}\n", .{ ordinal, value, group.consumed[ordinal], group.completions[ordinal] });
            };
            for (group.stores[0..group.store_count]) |value| std.debug.print("causal group zero pin snapshot: mask={d} point={any}\n", .{ value.mask, value.at });
            return;
        };
    }
    fn diagnoseGroupZeroDesired(self: *const Validator, key: format.OperationKey, event: format.readiness.Event) void {
        if (!@import("builtin").is_test or self.test_unsupported_reasons[@intFromEnum(UnsupportedReason.group_zero_without_prefix)] != 1) return;
        const v = event.payload.reconciliation;
        if (v.ordinal != 0) return;
        for (self.group_pins.groups[0..self.group_pins.capacity]) |entry| if (entry) |group| {
            if (group.index != v.handle.index or group.generation != v.handle.generation) continue;
            const release = group.release_attempt orelse return;
            if (release.zero_proven or release.operation != key.ordinal or release.attempt != v.parent_attempt) return;
            std.debug.print("causal group zero actual following desired: operation={any} key={any} anchors={any} record={any}\n", .{ key, event.key, event.anchors, v });
            return;
        };
    }
    fn noteUnsupported(self: *Validator, reason: UnsupportedReason) void {
        self.unsupported_cuts += 1;
        if (@import("builtin").is_test) self.test_unsupported_reasons[@intFromEnum(reason)] += 1;
    }
    fn printUnsupportedReasons(self: *const Validator) void {
        if (!@import("builtin").is_test or self.unsupported_cuts == 0) return;
        std.debug.print("causal unsupported reasons:", .{});
        inline for (@typeInfo(UnsupportedReason).@"enum".fields, 0..) |field, i| {
            if (self.test_unsupported_reasons[i] != 0) std.debug.print(" {s}={d}", .{ field.name, self.test_unsupported_reasons[i] });
        }
        std.debug.print("\n", .{});
    }
    fn noteSchedulerCut(self: *Validator, site: Site, state: rt.scheduler.State) void {
        if (!@import("builtin").is_test) return;
        const base: u6 = if (site == .scheduler_scan) 0 else 16;
        const bit: u64 = @as(u64, 1) << (base + @as(u6, @intCast(@intFromEnum(state))));
        if (self.test_scheduler_cuts_seen & bit != 0) return;
        self.test_scheduler_cuts_seen |= bit;
        std.debug.print("causal unsupported scheduler cut: site={s} state={s}\n", .{ @tagName(site), @tagName(state) });
    }
    fn lifetimeLedger(self: *Validator) *Lifetimes.Ledger {
        // The compatibility init() returns by value. Rebind on entry rather
        // than retaining the address of its temporary; callbacks are synchronous.
        self.lifetimes.sink.context = self;
        return &self.lifetimes;
    }
    fn lifetimeError(err: anyerror) Error {
        return switch (err) {
            error.MissingPreparation => error.MissingPublication,
            error.MissingReturn => error.MissingAcquisition,
            // Remaining helper errors and our action sink errors are Error.
            else => @errorCast(err),
        };
    }
    fn lifetimeBindingPending(self: *Validator, binding: Binding) Error!bool {
        if (binding.key.role != .control) return false;
        for (self.lifetimes.deferred[0..self.lifetimes.deferred_count]) |entry| {
            try self.dependencies.charge();
            if (entry.?.key.tick_serial == binding.serial) return true;
        }
        return false;
    }
    fn releaseClosedLifetimeBindings(self: *Validator) Error!void {
        for (&self.bindings) |*entry| if (entry.*) |binding| {
            try self.dependencies.charge();
            if (binding.finished == 7 and binding.key.role == .control and !try self.lifetimeBindingPending(binding)) {
                entry.* = null;
                self.dependencies.releasePending();
            }
        };
    }
    fn lifetimeKey(self: *Validator, query: Lifetimes.QueryKey) Error!format.OperationKey {
        if (query.interval_id != self.header.session.interval_id or query.context != self.header.identity.context) return error.StaleIdentity;
        for (self.bindings) |entry| if (entry) |binding| {
            try self.dependencies.charge();
            if (binding.key.role == .control and binding.serial == query.tick_serial) return binding.key;
        };
        return error.UnboundOperation;
    }
    fn lifetimeRead(self: *Validator, key: format.OperationKey, kind: ProgressKind, handle: rt.scheduler.Handle, site: Site, value: u64) Error!void {
        const before = try self.boundPoint(key, site, handle.index, handle.generation, .before);
        const track = try self.progressTrack(kind, handle.index, handle.generation);
        try track.prefix.acquire(&self.dependencies, value, before);
        var after = before;
        after.edge = .after;
        try self.check(after, value);
    }
    fn prepareLifetimeTrack(self: *Validator, kind: ProgressKind, handle: rt.scheduler.Handle, count: u16) Error!void {
        const track = try self.progressTrack(kind, handle.index, handle.generation);
        if (track.prepared or track.retired) return error.DuplicatePublication;
        track.prepared = true;
        track.expected_count = count;
    }
    fn retireLifetimeTrack(self: *Validator, kind: ProgressKind, handle: rt.scheduler.Handle) Error!void {
        const track = try self.progressTrack(kind, handle.index, handle.generation);
        if (!track.prepared or track.retired) return error.InvalidEvidence;
        // Render facts/reads can still be physically later in the file. Keep
        // this aggregate-charged row until finishProgress proves its closure.
        track.retired = true;
    }
    fn terminalScanRead(self: *Validator, key: format.OperationKey, index: u16, generation: u64, state: rt.scheduler.State) Error!void {
        if (state == .free) {
            if (generation != 0) return error.StaleReference;
        } else {
            if (state != .published and state != .acquired and state != .terminal) return error.UnrepresentedCut;
            if (generation == 0) return error.MissingPublication;
        }
        const before = try self.boundPoint(key, .terminal_scan, index, 0, .before);
        if (state != .free) {
            const track = try self.progressTrack(.block_state, index, generation);
            if (!track.prepared or track.retired) return error.MissingPublication;
            try track.prefix.acquire(&self.dependencies, @intFromEnum(state), before);
        }
        var after = before;
        after.edge = .after;
        try self.check(after, @intFromEnum(state));
    }
    fn lifetimeAction(raw: *anyopaque, action: Lifetimes.Action) anyerror!void {
        const self: *Validator = @ptrCast(@alignCast(raw));
        switch (action) {
            .reserve => try self.dependencies.reservePending(),
            .release => self.dependencies.releasePending(),
            .charge => |count| for (0..count) |_| try self.dependencies.charge(),
            .prepare_block => |v| {
                _ = try self.lifetimeKey(v.key);
                try self.prepareLifetimeTrack(.block_state, v.block, @intFromEnum(rt.scheduler.State.terminal));
                try self.prepareLifetimeTrack(.block_receipt, v.block, v.command_count);
            },
            .prepare_plan => |v| {
                _ = try self.lifetimeKey(v.key);
                try self.prepareLifetimeTrack(.plan_phase, v.plan, v.total_phases);
            },
            .bind_publication => |v| {
                // The original feed already emitted this exact publication
                // checkpoint. Its helper join supplies preparation identity,
                // never a second release or a computed schedule outcome.
                const track = try self.progressTrack(.block_state, v.value.block.index, v.value.block.generation);
                if (!track.prepared or track.prefix.latest < @intFromEnum(rt.scheduler.State.published)) return error.MissingPublication;
            },
            .schedule_release_cut => |v| {
                const key = try self.lifetimeKey(v.key);
                try self.lifetimeRead(key, .block_state, v.value.handle, .scheduler_validate, @intFromEnum(v.value.validation_state.?));
                try self.lifetimeRead(key, .block_state, v.value.handle, .schedule_release, @intFromEnum(v.value.terminal_state.?));
            },
            .source_switch_empty_cut => |v| {
                const key = try self.lifetimeKey(v.key);
                const before = try self.boundPoint(key, .group_source_switch_read, v.group.index, v.group.generation, .before);
                var after = before;
                after.edge = .after;
                try self.check(after, 0);
            },
            .source_final_cut => |v| {
                if (!std.meta.eql(try self.lifetimeKey(v.key), v.fact.key) or v.fact.value.published) return error.InvalidEvidence;
                // The actual host-lane final checkpoint was emitted at feed.
                // Existing GroupPins/terminal/lease retirement excludes a later
                // writer. Monotonic initial0 + final0 proves every empty poll.
            },
            .terminal_scan_cut => |v| {
                const key = try self.lifetimeKey(v.key);
                try self.terminalScanRead(key, v.index, v.generation, v.state);
            },
            .control_cut => |v| {
                const key = try self.lifetimeKey(v.key);
                switch (v.value) {
                    .prepare_horizon => |read| {
                        try self.horizonRead(key, .scheduler_prepare_horizon, read.horizon);
                    },
                    .slot_scan => |scan| for (0..scan.count) |offset| {
                        const index: u16 = scan.first_slot + @as(u16, @intCast(offset));
                        const state = scan.state(offset);
                        const before = try self.boundPoint(key, .scheduler_control_scan, index, 0, .before);
                        var after = before;
                        after.edge = .after;
                        try self.check(after, @intFromEnum(state));
                        switch (state) {
                            .free => {}, // Existing initial/free-scan contract.
                            .published, .acquired, .terminal => {
                                const block = &self.lifetimes.blocks[index];
                                if (!block.live) return error.MissingPublication;
                                const track = try self.progressTrack(.block_state, index, block.generation);
                                try track.prefix.acquire(&self.dependencies, @intFromEnum(state), before);
                            },
                            // No exact store/CAS witness authorizes these cuts.
                            .prepared, .queued, .partially_executed => {
                                self.noteSchedulerCut(.scheduler_control_scan, state);
                                return error.UnrepresentedCut;
                            },
                        }
                    },
                    .acknowledge_validation => |read| try self.lifetimeRead(key, .block_state, read.target, .scheduler_validate, @intFromEnum(read.state.?)),
                    .acknowledge_terminal => |read| try self.lifetimeRead(key, .block_state, read.block, .scheduler_ack_terminal, @intFromEnum(read.state)),
                    .plan_reap => |read| {
                        try self.lifetimeRead(key, .plan_phase, read.plan, .scheduler_reap_phase, read.executed_count.?);
                        if (read.readers_cas_reached) {
                            const after = try self.boundPoint(key, .scheduler_reap_readers, read.plan.index, read.plan.generation, .after);
                            try self.check(after, if (read.readers_cas_failure) |count| @as(u64, count) + 1 else 0);
                            if (read.readers_cas_failure != null) return error.UnrepresentedCut;
                        }
                    },
                    else => return error.UnrepresentedCut,
                }
            },
            .retire_block => |v| {
                const key = try self.lifetimeKey(v.key);
                try self.check(try self.boundPoint(key, .scheduler_slot_return, v.block.index, v.block.generation, .after), @intFromEnum(rt.scheduler.State.free));
                try self.retireLifetimeTrack(.block_state, v.block);
                try self.retireLifetimeTrack(.block_receipt, v.block);
            },
            .retire_plan => |v| {
                _ = try self.lifetimeKey(v.key);
                try self.retireLifetimeTrack(.plan_phase, v.plan);
            },
            .retire_group_references => |v| {
                const key = try self.lifetimeKey(v.key);
                try self.group_pins.returnGroup(&self.dependencies, v.group, key.ordinal);
                try self.retireLifetimeTrack(.group_terminal, v.group);
            },
        }
    }
    fn keyedPoint(self: *Validator, key: format.OperationKey, site: Site, index: u64, generation: u64) Error!Point {
        const role: usize = @intFromEnum(key.role);
        if (key.role == .render) {
            // These two fact variants share one Render-owned SPSC. Its own
            // monotonic key is authoritative even when the host lane is ahead
            // or behind. Every role ordinal is later backed by an ended render.
            if (key.ordinal == 0 or key.ordinal < self.keyed_operations[role]) return error.InvalidOrder;
            if (key.ordinal > self.render_ended and key.ordinal - self.render_ended > localLimit(self.limits.pending_dependencies)) return error.DependencyCapacity;
            if (key.ordinal != self.keyed_operations[role]) {
                self.keyed_operations[role] = key.ordinal;
                self.keyed_occurrences[role].count = 0;
            }
        } else if (self.keyed_operations[role] != key.ordinal) return error.UnboundOperation;
        return .{ .role = key.role, .operation = key.ordinal, .site = site, .index = index, .generation = generation, .occurrence = try self.keyed_occurrences[role].next(site, index), .edge = .after };
    }
    // Match the actual offline hook allocator: site + index within an operation.
    // Different handles do not consume each other's occurrences; skipped loads
    // do not allocate one. Before and after share the same reached load identity.
    fn readinessReads(self: *Validator, operation: format.OperationKey, key: format.readiness.observation.QueryKey, v: format.readiness.observation.QueryRead, acceptance_anchor: ?u64) Error!void {
        if (v.has(.stopped_first)) try self.check(try self.boundPoint(operation, .readiness_stopped_first, key.handle.index, key.handle.generation, .after), @intFromBool(v.stopped_first));
        if (v.has(.stopped_second)) try self.check(try self.boundPoint(operation, .readiness_stopped_second, key.handle.index, key.handle.generation, .after), @intFromBool(v.stopped_second));
        // Same Service.observation_sequence/frame as availabilityReads, never
        // a per-handle atomic or a prefix shared across Service/session owners.
        if (v.has(.sequence_before)) {
            var at = try self.boundPoint(operation, .readiness_sequence, 0, 0, .before);
            try self.observation_sequences.acquireGlobal(&self.dependencies, v.sequence_before, at);
            at.edge = .after;
            try self.check(at, v.sequence_before);
        }
        if (v.has(.observation_frame)) {
            var at = try self.boundPoint(operation, .readiness_frame, 0, 0, .before);
            try self.observation_frames.acquireGlobal(&self.dependencies, v.frame, at);
            at.edge = .after;
            try self.check(at, v.frame);
        }
        if (v.has(.consumed)) try self.check(try self.boundPoint(operation, .readiness_consumed, key.handle.index, key.handle.generation, .after), v.consumed);
        if (v.has(.produced)) try self.check(try self.boundPoint(operation, .readiness_produced, key.handle.index, key.handle.generation, .after), v.produced);
        if (v.has(.sequence_after)) {
            var at = try self.boundPoint(operation, .readiness_final_sequence, 0, 0, .before);
            try self.observation_sequences.acquireGlobal(&self.dependencies, v.sequence_after, at);
            at.edge = .after;
            try self.check(at, v.sequence_after);
        }
        for (0..v.scanned) |index| {
            const observed = v.state(index);
            const job = self.jobs[index];
            if (observed != .free and !job.live) return error.MissingPublication;
            const at = try self.boundPoint(operation, .readiness_job, index, 0, .before);
            try self.job_cuts.acquireOrdered(&self.dependencies, @intCast(index), job.job, switch (observed) {
                .free => .free,
                .queued => .queued,
                .running => .running,
                .completed => .completed,
            }, at, if (acceptance_anchor) |anchor| .{ .readiness = anchor } else null);
            var after = at;
            after.edge = .after;
            try self.check(after, @intFromEnum(observed));
        }
    }
    fn boundPoint(self: *Validator, key: format.OperationKey, site: Site, index: u64, generation: u64, edge: Edge) Error!Point {
        for (&self.bindings) |*entry| if (entry.*) |*binding| {
            if (std.meta.eql(binding.key, key)) return .{ .role = key.role, .operation = key.ordinal, .site = site, .index = index, .generation = generation, .occurrence = try binding.occurrences.next(site, index), .edge = edge };
        };
        return error.UnboundOperation;
    }
    /// Select only from an actual published SlotRead in the Render witness FIFO.
    /// This metadata does not prepare, publish, acquire, or retire a lifetime.
    pub fn bindRenderPublishedScan(self: *Validator, handle: rt.scheduler.Handle) Error!void {
        var previous: ?*ProgressTrack = null;
        for (&self.progress_tracks) |*entry| if (entry.*) |*track| {
            try self.dependencies.charge();
            if (track.kind != .block_state or track.index != handle.index or !track.render_scan_selected) continue;
            if (previous != null) return error.InvalidEvidence;
            previous = track;
        };
        if (previous) |track| {
            if (track.generation == handle.generation) return error.DuplicateAcquisition;
            if (track.generation > handle.generation) return error.StaleReference;
            // Reuse is never inferred from Control's newest slot identity.
            if (!track.retired) return error.MissingAcquisition;
        }
        const selected = try self.progressTrack(.block_state, handle.index, handle.generation);
        if (previous) |track| track.render_scan_selected = false;
        selected.render_scan_selected = true;
    }
    /// Keep the original generation-zero checkpoint and span occurrence.
    /// Prefix emits acquired-after -> read-before -> terminal-before; both
    /// actual transitions and the separate ownership retirement remain required.
    pub fn acquireRenderScan(self: *Validator, index: u16, at: Point) Error!void {
        if (at.role != .render or at.site != .scheduler_scan or at.edge != .before or at.index != index or at.generation != 0) return error.InvalidEvidence;
        var selected: ?*ProgressTrack = null;
        for (&self.progress_tracks) |*entry| if (entry.*) |*track| {
            try self.dependencies.charge();
            if (track.kind != .block_state or track.index != index or !track.render_scan_selected) continue;
            if (selected != null) return error.InvalidEvidence;
            selected = track;
        };
        const track = selected orelse return error.MissingPublication;
        try track.prefix.acquire(&self.dependencies, @intFromEnum(rt.scheduler.State.acquired), at);
    }
    fn progressTrack(self: *Validator, kind: ProgressKind, index: u16, generation: u64) Error!*ProgressTrack {
        if (index >= 64 or generation == 0 or generation <= self.progress_retired[@intFromEnum(kind)][index]) return error.StaleReference;
        for (&self.progress_tracks) |*entry| if (entry.*) |*track| {
            if (track.kind == kind and track.index == index and track.generation == generation) return track;
        };
        for (self.progress_tracks[0..localLimit(self.limits.pending_dependencies)]) |*entry| if (entry.* == null) {
            try self.dependencies.reservePending();
            entry.* = .{ .kind = kind, .index = index, .generation = generation, .prefix = try Prefix.init(0, localLimit(self.limits.pending_dependencies)) };
            return &entry.*.?;
        };
        return error.DependencyCapacity;
    }
    fn progressPublish(self: *Validator, kind: ProgressKind, index: u16, generation: u64, value: u64, at: Point) Error!void {
        const track = try self.progressTrack(kind, index, generation);
        if (value <= track.prefix.latest) return error.DuplicatePublication;
        for (self.progress_facts) |entry| if (entry) |fact| {
            if (fact.kind == kind and fact.index == index and fact.generation == generation and fact.value == value) return error.DuplicatePublication;
        };
        for (self.progress_facts[0..localLimit(self.limits.pending_dependencies)]) |*entry| if (entry.* == null) {
            try self.dependencies.reservePending();
            entry.* = .{ .kind = kind, .index = index, .generation = generation, .value = value, .at = at };
            try self.flushProgress();
            return;
        };
        return error.DependencyCapacity;
    }
    fn flushProgress(self: *Validator) Error!void {
        var changed = true;
        while (changed) {
            changed = false;
            for (&self.progress_facts) |*entry| if (entry.*) |fact| {
                try self.dependencies.charge();
                const track = try self.progressTrack(fact.kind, fact.index, fact.generation);
                const latest = track.prefix.latest;
                const next: u64 = switch (fact.kind) {
                    .block_state => switch (latest) {
                        0 => @intFromEnum(rt.scheduler.State.published),
                        @intFromEnum(rt.scheduler.State.published) => @intFromEnum(rt.scheduler.State.acquired),
                        @intFromEnum(rt.scheduler.State.acquired) => @intFromEnum(rt.scheduler.State.terminal),
                        else => return error.UnrepresentedCut,
                    },
                    .block_receipt, .plan_phase => try add(latest, 1),
                    .group_terminal => 1,
                };
                if (fact.value < next) return error.DuplicatePublication;
                if (fact.value == next) {
                    try track.prefix.publish(&self.dependencies, fact.value, fact.at);
                    entry.* = null;
                    self.dependencies.releasePending();
                    changed = true;
                }
            };
        }
    }
    fn finishProgress(self: *Validator) Error!void {
        try self.flushProgress();
        for (self.progress_facts) |entry| if (entry != null) return error.MissingPublication;
        for (&self.progress_tracks) |*entry| if (entry.*) |*track| {
            // Source EOF is not a lifetime retirement. Until actual slot/plan/
            // group return facts are paired, a nonempty track cannot certify.
            if (!track.retired or !track.prepared) return error.UnrepresentedCut;
            if (track.kind == .block_state and track.prefix.latest != @intFromEnum(rt.scheduler.State.terminal)) return error.MissingPublication;
            if ((track.kind == .block_receipt or track.kind == .plan_phase or track.kind == .group_terminal) and track.prefix.latest != track.expected_count) return error.MissingPublication;
            try track.prefix.close(&self.dependencies, track.prefix.latest);
            try track.prefix.finish();
            if (track.pending) {
                track.pending = false;
                self.dependencies.releasePending();
            }
        };
    }
    pub fn finish(self: *Validator) Error!Summary {
        return self.finishImpl() catch |err| {
            if (@import("builtin").is_test and !self.failed) {
                std.debug.print("causal validator finish failed: error={s} records={d} work={d}/{d} pending={d}/{d} checks={d} unsupported_cuts={d}\n", .{ @errorName(err), self.cursor.records, self.dependencies.work, self.dependencies.work_limit, self.dependencies.pending_total, self.dependencies.capacity, self.checks, self.unsupported_cuts });
                self.printUnsupportedReasons();
                if (@errorReturnTrace()) |error_trace| std.debug.dumpErrorReturnTrace(error_trace);
            }
            self.failed = true;
            return err;
        };
    }
    fn finishImpl(self: *Validator) Error!Summary {
        if (self.failed or self.finished) return error.Incomplete;
        try self.flush();
        if (!self.group_event_terminal) return error.MissingTerminal;
        if (self.group_event_pending != null) return error.MissingAcquisition;
        if (self.keyed_operations[@intFromEnum(format.Role.render)] > self.render_ended) return error.UnboundOperation;
        try self.cursor.finish();
        if (self.pending_count != 0) return error.UnboundOperation;
        for (self.bindings) |entry| if (entry != null) return error.MissingAcquisition;
        for (self.peers) |peer_state| if (peer_state.open) return error.MissingAcquisition;
        if (self.render_call.open or self.worker.key != null or self.query != null) return error.MissingAcquisition;
        if (self.peers[0].ticks != self.peers[1].ticks or self.peers[0].ticks != self.peers[2].ticks) return error.InvalidEvidence;
        for (self.streams) |life| if (life.live) return error.MissingAcquisition;
        for (self.jobs) |job| if (job.live) return error.MissingAcquisition;
        if (self.saw_retirement != self.saw_retirement_ack or (self.retirement_worker != null and !self.retirement_linked)) return error.MissingAcquisition;
        const render_closed = self.render_terminal orelse return error.MissingTerminal;
        const ready_closed = self.readiness_terminal orelse return error.MissingTerminal;
        if (render_closed.calls_opened != self.render_calls or render_closed.final_frame != self.render_frame or render_closed.final_call_sequence != self.render_sequence or render_closed.final_gate != self.header.bindings.render_manifest.initial_gate + self.render_gates) return error.InvalidEvidence;
        if (ready_closed.ticks_opened != self.peers[2].ticks or ready_closed.final_frame != self.render_frame or ready_closed.final_call_sequence != self.render_sequence or ready_closed.final_gate != render_closed.final_gate or ready_closed.final_observation_sequence != self.header.bindings.readiness_manifest.initial_observation_sequence + 2 * self.service_gates) return error.InvalidEvidence;
        if (self.proved_failed_ticks != self.cursor.failed_ticks[0] or self.proved_failed_ticks != self.cursor.failed_ticks[1]) return error.IncompleteCoverage;
        try self.observation_sequences.close(&self.dependencies, ready_closed.final_observation_sequence);
        try self.observation_frames.close(&self.dependencies, self.observation_frames.latest);
        try self.observation_sequences.finish();
        try self.observation_frames.finish();
        if (self.horizon_gate_open) return error.MissingPublication;
        try self.commit_horizons.close(&self.dependencies, self.render_frame);
        try self.commit_horizons.finish();
        try self.render_frames.close(&self.dependencies, self.render_frame);
        try self.stream_frontier.close(&self.dependencies, self.publication_ordinal);
        try self.render_frames.finish();
        try self.stream_frontier.finish();
        try self.finishVisibilityReads();
        try self.visibility_owners.finish(&self.dependencies);
        try self.stream_stop_cuts.finish(&self.dependencies);
        try self.consumed_cuts.finish(&self.dependencies);
        try self.job_cuts.finish(&self.dependencies);
        try self.completion_cuts.finish(&self.dependencies);
        try self.group_pins.finish();
        self.lifetimeLedger().finish() catch |err| {
            const mapped = lifetimeError(err);
            return mapped;
        };
        try self.finishProgress();
        try self.exclusion_tickets.finish(&self.dependencies);
        try self.dependencies.finish();
        if (self.admission_ordinal != self.publication_ordinal or self.acknowledgement_ordinal != self.publication_ordinal or self.completion_read != self.completion_write) return error.MissingAcquisition;
        if (self.unsupported_cuts != 0) return error.UnrepresentedCut;
        self.finished = true;
        return .{ .records = self.cursor.records, .operations = self.cursor.operations, .witness_events = self.semantic_sequences, .matched_handoffs = self.dependencies.matched, .dependencies = self.dependencies.emitted, .pending_high_water = self.dependencies.high_water, .work = self.dependencies.work };
    }
};
pub const fixed_validator_bytes: usize = @sizeOf(Validator);
pub const fixed_progress_table_bytes: usize = @sizeOf([progress_capacity]?ProgressTrack);
pub const fixed_binding_table_bytes: usize = @sizeOf([max_operation_bindings]?Binding);
fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.InvalidEvidence;
}

/// Called by the registered standalone test root; package-local test blocks
/// are not discovered by that root's dependency module enumeration.
pub fn testPublicationReleaseIdentity() !void {
    if (!@import("builtin").is_test) @compileError("test-only publication checkpoint regression");
    const t = std.testing;
    const Log = struct {
        values: [2]Check = undefined,
        count: usize = 0,
        fn emit(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.count == self.values.len) return error.DependencyCapacity;
            self.values[self.count] = value;
            self.count += 1;
        }
    };
    var log: Log = .{};
    const validator = try t.allocator.create(Validator);
    defer t.allocator.destroy(validator);
    // Isolated extraction test: initialize precisely the fields used by the
    // real acceptance publication path, with no engine or claimed EOF proof.
    validator.dependencies = try Dependencies.init(8, 1024, null);
    try validator.stream_frontier.initInto(0, 8);
    for (&validator.bindings) |*entry| entry.* = null;
    const key: format.OperationKey = .{ .role = .control, .ordinal = 19 };
    validator.bindings[0] = .{ .key = key, .serial = 4, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 4, .frontier_tick_serial = 4 } } };
    validator.check_sink = .{ .context = &log, .emit = Log.emit };
    validator.checks = 0;
    validator.publication_ordinal = 0;
    _ = try validator.publicationRelease(key, 1);
    _ = try validator.publicationRelease(key, 2);
    try t.expectEqual(@as(usize, 2), log.count);
    for (log.values, 0..) |actual, i| {
        const expected: Check = .{ .point = .{ .role = .control, .operation = 19, .site = .publication_release, .index = 0, .generation = 0, .occurrence = @intCast(i + 1), .edge = .after }, .value = i + 1 };
        try t.expectEqualDeep(expected, actual);
        try t.expectEqualDeep(expected.point, validator.stream_frontier.publications[i].?.point);
    }
    // Duplicate, skipped, and old ordinals cannot mint a new checkpoint.
    for ([_]u64{ 2, 4, 1 }) |wrong| try t.expectError(error.InvalidEvidence, validator.publicationRelease(key, wrong));
    try t.expectEqual(@as(usize, 2), log.count);
    try t.expectEqual(@as(u64, 2), validator.publication_ordinal);
    try t.expectEqual(@as(u64, 2), validator.checks);
}

/// Extraction regression called by the registered standalone validation root.
pub fn testReadinessLoadOccurrences() !void {
    if (!@import("builtin").is_test) @compileError("test-only readiness checkpoint regression");
    const t = std.testing;
    const Log = struct {
        values: [33]Check = undefined,
        count: usize = 0,
        fn emit(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.count == self.values.len) return error.DependencyCapacity;
            self.values[self.count] = value;
            self.count += 1;
        }
    };
    var log: Log = .{};
    const validator = try t.allocator.create(Validator);
    defer t.allocator.destroy(validator);
    // Exercise the production extractor, not a synthetic complete recording.
    validator.dependencies = try Dependencies.init(32, 4096, null);
    try validator.observation_sequences.initInto(0, 16);
    try validator.observation_frames.initInto(0, 16);
    try validator.job_cuts.initInto(16);
    validator.jobs[0] = .{};
    for (&validator.bindings) |*entry| entry.* = null;
    const operation: format.OperationKey = .{ .role = .control, .ordinal = 2 };
    validator.bindings[0] = .{ .key = operation, .serial = 1, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 1, .frontier_tick_serial = 1 } } };
    validator.check_sink = .{ .context = &log, .emit = Log.emit };
    validator.checks = 0;
    var reads: format.readiness.observation.QueryRead = .{ .consumed = 7, .produced = 11 };
    inline for (.{ .stopped_first, .stopped_second, .sequence_before, .observation_frame, .consumed, .produced, .sequence_after }) |site| reads.saw(site);
    reads.putState(0, .free);
    const first: format.readiness.observation.QueryKey = .{ .handle = .{ .index = 0, .generation = 2 } };
    const second: format.readiness.observation.QueryKey = .{ .handle = .{ .index = 1, .generation = 2 } };
    try validator.readinessReads(operation, first, reads, null);
    try validator.readinessReads(operation, second, reads, null);
    try validator.readinessReads(operation, first, reads, null);
    // A reached first load must not consume skipped later sites. This only
    // tests extraction identity; it does not admit a failed/partial query.
    var partial: format.readiness.observation.QueryRead = .{ .stopped_first = true };
    partial.saw(.stopped_first);
    try validator.readinessReads(operation, first, partial, null);
    try validator.readinessReads(operation, first, reads, null);
    try t.expectEqual(@as(usize, 33), log.count);
    const sites = [_]Site{ .readiness_stopped_first, .readiness_stopped_second, .readiness_sequence, .readiness_frame, .readiness_consumed, .readiness_produced, .readiness_final_sequence, .readiness_job };
    for ([_]usize{ 0, 8, 16, 25 }, 0..) |base, query_index| {
        for (sites, 0..) |site, load_index| {
            const per_handle = load_index == 0 or load_index == 1 or load_index == 4 or load_index == 5;
            const handle = if (query_index == 1) second.handle else first.handle;
            const occurrence: u32 = if (!per_handle) @intCast(query_index + 1) else switch (query_index) {
                0, 1 => 1,
                2 => 2,
                3 => if (load_index == 0) 4 else 3,
                else => unreachable,
            };
            const expected: Check = .{ .point = .{ .role = .control, .operation = 2, .site = site, .index = if (per_handle) handle.index else 0, .generation = if (per_handle) handle.generation else 0, .occurrence = occurrence, .edge = .after }, .value = if (load_index == 4) 7 else if (load_index == 5) 11 else 0 };
            try t.expectEqualDeep(expected, log.values[base + load_index]);
        }
    }
    try t.expectEqualDeep(@as(Check, .{ .point = .{ .role = .control, .operation = 2, .site = .readiness_stopped_first, .index = 0, .generation = 2, .occurrence = 3, .edge = .after }, .value = 1 }), log.values[24]);
    try t.expectEqual(@as(u64, 33), validator.checks);
    // Prefix reads use before of the exact same occurrence as each comparator.
    var frame_reads: usize = 0;
    for (validator.observation_frames.reads) |entry| if (entry) |read| {
        frame_reads += 1;
        var expected = log.values[28].point;
        expected.edge = .before;
        try t.expectEqualDeep(expected, read.before);
    };
    try t.expectEqual(@as(usize, 1), frame_reads);
}

pub fn testTerminalScanIntervals() !void {
    if (!@import("builtin").is_test) @compileError("test-only terminal scan regression");
    const t = std.testing;
    const Log = struct {
        checks: [2]Check = undefined,
        edges: [4]Dependency = undefined,
        check_count: usize = 0,
        edge_count: usize = 0,
        fn check(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.check_count == self.checks.len) return error.DependencyCapacity;
            self.checks[self.check_count] = value;
            self.check_count += 1;
        }
        fn edge(raw: *anyopaque, value: Dependency) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.edge_count == self.edges.len) return error.DependencyCapacity;
            self.edges[self.edge_count] = value;
            self.edge_count += 1;
        }
    };
    var log: Log = .{};
    const validator = try t.allocator.create(Validator);
    defer t.allocator.destroy(validator);
    validator.limits = .{ .pending_dependencies = 8 };
    validator.dependencies = try Dependencies.init(8, 4096, .{ .context = &log, .emit = Log.edge });
    validator.check_sink = .{ .context = &log, .emit = Log.check };
    validator.checks = 0;
    for (&validator.bindings) |*entry| entry.* = null;
    for (&validator.progress_tracks) |*entry| entry.* = null;
    for (&validator.progress_retired) |*row| @memset(row, 0);
    const key: format.OperationKey = .{ .role = .control, .ordinal = 2 };
    validator.bindings[0] = .{ .key = key, .serial = 1, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 1, .frontier_tick_serial = 1 } } };
    // Isolated sink test. Actual Control prefix selection is exercised by the
    // separate lifecycle tests; this checks the resulting two-sided cuts.
    const track = try validator.progressTrack(.block_state, 0, 13);
    track.prepared = true;
    const published: Point = .{ .role = .control, .operation = 1, .site = .scheduler_publication, .index = 0, .generation = 13, .occurrence = 1, .edge = .after };
    const acquired: Point = .{ .role = .render, .operation = 1, .site = .scheduler_acquired, .index = 0, .generation = 13, .occurrence = 1, .edge = .after };
    const terminal: Point = .{ .role = .render, .operation = 1, .site = .scheduler_terminal, .index = 0, .generation = 13, .occurrence = 1, .edge = .after };
    try track.prefix.publish(&validator.dependencies, 3, published);
    try validator.terminalScanRead(key, 0, 13, .published);
    try track.prefix.publish(&validator.dependencies, 4, acquired);
    try validator.terminalScanRead(key, 0, 13, .acquired);
    try track.prefix.publish(&validator.dependencies, 6, terminal);
    try t.expectEqual(@as(usize, 2), log.check_count);
    try t.expectEqual(@as(usize, 4), log.edge_count);
    for (log.checks, 0..) |actual, index| {
        const expected: Check = .{ .point = .{ .role = .control, .operation = 2, .site = .terminal_scan, .index = 0, .generation = 0, .occurrence = @intCast(index + 1), .edge = .after }, .value = index + 3 };
        try t.expectEqualDeep(expected, actual);
        var before = actual.point;
        before.edge = .before;
        const lower = if (index == 0) published else acquired;
        var upper = if (index == 0) acquired else terminal;
        upper.edge = .before;
        try t.expectEqualDeep(@as(Dependency, .{ .before = lower, .after = before }), log.edges[index * 2]);
        try t.expectEqualDeep(@as(Dependency, .{ .before = actual.point, .after = upper }), log.edges[index * 2 + 1]);
    }
    try t.expectError(error.MissingPublication, validator.terminalScanRead(key, 0, 0, .published));
    try t.expectError(error.MissingPublication, validator.terminalScanRead(key, 0, 14, .acquired));
}

pub fn testGroupEventQueueCuts() !void {
    if (!@import("builtin").is_test) @compileError("test-only group queue regression");
    const t = std.testing;
    const Fixture = struct {
        validator: *Validator,
        checks: [16]Check = undefined,
        edges: [16]Dependency = undefined,
        check_count: usize = 0,
        edge_count: usize = 0,
        fn check(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.check_count == self.checks.len) return error.DependencyCapacity;
            self.checks[self.check_count] = value;
            self.check_count += 1;
        }
        fn edge(raw: *anyopaque, value: Dependency) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.edge_count == self.edges.len) return error.DependencyCapacity;
            self.edges[self.edge_count] = value;
            self.edge_count += 1;
        }
        fn initInto(self: *@This()) !void {
            self.validator = try t.allocator.create(Validator);
            const v = self.validator;
            v.limits = .{ .pending_dependencies = 16 };
            v.dependencies = try Dependencies.init(16, 8192, .{ .context = self, .emit = edge });
            v.check_sink = .{ .context = self, .emit = check };
            v.checks = 0;
            try v.group_event_writes.initInto(0, 16);
            try v.group_event_returns.initInto(0, 16);
            v.group_event_head = 0;
            v.group_event_tail = 0;
            v.group_event_seen_head = 0;
            v.group_event_seen_tail = 0;
            v.group_event_pending = null;
            v.group_event_terminal = false;
            v.keyed_operations = .{ 1, 0, 0 };
            v.render_ended = 0;
            for (&v.keyed_occurrences) |*entry| entry.count = 0;
        }
    };
    const control: format.OperationKey = .{ .role = .control, .ordinal = 1 };
    const render: format.OperationKey = .{ .role = .render, .ordinal = 1 };
    const event: trace.ScheduleEntry = .{ .event = .{ .kind = .group, .context = 1, .transport_epoch = 1, .asset_generation = 1 } };
    {
        var f: Fixture = .{ .validator = undefined };
        try f.initInto();
        defer t.allocator.destroy(f.validator);
        const v = f.validator;
        // Empty acquired prefix0 must precede the actual first release1,
        // even when the release fact is encountered later by the assembler.
        try v.groupEventQueue(control, 1, .{ .pop = .{ .tail_before = 0, .head_acquired = 0, .tail_after = 0, .present = false } });
        for (0..2) |index| {
            const n: u64 = @intCast(index);
            try v.groupEventQueue(render, 1, .{ .push = .{ .enabled = true, .head_before = n, .tail_acquired = n, .head_after = n + 1, .accepted = true } });
            try v.groupEventQueue(control, 1, .{ .pop = .{ .tail_before = n, .head_acquired = n + 1, .tail_after = n + 1, .present = true } });
            try v.groupEventSchedule(control, event);
        }
        try v.groupEventQueue(control, 1, .{ .pop = .{ .tail_before = 2, .head_acquired = 2, .tail_after = 2, .present = false } });
        try v.groupEventTerminal(1, 2, 2);
        try t.expectEqual(@as(usize, 10), f.check_count);
        try t.expectEqual(@as(u64, 10), v.checks);
        try t.expectEqual(@as(u32, 4), f.checks[9].point.occurrence);
        try t.expectEqual(@as(u64, 2), f.checks[9].value);
        for (f.checks[0..f.check_count]) |check| {
            try t.expectEqual(@as(u64, 0), check.point.index);
            try t.expectEqual(@as(u64, 1), check.point.generation);
            try t.expectEqual(Edge.after, check.point.edge);
        }
        var empty_upper = false;
        for (f.edges[0..f.edge_count]) |edge| if (edge.before.site == .group_event_pop and edge.before.occurrence == 1 and edge.after.site == .group_event_publish and edge.after.occurrence == 1) {
            empty_upper = true;
            try t.expectEqual(Edge.after, edge.before.edge);
            try t.expectEqual(Edge.before, edge.after.edge);
        };
        try t.expect(empty_upper);
        try t.expectEqual(@as(usize, 0), v.dependencies.pending_total);
        try t.expectError(error.StaleIdentity, v.groupEventTerminal(1, 2, 2));
    }
    for (0..5) |case| {
        var f: Fixture = .{ .validator = undefined };
        try f.initInto();
        defer t.allocator.destroy(f.validator);
        const v = f.validator;
        switch (case) {
            0 => try t.expectError(error.MissingAcquisition, v.groupEventSchedule(control, event)),
            1 => try t.expectError(error.StaleIdentity, v.groupEventQueue(control, 2, .{ .pop = .{ .tail_before = 0, .head_acquired = 0, .tail_after = 0, .present = false } })),
            2 => {
                try v.groupEventQueue(control, 1, .{ .pop = .{ .tail_before = 0, .head_acquired = 1, .tail_after = 1, .present = true } });
                try t.expectError(error.MissingAcquisition, v.groupEventTerminal(1, 1, 1));
            },
            3 => {
                try v.groupEventQueue(render, 1, .{ .push = .{ .enabled = true, .head_before = 0, .tail_acquired = 0, .head_after = 1, .accepted = true } });
                try v.groupEventQueue(control, 1, .{ .pop = .{ .tail_before = 0, .head_acquired = 1, .tail_after = 1, .present = true } });
                try t.expectError(error.StaleReference, v.groupEventSchedule(.{ .role = .control, .ordinal = 2 }, event));
            },
            4 => try t.expectError(error.InvalidEvidence, v.groupEventQueue(render, 1, .{ .push = .{ .enabled = true, .head_before = 1, .tail_acquired = 0, .head_after = 2, .accepted = true } })),
            else => unreachable,
        }
    }
}

pub fn testIndependentCollectionFrames() !void {
    if (!@import("builtin").is_test) @compileError("test-only collection frame regression");
    const t = std.testing;
    const Log = struct {
        checks: [2]Check = undefined,
        edges: [4]Dependency = undefined,
        checks_used: usize = 0,
        edges_used: usize = 0,
        fn check(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.checks_used == self.checks.len) return error.DependencyCapacity;
            self.checks[self.checks_used] = value;
            self.checks_used += 1;
        }
        fn edge(raw: *anyopaque, value: Dependency) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.edges_used == self.edges.len) return error.DependencyCapacity;
            self.edges[self.edges_used] = value;
            self.edges_used += 1;
        }
    };
    var log: Log = .{};
    const validator = try t.allocator.create(Validator);
    defer t.allocator.destroy(validator);
    validator.dependencies = try Dependencies.init(8, 4096, .{ .context = &log, .emit = Log.edge });
    validator.check_sink = .{ .context = &log, .emit = Log.check };
    validator.checks = 0;
    try validator.render_frames.initInto(0, 8);
    for (&validator.bindings) |*entry| entry.* = null;
    const key: format.OperationKey = .{ .role = .control, .ordinal = 2 };
    validator.bindings[0] = .{ .key = key, .serial = 1, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 1, .frontier_tick_serial = 1 } } };
    const frame64: Point = .{ .role = .render, .operation = 1, .site = .render_frame, .occurrence = 1, .edge = .after };
    var frame128 = frame64;
    frame128.occurrence = 2;
    var frame192 = frame64;
    frame192.occurrence = 3;
    try validator.render_frames.publish(&validator.dependencies, 64, frame64);
    _ = try validator.controlCollectFrame(key, 64);
    try validator.render_frames.publish(&validator.dependencies, 128, frame128);
    // The subsequent readiness acquire keeps its existing site/kind identity.
    const kind = @intFromEnum(format.readiness.AcquisitionKind.collect_frame);
    var later = try Validator.point(key, .collection_frame, kind, 0, 0, .before);
    try validator.render_frames.acquire(&validator.dependencies, 128, later);
    later.edge = .after;
    try validator.check(later, 128);
    try validator.render_frames.publish(&validator.dependencies, 192, frame192);
    try t.expectEqual(@as(usize, 2), log.checks_used);
    try t.expectEqual(@as(usize, 4), log.edges_used);
    try t.expectEqualDeep(@as(Check, .{ .point = .{ .role = .control, .operation = 2, .site = .control_collect_frame, .index = 0, .generation = 0, .occurrence = 1, .edge = .after }, .value = 64 }), log.checks[0]);
    try t.expectEqualDeep(@as(Check, .{ .point = later, .value = 128 }), log.checks[1]);
    for (log.checks, 0..) |check, i| {
        var before = check.point;
        before.edge = .before;
        const lower = if (i == 0) frame64 else frame128;
        var upper = if (i == 0) frame128 else frame192;
        upper.edge = .before;
        try t.expectEqualDeep(@as(Dependency, .{ .before = lower, .after = before }), log.edges[i * 2]);
        try t.expectEqualDeep(@as(Dependency, .{ .before = check.point, .after = upper }), log.edges[i * 2 + 1]);
    }
}

pub fn testVisibilityReadPrefixes() !void {
    if (!@import("builtin").is_test) @compileError("test-only visibility read regression");
    const t = std.testing;
    const Fixture = struct {
        validator: *Validator,
        checks: [4]Check = undefined,
        edges: [4]Dependency = undefined,
        check_count: usize = 0,
        edge_count: usize = 0,
        fn check(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.check_count == self.checks.len) return error.DependencyCapacity;
            self.checks[self.check_count] = value;
            self.check_count += 1;
        }
        fn edge(raw: *anyopaque, value: Dependency) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.edge_count == self.edges.len) return error.DependencyCapacity;
            self.edges[self.edge_count] = value;
            self.edge_count += 1;
        }
        fn initInto(self: *@This()) !void {
            self.validator = try t.allocator.create(Validator);
            const value = self.validator;
            value.dependencies = try Dependencies.init(8, 4096, .{ .context = self, .emit = edge });
            value.check_sink = .{ .context = self, .emit = check };
            value.checks = 0;
            try value.stream_admissions.initInto(0, 8);
            value.visibility_observed_read = 0;
            value.admission_ordinal = 0;
            value.publication_ordinal = 0;
            value.acknowledgement_ordinal = 0;
            for (&value.bindings) |*entry| entry.* = null;
            value.bindings[0] = .{ .key = .{ .role = .control, .ordinal = 2 }, .serial = 1, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 1, .frontier_tick_serial = 1 } } };
        }
    };
    const key: format.OperationKey = .{ .role = .control, .ordinal = 2 };
    const release: Point = .{ .role = .render, .operation = 1, .site = .visibility_release, .index = 0, .generation = 0, .occurrence = 1, .edge = .after };
    {
        var f: Fixture = .{ .validator = undefined };
        try f.initInto();
        defer t.allocator.destroy(f.validator);
        const value = f.validator;
        const empty = try value.visibilityPollRead(key, 0);
        try value.visibilityRelease(release, 1);
        const present = try value.visibilityPollRead(key, 1);
        // Isolated prefix closure uses exact already-established owner totals.
        value.publication_ordinal = 1;
        value.acknowledgement_ordinal = 1;
        try value.finishVisibilityReads();
        try t.expectEqual(@as(usize, 3), f.check_count);
        try t.expectEqual(@as(usize, 2), f.edge_count);
        var empty_after = empty;
        empty_after.edge = .after;
        var release_before = release;
        release_before.edge = .before;
        try t.expectEqualDeep(@as(Dependency, .{ .before = empty_after, .after = release_before }), f.edges[0]);
        try t.expectEqualDeep(@as(Dependency, .{ .before = release, .after = present }), f.edges[1]);
        try t.expectEqualDeep(@as(Check, .{ .point = empty_after, .value = 0 }), f.checks[0]);
        try t.expectEqualDeep(@as(Check, .{ .point = release, .value = 1 }), f.checks[1]);
        try t.expectEqual(@as(u32, 2), f.checks[2].point.occurrence);
        try t.expectEqual(@as(u64, 1), f.checks[2].value);
        try t.expectEqual(@as(usize, 0), value.dependencies.pending_total);
    }
    for (0..4) |case| {
        var f: Fixture = .{ .validator = undefined };
        try f.initInto();
        defer t.allocator.destroy(f.validator);
        const value = f.validator;
        switch (case) {
            0 => {
                _ = try value.visibilityPollRead(key, 1);
                // A read cannot create its missing actual Render publication.
                try t.expectError(error.MissingPublication, value.finishVisibilityReads());
            },
            1 => {
                try value.visibilityRelease(release, 1);
                try t.expectError(error.InvalidEvidence, value.visibilityRelease(release, 1));
            },
            2 => {
                _ = try value.visibilityPollRead(key, 1);
                try t.expectError(error.InvalidEvidence, value.visibilityPollRead(key, 0));
            },
            3 => {
                try value.visibilityRelease(release, 1);
                value.publication_ordinal = 1;
                try t.expectError(error.MissingAcquisition, value.finishVisibilityReads());
            },
            else => unreachable,
        }
    }
}

pub fn testCommitHorizonCuts() !void {
    if (!@import("builtin").is_test) @compileError("test-only commit horizon regression");
    const t = std.testing;
    const Fixture = struct {
        validator: *Validator = undefined,
        checks: [16]Check = undefined,
        edges: [16]Dependency = undefined,
        checks_used: usize = 0,
        edges_used: usize = 0,
        fn check(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.checks_used == self.checks.len) return error.DependencyCapacity;
            self.checks[self.checks_used] = value;
            self.checks_used += 1;
        }
        fn edge(raw: *anyopaque, value: Dependency) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.edges_used == self.edges.len) return error.DependencyCapacity;
            self.edges[self.edges_used] = value;
            self.edges_used += 1;
        }
        fn initInto(self: *@This()) !void {
            self.validator = try t.allocator.create(Validator);
            const value = self.validator;
            value.dependencies = try Dependencies.init(8, 4096, .{ .context = self, .emit = edge });
            value.check_sink = .{ .context = self, .emit = check };
            value.checks = 0;
            try value.render_frames.initInto(0, 8);
            try value.commit_horizons.initInto(0, 8);
            value.horizon_gate_open = false;
            for (&value.bindings) |*entry| entry.* = null;
            value.bindings[0] = .{ .key = .{ .role = .control, .ordinal = 2 }, .serial = 1, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 1, .frontier_tick_serial = 1 } } };
        }
    };
    const control: format.OperationKey = .{ .role = .control, .ordinal = 2 };
    const render_key: format.OperationKey = .{ .role = .render, .ordinal = 1 };
    const lead = rt.scheduler.default_profile.min_plan_lead_frames;
    const budget = rt.scheduler.default_profile.late_race_budget_frames;
    {
        var f: Fixture = .{};
        try f.initInto();
        defer t.allocator.destroy(f.validator);
        const value = f.validator;
        try value.planHorizon(control, 0, lead, budget, lead + budget);
        try value.horizonBegin(render_key, 0, 0);
        try value.horizonEnd(render_key, 0, 64);
        // The new commit horizon is visible before DSP/render_frame advances.
        try t.expectEqual(@as(u64, 0), value.render_frames.latest);
        try value.planHorizon(control, 64, lead, budget, 64 + lead + budget);
        try value.horizonRead(control, .scheduler_prepare_horizon, 64);
        try value.horizonBegin(render_key, 1, 64);
        try t.expectEqual(@as(u64, 1), value.commit_horizons.publication_count);
        try value.horizonEnd(render_key, 1, 128);
        try value.commit_horizons.close(&value.dependencies, 128);
        try value.commit_horizons.finish();
        try t.expectEqual(@as(usize, 0), value.dependencies.pending_total);
        try t.expectEqual(@as(usize, 7), f.checks_used);
        try t.expectEqual(@as(usize, 5), f.edges_used);
        const release64 = try Validator.point(render_key, .render_commit_horizon, 0, 0, 0, .after);
        var release64_before = release64;
        release64_before.edge = .before;
        try t.expectEqualDeep(@as(Dependency, .{ .before = f.checks[0].point, .after = release64_before }), f.edges[0]);
        var plan_before = f.checks[3].point;
        plan_before.edge = .before;
        try t.expectEqualDeep(@as(Dependency, .{ .before = release64, .after = plan_before }), f.edges[1]);
        try t.expectEqual(Site.control_horizon, f.checks[3].point.site);
        try t.expectEqual(@as(u32, 2), f.checks[3].point.occurrence);
        try t.expectEqual(@as(u64, 64), f.checks[3].value);
        try t.expectEqual(Site.scheduler_prepare_horizon, f.checks[4].point.site);
        try t.expectEqual(@as(u32, 1), f.checks[4].point.occurrence);
        try t.expectEqual(Site.scheduler_horizon, f.checks[5].point.site);
        try t.expectEqual(@as(u64, 64), f.checks[5].value);
        try t.expectEqual(@as(u32, 2), f.checks[5].point.occurrence);
    }
    {
        var f: Fixture = .{};
        try f.initInto();
        defer t.allocator.destroy(f.validator);
        try f.validator.planHorizon(control, 64, lead, budget, 64 + lead + budget);
        try t.expectError(error.MissingPublication, f.validator.commit_horizons.close(&f.validator.dependencies, 0));
    }
    {
        var f: Fixture = .{};
        try f.initInto();
        defer t.allocator.destroy(f.validator);
        try t.expectError(error.InvalidEvidence, f.validator.planHorizon(control, 64, lead, budget, 128 + lead + budget));
        try t.expectError(error.InvalidEvidence, f.validator.planHorizon(control, 64, lead + 1, budget, 65 + lead + budget));
        try t.expectError(error.InvalidEvidence, f.validator.planHorizon(control, 64, lead, budget + 1, 65 + lead + budget));
        try t.expectError(error.InvalidEvidence, f.validator.horizonEnd(render_key, 0, 64));
        try t.expectError(error.InvalidEvidence, f.validator.horizonBegin(render_key, 0, 64));
        try f.validator.horizonBegin(render_key, 0, 0);
        try t.expectError(error.InvalidEvidence, f.validator.horizonBegin(render_key, 1, 0));
        try t.expectError(error.InvalidEvidence, f.validator.horizonEnd(render_key, 0, 0));
        try f.validator.horizonEnd(render_key, 0, 64);
        try t.expectError(error.InvalidEvidence, f.validator.horizonEnd(render_key, 1, 128));
        try t.expectError(error.InvalidEvidence, f.validator.horizonBegin(render_key, 1, 0));
        try t.expectError(error.InvalidEvidence, f.validator.commit_horizons.close(&f.validator.dependencies, 128));
    }
}

pub fn testJobReadComparators() !void {
    if (!@import("builtin").is_test) @compileError("test-only job read comparator regression");
    const t = std.testing;
    const Log = struct {
        values: [2]Check = undefined,
        count: usize = 0,
        fn emit(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.count == self.values.len) return error.DependencyCapacity;
            self.values[self.count] = value;
            self.count += 1;
        }
    };
    var log: Log = .{};
    const value = try t.allocator.create(Validator);
    defer t.allocator.destroy(value);
    value.dependencies = try Dependencies.init(8, 4096, null);
    try value.job_cuts.initInto(8);
    value.check_sink = .{ .context = &log, .emit = Log.emit };
    value.checks = 0;
    for (&value.jobs) |*job| job.* = .{};
    for (&value.bindings) |*entry| entry.* = null;
    const key: format.OperationKey = .{ .role = .control, .ordinal = 2 };
    value.bindings[0] = .{ .key = key, .serial = 1, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 1, .frontier_tick_serial = 1 } } };
    const query: format.readiness.observation.QueryKey = .{ .handle = .{ .index = 0, .generation = 1 }, .attempt_ordinal = 1 };
    var read: format.readiness.observation.QueryRead = .{};
    read.scanned = 1;
    try value.readinessReads(key, query, read, 10);
    try value.readinessReads(key, query, read, 10);
    try t.expectEqual(@as(usize, 1), value.dependencies.pending_total);
    try t.expectEqual(@as(usize, 2), log.count);
    for (log.values, 0..) |check, index| {
        try t.expectEqual(Site.readiness_job, check.point.site);
        try t.expectEqual(@as(u32, @intCast(index + 1)), check.point.occurrence);
        try t.expectEqual(@as(u64, @intFromEnum(read.state(0))), check.value);
    }
}

pub fn testGlobalObservationComparators() !void {
    if (!@import("builtin").is_test) @compileError("test-only global observation extraction");
    const t = std.testing;
    const Log = struct {
        values: [9]Check = undefined,
        count: usize = 0,
        fn emit(raw: *anyopaque, value: Check) error{DependencyCapacity}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.count == self.values.len) return error.DependencyCapacity;
            self.values[self.count] = value;
            self.count += 1;
        }
    };
    const validator = try t.allocator.create(Validator);
    defer t.allocator.destroy(validator);
    // Isolated production extractors, not an engine or complete-tape proof.
    validator.dependencies = try Dependencies.init(8, 4096, null);
    try validator.observation_sequences.initInto(0, 8);
    try validator.observation_frames.initInto(0, 8);
    for (&validator.bindings) |*entry| entry.* = null;
    var log: Log = .{};
    validator.check_sink = .{ .context = &log, .emit = Log.emit };
    validator.checks = 0;
    const first: format.OperationKey = .{ .role = .control, .ordinal = 1 };
    const second: format.OperationKey = .{ .role = .control, .ordinal = 2 };
    validator.bindings[0] = .{ .key = first, .serial = 1, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 1, .frontier_tick_serial = 1 } } };
    validator.bindings[1] = .{ .key = second, .serial = 2, .args = .{ .tick = 1 }, .result = .{ .ticked = .{ .processed = 0, .control_tick = 2, .frontier_tick_serial = 2 } } };
    try validator.observation_sequences.publish(&validator.dependencies, 2, .{ .role = .render, .operation = 1, .site = .render_sequence_even, .occurrence = 1, .edge = .after });
    try validator.observation_frames.publish(&validator.dependencies, 32, .{ .role = .render, .operation = 1, .site = .stream_observation_frame, .occurrence = 1, .edge = .after });
    const available: stream.observation.Availability = .{ .attached = true, .sequence_before = 2, .frame = 32, .sequence_after = 2 };
    try validator.availabilityReads(first, .{ .index = 0, .generation = 7 }, available, .acceptance);
    try validator.availabilityReads(first, .{ .index = 1, .generation = 8 }, available, .readiness);
    try t.expectEqual(@as(usize, 6), validator.dependencies.pending_total);
    var query: format.readiness.observation.QueryRead = .{ .sequence_before = 2, .frame = 32, .sequence_after = 2 };
    inline for (.{ .sequence_before, .observation_frame, .sequence_after }) |site| query.saw(site);
    try validator.readinessReads(second, .{ .handle = .{ .index = 2, .generation = 9 } }, query, null);
    try t.expectEqual(@as(usize, 3), validator.dependencies.pending_total);
    try t.expectEqual(@as(usize, 6), validator.dependencies.high_water);
    try t.expectEqual(@as(u64, 9), validator.dependencies.emitted);
    try t.expectEqual(@as(u64, 9), validator.checks);
    try t.expectEqual(@as(usize, 9), log.count);
    const sites = [_]Site{
        .availability_acceptance_sequence_before, .availability_acceptance_frame, .availability_acceptance_sequence_after,
        .availability_readiness_sequence_before,  .availability_readiness_frame,  .availability_readiness_sequence_after,
        .readiness_sequence,                      .readiness_frame,               .readiness_final_sequence,
    };
    for (log.values, sites, 0..) |actual, site, i| {
        const group = i / 3;
        try t.expectEqualDeep(Check{ .point = .{
            .role = .control,
            .operation = if (group == 2) 2 else 1,
            .site = site,
            .index = if (group == 1) 1 else 0,
            .generation = if (group == 2) 0 else 7 + group,
            .occurrence = 1,
            .edge = .after,
        }, .value = if (i % 3 == 1) 32 else 2 }, actual);
    }
}
