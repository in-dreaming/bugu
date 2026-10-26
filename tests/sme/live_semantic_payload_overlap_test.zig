const std = @import("std");
const codec = @import("sme-author-live-owner").semantic_recording.codec;
const overlap = codec.payload_overlap;
const t = std.testing;
fn cut(role: @TypeOf(@as(codec.Cut, undefined).role), site: codec.cuts.Site, edge: codec.cuts.Edge, index: u64, generation: u64) codec.Cut {
    return .{ .role = role, .site = site, .edge = edge, .index = index, .generation = generation };
}
test "payload frame overlap rejects in either order regardless of stream labels" {
    var v: overlap.Validator = .{};
    try v.observe(cut(.control, .service_readiness_frame, .before, 9, 17));
    try t.expectError(error.UnsupportedOverlap, v.observe(cut(.render, .service_stream_observation_frame, .before, 0, 0)));
    v = .{};
    try v.observe(cut(.render, .service_stream_observation_frame, .before, 0, 0));
    try t.expectError(error.UnsupportedOverlap, v.observe(cut(.control, .service_availability_acceptance_frame, .before, 2, 8)));
}
test "payload consumed overlap rejects only same slot incarnation" {
    var v: overlap.Validator = .{};
    try v.observe(cut(.control, .service_readiness_consumed, .before, 2, 8));
    try t.expectError(error.UnsupportedOverlap, v.observe(cut(.render, .service_render_consumed, .before, 2, 8)));
    for ([_][2]u64{ .{ 3, 8 }, .{ 2, 9 } }) |identity| {
        v = .{};
        try v.observe(cut(.control, .service_availability_readiness_control_consumed, .before, 2, 8));
        try v.observe(cut(.render, .service_render_consumed, .before, identity[0], identity[1]));
        try v.observe(cut(.render, .service_render_consumed, .after, identity[0], identity[1]));
        try v.observe(cut(.control, .service_availability_readiness_control_consumed, .after, 2, 8));
        try v.finish();
    }
}
test "payload nonoverlap and different scalar classes remain admitted" {
    var v: overlap.Validator = .{};
    try v.observe(cut(.render, .service_stream_observation_frame, .before, 0, 0));
    try v.observe(cut(.control, .service_availability_acceptance_control_consumed, .before, 2, 8));
    try v.observe(cut(.control, .service_availability_acceptance_control_consumed, .after, 2, 8));
    try v.observe(cut(.render, .service_stream_observation_frame, .after, 0, 0));
    try v.observe(cut(.control, .service_availability_readiness_frame, .before, 2, 8));
    try v.observe(cut(.control, .service_availability_readiness_frame, .after, 2, 8));
    try v.finish();
}
test "payload malformed brackets do not hide missing after or changed identity" {
    var v: overlap.Validator = .{};
    try t.expectError(error.InvalidOrder, v.observe(cut(.worker, .service_readiness_frame, .before, 0, 0)));
    try v.observe(cut(.control, .service_readiness_consumed, .before, 2, 8));
    try t.expectError(error.InvalidOrder, v.observe(cut(.control, .service_readiness_consumed, .after, 2, 9)));
    try t.expectError(error.Incomplete, v.finish());
}

test "wire5 joint deferral only removes frame exclusion and preserves consumed identity rejection" {
    var v: overlap.Validator = .{ .defer_frame_to_joint = true };
    try v.observe(cut(.control, .service_readiness_frame, .before, 9, 17));
    try v.observe(cut(.render, .service_stream_observation_frame, .before, 0, 0));
    try v.observe(cut(.render, .service_stream_observation_frame, .after, 0, 0));
    try v.observe(cut(.control, .service_readiness_frame, .after, 9, 17));
    try v.finish();
    try v.observe(cut(.control, .service_readiness_consumed, .before, 2, 8));
    try t.expectError(error.UnsupportedOverlap, v.observe(cut(.render, .service_render_consumed, .before, 2, 8)));
}
