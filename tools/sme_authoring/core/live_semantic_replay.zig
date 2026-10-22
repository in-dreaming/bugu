//! Finite profile-9 fresh-process driver. The native Host, Worker, decoder,
//! planner, scheduler, renderer and destruction retain exclusive custody.
//! Only offline threads wait here. Forward hook occurrence order is evidence,
//! not proof of overlapping atomic order: the first different real observation
//! rejects the run; no expected result is installed or tried as an alternative.
const std = @import("std");
const audio = @import("bugu_audio");
pub const host = @import("live_owner.zig");
pub const codec = @import("live_semantic_codec.zig");
pub const format = codec.format;
pub const mailbox_schedule = @import("live_semantic_mailbox_schedule.zig");
pub const exclusion_schedule = @import("live_semantic_exclusion_schedule.zig");
const semantic = codec.semantic;
const cuts = codec.cuts;
const stream = codec.stream;
const source = codec.source;
pub const Error = codec.Error || error{ InvalidState, ReplayMismatch, ReplayTimeout, UnsupportedScope };
pub const Failure = struct {
    reason: anyerror,
    role: format.Role,
    occurrence: u64,
    family: ?codec.Family = null,
    byte_offset: ?usize = null,
    expected_family: ?codec.Family = null,
    expected_tag: ?u16 = null,
    actual_tag: ?u16 = null,
};
pub const Report = struct {
    matched: [format.role_count]u64 = @splat(0),
    input_events: [format.role_count]u64 = @splat(0),
    pcm_samples: [3]u64 = .{ 0, 0, 0 },
    ui_calls: u64 = 0,
    command_submitted: u64 = 0,
    command_accepted: u64 = 0,
    command_terminal: u64 = 0,
    terminal_acknowledged: u64 = 0,
    host_joined: bool = false,
    host_destroyed: bool = false,
    eof: bool = false,
    final_status: ?host.Status = null,
};
/// This component alone receives comparison cursors. It has no return channel
/// except equality/failure and never supplies a value to native execution.
const Comparison = struct {
    cursor: codec.ComparisonCursor,
    scratch: [format.max_payload]u8 = undefined,
    matched: u64 = 0,
    fn compare(self: *Comparison, family: codec.Family, actual: []const u8) !?usize {
        const expected = try self.cursor.next() orelse return error.Incomplete;
        if (expected.family != @intFromEnum(family)) return error.ReplayMismatch;
        const n = @min(actual.len, expected.bytes.len);
        for (actual[0..n], expected.bytes[0..n], 0..) |a, b, i| if (a != b) return i;
        if (actual.len != expected.bytes.len) return n;
        self.matched += 1;
        return null;
    }
    fn value(self: *Comparison, role: format.Role, family: codec.Family, occurrence: u64, value_: anytype) !?usize {
        const native: codec.Native(@TypeOf(value_)) = .{ .occurrence = occurrence, .value = value_ };
        if (@TypeOf(value_) == codec.Acceptance) {
            // Replay observes the full actual native value, not a Recorder
            // queue payload. Only the queue adapter accepts CompactAcceptance.
            if (role != .control or family != .acceptance) return error.UnsupportedValue;
            if (occurrence == 0) return error.InvalidOrder;
            if (!value_.attempt.evidence.representation_complete) return error.Incomplete;
            return self.compare(family, try codec.encode(native, .reference, &self.scratch));
        }
        const bytes = std.mem.asBytes(&native);
        const record: format.NativeRecord = .{ .role = role, .ordinal = 0, .family = @intFromEnum(family), .class = .reference, .bytes = bytes, .first_len = bytes.len };
        return self.compare(family, try codec.encodeNative(record, &self.scratch));
    }
    fn pcm(self: *Comparison, occurrence: u64, value_: @FieldType(audio.device.SemanticAudioEvent, "pcm")) !?usize {
        const header: codec.Native(codec.Pcm) = .{ .occurrence = occurrence, .value = .{
            .disposition = value_.disposition,
            .device_epoch = value_.device_epoch,
            .first_frame = value_.first_frame,
            .channels = value_.channels,
            .samples = std.math.cast(u32, value_.samples.len) orelse return error.InvalidLength,
        } };
        var e: codec.Encoder = .{ .wire = .{ .bytes = &self.scratch }, .class = .reference };
        try e.put(header);
        for (value_.samples) |sample| try e.wire.f32Bits(@bitCast(sample));
        return self.compare(.pcm, e.result());
    }
};
const Lane = struct {
    input: codec.InputCursor,
    input_scratch: [format.max_payload]u8 = undefined,
    comparison: Comparison,
    events: u64 = 0,
};
const max_consumed_reads = 65536;
const max_stream_slots = 64;
const ConsumedRead = struct { before: u64, after: u64, index: u64, generation: u64, prefix: u64 };
const ConsumedProgress = struct {
    generation: std.atomic.Value(u64) = .init(0),
    prefix: std.atomic.Value(u64) = .init(0),
};
const UiProgress = enum { idle, progressed, exhausted };

pub const Driver = struct {
    address: ?*Driver = null,
    io: std.Io = undefined,
    identity: format.Identity = undefined,
    launch_descriptor: codec.LaunchDescriptor = undefined,
    started_at: @TypeOf(std.Io.Clock.awake.now(@as(std.Io, undefined))) = undefined,
    lanes: [format.role_count]Lane = undefined,
    session: semantic.Session = .{},
    clock: cuts.OfflineClock = .{},
    publication_calendar: mailbox_schedule.Scheduler = .{},
    exclusion_calendar: exclusion_schedule.Scheduler = .{},
    turn: std.atomic.Value(u64) = .init(1),
    failed: std.atomic.Value(bool) = .init(false),
    failure_claimed: std.atomic.Value(bool) = .init(false),
    failure_value: ?Failure = null,
    clock_pending: ?codec.Native(codec.RawClock) = null, // Worker-only
    report: Report = .{},
    // UI-owned native cleanup evidence, never populated from references. A
    // mismatch after terminal pop must not strand its already-consumed credit.
    actual_ui: ?codec.UiInvocation = null,
    terminal_pending: [host.mailbox.command_capacity]?u64 = @splat(null),
    // Immutable, finite observed publication-coordinate calendar. No reference
    // cursor contributes to this scheduling input. Only real Ring.consume
    // stores advance progress; the driver never assigns an engine counter.
    consumed_reads: [max_consumed_reads]ConsumedRead = undefined,
    consumed_read_count: usize = 0,
    consumed_retired: std.atomic.Value(usize) = .init(0),
    consumed_active: ?usize = null, // Control-owned actual load in progress
    consumed_progress: [max_stream_slots]ConsumedProgress = .{ConsumedProgress{}} ** max_stream_slots,
    consumed_render_next: [max_stream_slots]usize = @splat(0), // Render-owned

    running: bool = false,
    completed: bool = false,

    /// Caller supplies an immutable, same-build/source-verified format Reader.
    /// Its bytes and this pinned final storage outlive the genuine Host joins.
    pub fn init(self: *Driver, reader: *const format.Reader, identity: format.Identity, io: std.Io) !void {
        return self.initWithPolicy(reader, identity, io, .native_attempt);
    }
    /// Policy is caller-selected admission, not a tape field or permission to
    /// change execution. Complete preflight precedes Session/native owner setup.
    pub fn initWithPolicy(self: *Driver, reader: *const format.Reader, identity: format.Identity, io: std.Io, policy: codec.AdmissionPolicy) !void {
        if (self.address != null) return error.InvalidState;
        _ = try codec.validateInputsWithPolicy(reader, identity, policy);
        self.io = io;
        self.identity = identity;
        self.launch_descriptor = try codec.readLaunchDescriptor(reader);
        inline for (std.meta.fields(format.Role)) |field| {
            const role: format.Role = @enumFromInt(field.value);
            self.lanes[field.value] = .{ .input = codec.InputCursor.init(reader, role), .comparison = .{ .cursor = codec.ComparisonCursor.init(reader, role) } };
        }
        try self.initConsumedReads(reader);
        try self.initPublicationCalendar(reader);
        try self.initExclusionCalendar(reader);
        self.address = self;
        try self.clock.init(self, onClock);
        try self.session.initReplay(self.config(self.launch_descriptor.pacing));
    }
    fn config(self: *Driver, pacing: semantic.PacingMode) semantic.Config {
        return .{
            .pacing = pacing,
            .output = .{ .context = self, .input = onInput, .schedule = onSchedule, .invalidate = invalidate },
            .service = .{ .cuts = .{ .context = self, .point = onPoint, .boundary = onBoundary }, .worker_facts = .{ .context = self, .emit = onWorkerFact }, .source = .{ .context = self, .emit = onSourceFact }, .clock = &self.clock, .consume = .{ .context = self, .checkpoint = onConsumed } },
            .audio = .{ .context = self, .call = onAudio, .wait_callback = awaitCallback },
            .acceptance = .{ .context = self, .emit = onAcceptance, .frontier = onFrontier, .event = onTick, .input = null },
            .source = .{ .context = self, .emit = onSource },
            .control = .{ .context = self, .emit = onControl },
            .worker = .{ .context = self, .emit = onWorker },
            .ui = .{ .context = self, .emit = onUi },
            .mailbox = .{ .context = self, .call = onMailbox },
            .worker_gate = .{ .context = self, .call = onWorkerGate },
            .context = self,
            .invalidate = invalidate,
        };
    }
    fn from(raw: *anyopaque) *Driver {
        return @ptrCast(@alignCast(raw));
    }
    fn lane(self: *Driver, role: format.Role) *Lane {
        return &self.lanes[@intFromEnum(role)];
    }
    fn invalidate(raw: *anyopaque) void {
        const self = from(raw);
        self.failed.store(true, .release);
        self.publication_calendar.abort();
        self.exclusion_calendar.abort();
        self.clock.abort();
        // Session.poison is idempotent: this path may be reached either from a
        // native invalidation or as the callback of our own failure poisoning.
        self.session.poison();
    }
    fn fail(self: *Driver, value: Failure) void {
        if (!self.failure_claimed.swap(true, .acq_rel)) self.failure_value = value;
        self.publication_calendar.abort();
        self.exclusion_calendar.abort();
        self.session.poison(); // aborts raw clock before releasing all waiters
        self.failed.store(true, .release);
    }
    fn wait(self: *Driver) void {
        if (!self.failed.load(.acquire) and self.started_at.durationTo(std.Io.Clock.awake.now(self.io)).nanoseconds > 60 * std.time.ns_per_s)
            self.fail(.{ .reason = error.ReplayTimeout, .role = .control, .occurrence = self.turn.load(.acquire) });
        std.Io.sleep(self.io, .fromNanoseconds(10_000), .awake) catch {};
    }
    fn enter(self: *Driver, role: format.Role, family: codec.Family, tag: u16) ?u64 {
        if (self.failed.load(.acquire)) return null;
        const record = self.lane(role).input.next() catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = 0, .family = family });
            return null;
        };
        const marker = codec.decodeInput(codec.EventCut, record orelse {
            self.fail(.{ .reason = error.Incomplete, .role = role, .occurrence = 0, .family = family });
            return null;
        }, .event_cut) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = 0, .family = family });
            return null;
        };
        if (marker.value.family != family or marker.value.tag != tag) {
            self.fail(.{ .reason = error.ReplayMismatch, .role = role, .occurrence = marker.occurrence, .family = family, .expected_family = marker.value.family, .expected_tag = marker.value.tag, .actual_tag = tag });
            return null;
        }
        while (!self.failed.load(.acquire)) {
            const turn = self.turn.load(.acquire);
            if (turn == marker.occurrence) {
                self.lane(role).events += 1;
                return turn;
            }
            if (turn > marker.occurrence) {
                self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = marker.occurrence, .family = family });
                return null;
            }
            self.wait();
        }
        return null;
    }
    fn leave(self: *Driver, occurrence: u64) void {
        if (self.failed.load(.acquire)) return;
        if (occurrence == std.math.maxInt(u64) or self.turn.cmpxchgStrong(occurrence, occurrence + 1, .release, .monotonic) != null)
            self.fail(.{ .reason = error.InvalidOrder, .role = .control, .occurrence = occurrence });
    }
    fn input(self: *Driver, role: format.Role, family: codec.Family, occurrence: u64, comptime T: type) ?T {
        const record = self.lane(role).input.next() catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = family });
            return null;
        };
        const value = codec.decodeInput(T, record orelse {
            self.fail(.{ .reason = error.Incomplete, .role = role, .occurrence = occurrence, .family = family });
            return null;
        }, family) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = family });
            return null;
        };
        if (value.occurrence != occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = occurrence, .family = family });
            return null;
        }
        return value.value;
    }
    fn checkInput(self: *Driver, role: format.Role, family: codec.Family, occurrence: u64, actual: anytype) bool {
        const lane_ = self.lane(role);
        const record = (lane_.input.next() catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = family });
            return false;
        }) orelse {
            self.fail(.{ .reason = error.Incomplete, .role = role, .occurrence = occurrence, .family = family });
            return false;
        };
        const expected = codec.decodeInput(@TypeOf(actual), record, family) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = family });
            return false;
        };
        if (expected.occurrence != occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = occurrence, .family = family });
            return false;
        }
        // Canonical input bytes deliberately ignore empty-slice addresses and
        // native padding. std.meta.eql would compare configuration slice PTRs.
        const native: codec.Native(@TypeOf(actual)) = .{ .occurrence = occurrence, .value = actual };
        const bytes = codec.encode(native, .input, &lane_.input_scratch) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = family });
            return false;
        };
        if (!std.mem.eql(u8, bytes, record.bytes)) {
            self.fail(.{ .reason = error.ReplayMismatch, .role = role, .occurrence = occurrence, .family = family });
            return false;
        }
        return true;
    }
    fn compare(self: *Driver, role: format.Role, family: codec.Family, occurrence: u64, actual: anytype) void {
        if (self.failed.load(.acquire)) return;
        const offset = self.lane(role).comparison.value(role, family, occurrence, actual) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = family });
            return;
        };
        if (offset) |i| self.fail(.{ .reason = error.ReplayMismatch, .role = role, .occurrence = occurrence, .family = family, .byte_offset = i });
    }
    fn observe(self: *Driver, role: format.Role, family: codec.Family, actual: anytype) void {
        const occurrence = self.enter(role, family, codec.eventTag(actual)) orelse return;
        defer self.leave(occurrence);
        self.compare(role, family, occurrence, actual);
    }
    fn mailboxSlot(value: codec.mailbox.RingCheckpoint) mailbox_schedule.Slot {
        return switch (value.queue) {
            .commands => if (value.counter == .written) .commands_written else .commands_read,
            .events => if (value.counter == .written) .events_written else .events_read,
        };
    }
    fn mailboxRole(value: anytype) format.Role {
        const actor = switch (value) {
            .ring => |v| v.role,
            .admission => |v| v.role,
        };
        return if (actor == .ui) .ui else .control;
    }
    fn mailboxEdge(value: anytype) codec.mailbox.Edge {
        return switch (value) {
            .ring => |v| v.edge,
            .admission => |v| v.edge,
        };
    }
    /// Build a bounded availability calendar solely from authenticated execution
    /// inputs. References never supply a target prefix or publication plan.
    fn initPublicationCalendar(self: *Driver, reader: *const format.Reader) !void {
        try self.publication_calendar.init(mailbox_schedule.hard_read_cap);
        inline for (.{ format.Role.control, format.Role.ui }) |role| {
            var cursor = codec.InputCursor.init(reader, role);
            var pending: ?codec.Native(codec.MailboxCut) = null;
            while (try cursor.next()) |record| {
                if (record.family != @intFromEnum(codec.Family.mailbox_cut)) continue;
                const cut = try codec.decodeInput(codec.MailboxCut, record, .mailbox_cut);
                try codec.validateMailboxCut(cut.value);
                if (mailboxRole(cut.value) != role) return error.InvalidOrder;
                if (mailboxEdge(cut.value) == .before) {
                    if (pending != null) return error.InvalidOrder;
                    pending = cut;
                    continue;
                }
                const before = pending orelse return error.InvalidOrder;
                if (cut.occurrence <= before.occurrence or std.meta.activeTag(before.value) != std.meta.activeTag(cut.value)) return error.InvalidOrder;
                switch (cut.value) {
                    .ring => |v| {
                        const prior = before.value.ring;
                        if (prior.role != v.role or prior.queue != v.queue or prior.counter != v.counter or prior.operation != v.operation or
                            prior.access != v.access or prior.local_prefix != v.local_prefix) return error.InvalidOrder;
                        const prefix = v.prefix orelse return error.InvalidOrder;
                        if (v.access == .acquire) {
                            if (prior.prefix != null) return error.InvalidOrder;
                            try self.publication_calendar.addRead(mailboxSlot(v), before.occurrence, cut.occurrence, @intCast(prefix));
                        } else {
                            if (prior.prefix != v.prefix) return error.InvalidOrder;
                            try self.publication_calendar.addPublication(mailboxSlot(v), before.occurrence, cut.occurrence, @intCast(prefix));
                        }
                    },
                    .admission => |v| {
                        const prior = before.value.admission;
                        if (prior.role != v.role or prior.operation != v.operation or prior.closed != null) return error.InvalidOrder;
                        const closed = v.closed orelse return error.InvalidOrder;
                        if (v.operation == .request_close) {
                            if (!closed or v.role != .ui) return error.UnsupportedScope;
                            try self.publication_calendar.addPublication(.closed, before.occurrence, cut.occurrence, 1);
                        } else try self.publication_calendar.addRead(.closed, before.occurrence, cut.occurrence, @intFromBool(closed));
                    },
                }
                pending = null;
            }
            if (pending != null) return error.Incomplete;
        }
        try self.initServiceSequenceCalendar(reader);
        try self.initWorkerGateCalendar(reader);
        try self.initRuntimePublicationCalendar(reader);
        try self.publication_calendar.seal();
    }
    fn runtimePublicationSlot(domain: codec.RuntimePublicationDomain) mailbox_schedule.Slot {
        return switch (domain) {
            .frame => .runtime_frame,
            .commit_horizon => .runtime_commit_horizon,
        };
    }
    /// These two counters belong to one Runtime for the complete Host lifetime.
    /// Prefixes are actual sparse frame values, not publication ordinals or a
    /// fixed span size. Only the closed existing load/store sites participate.
    fn initRuntimePublicationCalendar(self: *Driver, reader: *const format.Reader) !void {
        inline for (.{ format.Role.control, format.Role.render }) |role| {
            var cursor = codec.InputCursor.init(reader, role);
            var pending: ?codec.Native(codec.Cut) = null;
            while (try cursor.next()) |record| {
                if (record.family != @intFromEnum(codec.Family.cut)) continue;
                const point = try codec.decodeInput(codec.Cut, record, .cut);
                const domain = (if (role == .control) codec.runtimePublicationRead(point.value.site) else codec.runtimePublicationStore(point.value.site)) orelse continue;
                if (point.value.role != role) return error.InvalidOrder;
                if (point.value.edge == .before) {
                    if (pending != null) return error.InvalidOrder;
                    pending = point;
                    continue;
                }
                const before = pending orelse return error.InvalidOrder;
                if (before.occurrence >= point.occurrence or before.value.site != point.value.site or
                    before.value.index != point.value.index or before.value.generation != point.value.generation) return error.InvalidOrder;
                const slot = runtimePublicationSlot(domain);
                if (role == .control) {
                    try self.publication_calendar.addRead(slot, before.occurrence, point.occurrence, point.value.publication_prefix);
                } else {
                    try self.publication_calendar.addPublication(slot, before.occurrence, point.occurrence, point.value.publication_prefix);
                }
                pending = null;
            }
            if (pending != null) return error.Incomplete;
        }
    }
    fn workerGateSlot(counter: codec.mailbox.GateCounter) mailbox_schedule.Slot {
        return switch (counter) {
            .request => .gate_request,
            .acknowledgment => .gate_ack,
            .resumed => .gate_resumed,
            .progress => .gate_progress,
            .stopped => .gate_stopped,
        };
    }
    /// One Host owns one WorkerGate for its lifetime. Inputs establish a finite
    /// publication calendar; references remain equality-only actual evidence.
    fn initWorkerGateCalendar(self: *Driver, reader: *const format.Reader) !void {
        var epoch: ?u64 = null;
        inline for (.{ format.Role.control, format.Role.worker }) |role| {
            var cursor = codec.InputCursor.init(reader, role);
            var pending: ?codec.Native(codec.WorkerGateCut) = null;
            while (try cursor.next()) |record| {
                if (record.family != @intFromEnum(codec.Family.worker_gate_cut)) continue;
                const cut = try codec.decodeInput(codec.WorkerGateCut, record, .worker_gate_cut);
                const value = cut.value;
                if (codec.workerGateRole(value.role) != role) return error.InvalidOrder;
                if (epoch) |known| {
                    if (value.epoch != known) return error.InvalidOrder;
                } else epoch = value.epoch;
                if (value.edge == .before) {
                    if (pending != null) return error.InvalidOrder;
                    pending = cut;
                    continue;
                }
                const before = pending orelse return error.InvalidOrder;
                const prior = before.value;
                if (before.occurrence >= cut.occurrence or prior.role != value.role or
                    prior.counter != value.counter or prior.access != value.access or prior.epoch != value.epoch) return error.InvalidOrder;
                const prefix = value.prefix orelse return error.InvalidOrder;
                if (value.access == .acquire) {
                    if (prior.prefix != null) return error.InvalidOrder;
                    try self.publication_calendar.addRead(workerGateSlot(value.counter), before.occurrence, cut.occurrence, prefix);
                } else {
                    if (prior.prefix != value.prefix) return error.InvalidOrder;
                    try self.publication_calendar.addPublication(workerGateSlot(value.counter), before.occurrence, cut.occurrence, prefix);
                }
                pending = null;
            }
            if (pending != null) return error.Incomplete;
        }
    }
    /// One Service owns this monotonic sequence for its whole lifetime. Stream
    /// index/generation identify each native bracket, never separate counters.
    fn initServiceSequenceCalendar(self: *Driver, reader: *const format.Reader) !void {
        inline for (.{ format.Role.control, format.Role.render }) |role| {
            var cursor = codec.InputCursor.init(reader, role);
            var pending: ?codec.Native(codec.Cut) = null;
            while (try cursor.next()) |record| {
                if (record.family != @intFromEnum(codec.Family.cut)) continue;
                const point = try codec.decodeInput(codec.Cut, record, .cut);
                const relevant = if (role == .control) codec.serviceSequenceRead(point.value.site) else codec.serviceSequencePublication(point.value.site);
                if (!relevant) continue;
                if (point.value.role != role) return error.InvalidOrder;
                if (point.value.edge == .before) {
                    if (pending != null) return error.InvalidOrder;
                    pending = point;
                    continue;
                }
                const before = pending orelse return error.InvalidOrder;
                if (before.occurrence >= point.occurrence or before.value.site != point.value.site or
                    before.value.index != point.value.index or before.value.generation != point.value.generation) return error.InvalidOrder;
                if (role == .control) {
                    try self.publication_calendar.addRead(.service_sequence, before.occurrence, point.occurrence, point.value.publication_prefix);
                } else {
                    try self.publication_calendar.addPublication(.service_sequence, before.occurrence, point.occurrence, point.value.publication_prefix);
                }
                pending = null;
            }
            if (pending != null) return error.Incomplete;
        }
    }
    fn onMailbox(raw: *anyopaque, value: codec.mailbox.Checkpoint) void {
        const self = from(raw);
        if (self.failed.load(.acquire)) return;
        const role = mailboxRole(value);
        const edge = mailboxEdge(value);
        codec.validateMailboxCheckpoint(value) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .mailbox_event });
            return;
        };
        var expected_after: ?u64 = null;
        // These transitions witness operations which ALREADY happened. Retire a
        // load/update actual publication progress before waiting on its marker,
        // so an intervening other-role marker cannot deadlock this native seam.
        if (edge == .after) switch (value) {
            .ring => |v| if (v.access == .acquire) {
                expected_after = self.publication_calendar.acquired(mailboxSlot(v), @intCast(v.prefix.?)) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .mailbox_event });
                    return;
                };
            } else {
                self.publication_calendar.published(mailboxSlot(v), @intCast(v.prefix.?)) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .mailbox_event });
                    return;
                };
            },
            .admission => |v| if (v.operation == .request_close) {
                self.publication_calendar.published(.closed, @intFromBool(v.value.? & 2 != 0)) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .mailbox_event });
                    return;
                };
            } else {
                expected_after = self.publication_calendar.acquired(.closed, @intFromBool(v.value.? & 2 != 0)) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .mailbox_event });
                    return;
                };
            },
        };
        const occurrence = self.enter(role, .mailbox_event, codec.eventTag(value)) orelse return;
        if (expected_after) |expected| if (expected != occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = occurrence, .family = .mailbox_event });
            return;
        };
        if (!self.checkInput(role, .mailbox_cut, occurrence, codec.mailboxCut(value))) return;
        self.compare(role, .mailbox_event, occurrence, value);
        self.leave(occurrence);
        if (edge == .after) return;
        // Before an original native load/store, release the global turn first.
        // Wait only on scheduler progress produced by real after-store hooks.
        while (!self.failed.load(.acquire)) {
            const ready = switch (value) {
                .ring => |v| if (v.access == .acquire)
                    self.publication_calendar.readReady(mailboxSlot(v), occurrence)
                else
                    self.publication_calendar.publicationReady(mailboxSlot(v), @intCast(v.prefix.?)),
                .admission => |v| if (v.operation == .request_close)
                    self.publication_calendar.publicationReady(.closed, 1)
                else
                    self.publication_calendar.readReady(.closed, occurrence),
            } catch |err| {
                self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = .mailbox_event });
                return;
            };
            if (ready) return;
            self.wait();
        }
    }
    fn onWorkerGate(raw: *anyopaque, value: codec.mailbox.WorkerGateCheckpoint) void {
        const self = from(raw);
        if (self.failed.load(.acquire)) return;
        const role = codec.workerGateRole(value.role);
        codec.validateWorkerGateCheckpoint(value) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .worker_gate_event });
            return;
        };
        const slot = workerGateSlot(value.counter);
        var expected_after: ?u64 = null;
        // The real atomic already completed. Retire its acquired prefix or
        // publish its actual progress before waiting on the AFTER marker.
        if (value.edge == .after) {
            if (value.access == .acquire) {
                expected_after = self.publication_calendar.acquired(slot, value.prefix.?) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .worker_gate_event });
                    return;
                };
            } else self.publication_calendar.published(slot, value.prefix.?) catch |err| {
                self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .worker_gate_event });
                return;
            };
        }
        const occurrence = self.enter(role, .worker_gate_event, codec.eventTag(value)) orelse return;
        if (expected_after) |expected| if (expected != occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = occurrence, .family = .worker_gate_event });
            return;
        };
        if (!self.checkInput(role, .worker_gate_cut, occurrence, codec.workerGateCut(value))) return;
        self.compare(role, .worker_gate_event, occurrence, value);
        self.leave(occurrence);
        if (value.edge == .after) return;
        // Release the global BEFORE turn before waiting for the other actor.
        // A recorded target only gates the original load/store; it never sets
        // any engine gate counter or supplies a recorded return value.
        while (!self.failed.load(.acquire)) {
            const ready = (if (value.access == .acquire)
                self.publication_calendar.readReady(slot, occurrence)
            else
                self.publication_calendar.publicationReady(slot, value.prefix.?)) catch |err| {
                self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = .worker_gate_event });
                return;
            };
            if (ready) return;
            self.wait();
        }
    }
    fn exclusionRole(role: format.Role) exclusion_schedule.Role {
        return if (role == .control) .control else .worker;
    }
    fn nextExclusionOperation(cursor: *codec.InputCursor, role: format.Role) !?exclusion_schedule.Operation {
        var before: ?codec.Native(codec.Cut) = null;
        while (try cursor.next()) |record| {
            if (record.family != @intFromEnum(codec.Family.cut)) continue;
            const point = try codec.decodeInput(codec.Cut, record, .cut);
            const claim = codec.exclusionClaim(role, point.value.site);
            const release = codec.exclusionRelease(role, point.value.site);
            if (!claim and !release) continue;
            if (point.value.role != role) return error.InvalidOrder;
            if (point.value.edge == .before) {
                if (before != null) return error.InvalidOrder;
                before = point;
                continue;
            }
            const start = before orelse return error.InvalidOrder;
            if (start.occurrence >= point.occurrence or start.value.site != point.value.site or
                start.value.index != point.value.index or start.value.generation != point.value.generation) return error.InvalidOrder;
            var success: ?bool = null;
            if (claim) {
                const claim_input = try cursor.next() orelse return error.Incomplete;
                const result = try codec.decodeInput(bool, claim_input, .exclusion_claim);
                if (result.occurrence != point.occurrence) return error.InvalidOrder;
                success = result.value;
            }
            return .{ .role = exclusionRole(role), .kind = if (claim) .claim else .release, .before = start.occurrence, .after = point.occurrence, .site = @intFromEnum(point.value.site), .index = point.value.index, .generation = point.value.generation, .success = success };
        }
        if (before != null) return error.Incomplete;
        return null;
    }
    /// Two original actors share one worker_busy exclusion word. The planner
    /// receives only INPUT brackets/claim coordinates, globally AFTER-sorted
    /// for collection; seal derives a feasible atomic order within brackets.
    fn initExclusionCalendar(self: *Driver, reader: *const format.Reader) !void {
        try self.exclusion_calendar.init(65536);
        var cursors = [_]codec.InputCursor{ codec.InputCursor.init(reader, .control), codec.InputCursor.init(reader, .worker) };
        var heads = [_]?exclusion_schedule.Operation{ try nextExclusionOperation(&cursors[0], .control), try nextExclusionOperation(&cursors[1], .worker) };
        while (heads[0] != null or heads[1] != null) {
            const index: usize = if (heads[0] == null) 1 else if (heads[1] == null or heads[0].?.after < heads[1].?.after) 0 else 1;
            if (heads[0] != null and heads[1] != null and heads[0].?.after == heads[1].?.after) return error.InvalidOrder;
            try self.exclusion_calendar.add(heads[index].?);
            heads[index] = try nextExclusionOperation(&cursors[index], if (index == 0) .control else .worker);
        }
        try self.exclusion_calendar.seal();
    }
    /// Read the next execution marker without waiting or consuming it. Used
    /// only to retire an already completed native operation before its stamp.
    fn pointAfterOccurrence(self: *Driver, role: format.Role) ?u64 {
        var cursor = self.lane(role).input;
        const record = (cursor.next() catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = 0, .family = .cut_fact });
            return null;
        }) orelse {
            self.fail(.{ .reason = error.Incomplete, .role = role, .occurrence = 0, .family = .cut_fact });
            return null;
        };
        const marker = codec.decodeInput(codec.EventCut, record, .event_cut) catch |err| {
            self.fail(.{ .reason = err, .role = role, .occurrence = 0, .family = .cut_fact });
            return null;
        };
        if (marker.value.family != .cut_fact or marker.value.tag != 0) {
            self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = marker.occurrence, .family = .cut_fact });
            return null;
        }
        return marker.occurrence;
    }
    fn initConsumedReads(self: *Driver, reader: *const format.Reader) !void {
        var cursor = codec.InputCursor.init(reader, .control);
        var pending: ?codec.Native(codec.Cut) = null;
        var last_generation: [max_stream_slots]u64 = @splat(0);
        var last_prefix: [max_stream_slots]u64 = @splat(0);
        while (try cursor.next()) |record| {
            if (record.family != @intFromEnum(codec.Family.cut)) continue;
            const cut = try codec.decodeInput(codec.Cut, record, .cut);
            if (!codec.rawConsumedRead(cut.value.site)) continue;
            if (cut.value.index >= max_stream_slots or cut.value.generation == 0) return error.UnsupportedScope;
            const index: usize = @intCast(cut.value.index);
            if (cut.value.edge == .before) {
                if (pending != null) return error.InvalidOrder;
                pending = cut;
            } else {
                const before = pending orelse return error.InvalidOrder;
                if (before.value.site != cut.value.site or before.value.index != cut.value.index or before.value.generation != cut.value.generation or before.occurrence >= cut.occurrence) return error.InvalidOrder;
                if (self.consumed_read_count == max_consumed_reads) return error.UnsupportedScope;
                if (cut.value.generation < last_generation[index] or
                    (cut.value.generation == last_generation[index] and cut.value.publication_prefix < last_prefix[index])) return error.InvalidOrder;
                last_generation[index] = cut.value.generation;
                last_prefix[index] = cut.value.publication_prefix;
                self.consumed_reads[self.consumed_read_count] = .{ .before = before.occurrence, .after = cut.occurrence, .index = cut.value.index, .generation = cut.value.generation, .prefix = cut.value.publication_prefix };
                self.consumed_read_count += 1;
                pending = null;
            }
        }
        if (pending != null) return error.Incomplete;
    }
    fn waitConsumedRead(self: *Driver, point: cuts.Point, occurrence: u64) void {
        const n = self.consumed_retired.load(.acquire);
        if (self.consumed_active != null or n >= self.consumed_read_count) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .control, .occurrence = occurrence });
            return;
        }
        const cut = self.consumed_reads[n];
        if (cut.before != occurrence or cut.index != point.index or cut.generation != point.generation) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .control, .occurrence = occurrence });
            return;
        }
        self.consumed_active = n;
        if (cut.prefix == 0) return;
        const progress = &self.consumed_progress[@intCast(cut.index)];
        while (!self.failed.load(.acquire)) {
            const generation = progress.generation.load(.acquire);
            const actual = progress.prefix.load(.acquire);
            if (generation == cut.generation and actual == cut.prefix) return;
            if (generation > cut.generation or (generation == cut.generation and actual > cut.prefix)) {
                self.fail(.{ .reason = error.ReplayMismatch, .role = .control, .occurrence = occurrence, .family = .cut_fact });
                return;
            }
            self.wait();
        }
    }
    fn releaseConsumedRead(self: *Driver, point: cuts.Point) void {
        const n = self.consumed_active orelse {
            self.fail(.{ .reason = error.InvalidOrder, .role = .control, .occurrence = self.turn.load(.acquire) });
            return;
        };
        const cut = self.consumed_reads[n];
        if (point.index != cut.index or point.generation != cut.generation or point.value != cut.prefix) {
            self.fail(.{ .reason = error.ReplayMismatch, .role = .control, .occurrence = cut.after, .family = .cut_fact });
            return;
        }
        self.consumed_active = null;
        // The actual load has completed. Release before waiting on the after
        // hook occurrence: intervening Render markers may need to run first.
        self.consumed_retired.store(n + 1, .release);
    }
    fn onConsumed(raw: *anyopaque, point: stream.ConsumedCheckpoint) void {
        const self = from(raw);
        if (self.failed.load(.acquire)) return;
        if (point.site != .stream_consumed_release or point.index >= max_stream_slots or point.generation == 0) {
            self.fail(.{ .reason = error.UnsupportedScope, .role = .render, .occurrence = self.turn.load(.acquire) });
            return;
        }
        const index: usize = @intCast(point.index);
        const progress = &self.consumed_progress[index];
        if (point.edge == .after) {
            progress.prefix.store(point.value, .release);
            return;
        }
        if (progress.generation.load(.monotonic) != point.generation) {
            progress.prefix.store(0, .monotonic);
            progress.generation.store(point.generation, .release);
        }
        while (!self.failed.load(.acquire)) {
            var n = self.consumed_render_next[index];
            const retired = self.consumed_retired.load(.acquire);
            if (n < retired) n = retired;
            while (n < self.consumed_read_count and self.consumed_reads[n].index != point.index) : (n += 1) {}
            self.consumed_render_next[index] = n;
            if (n == self.consumed_read_count) return;
            const cut = self.consumed_reads[n];
            if (cut.generation > point.generation) return;
            if (cut.generation < point.generation) {
                self.fail(.{ .reason = error.InvalidOrder, .role = .render, .occurrence = cut.before });
                return;
            }
            if (point.value <= cut.prefix) return;
            self.wait();
        }
    }
    fn onPoint(raw: *anyopaque, value: cuts.Point) void {
        const self = from(raw);
        if (self.failed.load(.acquire)) return;
        const role = codec.wireRole(value.role);
        const sequence_read = role == .control and codec.serviceSequenceRead(value.site);
        const sequence_publication = role == .render and codec.serviceSequencePublication(value.site);
        const runtime_read = if (role == .control) codec.runtimePublicationRead(value.site) else null;
        const runtime_publication = if (role == .render) codec.runtimePublicationStore(value.site) else null;
        const busy_claim = codec.exclusionClaim(role, value.site);
        const busy_release = codec.exclusionRelease(role, value.site);
        var expected_after: ?u64 = null;
        if (value.edge == .after and (busy_claim or busy_release)) {
            const observed = value.value orelse {
                self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                return;
            };
            if (observed > (if (busy_claim) @as(u64, 1) else 0)) {
                self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                return;
            }
            expected_after = self.pointAfterOccurrence(role) orelse return;
            // The actual CAS/store already happened. Release this native handoff
            // before waiting for its later global marker, never with a recorded
            // result substituted into the original operation.
            self.exclusion_calendar.completed(exclusionRole(role), expected_after.?, if (busy_claim) observed == 0 else null) catch |err| {
                self.fail(.{ .reason = err, .role = role, .occurrence = expected_after.?, .family = .cut_fact });
                return;
            };
        }
        if (role == .control and codec.rawConsumedRead(value.site) and value.edge == .after) self.releaseConsumedRead(value);
        // AFTER means the original atomic already completed. Retire the real
        // acquired prefix or publish actual fetchAdd progress before waiting on
        // the later marker, otherwise a crossed hook can deadlock both actors.
        if (value.edge == .after and (sequence_read or sequence_publication)) {
            const actual_prefix = value.value orelse {
                self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                return;
            };
            if (sequence_read) {
                expected_after = self.publication_calendar.acquired(.service_sequence, actual_prefix) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                    return;
                };
            } else self.publication_calendar.published(.service_sequence, actual_prefix) catch |err| {
                self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                return;
            };
        }
        if (value.edge == .after) {
            if (runtime_read orelse runtime_publication) |domain| {
                const actual_prefix = value.value orelse {
                    self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                    return;
                };
                const slot = runtimePublicationSlot(domain);
                if (runtime_read != null) {
                    expected_after = self.publication_calendar.acquired(slot, actual_prefix) catch |err| {
                        self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                        return;
                    };
                } else self.publication_calendar.published(slot, actual_prefix) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = self.turn.load(.acquire), .family = .cut_fact });
                    return;
                };
            }
        }
        const occurrence = self.enter(role, .cut_fact, codec.eventTag(value)) orelse return;
        if (expected_after) |expected| if (expected != occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = occurrence, .family = .cut_fact });
            return;
        };
        const actual: codec.Cut = .{ .role = role, .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation, .publication_prefix = if (codec.publicationPrefixPoint(role, value.site, value.edge)) value.value orelse 0 else 0 };
        if (!self.checkInput(role, .cut, occurrence, actual)) return;
        if (busy_claim and value.edge == .after and !self.checkInput(role, .exclusion_claim, occurrence, value.value.? == 0)) return;
        self.compare(role, .cut_fact, occurrence, value);
        self.leave(occurrence);
        // Advance the global marker before waiting, so the opposite native
        // actor can reach the exact publication required by this actual load.
        if (role == .control and codec.rawConsumedRead(value.site) and value.edge == .before) self.waitConsumedRead(value, occurrence);
        if (value.edge == .before and (busy_claim or busy_release)) {
            while (!self.failed.load(.acquire)) {
                if (self.exclusion_calendar.ready(exclusionRole(role), occurrence) catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = .cut_fact });
                    return;
                }) return;
                self.wait();
            }
        }
        if (value.edge == .before and (sequence_read or sequence_publication)) {
            // This next prefix comes only from actual completed fetchAdds. It
            // is a wait condition, never an assignment to the engine sequence.
            const next = if (sequence_publication) std.math.add(u64, self.publication_calendar.observed(.service_sequence), 1) catch {
                self.fail(.{ .reason = error.CounterOverflow, .role = role, .occurrence = occurrence, .family = .cut_fact });
                return;
            } else 0;
            while (!self.failed.load(.acquire)) {
                const ready = if (sequence_read)
                    self.publication_calendar.readReady(.service_sequence, occurrence)
                else
                    self.publication_calendar.publicationReady(.service_sequence, next);
                if (ready catch |err| {
                    self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = .cut_fact });
                    return;
                }) return;
                self.wait();
            }
        }
        if (value.edge == .before) {
            if (runtime_read orelse runtime_publication) |domain| {
                const slot = runtimePublicationSlot(domain);
                // Store BEFORE already carries the engine's computed sparse
                // frame. Do not derive it from a comparison or assume +1/+64.
                const next = if (runtime_publication != null) value.value orelse {
                    self.fail(.{ .reason = error.InvalidOrder, .role = role, .occurrence = occurrence, .family = .cut_fact });
                    return;
                } else 0;
                while (!self.failed.load(.acquire)) {
                    const ready = if (runtime_read != null)
                        self.publication_calendar.readReady(slot, occurrence)
                    else
                        self.publication_calendar.publicationReady(slot, next);
                    if (ready catch |err| {
                        self.fail(.{ .reason = err, .role = role, .occurrence = occurrence, .family = .cut_fact });
                        return;
                    }) return;
                    self.wait();
                }
            }
        }
    }
    fn onBoundary(raw: *anyopaque, value: cuts.BoundaryPoint) void {
        const self = from(raw);
        const role = codec.wireRole(value.role);
        const occurrence = self.enter(role, .boundary_fact, codec.eventTag(value)) orelse return;
        defer self.leave(occurrence);
        switch (value.site) {
            .service_acceptance_selected, .service_worker_selected => {},
            else => if (!self.checkInput(role, .boundary, occurrence, @as(codec.Boundary, .{ .role = role, .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation }))) return,
        }
        self.compare(role, .boundary_fact, occurrence, value);
    }
    fn onClock(raw: *anyopaque, stage: cuts.ClockStage, job: u64) ?cuts.ClockSample {
        const self = from(raw);
        if (self.clock_pending != null) {
            self.fail(.{ .reason = error.InvalidState, .role = .worker, .occurrence = 0, .family = .raw_clock });
            return null;
        }
        const occurrence = self.enter(.worker, .raw_clock, 0) orelse return null;
        const value = self.input(.worker, .raw_clock, occurrence, codec.RawClock) orelse return null;
        if (@intFromEnum(value.stage) != @intFromEnum(stage) or value.job != job or value.error_code != 0) {
            self.fail(.{ .reason = error.ReplayMismatch, .role = .worker, .occurrence = occurrence, .family = .raw_clock });
            return null;
        }
        self.clock_pending = .{ .occurrence = occurrence, .value = value };
        return .{ .value = value.value, .available = value.available, .error_code = value.error_code };
    }
    fn onWorkerFact(raw: *anyopaque, value: stream.WorkerFact) void {
        const self = from(raw);
        if (self.failed.load(.acquire)) return;
        switch (value) {
            .scan, .idle => {},
            .clock => |sample| {
                const pending = self.clock_pending orelse {
                    self.fail(.{ .reason = error.InvalidState, .role = .worker, .occurrence = 0, .family = .raw_clock });
                    return;
                };
                self.clock_pending = null;
                if (!std.meta.eql(pending.value, sample)) self.fail(.{ .reason = error.ReplayMismatch, .role = .worker, .occurrence = pending.occurrence, .family = .raw_clock });
                self.leave(pending.occurrence);
            },
            else => self.observe(.worker, .worker_fact, value),
        }
    }
    fn onSourceFact(raw: *anyopaque, value: stream.SourceFact) void {
        from(raw).observe(.worker, .source_fact, value);
    }
    fn onSource(raw: *anyopaque, value: source.SemanticEvent) void {
        const role: format.Role = switch (value) {
            .load_begin, .load_return => .control,
            else => .worker,
        };
        from(raw).observe(role, .source_event, value);
    }
    fn onControl(raw: *anyopaque, value: semantic.ControlEvent) void {
        const self = from(raw);
        const occurrence = self.enter(.control, .control_event, codec.eventTag(value)) orelse return;
        defer self.leave(occurrence);
        switch (value) {
            .started => |v| if (!self.checkInput(.control, .launch_descriptor, occurrence, codec.launchDescriptor(v))) return,
            .enter => |v| if (!self.checkInput(.control, .control_call, occurrence, @as(codec.ControlInvocation, .{ .call_id = v.call_id, .call = codec.controlArguments(v.call) }))) return,
            // Real UI calls own submission, event consumption, ACK and Close.
            // Control availability/Close outcomes remain equality-only facts.
            else => {},
        }
        self.compare(.control, .control_event, occurrence, value);
    }
    fn countActual(self: *Driver, count: *u64, occurrence: u64) void {
        count.* = std.math.add(u64, count.*, 1) catch {
            self.fail(.{ .reason = error.CounterOverflow, .role = .ui, .occurrence = occurrence, .family = .ui_event });
            return;
        };
    }
    fn rememberTerminal(self: *Driver, id: u64) void {
        for (self.terminal_pending) |pending| if (pending == id) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = self.turn.load(.acquire), .family = .ui_event });
            return;
        };
        for (&self.terminal_pending) |*pending| if (pending.* == null) {
            pending.* = id;
            return;
        };
        self.fail(.{ .reason = error.UnsupportedScope, .role = .ui, .occurrence = self.turn.load(.acquire), .family = .ui_event });
    }
    fn forgetTerminal(self: *Driver, id: u64) void {
        for (&self.terminal_pending) |*pending| if (pending.* == id) {
            pending.* = null;
            return;
        };
        self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = self.turn.load(.acquire), .family = .ui_event });
    }
    fn trackActualUi(self: *Driver, value: semantic.UiEvent) void {
        switch (value) {
            .enter => |v| {
                if (self.actual_ui != null) {
                    self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = self.turn.load(.acquire), .family = .ui_event });
                    return;
                }
                self.actual_ui = v;
            },
            .end => |v| {
                const invocation = self.actual_ui orelse {
                    self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = self.turn.load(.acquire), .family = .ui_event });
                    return;
                };
                if (invocation.call_id != v.call_id or std.meta.activeTag(invocation.call) != std.meta.activeTag(v.value)) {
                    self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = self.turn.load(.acquire), .family = .ui_event });
                    return;
                }
                switch (v.value) {
                    .pop_event => |event| if (event) |e| {
                        if (e.kind == .terminal) self.rememberTerminal(e.command.id);
                    },
                    .acknowledge_terminal => |result| if (result) {
                        self.forgetTerminal(invocation.call.acknowledge_terminal);
                    } else |_| {},
                    else => {},
                }
                self.actual_ui = null;
            },
        }
    }
    fn onUi(raw: *anyopaque, value: semantic.UiEvent) void {
        const self = from(raw);
        // Native terminal ownership is captured even if comparison already
        // failed or fails while admitting this end marker. Cleanup needs it.
        self.trackActualUi(value);
        const occurrence = self.enter(.ui, .ui_event, codec.eventTag(value)) orelse return;
        defer self.leave(occurrence);
        switch (value) {
            .enter => |v| if (!self.checkInput(.ui, .ui_call, occurrence, @as(codec.UiInvocation, v))) return,
            .end => |v| {
                self.countActual(&self.report.ui_calls, occurrence);
                switch (v.value) {
                    .submit => |result| if (result) |_| {
                        self.countActual(&self.report.command_submitted, occurrence);
                    } else |_| {},
                    .pop_event => |event| if (event) |e| switch (e.kind) {
                        .accepted => self.countActual(&self.report.command_accepted, occurrence),
                        .terminal => self.countActual(&self.report.command_terminal, occurrence),
                    },
                    .acknowledge_terminal => |result| if (result) {
                        self.countActual(&self.report.terminal_acknowledged, occurrence);
                    } else |_| {},
                    .request_close => {},
                }
            },
        }
        self.compare(.ui, .ui_event, occurrence, value);
    }
    fn onWorker(raw: *anyopaque, value: semantic.WorkerEvent) void {
        const self = from(raw);
        const occurrence = self.enter(.worker, .worker_event, codec.eventTag(value)) orelse return;
        defer self.leave(occurrence);
        switch (value) {
            .enter => |v| if (!self.checkInput(.worker, .worker_call, occurrence, v)) return,
            else => {},
        }
        self.compare(.worker, .worker_event, occurrence, value);
    }
    fn onInput(raw: *anyopaque, value: audio.music.trace.Input) void {
        from(raw).observe(.control, .public_input, value);
    }
    fn onSchedule(raw: *anyopaque, value: audio.music.trace.ScheduleEntry) void {
        from(raw).observe(.control, .schedule, value);
    }
    fn onAcceptance(raw: *anyopaque, value: *const stream.LiveAcceptanceAttemptV1, frame: u64) void {
        from(raw).observe(.control, .acceptance, @as(codec.Acceptance, .{ .attempt = value.*, .effective_frame = frame }));
    }
    fn onFrontier(raw: *anyopaque, phase: audio.ControlRuntime.TickPhaseV1, acquired: u64, effective: u64) void {
        from(raw).observe(.control, .frontier, @as(codec.Frontier, .{ .phase = phase, .acquired_frame = acquired, .effective_frame = effective }));
    }
    fn onTick(raw: *anyopaque, value: audio.ControlRuntime.LiveTickEventV1) void {
        from(raw).observe(.control, .tick, value);
    }
    fn awaitCallback(raw: *anyopaque, expected_stop: *const std.atomic.Value(bool)) audio.device.SemanticCallbackAdmission {
        const self = from(raw);
        // Physical null-device timer wakes are not recorded logical callback
        // inputs. Peek once without consuming a cursor or advancing a turn.
        // A captured callback may be in flight when native stop is requested.
        var preview_cursor = self.lane(.render).input;
        const raw_marker = preview_cursor.next() catch null;
        const marker = if (raw_marker) |record| codec.decodeInput(codec.EventCut, record, .event_cut) catch null else null;
        if (!self.failed.load(.acquire)) {
            if (marker) |next| {
                if (next.value.family == .audio_event and next.value.tag == @intFromEnum(std.meta.Tag(audio.device.SemanticAudioEvent).callback_begin)) return .admit;
                if (next.value.family != .audio_event or next.value.tag != @intFromEnum(std.meta.Tag(audio.device.SemanticAudioEvent).epoch_changed))
                    self.fail(.{ .reason = error.UnsupportedScope, .role = .render, .occurrence = next.occurrence, .family = next.value.family });
            } else self.fail(.{ .reason = error.Incomplete, .role = .render, .occurrence = self.turn.load(.acquire) });
        }
        // Real stop sets this before native join. Do not wait for the following
        // epoch_changed observation: it is emitted only after this thread joins.
        while (!expected_stop.load(.acquire)) self.wait();
        return .cancel_pending;
    }
    fn onAudio(raw: *anyopaque, value: audio.device.SemanticAudioEvent) void {
        const self = from(raw);
        const occurrence = self.enter(.render, .audio_event, codec.eventTag(value)) orelse return;
        defer self.leave(occurrence);
        switch (value) {
            .callback_begin => |v| {
                if (!self.checkInput(.render, .callback, occurrence, @as(codec.Callback, .{ .frame_count = v.frame_count, .channels = v.channels, .output_present = v.output_present }))) return;
                self.compare(.render, .audio_event, occurrence, value);
            },
            .pcm => |v| {
                const offset = self.lane(.render).comparison.pcm(occurrence, v) catch |err| {
                    self.fail(.{ .reason = err, .role = .render, .occurrence = occurrence, .family = .pcm });
                    return;
                };
                if (offset) |i| {
                    self.fail(.{ .reason = error.ReplayMismatch, .role = .render, .occurrence = occurrence, .family = .pcm, .byte_offset = i });
                    return;
                }
                self.report.pcm_samples[@intFromEnum(v.disposition)] += v.samples.len;
            },
            else => self.compare(.render, .audio_event, occurrence, value),
        }
    }
    /// Main/UI owner peeks only original input. Do not enter a future call and
    /// block this same thread from performing an earlier genuine Control join.
    fn serviceUi(self: *Driver, instance: *host.Host) UiProgress {
        if (self.failed.load(.acquire)) return .idle;
        var cursor = self.lane(.ui).input;
        const raw_marker = (cursor.next() catch |err| {
            self.fail(.{ .reason = err, .role = .ui, .occurrence = self.turn.load(.acquire) });
            return .idle;
        }) orelse return .exhausted;
        const marker = codec.decodeInput(codec.EventCut, raw_marker, .event_cut) catch |err| {
            self.fail(.{ .reason = err, .role = .ui, .occurrence = self.turn.load(.acquire) });
            return .idle;
        };
        if (marker.value.family != .ui_event or marker.value.tag != @intFromEnum(std.meta.Tag(semantic.UiEvent).enter)) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = marker.occurrence, .family = marker.value.family });
            return .idle;
        }
        const turn = self.turn.load(.acquire);
        if (turn < marker.occurrence) return .idle;
        if (turn > marker.occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = marker.occurrence });
            return .idle;
        }
        const raw_call = (cursor.next() catch |err| {
            self.fail(.{ .reason = err, .role = .ui, .occurrence = marker.occurrence });
            return .idle;
        }) orelse {
            self.fail(.{ .reason = error.Incomplete, .role = .ui, .occurrence = marker.occurrence });
            return .idle;
        };
        const invocation = codec.decodeInput(codec.UiInvocation, raw_call, .ui_call) catch |err| {
            self.fail(.{ .reason = err, .role = .ui, .occurrence = marker.occurrence });
            return .idle;
        };
        if (invocation.occurrence != marker.occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .ui, .occurrence = marker.occurrence });
            return .idle;
        }
        // Every return/error is observed by onUi and compared, never consulted
        // to decide which command to issue or which reservation to release.
        switch (invocation.value.call) {
            .submit => |args| _ = instance.submit(args.identity, args.kind) catch return .progressed,
            .pop_event => _ = instance.popEvent(),
            .acknowledge_terminal => |id| instance.acknowledgeTerminal(id) catch {},
            .request_close => |epoch| instance.requestClose(epoch) catch {},
        }
        return .progressed;
    }
    /// finished acquire excludes the Control producer before this cursor read.
    /// The remaining join marker is scheduling input, not an expected result.
    fn serviceJoin(self: *Driver, instance: *host.Host) void {
        if (self.failed.load(.acquire) or self.report.host_joined or !instance.finished.load(.acquire)) return;
        var cursor = self.lane(.control).input;
        const raw_marker = (cursor.next() catch |err| {
            self.fail(.{ .reason = err, .role = .control, .occurrence = self.turn.load(.acquire) });
            return;
        }) orelse {
            self.fail(.{ .reason = error.Incomplete, .role = .control, .occurrence = self.turn.load(.acquire) });
            return;
        };
        const marker = codec.decodeInput(codec.EventCut, raw_marker, .event_cut) catch |err| {
            self.fail(.{ .reason = err, .role = .control, .occurrence = self.turn.load(.acquire) });
            return;
        };
        if (marker.value.family != .control_event or marker.value.tag != @intFromEnum(std.meta.Tag(semantic.ControlEvent).control_joined)) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .control, .occurrence = marker.occurrence, .family = marker.value.family });
            return;
        }
        const turn = self.turn.load(.acquire);
        if (turn < marker.occurrence) return;
        if (turn > marker.occurrence) {
            self.fail(.{ .reason = error.InvalidOrder, .role = .control, .occurrence = marker.occurrence });
            return;
        }
        instance.join() catch |err| {
            self.fail(.{ .reason = err, .role = .control, .occurrence = marker.occurrence });
            return;
        };
        self.report.host_joined = true;
    }
    /// Only failed evidence permits runner cleanup to consume/ACK outside the
    /// original UI transcript. These calls still use the genuine native APIs.
    fn drainFailedUi(self: *Driver, instance: *host.Host) !void {
        if (!self.failed.load(.acquire)) return error.InvalidState;
        for (self.terminal_pending) |pending| if (pending) |id| try instance.acknowledgeTerminal(id);
        while (instance.popEvent()) |event| if (event.kind == .terminal) try instance.acknowledgeTerminal(event.command.id);
    }
    /// A timeout invalidates replay and releases clocks/gates, but is NEVER a
    /// free/join grant. The loop then waits for genuine native cleanup custody.
    /// If native cleanup is irrecoverably stuck the caller must keep this Driver
    /// alive (or end the isolated process); it cannot destroy retained resources.
    pub fn run(self: *Driver, launch: host.Launch, device: audio.device.DeviceConfig) !Report {
        return self.runWithPacing(launch, device, .legacy_poll);
    }
    /// Pacing is authenticated launch INPUT. An explicit caller expectation is
    /// checked before any Host/native owner exists, never borrowed from a
    /// comparison result. The old run API retains its legacy polling contract.
    pub fn runWithPacing(self: *Driver, launch: host.Launch, device: audio.device.DeviceConfig, pacing: semantic.PacingMode) !Report {
        if (self.address != self or self.running or self.completed or device.backend != .null_backend) return error.InvalidState;
        // Launch arguments are authenticated execution input, not a late
        // comparison against a started outcome after native owner effects.
        const requested: codec.LaunchDescriptor = .{ .document_id = launch.document_id, .revision = launch.revision, .draft_hash = launch.draft_hash, .state = launch.state, .device = device, .pacing = pacing };
        try codec.validateLaunchDescriptor(requested);
        if (!std.meta.eql(self.launch_descriptor, requested)) return error.WrongLaunch;
        if (!std.mem.eql(u8, &self.identity.config, &try codec.configHash(launch.config))) return error.WrongConfig;
        if (!std.mem.eql(u8, &self.identity.source, &format.hash(launch.compiled))) return error.WrongSource;
        const selection = try host.admission.validate(std.heap.page_allocator, launch.compiled, launch.state, launch.config);
        if (!std.mem.eql(u8, &self.identity.bank, &selection.bank_hash)) return error.WrongBank;
        self.started_at = std.Io.Clock.awake.now(self.io);
        const instance = try host.Host.create(launch, .{ .io = self.io, .semantic = &self.session, .device = device });
        self.running = true;
        var close_sent = false;
        while (true) {
            if (instance.readStatus()) |status| self.report.final_status = status.value;
            if (self.failed.load(.acquire)) {
                if (!close_sent) {
                    instance.requestClose(instance.identity().epoch) catch {};
                    close_sent = true;
                }
                self.drainFailedUi(instance) catch |err| self.fail(.{ .reason = err, .role = .ui, .occurrence = self.turn.load(.acquire) });
                if (instance.finished.load(.acquire)) break;
            } else {
                const progress = self.serviceUi(instance);
                if (self.failed.load(.acquire)) continue;
                self.serviceJoin(instance);
                if (self.failed.load(.acquire)) continue;
                // UI calls may remain after Control returned or joined. Their
                // explicit pop/ACK actions must run before native destruction.
                if (progress == .exhausted and self.report.host_joined) break;
            }
            self.wait();
        }
        // No post-create error may release borrowed driver/reader/source
        // storage while a real Host or native thread retains it. A failed UI
        // acknowledgment, join or status seal invalidates proof, not custody.
        // Keep retrying the native path; an unrecoverable error intentionally
        // leaves this isolated process waiting rather than returning/freeing.
        while (!instance.isClosed()) {
            self.fail(.{ .reason = error.InvalidState, .role = .control, .occurrence = self.turn.load(.acquire) });
            self.wait();
        }
        while (true) {
            if (self.failed.load(.acquire)) self.drainFailedUi(instance) catch |err| {
                self.fail(.{ .reason = err, .role = .ui, .occurrence = self.turn.load(.acquire) });
                self.wait();
                continue;
            };
            instance.acknowledgeClosed() catch |err| {
                self.fail(.{ .reason = err, .role = .control, .occurrence = self.turn.load(.acquire) });
                self.wait();
                continue;
            };
            break;
        }
        while (!self.report.host_joined) {
            instance.join() catch |err| {
                self.fail(.{ .reason = err, .role = .control, .occurrence = self.turn.load(.acquire) });
                self.wait();
                continue;
            }; // emits the final real Control-joined callback
            break;
        }
        self.report.host_joined = true;
        if (instance.readStatus()) |status| self.report.final_status = status.value;
        while (true) {
            if (self.failed.load(.acquire)) self.drainFailedUi(instance) catch |err| {
                self.fail(.{ .reason = err, .role = .ui, .occurrence = self.turn.load(.acquire) });
                self.wait();
                continue;
            };
            instance.destroy() catch |err| {
                self.fail(.{ .reason = err, .role = .control, .occurrence = self.turn.load(.acquire) });
                self.wait();
                continue;
            };
            break;
        }
        self.report.host_destroyed = true;
        self.completed = true;
        self.running = false;
        for (&self.lanes, 0..) |*lane_, i| {
            self.report.matched[i] = lane_.comparison.matched;
            self.report.input_events[i] = lane_.events;
            if (!self.failed.load(.acquire)) {
                lane_.input.finish() catch |err| self.fail(.{ .reason = err, .role = @enumFromInt(i), .occurrence = self.turn.load(.acquire) });
                lane_.comparison.cursor.finish() catch |err| self.fail(.{ .reason = err, .role = @enumFromInt(i), .occurrence = self.turn.load(.acquire) });
            }
        }
        if (self.failed.load(.acquire)) return error.ReplayMismatch;
        if (self.clock_pending != null or self.consumed_active != null or self.consumed_retired.load(.acquire) != self.consumed_read_count or
            !self.publication_calendar.complete() or !self.exclusion_calendar.complete() or self.actual_ui != null) return error.Incomplete;
        for (self.terminal_pending) |pending| if (pending != null) return error.Incomplete;
        const final_status = self.report.final_status orelse return error.Incomplete;
        if (final_status.phase != .closed or final_status.first_error != null or final_status.cleanup_error != null or
            !final_status.worker_joined or
            final_status.provider.live != 0 or final_status.provider.opened != final_status.provider.closed or
            final_status.sample_leases != 0 or final_status.live_instances != 0 or
            self.report.command_accepted > self.report.command_submitted or
            self.report.command_terminal != self.report.command_submitted or
            self.report.terminal_acknowledged != self.report.command_submitted)
            return error.Incomplete;
        self.report.eof = true;
        return self.report;
    }
};
// Proposed append to live_semantic_replay.zig after central build freeze.
// Private driver methods stay private; this test-only facade is absent in production.
pub const ConsumedPrefixRegression = if (@import("builtin").is_test) struct {
    /// Pre-owner input-only map admission; no Host or native effects.
    pub fn validateMap(reader: *const format.Reader) !usize {
        const driver = try std.testing.allocator.create(Driver);
        defer std.testing.allocator.destroy(driver);
        driver.* = .{};
        try driver.initConsumedReads(reader);
        return driver.consumed_read_count;
    }

    pub fn repeatedPrefixAndInterveningMarker() !void {
        const t = std.testing;
        const driver = try t.allocator.create(Driver);
        defer t.allocator.destroy(driver);
        driver.* = .{};
        driver.consumed_read_count = 2;
        driver.consumed_reads[0] = .{ .before = 10, .after = 14, .index = 3, .generation = 7, .prefix = 5568 };
        driver.consumed_reads[1] = .{ .before = 15, .after = 17, .index = 3, .generation = 7, .prefix = 5568 };
        driver.consumed_progress[3].generation.store(7, .release);
        driver.consumed_progress[3].prefix.store(5568, .release);
        const before: cuts.Point = .{ .role = .control, .site = .ring_consumed, .edge = .before, .index = 3, .generation = 7 };
        const after: cuts.Point = .{ .role = .control, .site = .ring_consumed, .edge = .after, .index = 3, .generation = 7, .value = 5568 };
        driver.turn.store(11, .release); // before stamp has already left.
        driver.waitConsumedRead(before, 10);
        try t.expectEqual(@as(?usize, 0), driver.consumed_active);
        driver.releaseConsumedRead(after); // acquired value copied, after stamp not reached.
        try t.expectEqual(@as(usize, 1), driver.consumed_retired.load(.acquire));
        try t.expectEqual(@as(u64, 11), driver.turn.load(.acquire));
        // An intervening Render marker can now leave while the Control after
        // stamp remains future. No sleeping or thread-timeout assertion needed.
        driver.leave(11);
        try t.expectEqual(@as(u64, 12), driver.turn.load(.acquire));
        driver.waitConsumedRead(before, 15);
        try t.expectEqual(@as(?usize, 1), driver.consumed_active);
        try t.expectEqual(@as(usize, 1), driver.consumed_retired.load(.acquire));
        driver.releaseConsumedRead(after);
        try t.expectEqual(@as(usize, 2), driver.consumed_retired.load(.acquire));
        try t.expectEqual(@as(?usize, null), driver.consumed_active);
        // Once both distinct reads retire, next real publication is admitted.
        Driver.onConsumed(driver, .{ .site = .stream_consumed_release, .edge = .before, .index = 3, .generation = 7, .value = 5569 });
        try t.expect(!driver.failed.load(.acquire));
        // Admission itself never advances actual observed consumption.
        try t.expectEqual(@as(u64, 5568), driver.consumed_progress[3].prefix.load(.acquire));
        Driver.onConsumed(driver, .{ .site = .stream_consumed_release, .edge = .after, .index = 3, .generation = 7, .value = 5569 });
        try t.expectEqual(@as(u64, 5569), driver.consumed_progress[3].prefix.load(.acquire));
    }
} else struct {};

/// Narrow UI-dispatch regression, not full Host/lifecycle admission. This uses
/// real native Mailboxes and actual four-method Host wrappers, but no engine or
/// native threads. Full process qualification remains a separate required gate.
pub const UiTranscriptRegression = if (@import("builtin").is_test) struct {
    const Events = struct {
        events: [96]semantic.UiEvent = undefined,
        count: usize = 0,
        invalid: bool = false,
        fn emit(raw: *anyopaque, value: semantic.UiEvent) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.count == self.events.len) {
                self.invalid = true;
                return;
            }
            self.events[self.count] = value;
            self.count += 1;
        }
        fn invalidate(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.invalid = true;
        }
    };
    fn identity() semantic.Identity {
        return .{ .epoch = 17, .document_id = 23, .revision = 9, .draft_hash = @splat(1), .artifact_hash = @splat(2), .state = @enumFromInt(1) };
    }
    fn initializeMailboxOnly(instance: *host.Host, session: *semantic.Session) !void {
        // Only the four UI methods are called. Their dependencies are precisely
        // Options.semantic and the initialized channel; other Host fields must
        // never be read, joined, freed or mistaken for a constructed engine.
        instance.options = .{ .io = std.testing.io, .semantic = session };
        instance.channel = try host.Mailbox.init(identity());
    }
    fn collect(events: *Events, driver: *Driver) !void {
        const t = std.testing;
        var config_ = driver.config(.legacy_poll);
        config_.service.clock = null;
        config_.service.consume = null;
        config_.audio.wait_callback = null;
        config_.ui = .{ .context = events, .emit = Events.emit };
        config_.mailbox = null;
        config_.context = events;
        config_.invalidate = Events.invalidate;
        var session: semantic.Session = .{};
        try session.init(config_);
        var instance: host.Host = undefined;
        try initializeMailboxOnly(&instance, &session);
        const id = identity();
        const first = try instance.submit(id, .play);
        try t.expectError(error.TerminalNotConsumed, instance.acknowledgeTerminal(first.id));
        try t.expectEqual(@as(?host.Mailbox.Event, null), instance.popEvent());
        var wrong = id;
        wrong.epoch += 1;
        try t.expectError(error.InvalidEpoch, instance.submit(wrong, .stop));
        try t.expectError(error.InvalidState, instance.submit(id, .recover));
        try t.expectError(error.InvalidEpoch, instance.requestClose(wrong.epoch));
        for (0..7) |_| _ = try instance.submit(id, .stop);
        try t.expectError(error.QueueFull, instance.submit(id, .stop));
        try instance.requestClose(id.epoch);
        try t.expectError(error.AdmissionClosed, instance.submit(id, .play));
        try instance.requestClose(id.epoch); // Native idempotence is a real success.
        try t.expect(!events.invalid and session.active_ui == null);
        try t.expectEqual(@as(u64, 17), session.ui_calls);
    }
    fn tape(events: *const Events, output: []u8, mismatch: bool) ![]const u8 {
        var writer = try format.Writer.init(output, .{ .build = @splat(3), .bank = @splat(4), .source = @splat(5), .config = @splat(6) }, codec.validate);
        var scratch: [2048]u8 = undefined;
        var ordinal: u64 = 0;
        for (events.events[0..events.count], 0..) |event, i| {
            const occurrence: u64 = @intCast(i + 1);
            const marker: codec.Native(codec.EventCut) = .{ .occurrence = occurrence, .value = .{ .family = .ui_event, .tag = codec.eventTag(event) } };
            ordinal += 1;
            try writer.append(.ui, ordinal, @intFromEnum(codec.Family.event_cut), .input, try codec.encode(marker, .input, &scratch));
            if (event == .enter) {
                const invocation: codec.Native(codec.UiInvocation) = .{ .occurrence = occurrence, .value = event.enter };
                ordinal += 1;
                try writer.append(.ui, ordinal, @intFromEnum(codec.Family.ui_call), .input, try codec.encode(invocation, .input, &scratch));
            }
            var reference = event;
            if (mismatch and i + 1 == events.count) {
                // Only a reference is changed. Native Close must still return
                // actual success, and the comparator must reject that mismatch.
                reference.end.value = .{ .request_close = error.InvalidEpoch };
            }
            const value: codec.Native(semantic.UiEvent) = .{ .occurrence = occurrence, .value = reference };
            ordinal += 1;
            try writer.append(.ui, ordinal, @intFromEnum(codec.Family.ui_event), .reference, try codec.encode(value, .reference, &scratch));
        }
        var counts: [format.role_count]u64 = @splat(0);
        counts[@intFromEnum(format.Role.ui)] = ordinal;
        return writer.sealFraming(.{ .healthy = true, .role_counts = counts, .closed_roles = @splat(true) });
    }
    pub fn actualCallsAndComparisonOnlyResults(mismatch: bool) !void {
        const t = std.testing;
        const driver = try t.allocator.create(Driver);
        defer t.allocator.destroy(driver);
        driver.* = .{};
        driver.io = t.io;
        driver.started_at = std.Io.Clock.awake.now(t.io);
        var events: Events = .{};
        try collect(&events, driver);
        var output: [32768]u8 = undefined;
        const bytes = try tape(&events, &output, mismatch);
        const reader = try format.Reader.preflight(bytes, .{ .build = @splat(3), .bank = @splat(4), .source = @splat(5), .config = @splat(6) }, codec.validate);
        // Deliberately initialize only the UI component, not Driver.init: this
        // unit tape is not a full-lifecycle corpus and must not pass admission.
        driver.lanes[@intFromEnum(format.Role.ui)] = .{ .input = codec.InputCursor.init(&reader, .ui), .comparison = .{ .cursor = codec.ComparisonCursor.init(&reader, .ui) } };
        try driver.clock.init(driver, Driver.onClock);
        try driver.publication_calendar.init(0);
        try driver.publication_calendar.seal();
        try driver.session.initReplay(driver.config(.legacy_poll));
        var instance: host.Host = undefined;
        try initializeMailboxOnly(&instance, &driver.session);
        for (0..17) |_| try t.expectEqual(UiProgress.progressed, driver.serviceUi(&instance));
        if (mismatch) {
            try t.expect(driver.failed.load(.acquire));
            try t.expectEqual(@as(?codec.Family, .ui_event), driver.failure_value.?.family);
            // The mismatching recorded error never replaced the successful
            // native result, reopened admission, or ran an automatic ACK.
            try instance.channel.requestClose(identity().epoch);
        } else {
            try t.expect(!driver.failed.load(.acquire));
            try t.expectEqual(UiProgress.exhausted, driver.serviceUi(&instance));
            try driver.lane(.ui).input.finish();
            try driver.lane(.ui).comparison.cursor.finish();
            try t.expectEqual(@as(u64, 17), driver.report.ui_calls);
            try t.expectEqual(@as(u64, 8), driver.report.command_submitted);
            try t.expectEqual(@as(u64, 0), driver.report.command_accepted);
            try t.expectEqual(@as(u64, 0), driver.report.command_terminal);
            try t.expectEqual(@as(u64, 0), driver.report.terminal_acknowledged);
        }
        try t.expectError(error.AdmissionClosed, instance.channel.submit(identity(), .play));
        try t.expectError(error.TerminalNotConsumed, instance.channel.acknowledgeTerminal(1));
    }
    pub fn failedPopRetainsCleanupCredit() !void {
        const t = std.testing;
        const driver = try t.allocator.create(Driver);
        defer t.allocator.destroy(driver);
        driver.* = .{};
        driver.io = t.io;
        driver.started_at = std.Io.Clock.awake.now(t.io);
        try driver.clock.init(driver, Driver.onClock);
        try driver.publication_calendar.init(0);
        try driver.publication_calendar.seal();
        try driver.session.initReplay(driver.config(.legacy_poll));
        var instance: host.Host = undefined;
        try initializeMailboxOnly(&instance, &driver.session);
        // Real native producer operations set up one cancelled terminal. No
        // transcript or reference supplies this command id to cleanup.
        const submitted = try instance.channel.submit(identity(), .play);
        const dequeued = instance.channel.popCommand().?;
        try t.expectEqualDeep(submitted, dequeued);
        try instance.channel.publishTerminal(dequeued, .cancelled, null);
        driver.failed.store(true, .release);
        const popped = instance.popEvent().?;
        try t.expectEqual(submitted.id, popped.command.id);
        try t.expectEqual(@as(?u64, submitted.id), driver.terminal_pending[0]);
        try driver.drainFailedUi(&instance);
        for (driver.terminal_pending) |pending| try t.expectEqual(@as(?u64, null), pending);
        try t.expectError(error.UnknownCommand, instance.channel.acknowledgeTerminal(submitted.id));
    }
} else struct {};
