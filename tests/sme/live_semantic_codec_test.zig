//! Dedicated root: imports the production owner's single codec identity.
const std = @import("std");
const live = @import("sme-author-live-owner");
const codec = live.semantic_recording.codec;
const f = codec.format;
const t = std.testing;
fn identity() f.Identity {
    return .{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) };
}
fn frameTape(out: []u8, input: []const u8, reference: []const u8, role: f.Role) ![]const u8 {
    var writer = try f.Writer.init(out, identity(), codec.validate);
    try writer.append(role, 1, @intFromEnum(codec.Family.point_packet_input), .input, input);
    try writer.append(role, 2, @intFromEnum(codec.Family.point_packet_reference), .reference, reference);
    var counts: [f.role_count]u64 = @splat(0);
    counts[@intFromEnum(role)] = 2;
    return writer.sealFraming(.{ .healthy = true, .closed_roles = @splat(true), .role_counts = counts });
}
fn point(site: codec.cuts.Site, role: f.Role, edge: codec.cuts.Edge, index: u64, generation: u64) codec.Cut {
    return .{ .role = role, .site = site, .edge = edge, .index = index, .generation = generation };
}
fn end(value: codec.Cut) codec.Cut {
    var result = value;
    result.edge = .after;
    return result;
}

test "production codec roundtrips nonexhaustive identities and rejects malformed primitives" {
    const Id = enum(u64) { _ };
    const Value = struct { identity: Id, present: bool };
    const original: Value = .{ .identity = @enumFromInt(0xabcdef0123456789), .present = true };
    var bytes: [128]u8 = undefined;
    const encoded = try codec.encode(original, .input, &bytes);
    try t.expectEqualDeep(original, try codec.decode(Value, encoded));
    bytes[8] = 2;
    try t.expectError(error.InvalidBoolean, codec.decode(Value, encoded));
    const Enum = enum(u8) { a, b };
    var e: f.Encoder = .{ .bytes = &bytes };
    try e.int(u64, 2);
    try t.expectError(error.InvalidEnum, codec.decode(Enum, e.result()));
    try t.expectError(error.ErrorInput, codec.encode(@as(error{Bad}, error.Bad), .input, &bytes));
    try t.expectError(error.BorrowedValue, codec.encode(@as([]const u8, "borrowed"), .input, &bytes));
    try t.expect(!codec.validate(@intFromEnum(codec.Family.point_packet_input), .reference));
    try t.expect(!codec.validate(@intFromEnum(codec.Family.point_packet_reference), .input));
}

test "maximum packet expands ordered independent input and reference cursors and survives value copies" {
    const inputs = try t.allocator.alloc(codec.PacketInput, codec.max_packet_points);
    defer t.allocator.free(inputs);
    const references = try t.allocator.alloc(codec.PacketReference, codec.max_packet_points);
    defer t.allocator.free(references);
    for (inputs, references, 0..) |*input, *reference, i| {
        input.* = .{ .occurrence = i + 1, .site = .service_worker_scan, .edge = if (i % 2 == 0) .before else .after, .index = i / 2, .generation = 0 };
        reference.* = .{ .input = input.*, .value = if (i % 2 == 0) null else @intFromEnum(codec.stream.observation.JobState.queued) };
    }
    const in_bytes = try t.allocator.alloc(u8, f.max_payload);
    defer t.allocator.free(in_bytes);
    const ref_bytes = try t.allocator.alloc(u8, f.max_payload);
    defer t.allocator.free(ref_bytes);
    const corpus = try t.allocator.alloc(u8, f.max_payload);
    defer t.allocator.free(corpus);
    const input_payload = try codec.encodePointInputs(.worker, inputs, in_bytes);
    const reference_payload = try codec.encodePointReferences(.worker, references, ref_bytes);
    try t.expectEqual(@as(usize, 4227), input_payload.len);
    try t.expectEqual(@as(usize, 5251), reference_payload.len);
    const reader = try f.Reader.preflight(try frameTape(corpus, input_payload, reference_payload, .worker), identity(), codec.validate);
    var input = codec.InputCursor.init(&reader, .worker);
    var comparison = codec.ComparisonCursor.init(&reader, .worker);
    for (inputs, 0..) |expected, i| {
        const marker = try codec.decodeInput(codec.EventCut, (try input.next()).?, .event_cut);
        try t.expectEqual(expected.occurrence, marker.occurrence);
        try t.expectEqual(codec.Family.cut_fact, marker.value.family);
        if (i == 255) {
            var copied = input;
            const coordinate = try codec.decodeInput(codec.Cut, (try copied.next()).?, .cut);
            try t.expectEqual(expected.occurrence, coordinate.occurrence);
            // Advancing the original cannot mutate copied pending/packet state.
            var second_copy = copied;
            const next_marker = try codec.decodeInput(codec.EventCut, (try second_copy.next()).?, .event_cut);
            try t.expectEqual(expected.occurrence + 1, next_marker.occurrence);
        }
        const coordinate = try codec.decodeInput(codec.Cut, (try input.next()).?, .cut);
        try t.expectEqual(expected.occurrence, coordinate.occurrence);
        try t.expectEqual(expected.index, coordinate.value.index);
        const reference = (try comparison.next()).?;
        const decoded = try codec.decode(codec.Native(codec.cuts.Point), reference.bytes);
        try t.expectEqual(expected.occurrence, decoded.occurrence);
        try t.expectEqual(expected.index, decoded.value.index);
        try t.expectEqual(references[i].value, decoded.value.value);
        var native: codec.Native(codec.cuts.Point) = .{ .occurrence = expected.occurrence, .value = .{ .role = .worker, .site = expected.site, .edge = expected.edge, .index = expected.index, .generation = expected.generation, .value = references[i].value } };
        var scratch: [128]u8 = undefined;
        const actual = try codec.encodeNative(.{ .role = .worker, .ordinal = 1, .family = @intFromEnum(codec.Family.cut_fact), .class = .reference, .bytes = std.mem.asBytes(&native), .first_len = @sizeOf(@TypeOf(native)) }, &scratch);
        try t.expectEqualSlices(u8, reference.bytes, actual);
    }
    try input.finish();
    try comparison.finish();
    // Framing + a valid packet cannot substitute for actual Host lifecycle.
    try t.expectError(error.Incomplete, codec.validateInputs(&reader, identity()));
}

test "packet readers reject invalid counts enum fields values and trailing payloads" {
    var in_bytes: [128]u8 = undefined;
    var ref_bytes: [128]u8 = undefined;
    var corpus: [2048]u8 = undefined;
    const input: codec.PacketInput = .{ .occurrence = 1, .site = .service_worker_scan, .edge = .after, .index = 0, .generation = 0 };
    const reference: codec.PacketReference = .{ .input = input, .value = @intFromEnum(codec.stream.observation.JobState.running) };
    const input_payload = try codec.encodePointInputs(.worker, &.{input}, &in_bytes);
    const reference_payload = try codec.encodePointReferences(.worker, &.{reference}, &ref_bytes);
    try t.expectError(error.InvalidLength, codec.encodePointInputs(.worker, &.{}, &in_bytes));
    try t.expectError(error.UnsupportedValue, codec.encodePointInputs(.control, &.{input}, &in_bytes));
    _ = try codec.encodePointInputs(.worker, &.{input}, &in_bytes);
    in_bytes[0] = 0;
    var reader = try f.Reader.preflight(try frameTape(&corpus, input_payload, reference_payload, .worker), identity(), codec.validate);
    var cursor = codec.InputCursor.init(&reader, .worker);
    try t.expectError(error.InvalidLength, cursor.next());
    _ = try codec.encodePointInputs(.worker, &.{input}, &in_bytes);
    in_bytes[3] = 0xff;
    in_bytes[4] = 0xff;
    reader = try f.Reader.preflight(try frameTape(&corpus, input_payload, reference_payload, .worker), identity(), codec.validate);
    cursor = codec.InputCursor.init(&reader, .worker);
    try t.expectError(error.InvalidEnum, cursor.next());
    _ = try codec.encodePointInputs(.worker, &.{input}, &in_bytes);
    ref_bytes[9] = 2;
    reader = try f.Reader.preflight(try frameTape(&corpus, input_payload, reference_payload, .worker), identity(), codec.validate);
    var comparison = codec.ComparisonCursor.init(&reader, .worker);
    try t.expectError(error.InvalidBoolean, comparison.next());
    _ = try codec.encodePointReferences(.worker, &.{reference}, &ref_bytes);
    ref_bytes[10] = 2;
    reader = try f.Reader.preflight(try frameTape(&corpus, input_payload, reference_payload, .worker), identity(), codec.validate);
    comparison = codec.ComparisonCursor.init(&reader, .worker);
    try t.expectError(error.Noncanonical, comparison.next());
    try t.expectError(error.InvalidEnum, codec.encodePointReferences(.worker, &.{.{ .input = input, .value = 99 }}, &ref_bytes));
    _ = try codec.encodePointReferences(.worker, &.{reference}, &ref_bytes);
    reader = try f.Reader.preflight(try frameTape(&corpus, input_payload, ref_bytes[0 .. reference_payload.len + 1], .worker), identity(), codec.validate);
    comparison = codec.ComparisonCursor.init(&reader, .worker);
    try t.expectError(error.InvalidLength, comparison.next());
}

test "same-slot atomic crossings fail in both orders but coarse and different-slot crossings remain admissible" {
    inline for (.{
        .{ codec.cuts.Site.service_worker_scan, f.Role.worker, codec.cuts.Site.service_job_queued, f.Role.control },
        .{ codec.cuts.Site.service_acceptance_scan, f.Role.control, codec.cuts.Site.service_worker_completed, f.Role.worker },
        .{ codec.cuts.Site.service_slot_guard_render_claim, f.Role.render, codec.cuts.Site.service_slot_guard_open, f.Role.control },
        .{ codec.cuts.Site.service_slot_guard_render_release, f.Role.render, codec.cuts.Site.service_slot_guard_close, f.Role.control },
    }) |case| {
        const read = point(case[0], case[1], .before, 7, 0);
        const publication = point(case[2], case[3], .before, 7, 12);
        var intervals: codec.ScanIntervals = .{};
        try intervals.point(read);
        try t.expectError(error.CrossedScan, intervals.point(publication));
        try t.expectError(error.Incomplete, intervals.finish());
        try t.expectError(error.InvalidOrder, intervals.point(read));
        var wrong = end(read);
        wrong.generation += 1;
        try t.expectError(error.InvalidOrder, intervals.point(wrong));
        try intervals.point(end(read));
        try t.expectError(error.InvalidOrder, intervals.point(end(read)));
        try intervals.finish();
        intervals = .{};
        try intervals.point(publication);
        try t.expectError(error.CrossedScan, intervals.point(read));
        try intervals.point(end(publication));
        try intervals.finish();
        intervals = .{};
        var other_slot = publication;
        other_slot.index += 1;
        try intervals.point(read);
        try intervals.point(other_slot);
        try intervals.point(end(read));
        try intervals.point(end(other_slot));
        try intervals.finish();
    }
    var intervals: codec.ScanIntervals = .{};
    const boundary: codec.Boundary = .{ .role = .worker, .site = .service_worker_scan, .edge = .before, .index = 48, .generation = 0 };
    try intervals.boundary(boundary);
    const publication = point(.service_job_queued, .control, .before, 7, 12);
    try intervals.point(publication);
    try intervals.point(end(publication));
    var after = boundary;
    after.edge = .after;
    try intervals.boundary(after);
    try intervals.finish();
    const scheduler: codec.Boundary = .{ .role = .render, .site = .scheduler_acquire_scan, .edge = .before, .index = 1, .generation = 256 };
    try intervals.boundary(scheduler);
    try t.expectError(error.CrossedScan, intervals.point(point(.scheduler_publication, .control, .before, 0, 1)));
}

test "finite Service grammar requires complete ordered slot reads and consumed guard custody" {
    var grammar: codec.ServiceScanGrammar = .{ .jobs = 2, .streams = 2 };
    const worker: codec.Boundary = .{ .role = .worker, .site = .service_worker_scan, .edge = .before, .index = 2, .generation = 0 };
    try grammar.boundary(worker);
    var after = worker;
    after.edge = .after;
    try t.expectError(error.Incomplete, grammar.boundary(after));
    try t.expectError(error.InvalidOrder, grammar.other(.worker));
    for (0..2) |i| {
        const read = point(.service_worker_scan, .worker, .before, i, 0);
        try grammar.point(read);
        try t.expectError(error.InvalidOrder, grammar.point(read));
        try grammar.point(end(read));
    }
    try grammar.boundary(after);
    try grammar.finish();
    try t.expectError(error.InvalidOrder, grammar.point(point(.service_worker_scan, .worker, .before, 0, 0)));
    const render: codec.Boundary = .{ .role = .render, .site = .service_render_consumed_prefix, .edge = .before, .index = 256, .generation = 3 };
    try grammar.boundary(render);
    const claim = point(.service_slot_guard_render_claim, .render, .before, 0, 0);
    try grammar.point(claim);
    try grammar.point(end(claim));
    const consumed = point(.service_render_consumed, .render, .before, 0, 7);
    try grammar.point(consumed);
    try grammar.point(end(consumed));
    const release = point(.service_slot_guard_render_release, .render, .before, 0, 7);
    try grammar.point(release);
    try grammar.point(end(release));
    var failed_claim = claim;
    failed_claim.index = 1;
    try grammar.point(failed_claim);
    try grammar.point(end(failed_claim));
    after = render;
    after.edge = .after;
    try grammar.boundary(after);
    try grammar.finish();
}

test "ordinary point packets preserve wide coordinates and mixed same-role event ordering" {
    var corpus: [4096]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var writer = try f.Writer.init(&corpus, identity(), codec.validate);
    const first: codec.PacketInput = .{ .occurrence = 5, .site = .runtime_render_frame, .edge = .before, .index = (@as(u64, 1) << 50) + 7, .generation = 9 };
    const last: codec.PacketInput = .{ .occurrence = 12, .site = .runtime_render_frame, .edge = .after, .index = first.index, .generation = 9 };
    try writer.append(.render, 1, @intFromEnum(codec.Family.point_packet_input), .input, try codec.encodePointInputs(.render, &.{first}, &scratch));
    try writer.append(.render, 2, @intFromEnum(codec.Family.point_packet_reference), .reference, try codec.encodePointReferences(.render, &.{.{ .input = first, .value = null }}, &scratch));
    const boundary: codec.Native(codec.EventCut) = .{ .occurrence = 9, .value = .{ .family = .boundary_fact, .tag = 0 } };
    try writer.append(.render, 3, @intFromEnum(codec.Family.event_cut), .input, try codec.encode(boundary, .input, &scratch));
    try writer.append(.render, 4, @intFromEnum(codec.Family.point_packet_input), .input, try codec.encodePointInputs(.render, &.{last}, &scratch));
    try writer.append(.render, 5, @intFromEnum(codec.Family.point_packet_reference), .reference, try codec.encodePointReferences(.render, &.{.{ .input = last, .value = std.math.maxInt(u64) }}, &scratch));
    const bytes = try writer.sealFraming(.{ .healthy = true, .closed_roles = @splat(true), .role_counts = .{ 0, 0, 5, 0 } });
    const reader = try f.Reader.preflight(bytes, identity(), codec.validate);
    var cursor = codec.InputCursor.init(&reader, .render);
    try t.expectEqual(@as(u64, 5), (try codec.decodeInput(codec.EventCut, (try cursor.next()).?, .event_cut)).occurrence);
    try t.expectEqual(first.index, (try codec.decodeInput(codec.Cut, (try cursor.next()).?, .cut)).value.index);
    try t.expectEqual(@as(u64, 9), (try codec.decodeInput(codec.EventCut, (try cursor.next()).?, .event_cut)).occurrence);
    try t.expectEqual(@as(u64, 12), (try codec.decodeInput(codec.EventCut, (try cursor.next()).?, .event_cut)).occurrence);
    var copied = cursor;
    try t.expectError(error.TrailingBytes, copied.finish());
    try t.expectEqual(last.index, (try codec.decodeInput(codec.Cut, (try cursor.next()).?, .cut)).value.index);
    try cursor.finish();
    var comparison = codec.ComparisonCursor.init(&reader, .render);
    try t.expectEqual(@as(u64, 5), (try codec.decode(codec.Native(codec.cuts.Point), (try comparison.next()).?.bytes)).occurrence);
    var copied_comparison = comparison;
    const copied_value = try codec.decode(codec.Native(codec.cuts.Point), (try copied_comparison.next()).?.bytes);
    const original_value = try codec.decode(codec.Native(codec.cuts.Point), (try comparison.next()).?.bytes);
    try t.expectEqualDeep(copied_value, original_value);
    try t.expectEqual(@as(?u64, std.math.maxInt(u64)), original_value.value.value);
    try comparison.finish();
    try copied_comparison.finish();
}

test "single strict-attempt admission counts unresolved job reads but never weakens guard custody" {
    inline for (.{
        .{ codec.cuts.Site.service_worker_scan, f.Role.worker, codec.cuts.Site.service_job_queued, f.Role.control },
        .{ codec.cuts.Site.service_acceptance_scan, f.Role.control, codec.cuts.Site.service_worker_completed, f.Role.worker },
    }) |case| {
        const read = point(case[0], case[1], .before, 3, 0);
        const publication = point(case[2], case[3], .before, 3, 94);
        inline for (.{ false, true }) |publication_first| {
            var intervals: codec.ScanIntervals = .{ .allow_unresolved_job_reads = true };
            if (publication_first) {
                try intervals.point(publication);
                try intervals.point(read);
            } else {
                try intervals.point(read);
                try intervals.point(publication);
            }
            try intervals.point(end(read));
            try intervals.point(end(publication));
            try intervals.finish();
            try t.expectEqual(@as(u64, 1), intervals.unresolved_scalar_overlaps);
        }
    }
    var intervals: codec.ScanIntervals = .{ .allow_unresolved_job_reads = true };
    try intervals.point(point(.service_slot_guard_render_claim, .render, .before, 3, 0));
    try t.expectError(error.CrossedScan, intervals.point(point(.service_slot_guard_open, .control, .before, 3, 94)));
    try t.expectEqual(@as(u64, 0), intervals.unresolved_scalar_overlaps);
}

const SequenceSite = struct { site: codec.cuts.Site, role: f.Role, code: u8 };
const sequence_sites = [_]SequenceSite{
    .{ .site = .service_availability_readiness_sequence_before, .role = .control, .code = 0x40 },
    .{ .site = .service_availability_readiness_sequence_after, .role = .control, .code = 0x44 },
    .{ .site = .service_availability_acceptance_sequence_before, .role = .control, .code = 0x45 },
    .{ .site = .service_availability_acceptance_sequence_after, .role = .control, .code = 0x49 },
    .{ .site = .service_readiness_sequence, .role = .control, .code = 0x62 },
    .{ .site = .service_readiness_final_sequence, .role = .control, .code = 0x67 },
    .{ .site = .service_render_sequence_odd, .role = .render, .code = 0x68 },
    .{ .site = .service_render_sequence_even, .role = .render, .code = 0x6b },
};

const runtime_publication_sites = [_]SequenceSite{
    .{ .site = .runtime_collection_frame, .role = .control, .code = 0x20 },
    .{ .site = .runtime_control_accept_frame, .role = .control, .code = 0x31 },
    .{ .site = .runtime_control_collect_frame, .role = .control, .code = 0x37 },
    .{ .site = .runtime_readiness_outer_before, .role = .control, .code = 0x3a },
    .{ .site = .runtime_readiness_outer_after, .role = .control, .code = 0x3b },
    .{ .site = .runtime_render_frame, .role = .render, .code = 0x32 },
    .{ .site = .runtime_control_horizon, .role = .control, .code = 0x30 },
    .{ .site = .scheduler_prepare_horizon, .role = .control, .code = 0x8d },
    .{ .site = .runtime_render_commit_horizon, .role = .render, .code = 0x38 },
    .{ .site = .scheduler_horizon, .role = .render, .code = 0x8c },
};

test "Service sequence publication coordinates have finite site role and edge shape" {
    var scratch: [256]u8 = undefined;
    for (sequence_sites) |entry| {
        try t.expectEqual(entry.code, @intFromEnum(entry.site));
        try t.expectEqual(entry.role == .control, codec.serviceSequenceRead(entry.site));
        try t.expectEqual(entry.role == .render, codec.serviceSequencePublication(entry.site));
        for ([_]codec.cuts.Edge{ .before, .after }) |edge| {
            try t.expectEqual(edge == .after, codec.publicationPrefixPoint(entry.role, entry.site, edge));
            // Zero is a genuine prefix, including a read before any Render span.
            try codec.validatePublicationPrefix(entry.role, entry.site, edge, 0);
            const coordinate: codec.PacketInput = .{ .occurrence = 1, .site = entry.site, .edge = edge, .index = 3, .generation = 7, .publication_prefix = 9 };
            if (edge == .after) {
                _ = try codec.encodePointInputs(entry.role, &.{coordinate}, &scratch);
            } else {
                try t.expectError(error.Noncanonical, codec.encodePointInputs(entry.role, &.{coordinate}, &scratch));
            }
            for ([_]f.Role{ .control, .worker, .render, .ui }) |role| {
                if (role == entry.role) continue;
                try t.expect(!codec.publicationPrefixPoint(role, entry.site, edge));
                try t.expectError(error.UnsupportedValue, codec.validatePublicationPrefix(role, entry.site, edge, 0));
                var wrong_role = coordinate;
                wrong_role.publication_prefix = 0;
                try t.expectError(error.UnsupportedValue, codec.encodePointInputs(role, &.{wrong_role}, &scratch));
            }
            const raw = try codec.encode(@as(codec.Native(codec.Cut), .{ .occurrence = 1, .value = .{ .role = entry.role, .site = entry.site, .edge = edge, .index = 3, .generation = 7, .publication_prefix = 9 } }), .input, &scratch);
            const record: f.InputRecord = .{ .role = entry.role, .ordinal = 1, .family = @intFromEnum(codec.Family.cut), .bytes = raw };
            if (edge == .after) {
                try t.expectEqual(@as(u64, 9), (try codec.decodeInput(codec.Cut, record, .cut)).value.publication_prefix);
            } else {
                try t.expectError(error.Noncanonical, codec.decodeInput(codec.Cut, record, .cut));
            }
        }
    }
    for ([_]codec.cuts.Site{ .service_availability_readiness_frame, .service_availability_readiness_control_consumed, .service_availability_readiness_produced, .service_stream_observation_frame, .service_render_consumed, .ring_produced }) |site| {
        try t.expect(!codec.serviceSequenceRead(site));
        try t.expect(!codec.serviceSequencePublication(site));
        for ([_]f.Role{ .control, .worker, .render, .ui }) |role| {
            try t.expect(!codec.publicationPrefixPoint(role, site, .after));
            try t.expectError(error.Noncanonical, codec.validatePublicationPrefix(role, site, .after, 1));
        }
    }
}

test "consumed-prefix scheduling input survives packets without substituting comparison values" {
    var in_bytes: [256]u8 = undefined;
    var ref_bytes: [256]u8 = undefined;
    var corpus: [2048]u8 = undefined;
    const acquired: u64 = 5568;
    const coordinate: codec.PacketInput = .{ .occurrence = 19, .site = .ring_consumed, .edge = .after, .index = 3, .generation = 7, .publication_prefix = acquired };
    const input_payload = try codec.encodePointInputs(.control, &.{coordinate}, &in_bytes);
    const reference_payload = try codec.encodePointReferences(.control, &.{.{ .input = coordinate, .value = acquired }}, &ref_bytes);
    const reader = try f.Reader.preflight(try frameTape(&corpus, input_payload, reference_payload, .control), identity(), codec.validate);
    var cursor = codec.InputCursor.init(&reader, .control);
    _ = try cursor.next();
    const cut = try codec.decodeInput(codec.Cut, (try cursor.next()).?, .cut);
    try t.expectEqual(acquired, cut.value.publication_prefix);
    try t.expectEqual(@as(u64, 3), cut.value.index);
    try t.expectEqual(@as(u64, 7), cut.value.generation);
    try cursor.finish();
    var comparison = codec.ComparisonCursor.init(&reader, .control);
    const actual = try codec.decode(codec.Native(codec.cuts.Point), (try comparison.next()).?.bytes);
    try t.expectEqual(@as(?u64, acquired), actual.value.value);
    try comparison.finish();
    // It is a coordinate only at that acquire. Before/other locations cannot
    // smuggle an expected decision through the new field, even in raw inputs.
    var invalid = coordinate;
    invalid.edge = .before;
    try t.expectError(error.Noncanonical, codec.encodePointInputs(.control, &.{invalid}, &in_bytes));
    invalid.edge = .after;
    invalid.site = .ring_produced;
    try t.expectError(error.Noncanonical, codec.encodePointInputs(.control, &.{invalid}, &in_bytes));
    const native: codec.Native(codec.Cut) = .{ .occurrence = 1, .value = .{ .role = .control, .site = .ring_consumed, .edge = .before, .index = 3, .generation = 7, .publication_prefix = acquired } };
    const raw = try codec.encode(native, .input, &in_bytes);
    try t.expectError(error.Noncanonical, codec.decodeInput(codec.Cut, .{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.cut), .bytes = raw }, .cut));
    // Zero is a valid real consumed prefix, not an absent coordinate.
    invalid = coordinate;
    invalid.publication_prefix = 0;
    _ = try codec.encodePointInputs(.control, &.{invalid}, &in_bytes);
}
// Proposed append to tests/sme/live_semantic_codec_test.zig.
test "consumed prefix repeated reads retain identity and release before after stamp" {
    try live.semantic_replay.ConsumedPrefixRegression.repeatedPrefixAndInterveningMarker();
}

// These malformed fields replace the first occurrence varint. Reader framing
// remains valid; only the independent input packet decoder rejects them.
test "point packet unsigned varints reject truncation overlong and overflow" {
    var corpus: [2048]u8 = undefined;
    var references: [128]u8 = undefined;
    const point_input: codec.PacketInput = .{ .occurrence = 1, .site = .service_worker_scan, .edge = .before, .index = 0, .generation = 0 };
    const reference = try codec.encodePointReferences(.worker, &.{.{ .input = point_input, .value = null }}, &references);
    const Case = struct { bytes: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .bytes = &.{ 1, 0, 0x80 }, .err = error.Truncated },
        .{ .bytes = &.{ 1, 0, 0x81, 0 }, .err = error.Noncanonical },
        .{ .bytes = &.{ 1, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2 }, .err = error.CounterOverflow },
        .{ .bytes = &.{ 1, 0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80 }, .err = error.CounterOverflow },
        .{ .bytes = &.{ 1, 2 }, .err = error.InvalidLength }, // 513 points
    };
    for (cases) |case| {
        const reader = try f.Reader.preflight(try frameTape(&corpus, case.bytes, reference, .worker), identity(), codec.validate);
        var cursor = codec.InputCursor.init(&reader, .worker);
        try t.expectError(case.err, cursor.next());
    }
}

test "point packet unsigned varint width boundaries roundtrip all independent fields" {
    var corpus: [2048]u8 = undefined;
    var inputs: [128]u8 = undefined;
    var references: [128]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 16383, 16384, (@as(u64, 1) << 63), std.math.maxInt(u64) }) |value| {
        const coordinate: codec.PacketInput = .{ .occurrence = @max(value, 1), .site = .ring_consumed, .edge = .after, .index = value, .generation = value, .publication_prefix = value };
        const input = try codec.encodePointInputs(.control, &.{coordinate}, &inputs);
        const reference = try codec.encodePointReferences(.control, &.{.{ .input = coordinate, .value = value }}, &references);
        const reader = try f.Reader.preflight(try frameTape(&corpus, input, reference, .control), identity(), codec.validate);
        var cursor = codec.InputCursor.init(&reader, .control);
        _ = (try cursor.next()).?;
        const decoded = try codec.decodeInput(codec.Cut, (try cursor.next()).?, .cut);
        try t.expectEqual(coordinate.occurrence, decoded.occurrence);
        try t.expectEqual(value, decoded.value.index);
        try t.expectEqual(value, decoded.value.generation);
        try t.expectEqual(value, decoded.value.publication_prefix);
        try cursor.finish();
        var comparison = codec.ComparisonCursor.init(&reader, .control);
        const actual = try codec.decode(codec.Native(codec.cuts.Point), (try comparison.next()).?.bytes);
        try t.expectEqual(coordinate.occurrence, actual.occurrence);
        try t.expectEqual(value, actual.value.index);
        try t.expectEqual(value, actual.value.generation);
        try t.expectEqual(@as(?u64, value), actual.value.value);
        try comparison.finish();
    }
}

fn uiIdentity() codec.semantic.Identity {
    return .{ .epoch = 7, .document_id = 3, .revision = 11, .draft_hash = @splat(8), .artifact_hash = @splat(4), .state = @enumFromInt(19) };
}
fn uiObserve(validator: *codec.UiTranscriptValidator, occurrence: *u64, event: codec.semantic.UiEvent) !void {
    var scratch: [8192]u8 = undefined;
    occurrence.* += 1;
    const payload = try codec.encode(@as(codec.Native(codec.semantic.UiEvent), .{ .occurrence = occurrence.*, .value = event }), .reference, &scratch);
    try validator.observe(.{ .role = .ui, .ordinal = occurrence.*, .family = @intFromEnum(codec.Family.ui_event), .bytes = payload });
}
fn uiPair(validator: *codec.UiTranscriptValidator, occurrence: *u64, call: codec.semantic.UiCall, result: codec.semantic.UiResult) !void {
    const id = validator.calls + 1;
    try uiObserve(validator, occurrence, .{ .enter = .{ .call_id = id, .call = call } });
    try uiObserve(validator, occurrence, .{ .end = .{ .call_id = id, .value = result } });
}
fn uiCommand(id: u64, slot: u8, kind: @FieldType(codec.semantic.Command, "kind")) codec.semantic.Command {
    return .{ .id = id, .identity = uiIdentity(), .kind = kind, .slot = slot, .device_epoch = 0 };
}
fn uiTerminal(command: codec.semantic.Command, terminal: @typeInfo(@FieldType(codec.semantic.UiMailboxEvent, "terminal")).optional.child) codec.semantic.UiMailboxEvent {
    return .{ .command = command, .kind = .terminal, .receipt = null, .terminal = terminal, .recovery = null };
}

test "UI inputs are owned arguments while returns and old Control observations are comparison only" {
    const call: codec.UiInvocation = .{ .call_id = 14, .call = .{ .submit = .{ .identity = uiIdentity(), .kind = .stop } } };
    try t.expect(codec.owned(call));
    var scratch: [8192]u8 = undefined;
    const bytes = try codec.encode(@as(codec.Native(codec.UiInvocation), .{ .occurrence = 42, .value = call }), .input, &scratch);
    const decoded = try codec.decodeUiCall(.{ .role = .ui, .ordinal = 1, .family = @intFromEnum(codec.Family.ui_call), .bytes = bytes });
    try t.expectEqualDeep(call, decoded.value);
    try t.expectError(error.InvalidOrder, codec.decodeUiCall(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.ui_call), .bytes = bytes }));
    inline for (.{ codec.Family.ui_event, codec.Family.command_dequeued, codec.Family.close_polled, codec.Family.close_observed }) |family| {
        try t.expect(codec.validate(@intFromEnum(family), .reference));
        try t.expect(!codec.validate(@intFromEnum(family), .input));
    }
    const failure: codec.Native(codec.semantic.UiEvent) = .{ .occurrence = 43, .value = .{ .end = .{ .call_id = 14, .value = .{ .submit = error.QueueFull } } } };
    try t.expect(codec.owned(failure));
    const reference = try codec.encode(failure, .reference, &scratch);
    try codec.validateReference(.{ .role = .ui, .ordinal = 2, .family = @intFromEnum(codec.Family.ui_event), .bytes = reference });
    try t.expectError(error.ErrorInput, codec.decode(codec.Native(codec.semantic.UiEvent), reference));
    try t.expectError(error.ErrorInput, codec.encode(failure, .input, &scratch));
}

test "UI transcript retains failed ordinary Recover and exact failed ACK attempts" {
    var validator: codec.UiTranscriptValidator = .{ .identity = uiIdentity() };
    var occurrence: u64 = 0;
    try uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .recover } }, .{ .submit = error.InvalidState });
    const command = uiCommand(1, 0, .stop);
    try uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .stop } }, .{ .submit = command });
    try uiPair(&validator, &occurrence, .{ .acknowledge_terminal = command.id }, .{ .acknowledge_terminal = error.TerminalNotConsumed });
    try uiPair(&validator, &occurrence, .pop_event, .{ .pop_event = uiTerminal(command, .rejected) });
    try uiPair(&validator, &occurrence, .{ .acknowledge_terminal = command.id }, .{ .acknowledge_terminal = {} });
    try uiPair(&validator, &occurrence, .{ .acknowledge_terminal = command.id }, .{ .acknowledge_terminal = error.UnknownCommand });
    try uiPair(&validator, &occurrence, .{ .request_close = 0 }, .{ .request_close = error.InvalidEpoch });
    try uiPair(&validator, &occurrence, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .play } }, .{ .submit = error.AdmissionClosed });
    try validator.finish();
    try t.expectEqual(@as(u64, 3), validator.submit_attempts);
    try t.expectEqual(@as(u64, 1), validator.successful_submissions);
    try t.expectEqual(@as(u64, 0), validator.accepted_events);
    try t.expectEqual(@as(u64, 1), validator.terminal_acks);
}

test "UI accounting supports all eight reservations delayed out of order ACK and first free reuse" {
    var validator: codec.UiTranscriptValidator = .{ .identity = uiIdentity() };
    var occurrence: u64 = 0;
    for (0..8) |i| {
        const command = uiCommand(i + 1, @intCast(i), if (i % 2 == 0) .stop else .play);
        try uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = command.kind } }, .{ .submit = command });
    }
    try uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .play } }, .{ .submit = error.QueueFull });
    for (0..8) |i| {
        const command = uiCommand(i + 1, @intCast(i), if (i % 2 == 0) .stop else .play);
        try uiPair(&validator, &occurrence, .pop_event, .{ .pop_event = uiTerminal(command, if (i % 2 == 0) .rejected else .cancelled) });
    }
    try uiPair(&validator, &occurrence, .{ .acknowledge_terminal = 4 }, .{ .acknowledge_terminal = {} });
    try uiPair(&validator, &occurrence, .{ .acknowledge_terminal = 2 }, .{ .acknowledge_terminal = {} });
    const ninth = uiCommand(9, 1, .stop);
    try uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .stop } }, .{ .submit = ninth });
    for ([_]u64{ 8, 1, 7, 3, 6, 5 }) |id| try uiPair(&validator, &occurrence, .{ .acknowledge_terminal = id }, .{ .acknowledge_terminal = {} });
    try uiPair(&validator, &occurrence, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try t.expectError(error.Incomplete, validator.finish());
    try uiPair(&validator, &occurrence, .pop_event, .{ .pop_event = uiTerminal(ninth, .failed) });
    try uiPair(&validator, &occurrence, .{ .acknowledge_terminal = 9 }, .{ .acknowledge_terminal = {} });
    try validator.finish();
    try t.expectEqual(@as(u64, 9), validator.successful_submissions);
    try t.expectEqual(@as(u64, 9), validator.terminal_events);
}

test "UI malformed call brackets recovery success slot reuse and unconsumed ACK fail closed" {
    var validator: codec.UiTranscriptValidator = .{ .identity = uiIdentity() };
    var occurrence: u64 = 0;
    try t.expectError(error.InvalidOrder, uiObserve(&validator, &occurrence, .{ .end = .{ .call_id = 1, .value = .{ .pop_event = null } } }));
    validator = .{ .identity = uiIdentity() };
    try uiObserve(&validator, &occurrence, .{ .enter = .{ .call_id = 1, .call = .pop_event } });
    try t.expectError(error.Incomplete, validator.finish());
    try t.expectError(error.InvalidOrder, uiObserve(&validator, &occurrence, .{ .end = .{ .call_id = 1, .value = .{ .request_close = {} } } }));
    validator = .{ .identity = uiIdentity() };
    try uiObserve(&validator, &occurrence, .{ .enter = .{ .call_id = 1, .call = .pop_event } });
    try t.expectError(error.InvalidOrder, uiObserve(&validator, &occurrence, .{ .enter = .{ .call_id = 2, .call = .pop_event } }));
    validator = .{ .identity = uiIdentity() };
    try t.expectError(error.InvalidOrder, uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .recover } }, .{ .submit = uiCommand(1, 0, .recover) }));
    validator = .{ .identity = uiIdentity() };
    try t.expectError(error.InvalidOrder, uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .stop } }, .{ .submit = uiCommand(1, 1, .stop) }));
    validator = .{ .identity = uiIdentity() };
    try uiPair(&validator, &occurrence, .{ .submit = .{ .identity = uiIdentity(), .kind = .stop } }, .{ .submit = uiCommand(1, 0, .stop) });
    try t.expectError(error.InvalidOrder, uiPair(&validator, &occurrence, .{ .acknowledge_terminal = 1 }, .{ .acknowledge_terminal = {} }));
}

test "UI cannot acquire a fabricated engine role or index three engine scan arrays" {
    try t.expectError(error.UnsupportedValue, codec.nativeRole(.ui));
    var grammar: codec.ServiceScanGrammar = .{};
    try grammar.other(.ui);
    try grammar.finish();
    try t.expectError(error.UnsupportedValue, grammar.point(point(.ring_consumed, .ui, .after, 0, 0)));
    var intervals: codec.ScanIntervals = .{};
    try t.expectError(error.UnsupportedValue, intervals.point(point(.ring_consumed, .ui, .after, 0, 0)));
    var scratch: [128]u8 = undefined;
    try t.expectError(error.UnsupportedValue, codec.encodePointInputs(.ui, &.{.{ .occurrence = 1, .site = .ring_consumed, .edge = .after, .index = 0, .generation = 0 }}, &scratch));
}

/// Synthetic schema corpus only: no claim that these labels execute a Host.
/// Native integration separately compares actual lifecycle and mailbox results.
const UiSchemaTape = struct {
    writer: f.Writer,
    occurrence: u64 = 0,
    ordinals: [f.role_count]u64 = @splat(0),
    scratch: [8192]u8 = undefined,
    fn append(self: *UiSchemaTape, role: f.Role, family: codec.Family, class: f.Class, value: anytype) !void {
        const i = @intFromEnum(role);
        self.ordinals[i] += 1;
        const bytes = try codec.encode(value, class, &self.scratch);
        try self.writer.append(role, self.ordinals[i], @intFromEnum(family), class, bytes);
    }
    fn event(self: *UiSchemaTape, role: f.Role, family: codec.Family, value: anytype) !void {
        self.occurrence += 1;
        try self.append(role, .event_cut, .input, @as(codec.Native(codec.EventCut), .{ .occurrence = self.occurrence, .value = .{ .family = family, .tag = codec.eventTag(value) } }));
        try self.append(role, family, .reference, @as(codec.Native(@TypeOf(value)), .{ .occurrence = self.occurrence, .value = value }));
    }
    fn control(self: *UiSchemaTape, value: codec.semantic.ControlEvent) !void {
        try self.event(.control, .control_event, value);
        if (value == .started) try self.append(.control, .launch_descriptor, .input, @as(codec.Native(codec.LaunchDescriptor), .{ .occurrence = self.occurrence, .value = codec.launchDescriptor(value.started) }));
        if (value == .enter) try self.append(.control, .control_call, .input, @as(codec.Native(codec.ControlInvocation), .{ .occurrence = self.occurrence, .value = .{ .call_id = value.enter.call_id, .call = codec.controlArguments(value.enter.call) } }));
    }
    fn call(self: *UiSchemaTape, id: u64, value: codec.semantic.ControlCall) !void {
        try self.control(.{ .enter = .{ .call_id = id, .call = value } });
        try self.control(.{ .result = .{ .call_id = id, .value = .done } });
        try self.control(.{ .end = .{ .call_id = id, .failed = false } });
    }
    fn ui(self: *UiSchemaTape, value: codec.semantic.UiEvent) !void {
        try self.event(.ui, .ui_event, value);
        if (value == .enter) try self.append(.ui, .ui_call, .input, @as(codec.Native(codec.UiInvocation), .{ .occurrence = self.occurrence, .value = value.enter }));
    }
    fn mailboxEvent(self: *UiSchemaTape, role: f.Role, value: codec.mailbox.Checkpoint) !void {
        try self.event(role, .mailbox_event, value);
        try self.append(role, .mailbox_cut, .input, @as(codec.Native(codec.MailboxCut), .{ .occurrence = self.occurrence, .value = codec.mailboxCut(value) }));
    }
    fn schedulingPoint(self: *UiSchemaTape, role: f.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, prefix: u64, observed: ?u64, packet: bool) !void {
        if (!packet) {
            try self.event(role, .cut_fact, @as(codec.cuts.Point, .{ .role = try codec.nativeRole(role), .site = site, .edge = edge, .index = 0, .generation = 0, .value = observed }));
            try self.append(role, .cut, .input, @as(codec.Native(codec.Cut), .{ .occurrence = self.occurrence, .value = .{ .role = role, .site = site, .edge = edge, .index = 0, .generation = 0, .publication_prefix = prefix } }));
            return;
        }
        self.occurrence += 1;
        const coordinate: codec.PacketInput = .{ .occurrence = self.occurrence, .site = site, .edge = edge, .index = 0, .generation = 0, .publication_prefix = prefix };
        const i = @intFromEnum(role);
        self.ordinals[i] += 1;
        try self.writer.append(role, self.ordinals[i], @intFromEnum(codec.Family.point_packet_input), .input, try codec.encodePointInputs(role, &.{coordinate}, &self.scratch));
        self.ordinals[i] += 1;
        try self.writer.append(role, self.ordinals[i], @intFromEnum(codec.Family.point_packet_reference), .reference, try codec.encodePointReferences(role, &.{.{ .input = coordinate, .value = observed }}, &self.scratch));
    }
    fn workerGate(self: *UiSchemaTape, value: codec.mailbox.WorkerGateCheckpoint) !void {
        const role = codec.workerGateRole(value.role);
        try self.event(role, .worker_gate_event, value);
        try self.append(role, .worker_gate_cut, .input, @as(codec.Native(codec.WorkerGateCut), .{ .occurrence = self.occurrence, .value = codec.workerGateCut(value) }));
    }
    fn pair(self: *UiSchemaTape, id: u64, call_value: codec.semantic.UiCall, result: codec.semantic.UiResult) !void {
        try self.ui(.{ .enter = .{ .call_id = id, .call = call_value } });
        try self.ui(.{ .end = .{ .call_id = id, .value = result } });
    }
    fn start(self: *UiSchemaTape) !void {
        try self.control(.{ .started = .{ .thread = 1, .identity = uiIdentity(), .config = .{}, .device = .{} } });
        try self.call(1, .{ .provider_create = .{ .source_hash = @splat(4), .source_bytes = 1 } });
        try self.call(2, .{ .owner_create = .{} });
        try self.call(3, .{ .load = .{ .source_hash = @splat(4), .source_bytes = 1 } });
        try self.event(.worker, .worker_event, @as(codec.semantic.WorkerEvent, .{ .started = 2 }));
    }
    fn closeControl(self: *UiSchemaTape) !void {
        try self.control(.close_observed);
        try self.event(.worker, .worker_event, @as(codec.semantic.WorkerEvent, .returned));
        try self.control(.worker_joined);
        try self.control(.closed);
        try self.control(.returned);
        try self.control(.control_joined);
    }
    fn finish(self: *UiSchemaTape) ![]const u8 {
        return self.writer.sealFraming(.{ .healthy = true, .closed_roles = @splat(true), .role_counts = self.ordinals });
    }
};
fn uiSchemaIdentity() !f.Identity {
    var result = identity();
    result.config = try codec.configHash(.{});
    return result;
}

test "complete four role preflight admits no audio no commands and UI after Control joined" {
    var output: [32768]u8 = undefined;
    const contract = try uiSchemaIdentity();
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try tape.closeControl();
    // Join is not UI EOF. Actual callers may still drain/ACK after joining.
    try tape.pair(2, .pop_event, .{ .pop_event = null });
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    const summary = try codec.validateInputs(&reader, contract);
    try t.expectEqual(@as(u64, 0), summary.commands);
    try t.expectEqual(@as(u64, 0), summary.callbacks);
    try t.expectEqual(@as(u64, 0), summary.multi_frame_ticks);
    try t.expectEqual(@as(u64, 2), summary.ui_calls);
}

test "preflight reconciles dequeue before submit return and pop before emitted hook without inventing order" {
    var output: [65536]u8 = undefined;
    const contract = try uiSchemaIdentity();
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    const first = uiCommand(1, 0, .stop);
    try tape.ui(.{ .enter = .{ .call_id = 1, .call = .{ .submit = .{ .identity = uiIdentity(), .kind = .stop } } } });
    try tape.control(.{ .command_dequeued = first });
    try tape.ui(.{ .end = .{ .call_id = 1, .value = .{ .submit = first } } });
    // The actual queue publication can precede this Control output hook.
    try tape.pair(2, .pop_event, .{ .pop_event = uiTerminal(first, .rejected) });
    try tape.control(.{ .command_emitted = .{ .command = first, .kind = .terminal, .receipt = null, .terminal = .rejected } });
    const second = uiCommand(2, 1, .play);
    try tape.pair(3, .{ .submit = .{ .identity = uiIdentity(), .kind = .play } }, .{ .submit = second });
    try tape.pair(4, .{ .acknowledge_terminal = 1 }, .{ .acknowledge_terminal = {} });
    const third = uiCommand(3, 0, .play);
    try tape.pair(5, .{ .submit = .{ .identity = uiIdentity(), .kind = .play } }, .{ .submit = third });
    try tape.pair(6, .{ .submit = .{ .identity = uiIdentity(), .kind = .recover } }, .{ .submit = error.InvalidState });
    try tape.pair(7, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    // Both commands were genuinely submitted before Close, not fabricated at
    // dequeue time. Their native cancellation references need no accepted event.
    for ([_]codec.semantic.Command{ second, third }) |command| {
        try tape.control(.{ .command_dequeued = command });
        try tape.control(.{ .command_emitted = .{ .command = command, .kind = .terminal, .receipt = null, .terminal = .cancelled } });
    }
    try tape.closeControl();
    try tape.pair(8, .pop_event, .{ .pop_event = uiTerminal(second, .cancelled) });
    try tape.pair(9, .pop_event, .{ .pop_event = uiTerminal(third, .cancelled) });
    try tape.pair(10, .{ .acknowledge_terminal = 3 }, .{ .acknowledge_terminal = {} });
    try tape.pair(11, .{ .acknowledge_terminal = 2 }, .{ .acknowledge_terminal = {} });
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    const summary = try codec.validateInputs(&reader, contract);
    try t.expectEqual(@as(u64, 3), summary.commands);
    try t.expectEqual(@as(u64, 4), summary.submit_attempts);
    try t.expectEqual(@as(u64, 3), summary.successful_submissions);
    try t.expectEqual(@as(u64, 0), summary.accepted_events);
    try t.expectEqual(@as(u64, 3), summary.terminal_events);
    try t.expectEqual(@as(u64, 3), summary.terminal_acks);
}

test "typed UI error vocabulary rejects an invented error even with valid framing" {
    var scratch: [8192]u8 = undefined;
    const failure: codec.Native(codec.semantic.UiEvent) = .{ .occurrence = 1, .value = .{ .end = .{ .call_id = 1, .value = .{ .submit = error.QueueFull } } } };
    const bytes = try codec.encode(failure, .reference, &scratch);
    const offset = std.mem.indexOf(u8, bytes, "QueueFull").?;
    @memcpy(scratch[offset..][0..9], "InventedX");
    try t.expectError(error.InvalidEnum, codec.validateReference(.{ .role = .ui, .ordinal = 1, .family = @intFromEnum(codec.Family.ui_event), .bytes = bytes }));
}

test "preflight rejects omitted terminal and mismatched returned command before owner effects" {
    inline for (.{ false, true }) |bad_command| {
        var output: [32768]u8 = undefined;
        const contract = try uiSchemaIdentity();
        var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
        try tape.start();
        const command = uiCommand(1, 0, .stop);
        try tape.pair(1, .{ .submit = .{ .identity = uiIdentity(), .kind = .stop } }, .{ .submit = command });
        try tape.control(.{ .command_dequeued = if (bad_command) uiCommand(1, 1, .stop) else command });
        try tape.pair(2, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
        try tape.closeControl();
        const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
        try t.expectError(if (bad_command) error.InvalidOrder else error.Incomplete, codec.validateInputs(&reader, contract));
    }
}

test "mailbox admission inputs retain only Close predicate not raw word or RMW return" {
    const without_custody: codec.mailbox.Checkpoint = .{ .admission = .{ .role = .ui, .operation = .request_close, .edge = .after, .value = 2, .prior = 0 } };
    const with_custody: codec.mailbox.Checkpoint = .{ .admission = .{ .role = .ui, .operation = .request_close, .edge = .after, .value = 3, .prior = 1 } };
    try codec.validateMailboxCheckpoint(without_custody);
    try codec.validateMailboxCheckpoint(with_custody);
    try t.expectEqualDeep(codec.mailboxCut(without_custody), codec.mailboxCut(with_custody));
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    const input_a = try codec.encode(codec.mailboxCut(without_custody), .input, &a);
    const input_b = try codec.encode(codec.mailboxCut(with_custody), .input, &b);
    try t.expectEqualSlices(u8, input_a, input_b);
    const reference_a = try codec.encode(without_custody, .reference, &a);
    const reference_b = try codec.encode(with_custody, .reference, &b);
    try t.expect(!std.mem.eql(u8, reference_a, reference_b));
    try t.expect(codec.validate(@intFromEnum(codec.Family.mailbox_cut), .input));
    try t.expect(!codec.validate(@intFromEnum(codec.Family.mailbox_event), .input));
    var invalid = with_custody;
    invalid.admission.prior = 0;
    try t.expectError(error.Noncanonical, codec.validateMailboxCheckpoint(invalid));
    invalid = with_custody;
    invalid.admission.edge = .before;
    try t.expectError(error.Noncanonical, codec.validateMailboxCheckpoint(invalid));
}

test "mailbox coordinates reject wrong actor access counter and impossible prefix shapes" {
    const before: codec.MailboxCut = .{ .ring = .{ .role = .ui, .queue = .commands, .counter = .read, .operation = .push, .access = .acquire, .edge = .before, .local_prefix = 8 } };
    try codec.validateMailboxCut(before);
    var invalid = before;
    invalid.ring.role = .control;
    try t.expectError(error.InvalidOrder, codec.validateMailboxCut(invalid));
    invalid = before;
    invalid.ring.prefix = 0;
    try t.expectError(error.Noncanonical, codec.validateMailboxCut(invalid));
    invalid = before;
    invalid.ring.edge = .after;
    try t.expectError(error.Incomplete, codec.validateMailboxCut(invalid));
    invalid.ring.prefix = 0;
    try codec.validateMailboxCut(invalid); // Eight real reservations is full, not malformed.
    invalid.ring.local_prefix = 9;
    try t.expectError(error.InvalidOrder, codec.validateMailboxCut(invalid));
    invalid = before;
    invalid.ring.access = .release;
    invalid.ring.counter = .written;
    invalid.ring.prefix = 9;
    try codec.validateMailboxCut(invalid);
    invalid.ring.prefix = 8;
    try t.expectError(error.Noncanonical, codec.validateMailboxCut(invalid));
    try t.expectError(error.InvalidOrder, codec.validateMailboxCut(.{ .admission = .{ .role = .ui, .operation = .admission_drained, .edge = .before, .closed = null } }));
}

test "mailbox event pairs nest inside genuine UI call brackets with separate references" {
    var output: [32768]u8 = undefined;
    const contract = try uiSchemaIdentity();
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    try tape.ui(.{ .enter = .{ .call_id = 1, .call = .{ .request_close = uiIdentity().epoch } } });
    try tape.mailboxEvent(.ui, .{ .admission = .{ .role = .ui, .operation = .request_close, .edge = .before } });
    try tape.mailboxEvent(.ui, .{ .admission = .{ .role = .ui, .operation = .request_close, .edge = .after, .value = 2, .prior = 0 } });
    try tape.ui(.{ .end = .{ .call_id = 1, .value = .{ .request_close = {} } } });
    try tape.mailboxEvent(.control, .{ .admission = .{ .role = .control, .operation = .close_requested, .edge = .before } });
    try tape.mailboxEvent(.control, .{ .admission = .{ .role = .control, .operation = .close_requested, .edge = .after, .value = 2 } });
    try tape.closeControl();
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    const summary = try codec.validateInputs(&reader, contract);
    try t.expectEqual(@as(u64, 1), summary.ui_calls);
}

test "unterminated mailbox atomic bracket cannot be hidden by UI end or EOF" {
    var output: [32768]u8 = undefined;
    const contract = try uiSchemaIdentity();
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    try tape.ui(.{ .enter = .{ .call_id = 1, .call = .{ .request_close = uiIdentity().epoch } } });
    try tape.mailboxEvent(.ui, .{ .admission = .{ .role = .ui, .operation = .request_close, .edge = .before } });
    try tape.ui(.{ .end = .{ .call_id = 1, .value = .{ .request_close = {} } } });
    try tape.closeControl();
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    try t.expectError(error.Incomplete, codec.validateInputs(&reader, contract));
}

test "pre-owner mailbox reference admission rejects busy drain words and Control Close publication" {
    var scratch: [256]u8 = undefined;
    for ([_]u8{ 1, 3 }) |word| {
        const busy: codec.mailbox.Checkpoint = .{ .admission = .{ .role = .control, .operation = .admission_drained, .edge = .after, .value = word } };
        var idle = busy;
        idle.admission.value = word & 2;
        // The execution coordinate deliberately cannot expose the custody bit.
        try t.expectEqualDeep(codec.mailboxCut(busy), codec.mailboxCut(idle));
        try codec.validateMailboxCheckpoint(idle);
        try t.expectError(error.UnsupportedValue, codec.validateMailboxCheckpoint(busy));
        const bytes = try codec.encode(@as(codec.Native(codec.mailbox.Checkpoint), .{ .occurrence = 1, .value = busy }), .reference, &scratch);
        try t.expectError(error.UnsupportedValue, codec.validateReference(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.mailbox_event), .bytes = bytes }));
    }
    inline for (.{ codec.mailbox.Edge.before, codec.mailbox.Edge.after }) |edge| {
        const control_close: codec.mailbox.Checkpoint = .{ .admission = .{ .role = .control, .operation = .request_close, .edge = edge, .value = if (edge == .after) 2 else null, .prior = if (edge == .after) 0 else null } };
        try t.expectError(error.UnsupportedValue, codec.validateMailboxCheckpoint(control_close));
        const bytes = try codec.encode(@as(codec.Native(codec.mailbox.Checkpoint), .{ .occurrence = 1, .value = control_close }), .reference, &scratch);
        try t.expectError(error.UnsupportedValue, codec.validateReference(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.mailbox_event), .bytes = bytes }));
    }
}

fn launchDescriptorFixture() codec.LaunchDescriptor {
    return .{ .document_id = uiIdentity().document_id, .revision = uiIdentity().revision, .draft_hash = uiIdentity().draft_hash, .state = uiIdentity().state, .device = .{ .backend = .null_backend } };
}

test "v3 launch pacing roundtrips both canonical INPUT and independent started reference" {
    try t.expectEqual(@as(u16, 3), codec.schema_version);
    try t.expectEqual(f.wire_version, codec.schema_version);
    try t.expectEqual(codec.semantic.PacingMode.legacy_poll, launchDescriptorFixture().pacing);
    inline for (.{ codec.semantic.PacingMode.legacy_poll, codec.semantic.PacingMode.notified_v1 }) |pacing| {
        const started: @FieldType(codec.semantic.ControlEvent, "started") = .{ .thread = 1234, .identity = uiIdentity(), .config = .{}, .device = .{ .backend = .null_backend }, .pacing = pacing };
        const descriptor = codec.launchDescriptor(started);
        try t.expectEqual(pacing, descriptor.pacing);
        try codec.validateLaunchDescriptor(descriptor);
        var input_bytes: [2048]u8 = undefined;
        var roundtrip_bytes: [2048]u8 = undefined;
        const native: codec.Native(codec.LaunchDescriptor) = .{ .occurrence = 1, .value = descriptor };
        const encoded = try codec.encode(native, .input, &input_bytes);
        // The appended closed enum uses the existing canonical u64 vocabulary.
        try t.expectEqual(@as(u64, @intFromEnum(pacing)), std.mem.readInt(u64, encoded[encoded.len - 8 ..][0..8], .little));
        const decoded = try codec.decodeInput(codec.LaunchDescriptor, .{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.launch_descriptor), .bytes = encoded }, .launch_descriptor);
        try t.expectEqualDeep(native, decoded);
        try t.expectEqualSlices(u8, encoded, try codec.encode(decoded, .input, &roundtrip_bytes));

        const observed = codec.canonicalNative(codec.semantic.ControlEvent, .{ .occurrence = 1, .value = .{ .started = started } });
        var reference_bytes: [4096]u8 = undefined;
        var reference_roundtrip: [4096]u8 = undefined;
        const reference = try codec.encode(observed, .reference, &reference_bytes);
        try codec.validateReference(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.control_event), .bytes = reference });
        // Decode only the known started payload, not ControlEvent's other
        // error-valued arms: those remain forbidden to execution decoders.
        var reference_decoder: codec.Decoder = .{ .wire = .{ .bytes = reference } };
        const occurrence = try reference_decoder.get(u64);
        const tag = try reference_decoder.get(std.meta.Tag(codec.semantic.ControlEvent));
        try t.expectEqual(std.meta.Tag(codec.semantic.ControlEvent).started, tag);
        const decoded_started = try reference_decoder.get(@FieldType(codec.semantic.ControlEvent, "started"));
        try reference_decoder.wire.finish();
        const reference_decoded: codec.Native(codec.semantic.ControlEvent) = .{ .occurrence = occurrence, .value = .{ .started = decoded_started } };
        try t.expectEqualDeep(observed, reference_decoded);
        try t.expectEqual(pacing, reference_decoded.value.started.pacing);
        try t.expectEqualSlices(u8, reference, try codec.encode(reference_decoded, .reference, &reference_roundtrip));
    }
}

test "v3 launch INPUT and started reference reject illegal pacing enum bytes" {
    const started: @FieldType(codec.semantic.ControlEvent, "started") = .{ .thread = 1, .identity = uiIdentity(), .config = .{}, .device = .{ .backend = .null_backend }, .pacing = .notified_v1 };
    inline for (.{ @as(u64, 2), std.math.maxInt(u64) }) |invalid| {
        var input_bytes: [2048]u8 = undefined;
        const encoded = try codec.encode(@as(codec.Native(codec.LaunchDescriptor), .{ .occurrence = 1, .value = codec.launchDescriptor(started) }), .input, &input_bytes);
        std.mem.writeInt(u64, input_bytes[encoded.len - 8 ..][0..8], invalid, .little);
        try t.expectError(error.InvalidEnum, codec.decodeInput(codec.LaunchDescriptor, .{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.launch_descriptor), .bytes = encoded }, .launch_descriptor));
        var reference_bytes: [4096]u8 = undefined;
        const reference = try codec.encode(@as(codec.Native(codec.semantic.ControlEvent), .{ .occurrence = 1, .value = .{ .started = started } }), .reference, &reference_bytes);
        std.mem.writeInt(u64, reference_bytes[reference.len - 8 ..][0..8], invalid, .little);
        try t.expectError(error.InvalidEnum, codec.validateReference(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.control_event), .bytes = reference }));
    }
}

test "complete v3 preflight binds launch pacing to started in both directions" {
    const contract = try uiSchemaIdentity();
    inline for (.{ codec.semantic.PacingMode.legacy_poll, codec.semantic.PacingMode.notified_v1 }) |actual| {
        inline for (.{ codec.semantic.PacingMode.legacy_poll, codec.semantic.PacingMode.notified_v1 }) |input_pacing| {
            var output: [32768]u8 = undefined;
            var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
            const started: @FieldType(codec.semantic.ControlEvent, "started") = .{ .thread = 1, .identity = uiIdentity(), .config = .{}, .device = .{}, .pacing = actual };
            try tape.event(.control, .control_event, @as(codec.semantic.ControlEvent, .{ .started = started }));
            var descriptor = codec.launchDescriptor(started);
            descriptor.pacing = input_pacing;
            try tape.append(.control, .launch_descriptor, .input, @as(codec.Native(codec.LaunchDescriptor), .{ .occurrence = tape.occurrence, .value = descriptor }));
            try tape.call(1, .{ .provider_create = .{ .source_hash = @splat(4), .source_bytes = 1 } });
            try tape.call(2, .{ .owner_create = .{} });
            try tape.call(3, .{ .load = .{ .source_hash = @splat(4), .source_bytes = 1 } });
            try tape.event(.worker, .worker_event, @as(codec.semantic.WorkerEvent, .{ .started = 2 }));
            try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
            try tape.closeControl();
            const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
            // Only INPUT is returned to execution. Reference equality is a
            // pre-owner consistency check, not an execution-result supplier.
            try t.expectEqual(input_pacing, (try codec.readLaunchDescriptor(&reader)).pacing);
            if (actual == input_pacing) {
                const summary = try codec.validateInputs(&reader, contract);
                try t.expectEqual(@as(u64, 0), summary.commands);
                try t.expectEqual(@as(u64, 0), summary.callbacks);
            } else try t.expectError(error.InvalidOrder, codec.validateInputs(&reader, contract));
        }
    }
}

test "launch descriptor reader uses only execution input and requires exactly one Control descriptor" {
    var output: [4096]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const descriptor = launchDescriptorFixture();
    const native: codec.Native(codec.LaunchDescriptor) = .{ .occurrence = 1, .value = descriptor };
    inline for (.{ @as(usize, 0), @as(usize, 1), @as(usize, 2) }) |count| {
        var writer = try f.Writer.init(&output, identity(), codec.validate);
        for (0..count) |i| try writer.append(.control, i + 1, @intFromEnum(codec.Family.launch_descriptor), .input, try codec.encode(native, .input, &scratch));
        const bytes = try writer.sealFraming(.{ .healthy = true, .closed_roles = @splat(true), .role_counts = .{ count, 0, 0, 0 } });
        const reader = try f.Reader.preflight(bytes, identity(), codec.validate);
        if (count == 0) {
            try t.expectError(error.Incomplete, codec.readLaunchDescriptor(&reader));
        } else if (count == 1) {
            // No references at all: this capability cannot consult them.
            try t.expectEqualDeep(descriptor, try codec.readLaunchDescriptor(&reader));
        } else try t.expectError(error.InvalidOrder, codec.readLaunchDescriptor(&reader));
    }
    var writer = try f.Writer.init(&output, identity(), codec.validate);
    try writer.append(.ui, 1, @intFromEnum(codec.Family.launch_descriptor), .input, try codec.encode(native, .input, &scratch));
    const bytes = try writer.sealFraming(.{ .healthy = true, .closed_roles = @splat(true), .role_counts = .{ 0, 0, 0, 1 } });
    const reader = try f.Reader.preflight(bytes, identity(), codec.validate);
    try t.expectError(error.InvalidOrder, codec.readLaunchDescriptor(&reader));
}

test "launch descriptor retains actual device backend and rejects unsupported period rate channels" {
    var descriptor = launchDescriptorFixture();
    try codec.validateLaunchDescriptor(descriptor);
    descriptor.device.backend = .system;
    try codec.validateLaunchDescriptor(descriptor);
    descriptor.device.period_frames = 128;
    try t.expectError(error.UnsupportedValue, codec.validateLaunchDescriptor(descriptor));
    descriptor = launchDescriptorFixture();
    descriptor.device.sample_rate = 44100;
    try t.expectError(error.UnsupportedValue, codec.validateLaunchDescriptor(descriptor));
    descriptor = launchDescriptorFixture();
    descriptor.device.channels = 1;
    try t.expectError(error.UnsupportedValue, codec.validateLaunchDescriptor(descriptor));
}

test "pre-owner launch descriptor must match started arguments without borrowing epoch or thread" {
    const started: @FieldType(codec.semantic.ControlEvent, "started") = .{ .thread = 1234, .identity = uiIdentity(), .config = .{}, .device = .{ .backend = .null_backend } };
    var other = started;
    other.thread = 9876;
    other.identity.epoch += 1;
    try t.expectEqualDeep(codec.launchDescriptor(started), codec.launchDescriptor(other));
    var output: [8192]u8 = undefined;
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, identity(), codec.validate) };
    try tape.event(.control, .control_event, @as(codec.semantic.ControlEvent, .{ .started = started }));
    var descriptor = codec.launchDescriptor(started);
    descriptor.revision += 1;
    try tape.append(.control, .launch_descriptor, .input, @as(codec.Native(codec.LaunchDescriptor), .{ .occurrence = tape.occurrence, .value = descriptor }));
    const reader = try f.Reader.preflight(try tape.finish(), identity(), codec.validate);
    try t.expectError(error.InvalidOrder, codec.validateInputs(&reader, identity()));
}

test "pre-owner global UI owner grammar rejects join inside a synchronous UI invocation" {
    var output: [32768]u8 = undefined;
    const contract = try uiSchemaIdentity();
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try tape.control(.close_observed);
    try tape.event(.worker, .worker_event, @as(codec.semantic.WorkerEvent, .returned));
    try tape.control(.worker_joined);
    try tape.control(.closed);
    try tape.control(.returned);
    // Both lane-local grammars and all native terminal/credit counts are
    // complete. Only this global placement violates the one-UI-owner contract.
    try tape.ui(.{ .enter = .{ .call_id = 2, .call = .pop_event } });
    try tape.control(.control_joined);
    try tape.ui(.{ .end = .{ .call_id = 2, .value = .{ .pop_event = null } } });
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    try t.expectError(error.InvalidOrder, codec.validateInputs(&reader, contract));
}

test "preflight compares every supported publication coordinate to the independent native reference" {
    const sites = [_]SequenceSite{.{ .site = .ring_consumed, .role = .control, .code = 0 }} ++ sequence_sites ++ runtime_publication_sites;
    const contract = try uiSchemaIdentity();
    for (sites) |entry| {
        for ([_]u64{ 0, 42 }) |prefix| {
            for ([_]bool{ false, true }) |packet| {
                // Both a different value and a missing native value must fail;
                // neither can be filled in from the scheduling INPUT coordinate.
                for ([_]?u64{ prefix, prefix + 1, null }, 0..) |observed, outcome| {
                    var output: [32768]u8 = undefined;
                    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
                    try tape.start();
                    try tape.schedulingPoint(entry.role, entry.site, .before, 0, null, packet);
                    try tape.schedulingPoint(entry.role, entry.site, .after, prefix, observed, packet);
                    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
                    try tape.closeControl();
                    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
                    if (outcome == 0) {
                        _ = try codec.validateInputs(&reader, contract);
                    } else {
                        try t.expectError(error.InvalidOrder, codec.validateInputs(&reader, contract));
                    }
                }
            }
        }
    }
}

const BusySite = struct { role: f.Role, claim: codec.cuts.Site, release: codec.cuts.Site };
const busy_sites = [_]BusySite{
    .{ .role = .control, .claim = .service_stream_close_claim, .release = .service_stream_close_idle },
    .{ .role = .worker, .claim = .service_worker_claim, .release = .service_worker_idle },
    .{ .role = .worker, .claim = .service_service_prepare_claim, .release = .service_service_prepare_idle },
};
fn busyAttempt(tape: *UiSchemaTape, site: BusySite, success: ?bool, observed: ?u64, packet: bool) !void {
    if (packet) {
        // A real recorder flushes AFTER the claim: both point edges may be
        // in one packet, then the same-occurrence bool is a separate record.
        const before: codec.PacketInput = .{ .occurrence = tape.occurrence + 1, .site = site.claim, .edge = .before, .index = 0, .generation = 0 };
        const after: codec.PacketInput = .{ .occurrence = tape.occurrence + 2, .site = site.claim, .edge = .after, .index = 0, .generation = 0 };
        tape.occurrence += 2;
        const i = @intFromEnum(site.role);
        tape.ordinals[i] += 1;
        try tape.writer.append(site.role, tape.ordinals[i], @intFromEnum(codec.Family.point_packet_input), .input, try codec.encodePointInputs(site.role, &.{ before, after }, &tape.scratch));
        tape.ordinals[i] += 1;
        try tape.writer.append(site.role, tape.ordinals[i], @intFromEnum(codec.Family.point_packet_reference), .reference, try codec.encodePointReferences(site.role, &.{ .{ .input = before, .value = null }, .{ .input = after, .value = observed } }, &tape.scratch));
    } else {
        try tape.schedulingPoint(site.role, site.claim, .before, 0, null, false);
        try tape.schedulingPoint(site.role, site.claim, .after, 0, observed, false);
    }
    if (success) |value| try tape.append(site.role, .exclusion_claim, .input, @as(codec.Native(bool), .{ .occurrence = tape.occurrence, .value = value }));
}
fn busyRelease(tape: *UiSchemaTape, site: BusySite, packet: bool) !void {
    try tape.schedulingPoint(site.role, site.release, .before, 0, 0, packet);
    try tape.schedulingPoint(site.role, site.release, .after, 0, 0, packet);
}

test "worker busy claim input is finite bool only and native scalars remain independent" {
    try t.expectEqual(@as(u16, 15), @intFromEnum(codec.Family.exclusion_claim));
    try t.expect(codec.validate(@intFromEnum(codec.Family.exclusion_claim), .input));
    try t.expect(!codec.validate(@intFromEnum(codec.Family.exclusion_claim), .reference));
    var scratch: [128]u8 = undefined;
    for ([_]bool{ false, true }) |success| {
        const encoded = try codec.encode(@as(codec.Native(bool), .{ .occurrence = 17, .value = success }), .input, &scratch);
        const record: f.InputRecord = .{ .role = .worker, .ordinal = 3, .family = @intFromEnum(codec.Family.exclusion_claim), .bytes = encoded };
        try t.expectEqual(success, (try codec.decodeInput(bool, record, .exclusion_claim)).value);
        scratch[8] = 2;
        try t.expectError(error.InvalidBoolean, codec.decodeInput(bool, record, .exclusion_claim));
    }
    for (busy_sites) |site| {
        try t.expect(codec.exclusionClaim(site.role, site.claim));
        try t.expect(!codec.exclusionRelease(site.role, site.claim));
        try t.expect(codec.exclusionRelease(site.role, site.release));
        try t.expect(!codec.exclusionClaim(site.role, site.release));
        for ([_]f.Role{ .control, .worker, .render, .ui }) |role| {
            if (role == site.role) continue;
            try t.expect(!codec.exclusionClaim(role, site.claim));
            try t.expect(!codec.exclusionRelease(role, site.release));
            const wrong: codec.Native(codec.Cut) = .{ .occurrence = 1, .value = point(site.claim, role, .after, 0, 0) };
            const bytes = try codec.encode(wrong, .input, &scratch);
            try t.expectError(error.UnsupportedValue, codec.decodeInput(codec.Cut, .{ .role = role, .ordinal = 1, .family = @intFromEnum(codec.Family.cut), .bytes = bytes }, .cut));
        }
        const role = try codec.nativeRole(site.role);
        try codec.validateExclusionPoint(.{ .role = role, .site = site.claim, .edge = .before });
        for ([_]u64{ 0, 1 }) |actual| try codec.validateExclusionPoint(.{ .role = role, .site = site.claim, .edge = .after, .value = actual });
        for ([_]?u64{ null, 2 }) |actual| try t.expectError(error.Noncanonical, codec.validateExclusionPoint(.{ .role = role, .site = site.claim, .edge = .after, .value = actual }));
        try t.expectError(error.Noncanonical, codec.validateExclusionPoint(.{ .role = role, .site = site.claim, .edge = .before, .value = 0 }));
        for ([_]codec.cuts.Edge{ .before, .after }) |edge| {
            try codec.validateExclusionPoint(.{ .role = role, .site = site.release, .edge = edge, .value = 0 });
            for ([_]?u64{ null, 1 }) |actual| try t.expectError(error.Noncanonical, codec.validateExclusionPoint(.{ .role = role, .site = site.release, .edge = edge, .value = actual }));
        }
    }
    try t.expect(!codec.exclusionClaim(.control, .service_slot_guard_open));
    try t.expect(!codec.exclusionRelease(.render, .service_slot_guard_render_release));
}

test "raw and packet claim companions preserve one occurrence and exact actual success" {
    const contract = try uiSchemaIdentity();
    for (busy_sites) |site| for ([_]bool{ false, true }) |packet| for ([_]bool{ false, true }) |success| {
        var output: [32768]u8 = undefined;
        var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
        try tape.start();
        // A failed claim has a real opposing holder; do not synthesize an
        // impossible failure against an otherwise unowned exclusion cell.
        const blocker = busy_sites[if (site.role == .control) @as(usize, 1) else 0];
        if (!success) try busyAttempt(&tape, blocker, true, 0, packet);
        try busyAttempt(&tape, site, success, if (success) 0 else 1, packet);
        const claim_occurrence = tape.occurrence;
        try busyRelease(&tape, if (success) site else blocker, packet);
        try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
        try tape.closeControl();
        const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
        const summary = try codec.validateInputs(&reader, contract);
        try t.expectEqual(tape.occurrence, summary.events);
        var cursor = codec.InputCursor.init(&reader, site.role);
        var found = false;
        while (try cursor.next()) |record| {
            if (record.family != @intFromEnum(codec.Family.cut)) continue;
            const value = try codec.decodeInput(codec.Cut, record, .cut);
            if (value.occurrence != claim_occurrence) continue;
            var copied = cursor;
            const claim = try codec.decodeInput(bool, (try cursor.next()).?, .exclusion_claim);
            const copied_claim = try codec.decodeInput(bool, (try copied.next()).?, .exclusion_claim);
            try t.expectEqualDeep(claim, copied_claim);
            try t.expectEqual(claim_occurrence, claim.occurrence);
            try t.expectEqual(success, claim.value);
            try t.expectEqual(@intFromEnum(codec.Family.event_cut), (try copied.next()).?.family);
            found = true;
        }
        try t.expect(found);
    };
}

test "preflight rejects missing duplicated misplaced or inconsistent busy claim input" {
    const contract = try uiSchemaIdentity();
    for ([_]bool{ false, true }) |packet| for (0..9) |mutation| {
        var output: [32768]u8 = undefined;
        var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
        try tape.start();
        const site = busy_sites[1];
        const actual: ?u64 = switch (mutation) {
            0 => 1,
            1 => null,
            2 => 2,
            else => 0,
        };
        try busyAttempt(&tape, site, if (mutation == 3 or mutation == 4) null else mutation != 8, actual, packet);
        if (mutation == 4 or mutation == 5) try tape.append(site.role, .exclusion_claim, .input, @as(codec.Native(bool), .{ .occurrence = tape.occurrence + (if (mutation == 4) @as(u64, 1) else 0), .value = true }));
        try busyRelease(&tape, site, packet);
        if (mutation == 6) try tape.append(site.role, .exclusion_claim, .input, @as(codec.Native(bool), .{ .occurrence = tape.occurrence, .value = true }));
        if (mutation == 7) {
            try tape.schedulingPoint(.control, .ring_produced, .after, 0, 0, packet);
            try tape.append(.control, .exclusion_claim, .input, @as(codec.Native(bool), .{ .occurrence = tape.occurrence, .value = true }));
        }
        try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
        try tape.closeControl();
        const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
        try t.expectError(switch (mutation) {
            0, 4, 8 => error.InvalidOrder,
            1, 2 => error.Noncanonical,
            else => error.UnsupportedFamily,
        }, codec.validateInputs(&reader, contract));
    };
}

fn richAcceptanceFixture() codec.Acceptance {
    const Worker = @typeInfo(@FieldType(codec.stream.observation.Acceptance, "actual_worker")).optional.child;
    const worker: Worker = .{
        .job = 3,
        .asset = 4,
        .generation = 5,
        .transport_epoch = 6,
        .operation = .decode,
        .state = .ready,
        .pcm_start = 64,
        .pcm_end = 192,
        .available_frames = 128,
        .channel_count = 2,
        .content_hash = @splat(7),
        .readiness_version = 8,
        .failure_code = 0,
        .group = 9,
        .layer = 10,
        .loop_epoch = 11,
        .target_cursor = 64,
        .realize_frame = 256,
        .job_descriptor_hash = @splat(12),
    };
    return .{
        .attempt = .{
            .incoming = .{ .accepted_control_frame = 128, .control_tick = 2, .input_order = 3 },
            .cut = .{ .sequence = 8, .frame = 256, .consumed = 64, .produced = 192, .available = 128 },
            .evidence = .{
                .position = .{ .accepted_control_frame = 256, .control_tick = 2, .input_order = 3 },
                .batch_id = 4,
                .runtime_attached = true,
                .replay_mode = true,
                .job_slots = 256,
                .scanned = 255,
                .states = @splat(.completed),
                .completed = @splat(.{ .job = 3, .handle = .{ .index = 1, .generation = 5 }, .generation = 5, .transport_epoch = 6 }),
                .selected = .{
                    .slot = 17,
                    .handle = .{ .index = 1, .generation = 5 },
                    .descriptor = .{ .job = 3, .asset = 4, .generation = 5, .transport_epoch = 6, .operation = .decode, .group = 9, .layer = 10, .loop_epoch = 11, .target_cursor = 64, .realize_frame = 256 },
                    .ordinal = 18,
                    .count = 128,
                    .outcome = .ready,
                    .failure_code = 0,
                    .content_hash = @splat(7),
                },
                .availability = .{ .attached = true, .requested_frame = 256, .sequence_before = 8, .frame = 256, .consumed = 64, .produced = 192, .sequence_after = 8, .available = 128, .error_code = 0 },
                .ring_capacity = 512,
                .publication_preflight = .{ .head = 10, .tail = 8, .capacity = 16 },
                .publication_commit = .{ .head = 11, .tail = 8, .capacity = 16 },
                .last_batch_id = 3,
                .next_snapshot = 5,
                .cancel = false,
                .stopped = true,
                .generation = 5,
                .transport_epoch = 6,
                .stale = false,
                .actual_worker = worker,
                .coordinate = .{ .cursor = 64, .loop_epoch = 11 },
                .ring_produced = 192,
                .ring_writable = .{ .consumed = 64, .produced = 192 },
                .ring_publish = .{ .availability = .{ .consumed = 64, .produced = 192 }, .write = 192, .end = 320 },
                .publication = .{
                    .version = 1,
                    .batch_id = 4,
                    .stream_slot = 1,
                    .stream_generation = 5,
                    .asset = 4,
                    .asset_generation = 5,
                    .transport_epoch = 6,
                    .profile_id = 2,
                    .profile_hash = @splat(13),
                    .publication_ordinal = 18,
                    .worker_job = 3,
                    .job_descriptor_hash = @splat(12),
                    .prefix_start = 192,
                    .prefix_end = 320,
                    .target_cursor = 64,
                    .loop_epoch = 11,
                    .channels = 2,
                    .pcm_hash = @splat(7),
                },
                .outcome = .accepted,
                .error_code = 0,
                .effects = .{ .stale_completion_counted = true, .pcm_published = true, .publication_published = true, .stream_failed = true, .stream_cancelled = true, .job_released = true, .throughput_observation_attempted = true },
                .accepted = .{ .input = .{ .position = .{ .accepted_control_frame = 256, .control_tick = 2, .input_order = 3 }, .payload = .{ .worker = worker } }, .handle = .{ .index = 1, .generation = 5 }, .stale = true },
            },
        },
        .effective_frame = 256,
    };
}

test "compact native acceptance preserves every canonical semantic field and exact wire bytes" {
    const default: codec.Acceptance = .{ .attempt = .{ .incoming = .{ .accepted_control_frame = 0, .control_tick = 0, .input_order = 0 } }, .effective_frame = 0 };
    const accepted = richAcceptanceFixture();
    var no_completion = default;
    no_completion.attempt.evidence.outcome = .no_completion;
    no_completion.attempt.evidence.job_slots = codec.stream.observation.job_capacity;
    no_completion.attempt.evidence.scanned = codec.stream.observation.job_capacity;
    no_completion.attempt.evidence.states = @splat(.running);
    var failed = accepted;
    failed.attempt.returned_error = error.RingFull;
    failed.attempt.evidence.accepted = null;
    failed.attempt.evidence.outcome = .failed;
    failed.attempt.evidence.error_code = 76;
    failed.attempt.evidence.selected.?.outcome = .failed;
    failed.attempt.evidence.selected.?.failure_code = 77;
    failed.attempt.evidence.actual_worker.?.state = .failed;
    failed.attempt.evidence.actual_worker.?.failure_code = 77;
    var deferred = accepted;
    deferred.attempt.cut = null;
    deferred.attempt.deferred = .{ .reason = .sequence_changed, .handle = .{ .index = 1, .generation = 5 }, .observed_frame = 256, .sequence_before = 8, .sequence_after = 10 };
    deferred.attempt.returned_error = error.DrainPending;
    deferred.attempt.evidence.accepted = null;
    deferred.attempt.evidence.outcome = .availability_unavailable;
    deferred.attempt.evidence.error_code = 73;
    deferred.attempt.evidence.availability.error_code = 74;
    deferred.attempt.evidence.selected.?.failure_code = 75;
    deferred.attempt.evidence.effects = .{};
    for ([_]codec.Acceptance{ default, no_completion, accepted, failed, deferred }) |original| {
        const compact = try codec.packAcceptance(original);
        try t.expect(codec.owned(compact));
        const restored = codec.unpackAcceptance(compact);
        try t.expectEqual(original.effective_frame, restored.effective_frame);
        inline for (@typeInfo(codec.stream.LiveAcceptanceAttemptV1).@"struct".fields) |field| {
            if (comptime !std.mem.eql(u8, field.name, "evidence")) try t.expectEqualDeep(@field(original.attempt, field.name), @field(restored.attempt, field.name));
        }
        inline for (@typeInfo(@TypeOf(compact.attempt.evidence)).@"struct".fields) |field| {
            try t.expectEqualDeep(@field(original.attempt.evidence, field.name), @field(restored.attempt.evidence, field.name));
        }
        try t.expect(restored.attempt.evidence.representation_complete);
        try t.expectEqual(@as(usize, 0), restored.attempt.evidence.job_slots);
        try t.expectEqual(@as(usize, 0), restored.attempt.evidence.scanned);
        try t.expectEqualDeep(@as([codec.stream.observation.job_capacity]codec.stream.observation.JobState, @splat(.free)), restored.attempt.evidence.states);
        try t.expectEqualDeep(@as([codec.stream.observation.job_capacity]codec.stream.observation.CompletedIdentity, @splat(.{})), restored.attempt.evidence.completed);
        var direct_bytes: [16384]u8 = undefined;
        var compact_bytes: [16384]u8 = undefined;
        const direct = try codec.encode(@as(codec.Native(codec.Acceptance), .{ .occurrence = 91, .value = original }), .reference, &direct_bytes);
        var native: codec.Native(codec.CompactAcceptance) = .{ .occurrence = 91, .value = compact };
        const encoded = try codec.encodeNative(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.acceptance), .class = .reference, .bytes = std.mem.asBytes(&native), .first_len = @sizeOf(@TypeOf(native)) }, &compact_bytes);
        try t.expectEqualSlices(u8, direct, encoded);
        try codec.validateReference(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.acceptance), .bytes = encoded });
    }
}

test "acceptance retries preserve equal incoming positions but require distinct occurrences" {
    // Codec-only fixtures, not claims of native Render or publication coverage.
    // A failed attempt does not consume a public Input position. Its next real
    // attempt may therefore have the identical tick, frame and input order.
    const first: codec.Acceptance = .{
        .attempt = .{
            .incoming = .{ .accepted_control_frame = 33792, .control_tick = 46, .input_order = 1 },
            .deferred = .{ .reason = .odd_sequence, .handle = .{ .index = 1, .generation = 2 }, .observed_frame = null, .sequence_before = 1057, .sequence_after = null },
            .evidence = .{
                .position = .{ .accepted_control_frame = 33792, .control_tick = 46, .input_order = 1 },
                .runtime_attached = true,
                .availability = .{ .attached = true, .sequence_before = 1057, .error_code = @intFromError(error.InvalidState) },
                .outcome = .availability_unavailable,
                .error_code = @intFromError(error.InvalidState),
            },
        },
        .effective_frame = 33792,
    };
    var second = first;
    second.attempt.deferred = .{ .reason = .sequence_changed, .handle = .{ .index = 1, .generation = 2 }, .observed_frame = 33856, .sequence_before = 1058, .sequence_after = 1060 };
    second.attempt.evidence.availability = .{ .attached = true, .sequence_before = 1058, .frame = 33856, .consumed = 12032, .produced = 12160, .sequence_after = 1060, .error_code = @intFromError(error.InvalidState) };
    try t.expectEqualDeep(first.attempt.incoming, second.attempt.incoming);
    const contract = try uiSchemaIdentity();
    for ([_]bool{ false, true }) |duplicate_occurrence| {
        var output: [32768]u8 = undefined;
        var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
        try tape.start();
        try tape.event(.control, .acceptance, first);
        const first_occurrence = tape.occurrence;
        if (duplicate_occurrence) tape.occurrence -= 1;
        try tape.event(.control, .acceptance, second);
        try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
        try tape.closeControl();
        const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
        if (duplicate_occurrence) {
            try t.expectError(error.InvalidOrder, codec.validateInputs(&reader, contract));
            continue;
        }
        const summary = try codec.validateInputs(&reader, contract);
        try t.expectEqual(@as(u64, 0), summary.multi_frame_ticks);
        var inputs = codec.InputCursor.init(&reader, .control);
        var markers: u64 = 0;
        while (try inputs.next()) |record| {
            if (record.family != @intFromEnum(codec.Family.event_cut)) continue;
            const marker = try codec.decodeInput(codec.EventCut, record, .event_cut);
            if (marker.value.family != .acceptance) continue;
            try t.expectEqual(f.Role.control, record.role);
            try t.expect(markers < 2);
            try t.expectEqual(first_occurrence + markers, marker.occurrence);
            try t.expectEqual(@as(u16, 0), marker.value.tag);
            markers += 1;
        }
        try t.expectEqual(@as(u64, 2), markers);
        try inputs.finish();
        var comparisons = codec.ComparisonCursor.init(&reader, .control);
        var found: usize = 0;
        while (try comparisons.next()) |record| {
            if (record.family != @intFromEnum(codec.Family.acceptance)) continue;
            try t.expect(found < 2);
            const expected = if (found == 0) first else second;
            var scratch: [8192]u8 = undefined;
            const bytes = try codec.encode(@as(codec.Native(codec.Acceptance), .{ .occurrence = first_occurrence + found, .value = expected }), .reference, &scratch);
            try t.expectEqualSlices(u8, bytes, record.bytes);
            found += 1;
        }
        try t.expectEqual(@as(usize, 2), found);
        try comparisons.finish();
    }
}

test "compact acceptance rejects incomplete capture and drops only excluded diagnostics" {
    try t.expect(@sizeOf(codec.Native(codec.CompactAcceptance)) * 4 < @sizeOf(codec.Native(codec.Acceptance)));
    var full = richAcceptanceFixture();
    const compact = try codec.packAcceptance(full);
    full.attempt.evidence.job_slots = 7;
    full.attempt.evidence.scanned = 0;
    full.attempt.evidence.states = @splat(.running);
    full.attempt.evidence.completed = @splat(.{});
    try t.expectEqualDeep(compact, try codec.packAcceptance(full));
    full.attempt.evidence.representation_complete = false;
    try t.expectError(error.Incomplete, codec.packAcceptance(full));
    // An accidentally retained full-size native producer fails closed instead
    // of interpreting its leading bytes as the new compact queue transport.
    var legacy: codec.Native(codec.Acceptance) = .{ .occurrence = 1, .value = full };
    var scratch: [16384]u8 = undefined;
    try t.expectError(error.InvalidLength, codec.encodeNative(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.acceptance), .class = .reference, .bytes = std.mem.asBytes(&legacy), .first_len = @sizeOf(@TypeOf(legacy)) }, &scratch));
}

test "compact acceptance native boundary rejects truncated suffix and zero occurrence" {
    var native: codec.Native(codec.CompactAcceptance) = .{ .occurrence = 1, .value = try codec.packAcceptance(richAcceptanceFixture()) };
    var scratch: [16384]u8 = undefined;
    const bytes = std.mem.asBytes(&native);
    try t.expectError(error.InvalidLength, codec.encodeNative(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.acceptance), .class = .reference, .bytes = bytes[0 .. bytes.len - 1], .first_len = bytes.len - 1 }, &scratch));
    var suffix: [@sizeOf(@TypeOf(native)) + 1]u8 = undefined;
    @memcpy(suffix[0..bytes.len], bytes);
    suffix[bytes.len] = 0;
    try t.expectError(error.InvalidLength, codec.encodeNative(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.acceptance), .class = .reference, .bytes = &suffix, .first_len = bytes.len }, &scratch));
    for ([_]f.Role{ .worker, .render, .ui }) |role| try t.expectError(error.UnsupportedValue, codec.encodeNative(.{ .role = role, .ordinal = 1, .family = @intFromEnum(codec.Family.acceptance), .class = .reference, .bytes = bytes, .first_len = bytes.len }, &scratch));
    native.occurrence = 0;
    try t.expectError(error.InvalidOrder, codec.encodeNative(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.acceptance), .class = .reference, .bytes = bytes, .first_len = bytes.len }, &scratch));
}

/// Initialize bounded metadata in the heap allocation without materializing a
/// multi-megabyte Driver aggregate temporary on the unit-test stack.
fn initAcceptanceCallbackDriver(driver: *live.semantic_replay.Driver, reader: *const f.Reader, contract: f.Identity) !void {
    driver.address = null;
    driver.session = .{};
    driver.clock = .{};
    driver.publication_calendar.address = null; // init resets its small metadata.
    driver.exclusion_calendar.address = null;
    driver.exclusion_calendar.limit = 0;
    driver.exclusion_calendar.used = 0;
    driver.exclusion_calendar.sealed = false;
    driver.exclusion_calendar.aborted = .init(false);
    driver.exclusion_calendar.turn = .init(0);
    driver.exclusion_calendar.roles = .{ .{}, .{} };
    driver.turn = .init(1);
    driver.failed = .init(false);
    driver.failure_claimed = .init(false);
    driver.failure_value = null;
    driver.clock_pending = null;
    driver.report = .{};
    driver.actual_ui = null;
    driver.terminal_pending = @splat(null);
    driver.consumed_read_count = 0;
    driver.consumed_retired = .init(0);
    driver.consumed_active = null;
    for (&driver.consumed_progress) |*progress| progress.* = .{};
    driver.consumed_render_next = @splat(0);
    driver.running = false;
    driver.completed = false;
    try driver.init(reader, contract, t.io);
    driver.started_at = std.Io.Clock.awake.now(t.io);
}

fn seekAcceptanceCallback(driver: *live.semantic_replay.Driver, occurrence: u64) !void {
    const lane = &driver.lanes[@intFromEnum(f.Role.control)];
    while (true) {
        const before = lane.input;
        const record = try lane.input.next() orelse return error.Incomplete;
        if (record.family != @intFromEnum(codec.Family.event_cut)) continue;
        const marker = try codec.decodeInput(codec.EventCut, record, .event_cut);
        if (marker.occurrence == occurrence) {
            try t.expectEqual(codec.Family.acceptance, marker.value.family);
            lane.input = before;
            break;
        }
    }
    while (true) {
        const before = lane.comparison.cursor;
        const record = try lane.comparison.cursor.next() orelse return error.Incomplete;
        if (record.family != @intFromEnum(codec.Family.acceptance)) continue;
        var header: f.Decoder = .{ .bytes = record.bytes };
        if (try header.int(u64) == occurrence) {
            lane.comparison.cursor = before;
            break;
        }
    }
    driver.turn.store(occurrence, .release);
}

test "Driver registered acceptance callback compares full native values independently of compact queue transport" {
    const contract = try uiSchemaIdentity();
    const expected = richAcceptanceFixture();
    var output: [32768]u8 = undefined;
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    try tape.event(.control, .acceptance, expected);
    const occurrence = tape.occurrence;
    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try tape.closeControl();
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    for (0..3) |mutation| {
        const driver = try t.allocator.create(live.semantic_replay.Driver);
        defer t.allocator.destroy(driver);
        try initAcceptanceCallbackDriver(driver, &reader, contract);
        // Isolate one actual registered callback after full format/semantic
        // admission. This does not claim native Host or engine execution.
        try seekAcceptanceCallback(driver, occurrence);
        var actual = expected;
        actual.attempt.evidence.job_slots = 0;
        actual.attempt.evidence.scanned = 0;
        actual.attempt.evidence.states = @splat(.free);
        actual.attempt.evidence.completed = @splat(.{});
        if (mutation == 1) actual.attempt.evidence.selected.?.ordinal += 1;
        if (mutation == 2) actual.attempt.evidence.representation_complete = false;
        const callback = driver.session.config.acceptance;
        callback.emit(callback.context, &actual.attempt, actual.effective_frame);
        const lane = &driver.lanes[@intFromEnum(f.Role.control)];
        try t.expectEqual(@as(u64, 1), lane.events);
        if (mutation == 0) {
            try t.expect(!driver.failed.load(.acquire));
            try t.expect(driver.failure_value == null);
            try t.expectEqual(@as(u64, 1), lane.comparison.matched);
            try t.expectEqual(occurrence + 1, driver.turn.load(.acquire));
            try t.expect(!driver.session.poisoned.load(.acquire));
            const next = try codec.decodeInput(codec.EventCut, (try lane.input.next()).?, .event_cut);
            try t.expectEqual(codec.Family.control_event, next.value.family);
            try t.expectEqual(@intFromEnum(codec.Family.control_event), (try lane.comparison.cursor.next()).?.family);
        } else {
            try t.expect(driver.failed.load(.acquire));
            const failure = driver.failure_value orelse return error.ExpectedReplayFailure;
            try t.expectEqual(if (mutation == 1) error.ReplayMismatch else error.Incomplete, failure.reason);
            try t.expectEqual(@as(?codec.Family, .acceptance), failure.family);
            try t.expectEqual(occurrence, failure.occurrence);
            try t.expectEqual(mutation == 1, failure.byte_offset != null);
            try t.expectEqual(@as(u64, 0), lane.comparison.matched);
            try t.expectEqual(occurrence, driver.turn.load(.acquire));
            try t.expect(driver.session.poisoned.load(.acquire));
        }
    }
}

fn gatePublisher(counter: codec.mailbox.GateCounter) codec.mailbox.GateRole {
    return switch (counter) {
        .request, .resumed, .stopped => .control,
        .acknowledgment, .progress => .worker,
    };
}
fn gatePair(tape: *UiSchemaTape, counter: codec.mailbox.GateCounter, access: codec.mailbox.Access, epoch: u64, prefix: u64) !void {
    const publisher = gatePublisher(counter);
    const role: codec.mailbox.GateRole = if (access == .release) publisher else if (publisher == .control) .worker else .control;
    try tape.workerGate(.{ .role = role, .counter = counter, .access = access, .edge = .before, .epoch = epoch, .prefix = if (access == .release) prefix else null });
    try tape.workerGate(.{ .role = role, .counter = counter, .access = access, .edge = .after, .epoch = epoch, .prefix = prefix });
}

test "finite WorkerGate inputs and independent checkpoint references own exact fields" {
    try t.expect(codec.validate(@intFromEnum(codec.Family.worker_gate_cut), .input));
    try t.expect(!codec.validate(@intFromEnum(codec.Family.worker_gate_cut), .reference));
    try t.expect(codec.validate(@intFromEnum(codec.Family.worker_gate_event), .reference));
    try t.expect(!codec.validate(@intFromEnum(codec.Family.worker_gate_event), .input));
    for ([_]codec.mailbox.GateCounter{ .request, .acknowledgment, .resumed, .progress, .stopped }) |counter| {
        for ([_]codec.mailbox.Access{ .acquire, .release }) |access| {
            const publisher = gatePublisher(counter);
            const role: codec.mailbox.GateRole = if (access == .release) publisher else if (publisher == .control) .worker else .control;
            for ([_]codec.mailbox.Edge{ .before, .after }) |edge| {
                const checkpoint: codec.mailbox.WorkerGateCheckpoint = .{ .role = role, .counter = counter, .access = access, .edge = edge, .epoch = 17, .prefix = if (access == .acquire and edge == .before) null else 1 };
                const cut = codec.workerGateCut(checkpoint);
                try codec.validateWorkerGateCut(cut);
                try codec.validateWorkerGateCheckpoint(checkpoint);
                var scratch: [256]u8 = undefined;
                const bytes = try codec.encode(@as(codec.Native(codec.WorkerGateCut), .{ .occurrence = 23, .value = cut }), .input, &scratch);
                const decoded = try codec.decodeInput(codec.WorkerGateCut, .{ .role = codec.workerGateRole(role), .ordinal = 1, .family = @intFromEnum(codec.Family.worker_gate_cut), .bytes = bytes }, .worker_gate_cut);
                try t.expectEqualDeep(cut, decoded.value);
                var invalid = cut;
                invalid.role = if (role == .control) .worker else .control;
                try t.expectError(error.InvalidOrder, codec.validateWorkerGateCut(invalid));
                invalid = cut;
                invalid.epoch = 0;
                try t.expectError(error.Noncanonical, codec.validateWorkerGateCut(invalid));
                invalid = cut;
                invalid.prefix = if (cut.prefix == null) 0 else null;
                try t.expectError(if (cut.prefix == null) error.Noncanonical else error.Incomplete, codec.validateWorkerGateCut(invalid));
                if (access == .release) {
                    invalid = cut;
                    invalid.prefix = 0;
                    try t.expectError(error.Noncanonical, codec.validateWorkerGateCut(invalid));
                } else if (edge == .after) {
                    invalid = cut;
                    invalid.prefix = 0;
                    try codec.validateWorkerGateCut(invalid);
                }
            }
        }
    }
    try t.expectError(error.Noncanonical, codec.validateWorkerGateCut(.{ .role = .worker, .counter = .stopped, .access = .acquire, .edge = .after, .epoch = 1, .prefix = 2 }));
}

test "WorkerGate preflight pairs all five counters and repeated acknowledgment progress publications" {
    const contract = try uiSchemaIdentity();
    var output: [65536]u8 = undefined;
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    // The nonzero lifetime epoch comes from INPUT, never a started reference.
    const epoch: u64 = 37;
    for ([_]codec.mailbox.GateCounter{ .request, .acknowledgment, .resumed, .progress, .stopped }) |counter| {
        try gatePair(&tape, counter, .acquire, epoch, 0);
        try gatePair(&tape, counter, .release, epoch, 1);
        try gatePair(&tape, counter, .acquire, epoch, 1);
    }
    try gatePair(&tape, .acknowledgment, .release, epoch, 1);
    try gatePair(&tape, .progress, .release, epoch, 1);
    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try tape.closeControl();
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    const summary = try codec.validateInputs(&reader, contract);
    try t.expectEqual(tape.occurrence, summary.events);
}

test "WorkerGate preflight rejects unpaired interleaved crossed epoch and inconsistent reference cuts" {
    const contract = try uiSchemaIdentity();
    for (0..9) |mutation| {
        var output: [32768]u8 = undefined;
        var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
        try tape.start();
        const before: codec.mailbox.WorkerGateCheckpoint = .{ .role = .control, .counter = .request, .access = .release, .edge = .before, .epoch = 17, .prefix = 1 };
        if (mutation != 0) try tape.workerGate(before);
        if (mutation == 1) try tape.workerGate(before);
        if (mutation == 2) try tape.control(.{ .close_polled = false });
        if (mutation != 3) {
            var after = before;
            after.edge = .after;
            if (mutation == 4) after.epoch += 1;
            if (mutation == 5) after.counter = .resumed;
            if (mutation == 6) after.prefix = 2;
            if (mutation == 7) {
                try tape.event(.control, .worker_gate_event, after);
                var cut = codec.workerGateCut(after);
                cut.prefix = 2;
                try tape.append(.control, .worker_gate_cut, .input, @as(codec.Native(codec.WorkerGateCut), .{ .occurrence = tape.occurrence, .value = cut }));
            } else try tape.workerGate(after);
        }
        if (mutation == 8) try gatePair(&tape, .progress, .release, 18, 1);
        try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
        try tape.closeControl();
        const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
        try t.expectError(if (mutation == 2 or mutation == 3) error.Incomplete else error.InvalidOrder, codec.validateInputs(&reader, contract));
    }
}

test "Control stop progress remains an original void call with a full owned reference result" {
    const call: codec.semantic.ControlCall = .stop_progress;
    try t.expectEqualDeep(@as(codec.ControlArguments, .stop_progress), codec.controlArguments(call));
    var bytes: [256]u8 = undefined;
    const reference = try codec.encode(@as(codec.Native(codec.semantic.ControlEvent), .{ .occurrence = 1, .value = .{ .result = .{ .call_id = 3, .value = .{ .stop_progress = .{ .state = .shutting_down, .active_music_groups = 2, .retired_music_groups = 5, .live_instances = 9 } } } } }), .reference, &bytes);
    try codec.validateReference(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.control_event), .bytes = reference });
}

const NativeGateTrace = struct {
    values: [256]codec.mailbox.WorkerGateCheckpoint = undefined,
    count: usize = 0,
    fn record(raw: *anyopaque, value: codec.mailbox.WorkerGateCheckpoint) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        std.debug.assert(self.count < self.values.len);
        self.values[self.count] = value;
        self.count += 1;
    }
};
fn exerciseNativeGate(gate: *codec.mailbox.WorkerGate) !void {
    const epoch = gate.epoch;
    try t.expectEqual(@as(u64, 1), try gate.requestPark(epoch));
    try t.expectEqualDeep(@as(codec.mailbox.WorkerGate.Action, .{ .park = 1 }), try gate.workerAction(epoch));
    try gate.acknowledgePark(epoch, 1);
    try gate.acknowledgePark(epoch, 1); // Native repeated acknowledgment.
    try t.expect(gate.parked(epoch, 1));
    try gate.resumeAfterPending(epoch, 1);
    try t.expectEqualDeep(@as(codec.mailbox.WorkerGate.Action, .work), try gate.workerAction(epoch));
    try gate.workerCompleted(epoch);
    try t.expectEqualDeep(@as(codec.mailbox.WorkerGate.Action, .work), try gate.workerAction(epoch));
    try gate.workerCompleted(epoch); // Native repeated progress publication.
    try t.expectEqual(@as(u64, 2), try gate.requestPark(epoch));
    try t.expectEqualDeep(@as(codec.mailbox.WorkerGate.Action, .{ .park = 2 }), try gate.workerAction(epoch));
    try gate.acknowledgePark(epoch, 2);
    try t.expect(gate.parked(epoch, 2));
}
fn appendGatePackets(tape: *UiSchemaTape, values: []const codec.mailbox.WorkerGateCheckpoint) !void {
    const first = tape.occurrence + 1;
    for ([_]f.Role{ .control, .worker }) |role| {
        var inputs: [256]codec.Native(codec.WorkerGateCut) = undefined;
        var references: [256]codec.Native(codec.mailbox.WorkerGateCheckpoint) = undefined;
        var count: usize = 0;
        for (values, 0..) |value, i| {
            if (codec.workerGateRole(value.role) != role) continue;
            inputs[count] = .{ .occurrence = first + i, .value = codec.workerGateCut(value) };
            references[count] = .{ .occurrence = first + i, .value = value };
            count += 1;
        }
        if (count == 0) continue;
        const i = @intFromEnum(role);
        tape.ordinals[i] += 1;
        try tape.writer.append(role, tape.ordinals[i], @intFromEnum(codec.Family.worker_gate_packet_input), .input, try codec.encodeWorkerGateInputs(role, inputs[0..count], &tape.scratch));
        tape.ordinals[i] += 1;
        try tape.writer.append(role, tape.ordinals[i], @intFromEnum(codec.Family.worker_gate_packet_reference), .reference, try codec.encodeWorkerGateReferences(role, references[0..count], &tape.scratch));
    }
    tape.occurrence += values.len;
}
fn seekGateCallbacks(driver: *live.semantic_replay.Driver, first: u64) !void {
    for ([_]f.Role{ .control, .worker }) |role| {
        const lane = &driver.lanes[@intFromEnum(role)];
        while (true) {
            const before = lane.input;
            const record = try lane.input.next() orelse return error.Incomplete;
            if (record.family != @intFromEnum(codec.Family.event_cut)) continue;
            const marker = try codec.decodeInput(codec.EventCut, record, .event_cut);
            if (marker.value.family == .worker_gate_event) {
                lane.input = before;
                break;
            }
        }
        while (true) {
            const before = lane.comparison.cursor;
            const record = try lane.comparison.cursor.next() orelse return error.Incomplete;
            if (record.family == @intFromEnum(codec.Family.worker_gate_event)) {
                lane.comparison.cursor = before;
                break;
            }
        }
    }
    driver.turn.store(first, .release);
}

test "Driver registered WorkerGate callback replays actual native park resume and repeated progress with raw and packet transport" {
    var original: NativeGateTrace = .{};
    var captured = try codec.mailbox.WorkerGate.initObserved(uiIdentity().epoch, .{ .context = &original, .call = NativeGateTrace.record });
    try exerciseNativeGate(&captured);
    const contract = try uiSchemaIdentity();
    for ([_]bool{ false, true }) |packet| {
        var output: [65536]u8 = undefined;
        var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
        try tape.start();
        const first = tape.occurrence + 1;
        if (packet) try appendGatePackets(&tape, original.values[0..original.count]) else for (original.values[0..original.count]) |value| try tape.workerGate(value);
        const last = tape.occurrence;
        try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
        try tape.closeControl();
        const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
        const driver = try t.allocator.create(live.semantic_replay.Driver);
        defer t.allocator.destroy(driver);
        try initAcceptanceCallbackDriver(driver, &reader, contract);
        try seekGateCallbacks(driver, first);
        // Real gate operations and the registered Driver callback, not a Host
        // lifetime or a fabricated owner-destroy capability.
        var actual = try codec.mailbox.WorkerGate.initObserved(uiIdentity().epoch, driver.session.config.worker_gate);
        try exerciseNativeGate(&actual);
        try t.expect(!driver.failed.load(.acquire));
        try t.expect(!driver.session.poisoned.load(.acquire));
        try t.expectEqual(last + 1, driver.turn.load(.acquire));
        try t.expect(driver.publication_calendar.complete());
        for ([_]f.Role{ .control, .worker }) |role| {
            var count: u64 = 0;
            for (original.values[0..original.count]) |value| if (codec.workerGateRole(value.role) == role) {
                count += 1;
            };
            try t.expectEqual(count, driver.lanes[@intFromEnum(role)].events);
            try t.expectEqual(count, driver.lanes[@intFromEnum(role)].comparison.matched);
        }
        try t.expectEqual(captured.request.load(.acquire), actual.request.load(.acquire));
        try t.expectEqual(captured.acknowledgment.load(.acquire), actual.acknowledgment.load(.acquire));
        try t.expectEqual(captured.resumed.load(.acquire), actual.resumed.load(.acquire));
        try t.expectEqual(captured.progress.load(.acquire), actual.progress.load(.acquire));
        try t.expectEqual(captured.stopped.load(.acquire), actual.stopped.load(.acquire));
        try t.expect(!actual.in_call);
    }
}

fn gateFrameTape(out: []u8, input: []const u8, reference: ?[]const u8, role: f.Role) ![]const u8 {
    var writer = try f.Writer.init(out, identity(), codec.validate);
    try writer.append(role, 1, @intFromEnum(codec.Family.worker_gate_packet_input), .input, input);
    if (reference) |bytes| try writer.append(role, 2, @intFromEnum(codec.Family.worker_gate_packet_reference), .reference, bytes);
    var counts: [f.role_count]u64 = @splat(0);
    counts[@intFromEnum(role)] = if (reference != null) 2 else 1;
    return writer.sealFraming(.{ .healthy = true, .closed_roles = @splat(true), .role_counts = counts });
}

test "WorkerGate packet cursors expand every edge into exact raw canonical bytes with independent cursor copies" {
    try t.expect(codec.validate(@intFromEnum(codec.Family.worker_gate_packet_input), .input));
    try t.expect(!codec.validate(@intFromEnum(codec.Family.worker_gate_packet_input), .reference));
    try t.expect(codec.validate(@intFromEnum(codec.Family.worker_gate_packet_reference), .reference));
    for ([_]f.Role{ .control, .worker }) |role| {
        var inputs: [20]codec.Native(codec.WorkerGateCut) = undefined;
        var references: [20]codec.Native(codec.mailbox.WorkerGateCheckpoint) = undefined;
        var count: usize = 0;
        for ([_]codec.mailbox.GateCounter{ .request, .acknowledgment, .resumed, .progress, .stopped }) |counter| {
            for ([_]codec.mailbox.Access{ .acquire, .release }) |access| {
                const publisher = gatePublisher(counter);
                const native_role: codec.mailbox.GateRole = if (access == .release) publisher else if (publisher == .control) .worker else .control;
                if (codec.workerGateRole(native_role) != role) continue;
                for ([_]codec.mailbox.Edge{ .before, .after }) |edge| {
                    const value: codec.mailbox.WorkerGateCheckpoint = .{ .role = native_role, .counter = counter, .access = access, .edge = edge, .epoch = std.math.maxInt(u64), .prefix = if (access == .acquire and edge == .before) null else if (counter == .stopped) 1 else std.math.maxInt(u64) };
                    references[count] = .{ .occurrence = count + 1, .value = value };
                    inputs[count] = .{ .occurrence = count + 1, .value = codec.workerGateCut(value) };
                    count += 1;
                }
            }
        }
        var input_bytes: [2048]u8 = undefined;
        var reference_bytes: [2048]u8 = undefined;
        const input = try codec.encodeWorkerGateInputs(role, inputs[0..count], &input_bytes);
        const reference = try codec.encodeWorkerGateReferences(role, references[0..count], &reference_bytes);
        var output: [8192]u8 = undefined;
        const reader = try f.Reader.preflight(try gateFrameTape(&output, input, reference, role), identity(), codec.validate);
        var execution = codec.InputCursor.init(&reader, role);
        var comparison = codec.ComparisonCursor.init(&reader, role);
        var scratch: [256]u8 = undefined;
        for (inputs[0..count], references[0..count], 0..) |value, checkpoint, i| {
            const marker = (try execution.next()).?;
            try t.expectEqual(@as(u64, 2 * i + 1), marker.ordinal);
            try t.expectEqualSlices(u8, try codec.encode(@as(codec.Native(codec.EventCut), .{ .occurrence = value.occurrence, .value = .{ .family = .worker_gate_event, .tag = 0 } }), .input, &scratch), marker.bytes);
            var copy = execution; // Includes the pending cut, not a scratch alias.
            const cut = (try execution.next()).?;
            try t.expectEqual(@as(u64, 2 * i + 2), cut.ordinal);
            try t.expectEqual(@intFromEnum(codec.Family.worker_gate_cut), cut.family);
            try t.expectEqualSlices(u8, try codec.encode(value, .input, &scratch), cut.bytes);
            try t.expectEqualSlices(u8, cut.bytes, (try copy.next()).?.bytes);
            var reference_copy = comparison;
            const actual_reference = (try comparison.next()).?;
            try t.expectEqual(@as(u64, i + 1), actual_reference.ordinal);
            try t.expectEqual(@intFromEnum(codec.Family.worker_gate_event), actual_reference.family);
            try t.expectEqualSlices(u8, try codec.encode(checkpoint, .reference, &scratch), actual_reference.bytes);
            try t.expectEqualSlices(u8, actual_reference.bytes, (try reference_copy.next()).?.bytes);
        }
        try execution.finish();
        try comparison.finish();
        // Native queue transport uses the same canonical packet codec, including
        // unaligned storage and exact header/element lengths.
        var native_bytes: [4096]u8 = undefined;
        const header: codec.PacketHeader = .{ .count = @intCast(count) };
        @memcpy(native_bytes[1..][0..@sizeOf(codec.PacketHeader)], std.mem.asBytes(&header));
        const first = 1 + @sizeOf(codec.PacketHeader);
        const input_native = std.mem.sliceAsBytes(inputs[0..count]);
        @memcpy(native_bytes[first..][0..input_native.len], input_native);
        var encoded: [2048]u8 = undefined;
        const record: f.NativeRecord = .{ .role = role, .ordinal = 1, .family = @intFromEnum(codec.Family.worker_gate_packet_input), .class = .input, .bytes = native_bytes[1 .. first + input_native.len], .first_len = @sizeOf(codec.PacketHeader) };
        try t.expectEqualSlices(u8, input, try codec.encodeNative(record, &encoded));
        var bad = record;
        bad.bytes = bad.bytes[0 .. bad.bytes.len - 1];
        try t.expectError(error.InvalidLength, codec.encodeNative(bad, &encoded));
        const reference_native = std.mem.sliceAsBytes(references[0..count]);
        @memcpy(native_bytes[first..][0..reference_native.len], reference_native);
        try t.expectEqualSlices(u8, reference, try codec.encodeNative(.{ .role = role, .ordinal = 1, .family = @intFromEnum(codec.Family.worker_gate_packet_reference), .class = .reference, .bytes = native_bytes[1 .. first + reference_native.len], .first_len = @sizeOf(codec.PacketHeader) }, &encoded));
    }
}

test "WorkerGate packets reject malformed canonical fields bounds and missing reference companions" {
    const before: codec.Native(codec.WorkerGateCut) = .{ .occurrence = 1, .value = .{ .role = .worker, .counter = .request, .access = .acquire, .edge = .before, .epoch = 7, .prefix = null } };
    var storage: [64]u8 = undefined;
    const good = try codec.encodeWorkerGateInputs(.worker, &.{before}, &storage);
    try t.expectEqual(@as(usize, 9), good.len);
    const failures = [_]anyerror{ error.InvalidLength, error.InvalidLength, error.Truncated, error.InvalidLength, error.InvalidOrder, error.InvalidEnum, error.InvalidEnum, error.InvalidEnum, error.Noncanonical, error.InvalidBoolean, error.Noncanonical, error.Incomplete };
    for (failures, 0..) |expected, mutation| {
        var bytes: [64]u8 = undefined;
        @memcpy(bytes[0..good.len], good);
        var length = good.len;
        switch (mutation) {
            0 => bytes[0] = 0,
            1 => {
                bytes[0] = 1;
                bytes[1] = 2;
            }, // 513 entries.
            2 => length -= 1,
            3 => {
                bytes[length] = 0;
                length += 1;
            },
            4 => bytes[2] = 0,
            5 => bytes[3] = 255,
            6 => bytes[4] = 255,
            7 => bytes[5] = 255,
            8 => bytes[6] = 0,
            9 => bytes[7] = 2,
            10 => bytes[8] = 1,
            11 => bytes[5] = @intFromEnum(codec.mailbox.Edge.after),
            else => unreachable,
        }
        var output: [4096]u8 = undefined;
        const reader = try f.Reader.preflight(try gateFrameTape(&output, bytes[0..length], bytes[0..length], .worker), identity(), codec.validate);
        var input = codec.InputCursor.init(&reader, .worker);
        var reference = codec.ComparisonCursor.init(&reader, .worker);
        try t.expectError(expected, input.next());
        try t.expectError(expected, reference.next());
    }
    const oversized = try t.allocator.alloc(codec.Native(codec.WorkerGateCut), codec.max_packet_points + 1);
    defer t.allocator.free(oversized);
    for (oversized, 0..) |*value, i| {
        value.* = before;
        value.occurrence = i + 1;
    }
    var encoded: [32768]u8 = undefined;
    try t.expectError(error.InvalidLength, codec.encodeWorkerGateInputs(.worker, oversized, &encoded));
    try t.expectError(error.InvalidLength, codec.encodeWorkerGateInputs(.worker, &.{}, &encoded));
    try t.expectError(error.InvalidOrder, codec.encodeWorkerGateInputs(.control, &.{before}, &encoded));
    const full = try codec.encodeWorkerGateInputs(.worker, oversized[0..codec.max_packet_points], &encoded);
    var tape_bytes: [65536]u8 = undefined;
    const full_reader = try f.Reader.preflight(try gateFrameTape(&tape_bytes, full, null, .worker), identity(), codec.validate);
    var cursor = codec.InputCursor.init(&full_reader, .worker);
    for (0..codec.max_packet_points) |_| {
        _ = (try cursor.next()).?;
        _ = (try cursor.next()).?;
    }
    try cursor.finish();
    var missing = codec.ComparisonCursor.init(&full_reader, .worker);
    try t.expect(try missing.next() == null);

    const contract = try uiSchemaIdentity();
    var output: [32768]u8 = undefined;
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    var missing_input = before;
    missing_input.occurrence = tape.occurrence + 1;
    tape.ordinals[@intFromEnum(f.Role.worker)] += 1;
    try tape.writer.append(.worker, tape.ordinals[@intFromEnum(f.Role.worker)], @intFromEnum(codec.Family.worker_gate_packet_input), .input, try codec.encodeWorkerGateInputs(.worker, &.{missing_input}, &tape.scratch));
    tape.occurrence += 1;
    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try tape.closeControl();
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    try t.expectError(error.UnsupportedFamily, codec.validateInputs(&reader, contract));
}

test "WorkerGate packet expansion preserves mixed engine gate and ordinary event ordering in full preflight" {
    const contract = try uiSchemaIdentity();
    var output: [32768]u8 = undefined;
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    try tape.schedulingPoint(.control, .service_readiness_sequence, .before, 0, null, true);
    try tape.schedulingPoint(.control, .service_readiness_sequence, .after, 0, 0, true);
    const checkpoint: codec.mailbox.WorkerGateCheckpoint = .{ .role = .control, .counter = .request, .access = .release, .edge = .before, .epoch = 7, .prefix = 1 };
    var after = checkpoint;
    after.edge = .after;
    try appendGatePackets(&tape, &.{ checkpoint, after });
    try tape.control(.{ .close_polled = false });
    try tape.schedulingPoint(.control, .service_readiness_sequence, .before, 0, null, true);
    try tape.schedulingPoint(.control, .service_readiness_sequence, .after, 0, 0, true);
    try gatePair(&tape, .request, .acquire, 7, 1);
    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try tape.closeControl();
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    try t.expectEqual(tape.occurrence, (try codec.validateInputs(&reader, contract)).events);
}

test "Runtime publication coordinates have closed domain role and AFTER-only shape" {
    var scratch: [256]u8 = undefined;
    for (runtime_publication_sites, 0..) |entry, i| {
        const domain: codec.RuntimePublicationDomain = if (i < 6) .frame else .commit_horizon;
        try t.expectEqual(entry.code, @intFromEnum(entry.site));
        try t.expectEqual(if (entry.role == .control) @as(?codec.RuntimePublicationDomain, domain) else null, codec.runtimePublicationRead(entry.site));
        try t.expectEqual(if (entry.role == .render) @as(?codec.RuntimePublicationDomain, domain) else null, codec.runtimePublicationStore(entry.site));
        for ([_]codec.cuts.Edge{ .before, .after }) |edge| {
            try t.expectEqual(edge == .after, codec.publicationPrefixPoint(entry.role, entry.site, edge));
            try codec.validatePublicationPrefix(entry.role, entry.site, edge, 0);
            const coordinate: codec.PacketInput = .{ .occurrence = 1, .site = entry.site, .edge = edge, .index = 3, .generation = 7, .publication_prefix = 64 };
            if (edge == .after) {
                _ = try codec.encodePointInputs(entry.role, &.{coordinate}, &scratch);
            } else try t.expectError(error.Noncanonical, codec.encodePointInputs(entry.role, &.{coordinate}, &scratch));
            for ([_]f.Role{ .control, .worker, .render, .ui }) |role| {
                if (role == entry.role) continue;
                try t.expect(!codec.publicationPrefixPoint(role, entry.site, edge));
                try t.expectError(error.UnsupportedValue, codec.validatePublicationPrefix(role, entry.site, edge, 0));
                var wrong = coordinate;
                wrong.publication_prefix = 0;
                try t.expectError(error.UnsupportedValue, codec.encodePointInputs(role, &.{wrong}, &scratch));
                const raw = try codec.encode(@as(codec.Native(codec.Cut), .{ .occurrence = 1, .value = .{ .role = role, .site = entry.site, .edge = edge, .index = 3, .generation = 7 } }), .input, &scratch);
                try t.expectError(error.UnsupportedValue, codec.decodeInput(codec.Cut, .{ .role = role, .ordinal = 1, .family = @intFromEnum(codec.Family.cut), .bytes = raw }, .cut));
            }
            const raw = try codec.encode(@as(codec.Native(codec.Cut), .{ .occurrence = 1, .value = .{ .role = entry.role, .site = entry.site, .edge = edge, .index = 3, .generation = 7, .publication_prefix = 64 } }), .input, &scratch);
            const record: f.InputRecord = .{ .role = entry.role, .ordinal = 1, .family = @intFromEnum(codec.Family.cut), .bytes = raw };
            if (edge == .after) {
                const decoded = try codec.decodeInput(codec.Cut, record, .cut);
                try t.expectEqual(@as(u64, 64), decoded.value.publication_prefix);
                try t.expectEqual(@as(u64, 3), decoded.value.index);
                try t.expectEqual(@as(u64, 7), decoded.value.generation);
            } else try t.expectError(error.Noncanonical, codec.decodeInput(codec.Cut, record, .cut));
        }
    }
    // Other native scalar sites stay comparison-only, including Service's
    // distinct observation_frame and scheduler state/phase/publication points.
    for ([_]codec.cuts.Site{ .service_stream_observation_frame, .service_readiness_frame, .runtime_schedule_admission, .runtime_load_state_read, .scheduler_publication, .service_render_sequence_even }) |site| {
        try t.expect(codec.runtimePublicationRead(site) == null);
        try t.expect(codec.runtimePublicationStore(site) == null);
    }
}

const RuntimeAtomicReplay = struct {
    driver: *live.semantic_replay.Driver,
    scalar: std.atomic.Value(u64) = .init(0),
    acquired: [2]u64 = @splat(std.math.maxInt(u64)),
    read_sites: []const codec.cuts.Site,
    store_sites: []const codec.cuts.Site,
    publish_value: u64,
    fn emit(self: *@This(), role: codec.cuts.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, value: ?u64) void {
        const hook = self.driver.session.config.service.cuts;
        hook.point(hook.context, .{ .role = role, .site = site, .edge = edge, .value = value });
    }
    fn render(self: *@This()) void {
        for (self.store_sites) |site| {
            self.emit(.render, site, .before, self.publish_value);
            // This original operation is the only writer. The Driver merely
            // orders it and receives the actual published value afterward.
            self.scalar.store(self.publish_value, .release);
            self.emit(.render, site, .after, self.publish_value);
        }
    }
    fn control(self: *@This()) void {
        for (self.read_sites, 0..) |site, i| {
            self.emit(.control, site, .before, null);
            self.acquired[i] = self.scalar.load(.acquire);
            self.emit(.control, site, .after, self.acquired[i]);
        }
    }
};
fn seekRuntimeAtomicCallbacks(driver: *live.semantic_replay.Driver, first: u64) !void {
    for ([_]f.Role{ .control, .render }) |role| {
        const lane = &driver.lanes[@intFromEnum(role)];
        while (true) {
            const before = lane.input;
            const record = try lane.input.next() orelse return error.Incomplete;
            if (record.family != @intFromEnum(codec.Family.event_cut)) continue;
            const marker = try codec.decodeInput(codec.EventCut, record, .event_cut);
            if (marker.value.family == .cut_fact) {
                lane.input = before;
                break;
            }
        }
        while (true) {
            const before = lane.comparison.cursor;
            const record = try lane.comparison.cursor.next() orelse return error.Incomplete;
            if (record.family == @intFromEnum(codec.Family.cut_fact)) {
                lane.comparison.cursor = before;
                break;
            }
        }
    }
    driver.turn.store(first, .release);
}
fn crossedRuntimeAtomicReplay(read_sites: []const codec.cuts.Site, store_sites: []const codec.cuts.Site, publish_value: u64, acquired_value: u64, packet: bool) !void {
    try t.expect(read_sites.len == store_sites.len and read_sites.len <= 2);
    const contract = try uiSchemaIdentity();
    var output: [32768]u8 = undefined;
    var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
    try tape.start();
    const first = tape.occurrence + 1;
    for (read_sites, store_sites) |read_site, store_site| {
        // Crossed observed stamps, not a forced atomic outcome order:
        // Render BEFORE1, Control BEFORE2, Render AFTER3, Control AFTER4.
        try tape.schedulingPoint(.render, store_site, .before, 0, publish_value, packet);
        try tape.schedulingPoint(.control, read_site, .before, 0, null, packet);
        try tape.schedulingPoint(.render, store_site, .after, publish_value, publish_value, packet);
        try tape.schedulingPoint(.control, read_site, .after, acquired_value, acquired_value, packet);
    }
    const last = tape.occurrence;
    try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
    try tape.closeControl();
    const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
    const driver = try t.allocator.create(live.semantic_replay.Driver);
    defer t.allocator.destroy(driver);
    try initAcceptanceCallbackDriver(driver, &reader, contract);
    try seekRuntimeAtomicCallbacks(driver, first);
    var actual: RuntimeAtomicReplay = .{ .driver = driver, .read_sites = read_sites, .store_sites = store_sites, .publish_value = publish_value };
    const render = try std.Thread.spawn(.{}, RuntimeAtomicReplay.render, .{&actual});
    const control = std.Thread.spawn(.{}, RuntimeAtomicReplay.control, .{&actual}) catch |err| {
        driver.session.config.invalidate(driver.session.config.context);
        render.join();
        return err;
    };
    control.join();
    render.join();
    try t.expect(!driver.failed.load(.acquire));
    try t.expect(!driver.session.poisoned.load(.acquire));
    try t.expect(driver.publication_calendar.complete());
    try t.expectEqual(last + 1, driver.turn.load(.acquire));
    try t.expectEqual(publish_value, actual.scalar.load(.acquire));
    for (actual.acquired[0..read_sites.len]) |value| try t.expectEqual(acquired_value, value);
    for ([_]f.Role{ .control, .render }) |role| {
        try t.expectEqual(@as(u64, read_sites.len * 2), driver.lanes[@intFromEnum(role)].events);
        try t.expectEqual(@as(u64, read_sites.len * 2), driver.lanes[@intFromEnum(role)].comparison.matched);
    }
}

test "Driver Runtime frame calendar orders real atomic old and new acquires through crossed callback stamps" {
    for ([_]bool{ false, true }) |packet| {
        try crossedRuntimeAtomicReplay(&.{.runtime_collection_frame}, &.{.runtime_render_frame}, 64, 0, packet);
        try crossedRuntimeAtomicReplay(&.{.runtime_collection_frame}, &.{.runtime_render_frame}, 64, 64, packet);
    }
}

test "Driver commit horizon calendar admits real duplicate zero stores across both publication sites" {
    for ([_]bool{ false, true }) |packet| {
        try crossedRuntimeAtomicReplay(&.{ .runtime_control_horizon, .scheduler_prepare_horizon }, &.{ .runtime_render_commit_horizon, .scheduler_horizon }, 0, 0, packet);
    }
}

fn initialConsumedMap(inputs: []const codec.PacketInput) !usize {
    var input_bytes: [4096]u8 = undefined;
    var reference_bytes: [4096]u8 = undefined;
    var corpus: [12288]u8 = undefined;
    var references: [8]codec.PacketReference = undefined;
    for (inputs, 0..) |input, i| references[i] = .{ .input = input, .value = if (input.edge == .after) input.publication_prefix else null };
    const payload = try codec.encodePointInputs(.control, inputs, &input_bytes);
    const reference = try codec.encodePointReferences(.control, references[0..inputs.len], &reference_bytes);
    const reader = try f.Reader.preflight(try frameTape(&corpus, payload, reference, .control), identity(), codec.validate);
    return live.semantic_replay.ConsumedPrefixRegression.validateMap(&reader);
}

test "initial entry raw consumed alias rejects wrong roles before prefixes and crossed sites" {
    var bytes: [512]u8 = undefined;
    var pair = [_]codec.PacketInput{
        .{ .occurrence = 1, .site = .service_initial_entry_consumed, .edge = .before, .index = 3, .generation = 7 },
        .{ .occurrence = 2, .site = .service_initial_entry_consumed, .edge = .after, .index = 3, .generation = 7 },
    };
    try t.expectEqual(@as(usize, 1), try initialConsumedMap(&pair));
    inline for (.{ f.Role.worker, f.Role.render, f.Role.ui }) |role| {
        try t.expectError(error.UnsupportedValue, codec.encodePointInputs(role, &pair, &bytes));
    }
    pair[0].publication_prefix = 1;
    try t.expectError(error.Noncanonical, codec.encodePointInputs(.control, &pair, &bytes));
    const native: codec.Native(codec.Cut) = .{ .occurrence = 1, .value = .{ .role = .control, .site = .service_initial_entry_consumed, .edge = .before, .index = 3, .generation = 7, .publication_prefix = 1 } };
    const raw = try codec.encode(native, .input, &bytes);
    try t.expectError(error.Noncanonical, codec.decodeInput(codec.Cut, .{ .role = .control, .ordinal = 1, .family = @intFromEnum(codec.Family.cut), .bytes = raw }, .cut));
    pair[0].publication_prefix = 0;
    pair[0].site = .ring_consumed;
    try t.expectError(error.InvalidOrder, initialConsumedMap(&pair));
}

test "initial entry raw consumed calendar keeps monotonic generation scoped coordinates" {
    var values = [_]codec.PacketInput{
        .{ .occurrence = 1, .site = .ring_consumed, .edge = .before, .index = 3, .generation = 7 },
        .{ .occurrence = 2, .site = .ring_consumed, .edge = .after, .index = 3, .generation = 7, .publication_prefix = 64 },
        .{ .occurrence = 3, .site = .service_initial_entry_consumed, .edge = .before, .index = 3, .generation = 7 },
        .{ .occurrence = 4, .site = .service_initial_entry_consumed, .edge = .after, .index = 3, .generation = 7, .publication_prefix = 64 },
    };
    try t.expectEqual(@as(usize, 2), try initialConsumedMap(&values));
    values[3].publication_prefix = 0;
    try t.expectError(error.InvalidOrder, initialConsumedMap(&values));
    values[2].generation = 8;
    values[3].generation = 8;
    try t.expectEqual(@as(usize, 2), try initialConsumedMap(&values));
    values[2].generation = 6;
    values[3].generation = 6;
    try t.expectError(error.InvalidOrder, initialConsumedMap(&values));
}

fn admissionPoint(tape: *UiSchemaTape, value: codec.Cut) !void {
    try tape.event(value.role, .cut_fact, @as(codec.cuts.Point, .{ .role = try codec.nativeRole(value.role), .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation, .value = if (value.edge == .after) 0 else null }));
    try tape.append(value.role, .cut, .input, @as(codec.Native(codec.Cut), .{ .occurrence = tape.occurrence, .value = value }));
}
fn admissionScan(tape: *UiSchemaTape, role: f.Role, site: codec.cuts.Boundary, edge: codec.cuts.Edge, jobs: u64) !void {
    try tape.event(role, .boundary_fact, @as(codec.cuts.BoundaryPoint, .{ .role = try codec.nativeRole(role), .site = site, .edge = edge, .index = jobs }));
    try tape.append(role, .boundary, .input, @as(codec.Native(codec.Boundary), .{ .occurrence = tape.occurrence, .value = .{ .role = role, .site = site, .edge = edge, .index = jobs, .generation = 0 } }));
}

test "ordered job scans reject both predicate crossings while native attempt remains the default" {
    inline for (.{
        .{ codec.cuts.Site.service_worker_scan, f.Role.worker, codec.cuts.Site.service_job_queued, f.Role.control, codec.cuts.Boundary.service_worker_scan },
        .{ codec.cuts.Site.service_acceptance_scan, f.Role.control, codec.cuts.Site.service_worker_completed, f.Role.worker, codec.cuts.Boundary.service_acceptance_scan },
    }) |case| {
        for ([_]bool{ false, true }) |publication_first| {
            const Shape = enum { overlap, different_slot, serial };
            for (std.enums.values(Shape)) |shape| {
                var output: [131072]u8 = undefined;
                const contract = try uiSchemaIdentity();
                var tape: UiSchemaTape = .{ .writer = try f.Writer.init(&output, contract, codec.validate) };
                try tape.start();
                const jobs = (codec.ServiceScanGrammar{}).jobs;
                try admissionScan(&tape, case[1], case[4], .before, jobs);
                for (0..jobs) |slot| {
                    const read = point(case[0], case[1], .before, slot, 0);
                    if (slot != 0) {
                        try admissionPoint(&tape, read);
                        try admissionPoint(&tape, end(read));
                        continue;
                    }
                    const publication = point(case[2], case[3], .before, if (shape == .different_slot) 1 else 0, 94);
                    if (publication_first) {
                        try admissionPoint(&tape, publication);
                        if (shape == .serial) try admissionPoint(&tape, end(publication));
                        try admissionPoint(&tape, read);
                        try admissionPoint(&tape, end(read));
                        if (shape != .serial) try admissionPoint(&tape, end(publication));
                    } else {
                        try admissionPoint(&tape, read);
                        if (shape == .serial) try admissionPoint(&tape, end(read));
                        try admissionPoint(&tape, publication);
                        try admissionPoint(&tape, end(publication));
                        if (shape != .serial) try admissionPoint(&tape, end(read));
                    }
                }
                try admissionScan(&tape, case[1], case[4], .after, jobs);
                try tape.pair(1, .{ .request_close = uiIdentity().epoch }, .{ .request_close = {} });
                try tape.closeControl();
                const reader = try f.Reader.preflight(try tape.finish(), contract, codec.validate);
                const compatibility = try codec.validateInputs(&reader, contract);
                const explicit_attempt = try codec.validateInputsWithPolicy(&reader, contract, .native_attempt);
                try t.expectEqualDeep(compatibility, explicit_attempt);
                try t.expectEqual(@as(u64, if (shape == .overlap) 1 else 0), compatibility.unresolved_scalar_overlaps);
                if (shape == .overlap) {
                    try t.expectError(error.CrossedScan, codec.validateInputsWithPolicy(&reader, contract, .ordered_job_scans));
                } else {
                    const ordered = try codec.validateInputsWithPolicy(&reader, contract, .ordered_job_scans);
                    try t.expectEqualDeep(compatibility, ordered);
                }
            }
        }
    }
}

fn admissionEnvironment(name: []const u8) !?[]u8 {
    return std.process.Environ.getAlloc(t.environ, t.allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}
fn admissionHash(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidAdmissionIdentity;
    var hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hash, hex);
    return hash;
}

test "external original identity tape is rejected by ordered admission before Driver owners" {
    const tape_path = try admissionEnvironment("SME_LIVE_ADMISSION_TAPE");
    defer if (tape_path) |value| t.allocator.free(value);
    const identity_path = try admissionEnvironment("SME_LIVE_ADMISSION_IDENTITY_JSON");
    defer if (identity_path) |value| t.allocator.free(value);
    if (tape_path == null and identity_path == null) return error.SkipZigTest;
    if (tape_path == null or identity_path == null) return error.MissingAdmissionEnvironment;
    // Original capture identity supplied explicitly. Never substitute this
    // test executable's build hash or edit/reseal the original tape.
    const identity_bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, identity_path.?, t.allocator, .limited(4096));
    defer t.allocator.free(identity_bytes);
    const JsonIdentity = struct { build: []const u8, bank: []const u8, config: []const u8, source: []const u8 };
    const parsed = try std.json.parseFromSlice(JsonIdentity, t.allocator, identity_bytes, .{});
    defer parsed.deinit();
    const contract: f.Identity = .{ .build = try admissionHash(parsed.value.build), .bank = try admissionHash(parsed.value.bank), .config = try admissionHash(parsed.value.config), .source = try admissionHash(parsed.value.source) };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, tape_path.?, t.allocator, .limited(f.max_file_bytes + 1));
    defer t.allocator.free(bytes);
    if (bytes.len > f.max_file_bytes) return error.AdmissionTapeTooLarge;
    const reader = try f.Reader.preflight(bytes, contract, codec.validate);
    const native = try codec.validateInputsWithPolicy(&reader, contract, .native_attempt);
    try t.expectEqual(@as(u64, 1), native.unresolved_scalar_overlaps);
    try t.expectEqualDeep(native, try codec.validateInputs(&reader, contract));
    try t.expectError(error.CrossedScan, codec.validateInputsWithPolicy(&reader, contract, .ordered_job_scans));
    const driver = try t.allocator.create(live.semantic_replay.Driver);
    defer t.allocator.destroy(driver);
    // initWithPolicy checks address, then complete policy preflight before
    // touching any execution state. Initialize precisely that pre-owner state;
    // avoid a multi-megabyte default aggregate temporary on the test stack.
    driver.address = null;
    driver.session = .{};
    driver.running = false;
    try t.expectError(error.CrossedScan, driver.initWithPolicy(&reader, contract, t.io, .ordered_job_scans));
    try t.expect(driver.address == null and driver.session.address == null and driver.session.host == null and !driver.session.used and !driver.running);
    std.debug.print("ADMISSION_ORIGINAL_TAPE native_unresolved={d} ordered=CrossedScan driver_address_null=true session_uninitialized=true running=false owners_created=false\n", .{native.unresolved_scalar_overlaps});
}
