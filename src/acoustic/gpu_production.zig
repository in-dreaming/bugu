//! Non-owning GPU acoustic submission contract and bounded async response ring.
//! The embedding engine owns the device, queue, command submission, and fences.
const std = @import("std");

pub const readback_slots = 3;
pub const max_batch = 32;

pub const Identity = extern struct {
    request_id: u64,
    source_id: u64,
    listener_id: u64,
    scene_id: u64,
    source_generation: u32,
    listener_generation: u32,
    scene_generation: u32,
    dynamic_generation: u32,
    device_generation: u32,
};

pub const PackedRequest = extern struct {
    identity: Identity,
    values: [40]f32,
};

pub const PackedResponse = extern struct {
    identity: Identity,
    direct_gain: f32,
    transmission_gain: f32,
    portal_gain: f32,
    portal_direction: [3]f32,
    openness: f32,
    confidence: f32,
    direct_lowpass_hz: f32,
};

pub const SubmitStatus = enum(u8) { success, unsupported, queue_full, device_lost, failure };
pub const PollStatus = enum(u8) { pending, ready, unsupported, device_lost, failure };

pub const ExternalComputeVTable = struct {
    submit: *const fn (*anyopaque, u8, u64, []const PackedRequest) SubmitStatus,
    poll: *const fn (*anyopaque, u8, u64, []PackedResponse, *usize) PollStatus,
    discard: *const fn (*anyopaque, u8, u64) void,
    device_generation: *const fn (*anyopaque) u32,
};

pub const ExternalComputeContext = struct {
    context: *anyopaque,
    vtable: *const ExternalComputeVTable,
};

pub const ResultStatus = enum(u8) { none, submitted, ready, overdue, stale, unsupported, overflow, device_lost, failure };
pub const PollResult = struct { status: ResultStatus = .none, count: usize = 0, age_frames: u32 = 0, confidence_scale: f32 = 1 };

const SlotState = enum(u8) { free, in_flight };
const Slot = struct {
    state: SlotState = .free,
    sequence: u64 = 0,
    submit_frame: u64 = 0,
    generation: u64 = 0,
    device_generation: u32 = 0,
    count: usize = 0,
    overdue_reported: bool = false,
    identities: [max_batch]Identity = undefined,
};

pub const ResponseReadbackRing = struct {
    executor: ExternalComputeContext,
    max_latency_frames: u32,
    slots: [readback_slots]Slot = [_]Slot{.{}} ** readback_slots,
    next_sequence: u64 = 1,
    next_generation: u64 = 1,

    pub fn init(executor: ExternalComputeContext, max_latency_frames: u32) !ResponseReadbackRing {
        if (max_latency_frames == 0 or executor.vtable.device_generation(executor.context) == 0) return error.InvalidExternalComputeContext;
        return .{ .executor = executor, .max_latency_frames = max_latency_frames };
    }

    /// Control/GPU-executor thread only. Never call from the PCM callback.
    pub fn submit(self: *ResponseReadbackRing, frame: u64, requests: []const PackedRequest) ResultStatus {
        if (requests.len == 0 or requests.len > max_batch) return .failure;
        const index = self.freeSlot() orelse return .overflow;
        const generation = self.takeGeneration();
        const status = self.executor.vtable.submit(self.executor.context, @intCast(index), generation, requests);
        switch (status) {
            .success => {},
            .unsupported => return .unsupported,
            .queue_full => return .overflow,
            .device_lost => return .device_lost,
            .failure => return .failure,
        }
        const slot = &self.slots[index];
        slot.* = .{
            .state = .in_flight,
            .sequence = self.takeSequence(),
            .submit_frame = frame,
            .generation = generation,
            .device_generation = self.executor.vtable.device_generation(self.executor.context),
            .count = requests.len,
        };
        for (requests, slot.identities[0..requests.len]) |item, *identity| identity.* = item.identity;
        return .submitted;
    }

    /// Control/GPU-executor thread only. Polls only results at least one frame
    /// old; the external executor may map only data already reported complete.
    pub fn poll(self: *ResponseReadbackRing, frame: u64, output: []PackedResponse) PollResult {
        const index = self.oldestSlot() orelse return .{};
        const slot = &self.slots[index];
        if (frame <= slot.submit_frame) return .{};
        const age: u32 = @intCast(@min(frame - slot.submit_frame, std.math.maxInt(u32)));
        if (slot.device_generation != self.executor.vtable.device_generation(self.executor.context)) {
            self.executor.vtable.discard(self.executor.context, @intCast(index), slot.generation);
            slot.state = .free;
            return .{ .status = .device_lost, .age_frames = age, .confidence_scale = 0 };
        }
        if (output.len < slot.count) return .{ .status = .failure, .age_frames = age, .confidence_scale = 0 };
        var count: usize = 0;
        const status = self.executor.vtable.poll(self.executor.context, @intCast(index), slot.generation, output[0..slot.count], &count);
        switch (status) {
            .pending => {
                if (age > self.max_latency_frames and !slot.overdue_reported) {
                    slot.overdue_reported = true;
                    return .{ .status = .overdue, .age_frames = age, .confidence_scale = 0.5 };
                }
                return .{};
            },
            .unsupported => {
                slot.state = .free;
                return .{ .status = .unsupported, .age_frames = age, .confidence_scale = 0 };
            },
            .device_lost => {
                slot.state = .free;
                return .{ .status = .device_lost, .age_frames = age, .confidence_scale = 0 };
            },
            .failure => {
                slot.state = .free;
                return .{ .status = .failure, .age_frames = age, .confidence_scale = 0 };
            },
            .ready => {},
        }
        defer slot.state = .free;
        if (count != slot.count) return .{ .status = .stale, .age_frames = age, .confidence_scale = 0 };
        for (output[0..count], slot.identities[0..count]) |response, identity| {
            if (!identityEqual(response.identity, identity) or !validResponse(response)) return .{ .status = .stale, .age_frames = age, .confidence_scale = 0 };
        }
        if (slot.overdue_reported or age > self.max_latency_frames) return .{ .status = .stale, .age_frames = age, .confidence_scale = 0 };
        return .{ .status = .ready, .count = count, .age_frames = age, .confidence_scale = if (age == 1) 1 else 0.8 };
    }

    pub fn inFlight(self: *const ResponseReadbackRing) usize {
        var result: usize = 0;
        for (self.slots) |slot| result += @intFromBool(slot.state == .in_flight);
        return result;
    }

    fn freeSlot(self: *ResponseReadbackRing) ?usize {
        for (&self.slots, 0..) |*slot, index| if (slot.state == .free) return index;
        return null;
    }

    fn oldestSlot(self: *ResponseReadbackRing) ?usize {
        var found: ?usize = null;
        for (self.slots, 0..) |slot, index| if (slot.state == .in_flight and (found == null or slot.sequence < self.slots[found.?].sequence)) {
            found = index;
        };
        return found;
    }

    fn takeSequence(self: *ResponseReadbackRing) u64 {
        const result = self.next_sequence;
        self.next_sequence +%= 1;
        if (self.next_sequence == 0) self.next_sequence = 1;
        return result;
    }

    fn takeGeneration(self: *ResponseReadbackRing) u64 {
        const result = self.next_generation;
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        return result;
    }
};

fn validResponse(value: PackedResponse) bool {
    return std.math.isFinite(value.direct_gain) and value.direct_gain >= 0 and value.direct_gain <= 1 and
        std.math.isFinite(value.transmission_gain) and value.transmission_gain >= 0 and value.transmission_gain <= 1 and
        std.math.isFinite(value.portal_gain) and value.portal_gain >= 0 and value.portal_gain <= 1 and
        std.math.isFinite(value.openness) and value.openness >= 0 and value.openness <= 1 and
        std.math.isFinite(value.confidence) and value.confidence >= 0 and value.confidence <= 1 and
        std.math.isFinite(value.portal_direction[0]) and std.math.isFinite(value.portal_direction[1]) and std.math.isFinite(value.portal_direction[2]) and
        std.math.isFinite(value.direct_lowpass_hz) and value.direct_lowpass_hz >= 20;
}

fn identityEqual(a: Identity, b: Identity) bool {
    return a.request_id == b.request_id and a.source_id == b.source_id and a.listener_id == b.listener_id and
        a.scene_id == b.scene_id and a.source_generation == b.source_generation and
        a.listener_generation == b.listener_generation and a.scene_generation == b.scene_generation and
        a.dynamic_generation == b.dynamic_generation and a.device_generation == b.device_generation;
}

const FakeSubmission = struct { generation: u64, count: usize, identities: [max_batch]Identity };

const Fake = struct {
    generation: u32 = 1,
    ready: bool = false,
    corrupt: bool = false,
    submitted: [readback_slots]?FakeSubmission = [_]?FakeSubmission{null} ** readback_slots,

    fn context(self: *Fake) ExternalComputeContext {
        return .{ .context = self, .vtable = &.{ .submit = submit, .poll = poll, .discard = discard, .device_generation = deviceGeneration } };
    }
    fn submit(raw: *anyopaque, slot: u8, generation: u64, requests: []const PackedRequest) SubmitStatus {
        const self: *Fake = @ptrCast(@alignCast(raw));
        var value: @TypeOf(self.submitted[0].?) = .{ .generation = generation, .count = requests.len, .identities = undefined };
        for (requests, value.identities[0..requests.len]) |item, *identity| identity.* = item.identity;
        self.submitted[slot] = value;
        return .success;
    }
    fn poll(raw: *anyopaque, slot: u8, generation: u64, output: []PackedResponse, count: *usize) PollStatus {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (!self.ready) return .pending;
        const submitted = self.submitted[slot] orelse return .failure;
        if (submitted.generation != generation) return .failure;
        for (output[0..submitted.count], submitted.identities[0..submitted.count]) |*response, identity| response.* = .{ .identity = identity, .direct_gain = 0.5, .transmission_gain = 0.1, .portal_gain = 0.2, .portal_direction = .{ 1, 0, 0 }, .openness = 0.8, .confidence = 0.9, .direct_lowpass_hz = 12_000 };
        if (self.corrupt) output[0].identity.scene_generation += 1;
        count.* = submitted.count;
        self.submitted[slot] = null;
        return .ready;
    }
    fn deviceGeneration(raw: *anyopaque) u32 {
        const self: *Fake = @ptrCast(@alignCast(raw));
        return self.generation;
    }
    fn discard(raw: *anyopaque, slot: u8, generation: u64) void {
        const self: *Fake = @ptrCast(@alignCast(raw));
        if (self.submitted[slot]) |submitted| if (submitted.generation == generation) {
            self.submitted[slot] = null;
        };
    }
};

fn request(id: u64) PackedRequest {
    return .{ .identity = .{ .request_id = id, .source_id = id + 10, .listener_id = 20, .scene_id = 30, .source_generation = 1, .listener_generation = 2, .scene_generation = 3, .dynamic_generation = 4, .device_generation = 1 }, .values = [_]f32{0} ** 40 };
}

test "C ABI packed request and response layout is stable" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Identity));
    try std.testing.expectEqual(@as(usize, 216), @sizeOf(PackedRequest));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(PackedResponse));
}

test "external GPU ring protects three in-flight slots and consumes N-1" {
    var fake: Fake = .{};
    var ring = try ResponseReadbackRing.init(fake.context(), 2);
    const batch = [_]PackedRequest{request(1)};
    try std.testing.expectEqual(ResultStatus.submitted, ring.submit(1, &batch));
    try std.testing.expectEqual(ResultStatus.submitted, ring.submit(1, &batch));
    try std.testing.expectEqual(ResultStatus.submitted, ring.submit(1, &batch));
    try std.testing.expectEqual(ResultStatus.overflow, ring.submit(1, &batch));
    var output: [max_batch]PackedResponse = undefined;
    try std.testing.expectEqual(ResultStatus.none, ring.poll(1, &output).status);
    fake.ready = true;
    const result = ring.poll(2, &output);
    try std.testing.expectEqual(ResultStatus.ready, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expectEqual(@as(usize, 2), ring.inFlight());
}

test "late identity and device changes never publish a response" {
    var fake: Fake = .{};
    var ring = try ResponseReadbackRing.init(fake.context(), 2);
    const batch = [_]PackedRequest{request(1)};
    try std.testing.expectEqual(ResultStatus.submitted, ring.submit(1, &batch));
    var output: [max_batch]PackedResponse = undefined;
    try std.testing.expectEqual(ResultStatus.overdue, ring.poll(4, &output).status);
    fake.ready = true;
    try std.testing.expectEqual(ResultStatus.stale, ring.poll(5, &output).status);
    try std.testing.expectEqual(ResultStatus.submitted, ring.submit(6, &batch));
    fake.generation += 1;
    try std.testing.expectEqual(ResultStatus.device_lost, ring.poll(7, &output).status);
    fake.generation = 1;
    fake.corrupt = true;
    try std.testing.expectEqual(ResultStatus.submitted, ring.submit(8, &batch));
    try std.testing.expectEqual(ResultStatus.stale, ring.poll(9, &output).status);
}
