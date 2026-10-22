//! Explicit owned configuration for the finite public V1 consumer.
//! Layer and crossfade binding slices have dedicated owned backing. No future
//! borrowed field is silently accepted: extending its shape requires an explicit
//! ownership edit.
const std = @import("std");
const music = @import("bugu_audio").music;
pub const Config = music.MusicRuntimeConfigV1;
const Capacity = @FieldType(Config, "capacity");
pub const LayerConfig = music.MusicLayerGainConfigV1;
pub const Binding = music.MusicLayerGainBindingV1;
pub const CrossfadeConfig = @FieldType(Config, "crossfade");
pub const CrossfadeBinding = std.meta.Child(@FieldType(CrossfadeConfig, "bindings"));
const Ramps = @FieldType(Binding, "ramps");
const Duration = @FieldType(Ramps, "attack");
const QuarterBeats = @FieldType(Duration, "quarter_beats");

comptime {
    if (std.meta.fields(Config).len != 16 or std.meta.fields(Capacity).len != 11 or
        std.meta.fields(LayerConfig).len != 3 or std.meta.fields(Binding).len != 4 or
        std.meta.fields(CrossfadeConfig).len != 2 or std.meta.fields(CrossfadeBinding).len != 2 or
        std.meta.fields(Ramps).len != 2 or std.meta.fields(Duration).len != 2 or
        std.meta.fields(QuarterBeats).len != 2)
        @compileError("Preview config ownership must be extended for the actual runtime config shape");
    for (.{ "version", "context", "seed", "quantum_frames" }) |name| {
        if (@typeInfo(@FieldType(Config, name)) != .int)
            @compileError("Preview config integer field changed ownership shape");
    }
    for (.{ "kind", "policy_support", "snapshot_profile", "control_driver", "streaming_reservation", "sfx_generation_custody", "streamed_fill_mode" }) |name| {
        if (@typeInfo(@FieldType(Config, name)) != .@"enum")
            @compileError("Preview config enum field changed ownership shape");
    }
    for (.{ "boundary_stop", "preview_seek" }) |name| {
        if (@typeInfo(@FieldType(Config, name)) != .optional or
            @typeInfo(std.meta.Child(@FieldType(Config, name))) != .@"enum")
            @compileError("Preview optional enum ownership shape changed");
    }
    if (@FieldType(Config, "layer_gain") != LayerConfig or
        @FieldType(LayerConfig, "bindings") != []const Binding or
        @FieldType(LayerConfig, "version") != u16 or
        @typeInfo(@FieldType(LayerConfig, "parameter_sampling")) != .@"enum" or
        @typeInfo(@FieldType(Binding, "layer")) != .@"enum" or
        @typeInfo(@FieldType(Binding, "parameter")) != .@"enum" or
        @typeInfo(@FieldType(Binding, "output_policy")) != .@"enum" or
        @FieldType(Ramps, "release") != Duration or
        @FieldType(Duration, "frames") != u64 or
        @FieldType(QuarterBeats, "numerator") != u64 or
        @FieldType(QuarterBeats, "denominator") != u64)
        @compileError("Preview binding ownership requires explicit handling of this shape");
    if (@FieldType(CrossfadeConfig, "version") != u16 or
        @FieldType(CrossfadeConfig, "bindings") != []const CrossfadeBinding or
        @FieldType(CrossfadeBinding, "transition_id") != u64 or
        @typeInfo(@FieldType(CrossfadeBinding, "curve")) != .@"enum")
        @compileError("Preview crossfade ownership requires explicit handling of this shape");
    for (std.meta.fields(Capacity)) |field| {
        if (@typeInfo(field.type) != .int)
            @compileError("Preview capacity ownership must be handled explicitly");
    }
}

/// The only slices installed here use the explicitly supplied owned backing.
/// Every current field is enumerated; unknown fields require a source change.
fn copyWithBindings(value: Config, owned_bindings: []const Binding, owned_crossfades: []const CrossfadeBinding) Config {
    return .{
        .version = value.version,
        .context = value.context,
        .kind = value.kind,
        .seed = value.seed,
        .quantum_frames = value.quantum_frames,
        .capacity = .{
            .request_slots = value.capacity.request_slots,
            .reserved_request_slots = value.capacity.reserved_request_slots,
            .receipt_slots = value.capacity.receipt_slots,
            .load_slots = value.capacity.load_slots,
            .snapshot_slots = value.capacity.snapshot_slots,
            .borrowed_sound_lease_slots = value.capacity.borrowed_sound_lease_slots,
            .trace_input_slots = value.capacity.trace_input_slots,
            .trace_event_slots = value.capacity.trace_event_slots,
            .max_in_flight_requests = value.capacity.max_in_flight_requests,
            .music_request_drain = value.capacity.music_request_drain,
            .max_bank_bytes = value.capacity.max_bank_bytes,
        },
        .policy_support = value.policy_support,
        .snapshot_profile = value.snapshot_profile,
        .layer_gain = .{
            .version = value.layer_gain.version,
            .bindings = owned_bindings,
            .parameter_sampling = value.layer_gain.parameter_sampling,
        },
        .crossfade = .{
            .version = value.crossfade.version,
            .bindings = owned_crossfades,
        },
        .sfx_generation_custody = value.sfx_generation_custody,
        .control_driver = value.control_driver,
        .streaming_reservation = value.streaming_reservation,
        .streamed_fill_mode = value.streamed_fill_mode,
        .boundary_stop = value.boundary_stop,
        .preview_seek = value.preview_seek,
    };
}

/// Validation returns a call-bounded view only. Persistence requires Owned.create,
/// which copies the binding storage before any owner/Worker can retain it.
pub fn resolve(context: u64, seed: u64, explicit: ?Config) !Config {
    const value = explicit orelse Config{
        .context = context,
        .seed = seed,
        .kind = .offline,
        .control_driver = .integrated,
        .quantum_frames = 256,
    };
    if (value.context != context or value.seed != seed) return error.PreviewConfigIdentityMismatch;
    if (value.kind != .offline or value.control_driver != .integrated or value.quantum_frames != 256)
        return error.UnsupportedPreviewConfig;
    try value.validate();
    return value;
}

/// A stable owner is retained by Session until real cleanup succeeds. Capture
/// owns a separate allocation, so its configuration outlives Session teardown.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    value: Config,
    pub fn create(allocator: std.mem.Allocator, value: Config) !*Owned {
        try value.validate();
        const result = try allocator.create(Owned);
        errdefer allocator.destroy(result);
        const bindings = try allocator.alloc(Binding, value.layer_gain.bindings.len);
        errdefer allocator.free(bindings);
        for (bindings, value.layer_gain.bindings) |*destination, binding| destination.* = .{
            .layer = binding.layer,
            .parameter = binding.parameter,
            .ramps = .{ .attack = copyDuration(binding.ramps.attack), .release = copyDuration(binding.ramps.release) },
            .output_policy = binding.output_policy,
        };
        const crossfades = try allocator.alloc(CrossfadeBinding, value.crossfade.bindings.len);
        for (crossfades, value.crossfade.bindings) |*destination, binding| destination.* = .{
            .transition_id = binding.transition_id,
            .curve = binding.curve,
        };
        result.* = .{ .allocator = allocator, .value = copyWithBindings(value, bindings, crossfades) };
        return result;
    }
    pub fn clone(self: *const Owned) !*Owned {
        return create(self.allocator, self.value);
    }
    pub fn destroy(self: *Owned) void {
        const allocator = self.allocator;
        allocator.free(self.value.layer_gain.bindings);
        allocator.free(self.value.crossfade.bindings);
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn copyDuration(value: Duration) Duration {
    return switch (value) {
        .frames => |frames| .{ .frames = frames },
        .quarter_beats => |beats| .{ .quarter_beats = .{ .numerator = beats.numerator, .denominator = beats.denominator } },
    };
}
fn equalDuration(left: Duration, right: Duration) bool {
    return switch (left) {
        .frames => |frames| right == .frames and frames == right.frames,
        .quarter_beats => |beats| right == .quarter_beats and beats.numerator == right.quarter_beats.numerator and beats.denominator == right.quarter_beats.denominator,
    };
}
/// Value comparison, never pointer equality for independent binding storage.
pub fn equal(left: Config, right: Config) bool {
    if (left.version != right.version or left.context != right.context or left.kind != right.kind or
        left.seed != right.seed or left.quantum_frames != right.quantum_frames or
        !std.meta.eql(left.capacity, right.capacity) or left.policy_support != right.policy_support or
        left.snapshot_profile != right.snapshot_profile or
        left.control_driver != right.control_driver or left.streaming_reservation != right.streaming_reservation or
        left.sfx_generation_custody != right.sfx_generation_custody or
        left.streamed_fill_mode != right.streamed_fill_mode or
        left.boundary_stop != right.boundary_stop or left.preview_seek != right.preview_seek or
        left.layer_gain.version != right.layer_gain.version or
        left.layer_gain.parameter_sampling != right.layer_gain.parameter_sampling or
        left.layer_gain.bindings.len != right.layer_gain.bindings.len or
        left.crossfade.version != right.crossfade.version or
        left.crossfade.bindings.len != right.crossfade.bindings.len) return false;
    for (left.layer_gain.bindings, right.layer_gain.bindings) |l, r| {
        if (l.layer != r.layer or l.parameter != r.parameter or l.output_policy != r.output_policy or
            !equalDuration(l.ramps.attack, r.ramps.attack) or !equalDuration(l.ramps.release, r.ramps.release)) return false;
    }
    for (left.crossfade.bindings, right.crossfade.bindings) |l, r| {
        if (l.transition_id != r.transition_id or l.curve != r.curve) return false;
    }
    return true;
}
