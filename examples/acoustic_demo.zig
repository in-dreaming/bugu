const std = @import("std");
const bugu = @import("bugu_audio");

const SceneCase = struct {
    name: []const u8,
    scene: bugu.acoustic.TestScene,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
    const source = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };
    const config: bugu.acoustic.SolveConfig = .{ .enable_smoothing = false };

    const wall_hole_portals = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 1, .center = .{ .x = 0, .y = 2.0, .z = 0 }, .radius = 1.0, .area_open_m2 = 1.8, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.concrete_id },
    };
    const door_half_portals = [_]bugu.acoustic.AcousticPortal{
        .{ .id = 2, .center = .{ .x = 0, .y = 0, .z = 0 }, .radius = 0.9, .area_open_m2 = 1.0, .max_area_m2 = 2.0, .material_id = bugu.acoustic.TestScenes.wood_id, .state = .partial },
    };
    const scenes = [_]SceneCase{
        .{ .name = "open_air", .scene = bugu.acoustic.TestScenes.openAir() },
        .{ .name = "thick_wall", .scene = bugu.acoustic.TestScenes.thickWall() },
        .{ .name = "wall_hole", .scene = bugu.acoustic.TestScenes.wallHole(&wall_hole_portals) },
        .{ .name = "door_opening_half", .scene = bugu.acoustic.TestScenes.doorOpening(&door_half_portals) },
        .{ .name = "cave", .scene = bugu.acoustic.TestScenes.cave() },
        .{ .name = "open_field", .scene = bugu.acoustic.TestScenes.openField() },
    };

    std.debug.print("[\n", .{});
    for (scenes, 0..) |case, index| {
        const response = try bugu.acoustic.solve(allocator, case.scene, listener, source, config, null);
        std.debug.print(
            "  {{\"scene\":\"{s}\",\"direct_gain\":{d:.5},\"direct_lowpass_hz\":{d:.1},\"transmission_gain\":{d:.5},\"transmission_lowpass_hz\":{d:.1},\"portal_gain\":{d:.5},\"portal_dir\":[{d:.3},{d:.3},{d:.3}],\"reflection0_gain\":{d:.5},\"late_reverb_send\":{d:.5},\"openness\":{d:.5},\"ambient_dir\":[{d:.3},{d:.3},{d:.3}],\"confidence\":{d:.3}}}{s}\n",
            .{
                case.name,
                response.direct_gain,
                response.direct_lowpass_hz,
                response.transmission_gain,
                response.transmission_lowpass_hz,
                response.diffraction_or_portal_gain,
                response.diffraction_or_portal_direction.x,
                response.diffraction_or_portal_direction.y,
                response.diffraction_or_portal_direction.z,
                response.early_reflection_taps[0].gain,
                response.late_reverb_send,
                response.openness,
                response.ambient_direction.x,
                response.ambient_direction.y,
                response.ambient_direction.z,
                response.confidence,
                if (index + 1 == scenes.len) "" else ",",
            },
        );
    }
    std.debug.print("]\n", .{});
}
