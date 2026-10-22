//! Copied, versioned host-to-layer gain binding input. No runtime or DSP imports.
const ids = @import("ids.zig");
const layer_contract = @import("sme-layer-contract");
/// Explicit accepted-input driver. Initial gain_db remains authored until input.
/// Curves produce linear amplitude, not decibels inferred from their names.
pub const BindingV1 = struct {
    layer: ids.LayerId,
    parameter: ids.MusicParameterId,
    ramps: layer_contract.Ramps = .{},
    output_policy: layer_contract.OutputPolicy = .reject,
};
pub const ConfigV1 = struct {
    version: u16 = 1,
    bindings: []const BindingV1 = &.{},
    /// Director values are sampled only at genuine owned Control observations.
    /// M2 still ramps on the independent available-source clock.
    parameter_sampling: enum { accepted_only, observed_control_v1 } = .accepted_only,
    pub fn validate(self: ConfigV1) !void {
        if (self.version != 1) return error.UnsupportedVersion;
        for (self.bindings, 0..) |binding, i| {
            if (binding.layer.value() == 0 or binding.parameter.value() == 0) return error.InvalidBinding;
            for (self.bindings[0..i]) |prior| if (prior.layer == binding.layer) return error.ConflictingWriters;
            inline for (.{ binding.ramps.attack, binding.ramps.release }) |duration| switch (duration) {
                .frames => {},
                .quarter_beats => |q| if (q.denominator == 0) return error.InvalidDuration,
            };
        }
    }
};
