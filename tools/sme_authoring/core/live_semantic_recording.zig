//! Bounded production Host -> profile 9 adapter. Allocate Recorder in its final
//! storage, call init before Host.launch, drain on one non-RT consumer, and call
//! finish only after genuine Host.join and Host.destroy. Framing completion is
//! NOT semantic replay admission; no expected value is a runtime input here.
const std = @import("std");
pub const compilation_mode = @import("builtin").mode;
const builtin = @import("builtin");
pub const collector_profile = @import("live_semantic_collector_profile.zig");
const audio = @import("bugu_audio");
pub const codec = @import("sme-live-codec");
pub const semantic = codec.semantic;
pub const format = codec.format;
const cuts = codec.cuts;
const stream = codec.stream;
const source = codec.source;
pub const Error = codec.Error || error{ InvalidState, CaptureBudgetExceeded, UnsupportedScope };
pub const default_corpus_bytes: usize = 40 * 1024 * 1024;
pub const max_generated_frames: u64 = 262144;
pub const Stats = struct {
    allocation_bytes: usize,
    corpus_bytes: usize,
    occurrences: u64,
    lanes: [format.role_count]format.LaneStats,
    pcm_samples: [3]u64,
    submitted_frames: u64,
    generated_frames: u64,
    discarded_pending_frames: u64,
    discarded_generated_frames: u64,
    multi_frame_ticks: u64,
    control_thread_id: u64,
    worker_thread_id: u64,
    callback_thread_id: u64,
    ui_calls: u64,
    command_submitted: u64,
    command_terminal: u64,
    terminal_acknowledged: u64,
};
pub const Progress = struct {
    generated_frames: u64,
    submitted_frames: u64,
    discarded_pending_frames: u64,
    discarded_generated_frames: u64,
    multi_frame_ticks: u64,
    control_thread_id: u64,
    worker_thread_id: u64,
    callback_thread_id: u64,
};
const Lifecycle = struct {
    started: bool = false,
    worker_started: bool = false,
    ready: bool = false,
    close_observed: bool = false,
    device_stopped: bool = false,
    owner_destroyed: bool = false,
    provider_released: bool = false,
    audio_detached: bool = false,
    worker_returned: bool = false,
    worker_joined: bool = false,
    closed: bool = false,
    returned: bool = false,
    control_joined: bool = false,
    control_thread: u64 = 0,
    worker_thread: u64 = 0,
    active_call: ?semantic.ControlCall = null,
    active_ui: ?codec.UiInvocation = null,
    ui_calls: u64 = 0,
    command_submitted: u64 = 0,
    command_terminal: u64 = 0,
    terminal_acknowledged: u64 = 0,
    callback_calls: u64 = 0,
    pcm_samples: [3]u64 = .{ 0, 0, 0 },
    submitted_frames: u64 = 0,
    generated_frames: u64 = 0,
    discarded_pending_frames: u64 = 0,
    discarded_generated_frames: u64 = 0,
    multi_frame_ticks: u64 = 0,
    acceptance_tick: ?u64 = null,
    acceptance_frame: u64 = 0,
    witnessed_tick: ?u64 = null,
};
const PointBuffer = struct {
    envelope: ?codec.Boundary = null,
    count: u16 = 0,
    inputs: [codec.max_packet_points]codec.PacketInput = undefined,
    references: [codec.max_packet_points]codec.PacketReference = undefined,
};
const GateBuffer = struct {
    count: u16 = 0,
    inputs: [codec.max_packet_points]codec.Native(codec.WorkerGateCut) = undefined,
    references: [codec.max_packet_points]codec.Native(codec.mailbox.WorkerGateCheckpoint) = undefined,
};
pub const gate_packet_storage_bytes = 2 * @sizeOf(GateBuffer);
pub const Recorder = struct {
    address: ?*Recorder = null,
    /// Test-only consumer diagnostics; attach after successful init and retain
    /// externally owned storage until genuine join. Production is null-only.
    test_collector_profile: collector_profile.Pointer = if (builtin.is_test) null else {},
    capture: format.Capture = undefined,
    session: semantic.Session = .{},
    writer: format.Writer = undefined,
    streaming_writer: ?format.StreamingWriter = null,
    allocation_bytes: usize = 0,
    /// Sole-consumer diagnostic. External sink bytes may be uncertain on error.
    first_output_error: ?anyerror = null,
    identity: format.Identity = undefined,
    /// Fixed by the constructor before Session initialization and attachment.
    pacing: semantic.PacingMode = .legacy_poll,
    occurrence: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    callback_thread: std.atomic.Value(u64) = .init(0),
    native_scratch: [format.max_payload]u8 = undefined,
    wire_scratch: [format.max_payload]u8 = undefined,
    lifecycle: Lifecycle = .{},
    points: [3]PointBuffer = undefined,
    gate_points: [2]GateBuffer = undefined, // Control and Worker only.
    finished: bool = false,

    /// No large struct assignment or Capture temporary is constructed here.
    /// Corpus, lane backing, descriptors and both fixed scratch buffers all
    /// count toward the same allocation admission cap before attachment.
    pub fn init(self: *Recorder, identity: format.Identity, corpus: []u8) Error!void {
        return self.initWithPacing(identity, corpus, .legacy_poll);
    }
    pub fn initWithPacing(self: *Recorder, identity: format.Identity, corpus: []u8, pacing: semantic.PacingMode) Error!void {
        if (self.address != null) return error.InvalidState;
        if (comptime builtin.is_test) self.test_collector_profile = null;
        const total = std.math.add(usize, @sizeOf(Recorder), corpus.len) catch return error.CaptureBudgetExceeded;
        if (total > format.max_capture_bytes) return error.CaptureBudgetExceeded;
        self.writer = try format.Writer.init(corpus, identity, codec.validate);
        self.allocation_bytes = total;
        self.streaming_writer = null;
        self.first_output_error = null;
        try self.initCommon(identity, pacing);
    }
    /// Non-RT only. Sink must synchronously consume borrowed bytes. Its caller
    /// declares all retained sink staging in resident_staging_bytes; the file
    /// ceiling is not a resident allocation. Sink/file lifetime stays with caller.
    pub fn initStreaming(self: *Recorder, identity: format.Identity, sink: format.StreamSink, byte_cap: u64, resident_staging_bytes: usize) !void {
        return self.initStreamingWithPacing(identity, sink, byte_cap, resident_staging_bytes, .legacy_poll);
    }
    pub fn initStreamingWithPacing(self: *Recorder, identity: format.Identity, sink: format.StreamSink, byte_cap: u64, resident_staging_bytes: usize, pacing: semantic.PacingMode) !void {
        if (self.address != null) return error.InvalidState;
        if (comptime builtin.is_test) self.test_collector_profile = null;
        const total = std.math.add(usize, @sizeOf(Recorder), resident_staging_bytes) catch return error.CaptureBudgetExceeded;
        if (total > format.max_capture_bytes) return error.CaptureBudgetExceeded;
        self.allocation_bytes = total;
        self.streaming_writer = null;
        self.first_output_error = null;
        self.streaming_writer = format.StreamingWriter.init(sink, byte_cap, identity, codec.validate) catch |err| {
            self.first_output_error = err;
            self.address = self;
            self.failed = .init(true);
            return err;
        };
        errdefer self.poisonOutput();
        try self.initCommon(identity, pacing);
    }
    fn initCommon(self: *Recorder, identity: format.Identity, pacing: semantic.PacingMode) Error!void {
        self.identity = identity;
        self.pacing = pacing;
        self.occurrence = .init(0);
        self.failed = .init(false);
        self.callback_thread = .init(0);
        self.lifecycle = .{};
        for (&self.points) |*points| {
            points.envelope = null;
            points.count = 0;
        }
        for (&self.gate_points) |*points| points.count = 0;
        self.finished = false;
        self.capture.init(codec.validate);
        self.address = self;
        try self.session.init(self.sessionConfig());
    }
    fn poisonOutput(self: *Recorder) void {
        if (self.streaming_writer) |*writer| writer.poison() else self.writer.poison();
    }
    pub fn sessionConfig(self: *Recorder) semantic.Config {
        return .{
            .pacing = self.pacing,
            .output = .{ .context = self, .input = onInput, .schedule = onSchedule, .invalidate = invalidate },
            .service = .{
                .cuts = .{ .context = self, .point = onPoint, .boundary = onBoundary },
                .worker_facts = .{ .context = self, .emit = onWorkerFact },
                .source = .{ .context = self, .emit = onSourceFact },
                .clock = null,
            },
            .audio = .{ .context = self, .call = onAudio },
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
    pub fn healthy(self: *const Recorder) bool {
        return self.address == self and !self.failed.load(.acquire) and !self.session.poisoned.load(.acquire) and self.capture.healthy();
    }
    fn from(raw: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(raw));
    }
    fn invalidate(raw: *anyopaque) void {
        from(raw).failed.store(true, .release);
    }
    fn fail(self: *Recorder) void {
        self.failed.store(true, .release);
    }
    /// Conservative source-bracket order. Acquire/release stamps anchor real
    /// before/after operations for finite scalar interval admission. They
    /// are not a generic causal graph and never wait/serialize whole operations.
    fn next(self: *Recorder) ?u64 {
        if (self.failed.load(.acquire)) return null;
        const prior = self.occurrence.fetchAdd(1, .acq_rel);
        if (prior == std.math.maxInt(u64)) {
            self.fail();
            return null;
        }
        return prior + 1;
    }
    fn pushAt(self: *Recorder, role: format.Role, family: codec.Family, class: format.Class, occurrence: u64, value: anytype) void {
        const T = @TypeOf(value);
        if (!codec.owned(value)) {
            self.fail();
            return;
        }
        const native: codec.Native(T) = .{ .occurrence = occurrence, .value = value };
        if (!self.capture.lane(role).push(@intFromEnum(family), class, std.mem.asBytes(&native), &.{})) self.fail();
    }
    fn flushPoints(self: *Recorder, role: format.Role) void {
        const points = &self.points[@intFromEnum(role)];
        if (points.count == 0) return;
        const header: codec.PacketHeader = .{ .count = points.count };
        const lane = self.capture.lane(role);
        if (!lane.push(@intFromEnum(codec.Family.point_packet_input), .input, std.mem.asBytes(&header), std.mem.sliceAsBytes(points.inputs[0..points.count])) or
            !lane.push(@intFromEnum(codec.Family.point_packet_reference), .reference, std.mem.asBytes(&header), std.mem.sliceAsBytes(points.references[0..points.count]))) self.fail();
        points.count = 0;
    }
    fn flushGatePoints(self: *Recorder, role: format.Role) void {
        const index = @intFromEnum(role);
        if (index >= self.gate_points.len) return;
        const points = &self.gate_points[index];
        if (points.count == 0) return;
        const header: codec.PacketHeader = .{ .count = points.count };
        const lane = self.capture.lane(role);
        if (!lane.push(@intFromEnum(codec.Family.worker_gate_packet_input), .input, std.mem.asBytes(&header), std.mem.sliceAsBytes(points.inputs[0..points.count])) or
            !lane.push(@intFromEnum(codec.Family.worker_gate_packet_reference), .reference, std.mem.asBytes(&header), std.mem.sliceAsBytes(points.references[0..points.count]))) self.fail();
        points.count = 0;
    }
    fn beginEvent(self: *Recorder, role: format.Role, family: codec.Family, value: anytype) ?u64 {
        // Every same-role nonbuffered event first publishes the earlier points.
        // The original hook stamps, not this later flush, define occurrence.
        if (role != .ui) self.flushPoints(role);
        if (role == .control or role == .worker) self.flushGatePoints(role);
        const occurrence = self.next() orelse return null;
        self.pushAt(role, .event_cut, .input, occurrence, @as(codec.EventCut, .{ .family = family, .tag = codec.eventTag(value) }));
        return occurrence;
    }
    fn push(self: *Recorder, role: format.Role, family: codec.Family, class: format.Class, value: anytype) void {
        self.pushAt(role, family, class, self.beginEvent(role, family, value) orelse return, value);
    }
    fn onPoint(raw: *anyopaque, value: cuts.Point) void {
        const self = from(raw);
        if (!cuts.allowedPoint(value)) {
            self.fail();
            return;
        }
        codec.validateExclusionPoint(value) catch {
            self.fail();
            return;
        };
        const job_scan_eligible = codec.jobObservedEligibility(value) catch {
            self.fail();
            return;
        };
        const role = codec.wireRole(value.role);
        if (role == .control or role == .worker) self.flushGatePoints(role);
        const points = &self.points[@intFromEnum(role)];
        const occurrence = self.next() orelse return;
        const publication_prefix: u64 = if (codec.publicationPrefixPoint(role, value.site, value.edge)) value.value orelse {
            self.fail();
            return;
        } else 0;
        const coordinate: codec.PacketInput = .{ .occurrence = occurrence, .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation, .publication_prefix = publication_prefix, .job_scan_eligible = job_scan_eligible };
        points.inputs[points.count] = coordinate;
        points.references[points.count] = .{ .input = coordinate, .value = value.value };
        points.count += 1;
        if (codec.exclusionClaim(role, value.site) and value.edge == .after) {
            const observed = value.value orelse {
                self.fail();
                return;
            };
            if (observed > 1) {
                self.fail();
                return;
            }
            // This bounded handoff coordinate follows its exact claim cut,
            // including the last virtual point of a packet. No new stamp and
            // no callback allocation/wait is introduced. Native facts remain
            // in the separate point reference, including failed claims.
            self.flushPoints(role);
            self.pushAt(role, .exclusion_claim, .input, occurrence, observed == 0);
        } else if (points.count == codec.max_packet_points) self.flushPoints(role);
    }

    fn onBoundary(raw: *anyopaque, value: cuts.BoundaryPoint) void {
        const self = from(raw);
        const role = codec.wireRole(value.role);
        const occurrence = self.beginEvent(role, .boundary_fact, value) orelse return;
        // Selection is a computed fact, never an instruction to choose a job.
        switch (value.site) {
            .service_acceptance_selected, .service_worker_selected => {},
            else => self.pushAt(role, .boundary, .input, occurrence, @as(codec.Boundary, .{ .role = role, .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation })),
        }
        self.pushAt(role, .boundary_fact, .reference, occurrence, value);
        if (codec.packetEnvelope(value.site)) {
            const points = &self.points[@intFromEnum(role)];
            const coordinate: codec.Boundary = .{ .role = role, .site = value.site, .edge = .before, .index = value.index, .generation = value.generation };
            switch (value.edge) {
                .before => {
                    if (points.envelope != null) {
                        self.fail();
                        return;
                    }
                    points.envelope = coordinate;
                },
                .after => {
                    if (points.envelope == null or !std.meta.eql(points.envelope.?, coordinate)) {
                        self.fail();
                        return;
                    }
                    points.envelope = null;
                },
            }
        }
    }
    fn onWorkerFact(raw: *anyopaque, value: stream.WorkerFact) void {
        const self = from(raw);
        switch (value) {
            .clock => |v| self.push(.worker, .raw_clock, .input, v),
            // Native scan cuts already carry slot crossing. Internal empty
            // scans and idle bookkeeping are outside the observable contract.
            .scan, .idle => {},
            .source_read => |v| {
                self.push(.worker, .worker_fact, .reference, value);
                if (v.error_code != 0) self.fail();
            },
            else => self.push(.worker, .worker_fact, .reference, value),
        }
    }
    fn onSourceFact(raw: *anyopaque, value: stream.SourceFact) void {
        const self = from(raw);
        // Both preparation and decoding are genuine Worker operations in Host.
        self.push(.worker, .source_fact, .reference, value);
        if (value.call == 0 or value.error_code != 0) self.fail();
    }
    fn onSource(raw: *anyopaque, value: source.SemanticEvent) void {
        const self = from(raw);
        // Source loading occurs before Worker acquisition. Provider callback
        // open/read/close subsequently belong to the sole actual Worker.
        const role: format.Role = switch (value) {
            .load_begin, .load_return => .control,
            .enter, .result, .end => .worker,
        };
        self.push(role, .source_event, .reference, value);
        switch (value) {
            .load_return => |v| switch (v) {
                .failure => self.fail(),
                else => {},
            },
            .result => |v| switch (v.value) {
                .failure => self.fail(),
                else => {},
            },
            .end => |v| if (v.failed or v.call == 0) {
                self.fail();
            },
            .enter => |v| if (v.call == 0) {
                self.fail();
            },
            else => {},
        }
    }
    fn onControl(raw: *anyopaque, value: semantic.ControlEvent) void {
        const self = from(raw);
        const occurrence = self.beginEvent(.control, .control_event, value) orelse return;
        switch (value) {
            .started => |v| self.pushAt(.control, .launch_descriptor, .input, occurrence, codec.launchDescriptor(v)),
            .enter => |v| self.pushAt(.control, .control_call, .input, occurrence, @as(codec.ControlInvocation, .{ .call_id = v.call_id, .call = codec.controlArguments(v.call) })),
            // Dequeue and Close observations are comparison-only. Original UI
            // attempts, not Control results, supply the UI execution transcript.
            .command_dequeued => |v| if (v) |command| if (command.kind == .recover) {
                self.fail();
            },
            else => {},
        }
        self.pushAt(.control, .control_event, .reference, occurrence, value);
    }
    fn onMailbox(raw: *anyopaque, value: codec.mailbox.Checkpoint) void {
        const self = from(raw);
        codec.validateMailboxCheckpoint(value) catch {
            self.fail();
            return;
        };
        const actor = switch (value) {
            .ring => |v| v.role,
            .admission => |v| v.role,
        };
        const role: format.Role = if (actor == .ui) .ui else .control;
        const occurrence = self.beginEvent(role, .mailbox_event, value) orelse return;
        self.pushAt(role, .mailbox_cut, .input, occurrence, codec.mailboxCut(value));
        self.pushAt(role, .mailbox_event, .reference, occurrence, value);
    }
    fn onWorkerGate(raw: *anyopaque, value: codec.mailbox.WorkerGateCheckpoint) void {
        const self = from(raw);
        codec.validateWorkerGateCheckpoint(value) catch {
            self.fail();
            return;
        };
        const role = codec.workerGateRole(value.role);
        self.flushPoints(role);
        const occurrence = self.next() orelse return;
        const points = &self.gate_points[@intFromEnum(role)];
        points.inputs[points.count] = .{ .occurrence = occurrence, .value = codec.workerGateCut(value) };
        points.references[points.count] = .{ .occurrence = occurrence, .value = value };
        points.count += 1;
        if (points.count == codec.max_packet_points) self.flushGatePoints(role);
    }
    fn onUi(raw: *anyopaque, value: semantic.UiEvent) void {
        const self = from(raw);
        const occurrence = self.beginEvent(.ui, .ui_event, value) orelse return;
        switch (value) {
            .enter => |v| self.pushAt(.ui, .ui_call, .input, occurrence, @as(codec.UiInvocation, v)),
            .end => {},
        }
        self.pushAt(.ui, .ui_event, .reference, occurrence, value);
    }
    fn onWorker(raw: *anyopaque, value: semantic.WorkerEvent) void {
        const self = from(raw);
        const occurrence = self.beginEvent(.worker, .worker_event, value) orelse return;
        switch (value) {
            .enter => |v| self.pushAt(.worker, .worker_call, .input, occurrence, v),
            else => {},
        }
        self.pushAt(.worker, .worker_event, .reference, occurrence, value);
    }
    fn onInput(raw: *anyopaque, value: audio.music.trace.Input) void {
        from(raw).push(.control, .public_input, .reference, value);
    }
    fn onSchedule(raw: *anyopaque, value: audio.music.trace.ScheduleEntry) void {
        from(raw).push(.control, .schedule, .reference, value);
    }
    fn onAcceptance(raw: *anyopaque, value: *const stream.LiveAcceptanceAttemptV1, frame: u64) void {
        const self = from(raw);
        if (!value.evidence.representation_complete) {
            self.fail();
            return;
        }
        // These diagnostic arrays are already excluded from the canonical wire.
        // Queue only its owned semantic fields, never a borrowed evidence pointer.
        const compact = codec.packAcceptance(.{ .attempt = value.*, .effective_frame = frame }) catch {
            self.fail();
            return;
        };
        self.push(.control, .acceptance, .reference, compact);
    }
    fn onFrontier(raw: *anyopaque, phase: audio.ControlRuntime.TickPhaseV1, acquired: u64, effective: u64) void {
        from(raw).push(.control, .frontier, .reference, @as(codec.Frontier, .{ .phase = phase, .acquired_frame = acquired, .effective_frame = effective }));
    }
    fn onTick(raw: *anyopaque, value: audio.ControlRuntime.LiveTickEventV1) void {
        from(raw).push(.control, .tick, .reference, value);
    }
    fn onAudio(raw: *anyopaque, value: audio.device.SemanticAudioEvent) void {
        const self = from(raw);
        const occurrence = self.beginEvent(.render, .audio_event, value) orelse return;
        switch (value) {
            .pcm => |v| {
                if (v.samples.len > std.math.maxInt(u32) or v.channels == 0 or v.samples.len % v.channels != 0) {
                    self.fail();
                    return;
                }
                const header: codec.Native(codec.Pcm) = .{ .occurrence = occurrence, .value = .{
                    .disposition = v.disposition,
                    .device_epoch = v.device_epoch,
                    .first_frame = v.first_frame,
                    .channels = v.channels,
                    .samples = @intCast(v.samples.len),
                } };
                // Copy the borrowed samples now. The descriptor retains only
                // byte offsets in owned storage, never the borrowed PCM slice.
                if (!self.capture.lane(.render).push(@intFromEnum(codec.Family.pcm), .reference, std.mem.asBytes(&header), std.mem.sliceAsBytes(v.samples))) self.fail();
            },
            .callback_begin => |v| {
                if (self.callback_thread.load(.monotonic) == 0) self.callback_thread.store(@intCast(std.Thread.getCurrentId()), .release);
                self.pushAt(.render, .callback, .input, occurrence, @as(codec.Callback, .{ .frame_count = v.frame_count, .channels = v.channels, .output_present = v.output_present }));
                self.pushAt(.render, .audio_event, .reference, occurrence, value);
                if (!v.output_present or v.channels != 2) self.fail();
            },
            else => {
                self.pushAt(.render, .audio_event, .reference, occurrence, value);
                switch (value) {
                    .loss_acquired => |loss| if (loss) {
                        self.fail();
                    },
                    .callback_return => |v| if (v.failure != null or v.kind != .completed) {
                        self.fail();
                    },
                    else => {},
                }
            },
        }
    }
    /// One bounded pass; false means all lanes were empty at their individual
    /// acquires, not that any producer has joined. Does not wait for producers.
    pub fn drain(self: *Recorder) Error!bool {
        if (self.streaming_writer != null) return error.InvalidState;
        return self.drainMode(false);
    }
    pub fn drainStreaming(self: *Recorder) !bool {
        if (self.streaming_writer == null) return error.InvalidState;
        return self.drainMode(true);
    }
    fn drainMode(self: *Recorder, comptime streaming: bool) !bool {
        if (comptime builtin.is_test) if (self.test_collector_profile) |profile| return self.drainModeProfiled(streaming, profile);
        if (self.address != self or self.finished) return error.InvalidState;
        if (!self.healthy()) {
            self.poisonOutput();
            return error.Poisoned;
        }
        errdefer {
            self.fail();
            self.poisonOutput();
        }
        var progressed = false;
        // Round-robin bounds a call even while a producer remains active.
        for (&self.capture.lanes) |*lane| {
            const record = try lane.pop(&self.native_scratch) orelse continue;
            try self.observe(record);
            const payload = try codec.encodeNative(record, &self.wire_scratch);
            if (comptime streaming) {
                self.streaming_writer.?.append(record.role, record.ordinal, record.family, record.class, payload) catch |err| {
                    if (self.first_output_error == null) self.first_output_error = err;
                    return err;
                };
            } else {
                try self.writer.append(record.role, record.ordinal, record.family, record.class, payload);
            }
            progressed = true;
        }
        return progressed;
    }
    /// Mirrors the unchanged production path above. Timers are completed on
    /// errors as well as successes; they never change returned errors, poison
    /// behavior, wire bytes, round-robin order, or capture admission.
    fn drainModeProfiled(self: *Recorder, comptime streaming: bool, profile: *collector_profile.Profile) !bool {
        profile.beginPass();
        var success = false;
        var progressed = false;
        defer profile.endPass(success, progressed);
        if (self.address != self or self.finished) return error.InvalidState;
        profile.snapshot(&self.capture, .start);
        profile.snapshot(&self.capture, .periodic);
        errdefer profile.snapshot(&self.capture, .first_failure);
        if (!self.healthy()) {
            self.poisonOutput();
            return error.Poisoned;
        }
        errdefer {
            self.fail();
            self.poisonOutput();
        }
        for (&self.capture.lanes, 0..) |*lane, role| {
            const sampled = profile.sample(role);
            var popped: ?format.NativeRecord = null;
            {
                const token = profile.start(sampled);
                var completed = false;
                defer if (popped) |record| profile.accountRecord(role, record.family, .pop_observe, record.bytes.len);
                defer profile.complete(role, if (popped) |r| r.family else null, .pop_observe, token, completed, if (popped) |r| r.bytes.len else 0);
                popped = lane.pop(&self.native_scratch) catch |err| {
                    profile.popError(role);
                    return err;
                };
                const record = popped orelse {
                    profile.empty(role);
                    completed = true;
                    continue;
                };
                self.observe(record) catch |err| {
                    profile.observeError(role);
                    return err;
                };
                completed = true;
            }
            const record = popped.?;
            const payload = blk: {
                const token = profile.start(sampled);
                var completed = false;
                var bytes: u64 = 0;
                defer profile.complete(role, record.family, .encode, token, completed, bytes);
                const encoded = try codec.encodeNative(record, &self.wire_scratch);
                bytes = encoded.len;
                completed = true;
                break :blk encoded;
            };
            profile.accountRecord(role, record.family, .encode, payload.len);
            {
                const token = profile.start(sampled);
                var completed = false;
                defer profile.complete(role, record.family, .append, token, completed, payload.len);
                if (comptime streaming) {
                    self.streaming_writer.?.append(record.role, record.ordinal, record.family, record.class, payload) catch |err| {
                        if (self.first_output_error == null) self.first_output_error = err;
                        return err;
                    };
                } else {
                    try self.writer.append(record.role, record.ordinal, record.family, record.class, payload);
                }
                completed = true;
            }
            profile.accountRecord(role, record.family, .append, payload.len + format.frame_header_size);
            progressed = true;
        }
        success = true;
        return progressed;
    }
    fn observe(self: *Recorder, r: format.NativeRecord) Error!void {
        const l = &self.lifecycle;
        const family: codec.Family = @enumFromInt(r.family);
        switch (family) {
            .control_event => {
                const event = (try codec.native(semantic.ControlEvent, r.first())).value;
                switch (event) {
                    .started => |v| {
                        if (l.started) return error.InvalidOrder;
                        if (!std.mem.eql(u8, &self.identity.config, &try codec.configHash(v.config))) return error.WrongConfig;
                        if (!std.mem.eql(u8, &self.identity.source, &v.identity.artifact_hash)) return error.WrongSource;
                        l.started = true;
                        l.control_thread = v.thread;
                    },
                    .enter => |v| {
                        if (l.active_call != null or v.call_id == 0) return error.InvalidOrder;
                        l.active_call = v.call;
                    },
                    .result => |v| {
                        const call = l.active_call orelse return error.InvalidOrder;
                        switch (v.value) {
                            .destroyed => |report| {
                                if (report.sample_leases != 0 or report.live_instances != 0) return error.Incomplete;
                                l.owner_destroyed = true;
                            },
                            .device_stopped => l.device_stopped = true,
                            .cleanup_render => |accounting| try self.account(accounting),
                            .done => switch (call) {
                                .provider_release => |counts| {
                                    if (counts.live != 0 or counts.opened != counts.closed) return error.Incomplete;
                                    l.provider_released = true;
                                },
                                .detach_audio => l.audio_detached = true,
                                else => {},
                            },
                            else => {},
                        }
                    },
                    .end => {
                        if (l.active_call == null) return error.InvalidOrder;
                        l.active_call = null;
                    },
                    .ready => |v| {
                        if (!v.attached) return error.Incomplete;
                        l.ready = true;
                    },
                    .close_observed => l.close_observed = true,
                    .worker_joined => l.worker_joined = true,
                    .closed => l.closed = true,
                    .returned => l.returned = true,
                    .control_joined => l.control_joined = true,
                    else => {},
                }
            },
            .ui_event => switch ((try codec.native(semantic.UiEvent, r.first())).value) {
                .enter => |v| {
                    if (l.active_ui != null or l.ui_calls == std.math.maxInt(u64) or v.call_id != l.ui_calls + 1) return error.InvalidOrder;
                    l.ui_calls += 1;
                    l.active_ui = v;
                },
                .end => |v| {
                    const invocation = l.active_ui orelse return error.InvalidOrder;
                    if (invocation.call_id != v.call_id or std.meta.activeTag(invocation.call) != std.meta.activeTag(v.value)) return error.InvalidOrder;
                    switch (v.value) {
                        .submit => |result| if (result) |_| {
                            l.command_submitted = std.math.add(u64, l.command_submitted, 1) catch return error.CounterOverflow;
                        } else |_| {},
                        .pop_event => |event| if (event) |e| {
                            if (e.kind == .terminal) l.command_terminal = std.math.add(u64, l.command_terminal, 1) catch return error.CounterOverflow;
                        },
                        .acknowledge_terminal => |result| if (result) {
                            l.terminal_acknowledged = std.math.add(u64, l.terminal_acknowledged, 1) catch return error.CounterOverflow;
                        } else |_| {},
                        .request_close => {},
                    }
                    l.active_ui = null;
                },
            },
            .worker_event => switch ((try codec.native(semantic.WorkerEvent, r.first())).value) {
                .started => |thread| {
                    if (l.worker_started) return error.InvalidOrder;
                    l.worker_started = true;
                    l.worker_thread = thread;
                },
                .startup_aborted => return error.UnsupportedScope,
                .returned => l.worker_returned = true,
                else => {},
            },
            .source_event => switch ((try codec.native(source.SemanticEvent, r.first())).value) {
                .load_begin => |v| if (!std.mem.eql(u8, &self.identity.source, &v.source_hash)) {
                    return error.WrongSource;
                },
                .load_return => |v| switch (v) {
                    .loaded => |loaded| if (!std.mem.eql(u8, &self.identity.bank, &loaded.bank_hash)) {
                        return error.WrongBank;
                    },
                    .failure => return error.UnsupportedScope,
                },
                else => {},
            },
            .audio_event => switch ((try codec.native(audio.device.SemanticAudioEvent, r.first())).value) {
                .callback_begin => |v| {
                    l.callback_calls = std.math.add(u64, l.callback_calls, 1) catch return error.CounterOverflow;
                    try self.account(v.accounting);
                },
                .callback_return => |v| try self.account(v.accounting),
                .epoch_changed => |v| try self.account(v.accounting),
                else => {},
            },
            .acceptance => {
                const accepted = codec.unpackAcceptance((try codec.native(codec.CompactAcceptance, r.first())).value);
                if (accepted.attempt.evidence.accepted != null) {
                    const tick = accepted.attempt.incoming.control_tick;
                    if (l.acceptance_tick != tick) {
                        l.acceptance_tick = tick;
                        l.acceptance_frame = accepted.effective_frame;
                    } else if (l.acceptance_frame != accepted.effective_frame and l.witnessed_tick != tick) {
                        l.multi_frame_ticks = std.math.add(u64, l.multi_frame_ticks, 1) catch return error.CounterOverflow;
                        l.witnessed_tick = tick;
                    }
                }
            },
            .pcm => {
                const pcm = (try codec.native(codec.Pcm, r.first())).value;
                const i: usize = @intFromEnum(pcm.disposition);
                l.pcm_samples[i] = std.math.add(u64, l.pcm_samples[i], pcm.samples) catch return error.CounterOverflow;
                if (pcm.channels == 0 or pcm.samples % pcm.channels != 0) return error.InvalidLength;
                const frames = pcm.samples / pcm.channels;
                switch (pcm.disposition) {
                    .discarded_pending => l.discarded_pending_frames = std.math.add(u64, l.discarded_pending_frames, frames) catch return error.CounterOverflow,
                    .discarded_generated => l.discarded_generated_frames = std.math.add(u64, l.discarded_generated_frames, frames) catch return error.CounterOverflow,
                    .submitted => {},
                }
            },
            else => {},
        }
    }
    fn account(self: *Recorder, value: audio.device.RuntimeAccounting) Error!void {
        if (value.generated_frames > max_generated_frames) return error.UnsupportedScope;
        self.lifecycle.generated_frames = @max(self.lifecycle.generated_frames, value.generated_frames);
        self.lifecycle.submitted_frames = @max(self.lifecycle.submitted_frames, value.submitted_frames);
    }
    /// A caller assertion is not accepted as a join. Require pinned Host state
    /// plus observed successful teardown and both genuine native join events.
    pub fn finish(self: *Recorder) Error![]const u8 {
        if (self.streaming_writer != null) return error.InvalidState;
        const evidence = try self.finishEvidence(false);
        const bytes = try self.writer.sealFraming(evidence);
        self.finished = true;
        return bytes;
    }
    /// This seals transport framing only. Caller must still flush/close and
    /// publish separately; an error never grants permission to free live roles.
    pub fn finishStreaming(self: *Recorder) !format.StreamSeal {
        if (self.streaming_writer == null) return error.InvalidState;
        const evidence = try self.finishEvidence(true);
        const seal = self.streaming_writer.?.sealFraming(evidence) catch |err| {
            if (self.first_output_error == null) self.first_output_error = err;
            self.fail();
            return err;
        };
        self.finished = true;
        return seal;
    }
    fn finishEvidence(self: *Recorder, comptime streaming: bool) !format.SealEvidence {
        if (self.address != self or self.finished) return error.InvalidState;
        if (self.session.host != null or !self.session.used or self.session.audio_attached or self.session.active_control != null or self.session.active_ui != null) return error.Incomplete;
        if (!self.healthy()) {
            self.poisonOutput();
            return error.Poisoned;
        }
        for (self.points) |points| if (points.envelope != null or points.count != 0) return error.Incomplete;
        // Host exclusion above makes the producer-only buffers safe to flush
        // here. No buffered gate occurrence may disappear at framing seal.
        self.flushGatePoints(.control);
        self.flushGatePoints(.worker);
        while (try self.drainMode(streaming)) {}
        const l = self.lifecycle;
        if (!l.started or !l.worker_started or !l.ready or !l.close_observed or !l.device_stopped or
            !l.owner_destroyed or !l.provider_released or !l.audio_detached or !l.worker_returned or
            !l.worker_joined or !l.closed or !l.returned or !l.control_joined or l.active_call != null or
            l.control_thread == 0 or l.worker_thread == 0 or l.control_thread == l.worker_thread or
            l.active_ui != null or l.ui_calls != self.session.ui_calls or
            l.command_submitted != l.command_terminal or l.command_submitted != l.terminal_acknowledged) return error.Incomplete;
        const callback_thread = self.callback_thread.load(.acquire);
        if ((l.callback_calls == 0) != (callback_thread == 0)) return error.Incomplete;
        if (callback_thread != 0 and (callback_thread == l.control_thread or callback_thread == l.worker_thread)) return error.Incomplete;
        // device_stopped above is the actual backend.stop result, including its
        // real join when a device was started. Zero callbacks invents no join.
        // Host.destroy already excluded future UI calls under the one-UI API;
        // sealing this lane is owner exclusion, not a fictitious UI thread join.
        for (&self.capture.lanes) |*lane| lane.closeAfterJoin();
        return self.capture.sealEvidence();
    }
    /// Called by the sole consumer, after drain, while producers may still run.
    pub fn progress(self: *const Recorder) Progress {
        return .{ .generated_frames = self.lifecycle.generated_frames, .submitted_frames = self.lifecycle.submitted_frames, .discarded_pending_frames = self.lifecycle.discarded_pending_frames, .discarded_generated_frames = self.lifecycle.discarded_generated_frames, .multi_frame_ticks = self.lifecycle.multi_frame_ticks, .control_thread_id = self.lifecycle.control_thread, .worker_thread_id = self.lifecycle.worker_thread, .callback_thread_id = self.callback_thread.load(.acquire) };
    }
    /// Legal only after genuine producer exclusion, just like Lane.finalStats.
    pub fn finalStats(self: *const Recorder) Stats {
        var lanes: [format.role_count]format.LaneStats = undefined;
        for (&self.capture.lanes, 0..) |*lane, i| lanes[i] = lane.finalStats();
        return .{ .allocation_bytes = self.allocation_bytes, .corpus_bytes = if (self.streaming_writer) |writer| @intCast(writer.offset) else self.writer.offset, .occurrences = self.occurrence.load(.acquire), .lanes = lanes, .pcm_samples = self.lifecycle.pcm_samples, .submitted_frames = self.lifecycle.submitted_frames, .generated_frames = self.lifecycle.generated_frames, .discarded_pending_frames = self.lifecycle.discarded_pending_frames, .discarded_generated_frames = self.lifecycle.discarded_generated_frames, .multi_frame_ticks = self.lifecycle.multi_frame_ticks, .control_thread_id = self.lifecycle.control_thread, .worker_thread_id = self.lifecycle.worker_thread, .callback_thread_id = self.callback_thread.load(.acquire), .ui_calls = self.lifecycle.ui_calls, .command_submitted = self.lifecycle.command_submitted, .command_terminal = self.lifecycle.command_terminal, .terminal_acknowledged = self.lifecycle.terminal_acknowledged };
    }
};
comptime {
    if (collector_profile.role_count != format.role_count) @compileError("collector role schema drift");
    const families = std.meta.fields(codec.Family);
    if (families.len != collector_profile.family_codes.len) @compileError("collector family schema drift");
    for (families, collector_profile.family_codes) |family, code| if (family.value != code) @compileError("collector family schema drift");
    if (@sizeOf(Recorder) + default_corpus_bytes > format.max_capture_bytes) @compileError("profile 9 recorder allocation exceeds 64 MiB");
}
