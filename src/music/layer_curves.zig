//! TASK-012 bounded, target-unit-agnostic curve evaluation.
//! Construction owns every numeric byte; evaluation never borrows a bank/AST.
//! See docs/validation/sme/TASK-012/curve-contract.md for the narrow contract.
const std = @import("std");
const s = @import("sme-bank").schema;
pub const max_curves: usize = 1024;
pub const max_points_per_curve: usize = 256;
pub const max_total_points: usize = 65536;
pub const Error = s.BankError || std.mem.Allocator.Error || error{ NonFiniteInput, InvalidInputRange };

/// Validate this typed component only, not a whole bank. Unowned flat points
/// still must be finite and normalized. Shared ranges are valid inputs.
pub fn validateTables(curves: []const s.Curve, points: []const s.CurvePoint, profile: s.Platform) s.BankError!void {
    if (profile.max_table_records == 0 or profile.max_table_records > s.Limits.records or curves.len > profile.max_table_records or points.len > profile.max_table_records) return error.ResourceLimitExceeded;
    if (curves.len > max_curves or points.len > max_total_points) return error.ResourceLimitExceeded;
    for (points) |point| {
        if (!std.math.isFinite(point.position) or point.position < 0 or point.position > 1 or !std.math.isFinite(point.value)) return error.InvalidRecord;
    }
    for (curves) |curve| {
        if (curve.points.count == 0) return error.InvalidRecord;
        if (curve.points.count > max_points_per_curve) return error.ResourceLimitExceeded;
        const first: usize = curve.points.first;
        const count: usize = curve.points.count;
        if (first > points.len or count > points.len - first) return error.InvalidReference;
        const items = points[first..][0..count];
        for (items[1..], items[0 .. items.len - 1]) |next, previous| {
            if (next.position <= previous.position) return error.InvalidRecord;
        }
    }
}

/// Explicit external-input normalization; target units are the caller's policy.
pub fn normalize(input: f64, minimum: f64, maximum: f64) Error!f64 {
    if (!std.math.isFinite(input)) return error.NonFiniteInput;
    if (!std.math.isFinite(minimum) or !std.math.isFinite(maximum) or minimum >= maximum) return error.InvalidInputRange;
    if (input <= minimum) return 0;
    if (input >= maximum) return 1;
    const span = maximum - minimum;
    const result = if (std.math.isFinite(span))
        (input - minimum) / span
    else
        (input * 0.5 - minimum * 0.5) / (maximum * 0.5 - minimum * 0.5);
    return std.math.clamp(result, 0, 1);
}

/// Numeric descriptors intentionally omit string-pool indices so the owner
/// survives destruction of the bank and compiler that supplied its tables.
pub const Descriptor = struct { id: u64, points: s.Range };
pub const OwnedCurves = struct {
    allocator: std.mem.Allocator,
    descriptors: []const Descriptor,
    points: []const s.CurvePoint,

    /// Offline/control construction. Do not shallow-copy this owning value.
    pub fn init(allocator: std.mem.Allocator, curves: []const s.Curve, points: []const s.CurvePoint, profile: s.Platform) Error!OwnedCurves {
        try validateTables(curves, points, profile);
        const descriptors = try allocator.alloc(Descriptor, curves.len);
        errdefer allocator.free(descriptors);
        const copied = try allocator.dupe(s.CurvePoint, points);
        for (curves, descriptors) |curve, *descriptor| descriptor.* = .{ .id = curve.key.id, .points = curve.points };
        return .{ .allocator = allocator, .descriptors = descriptors, .points = copied };
    }
    /// All readers must have stopped. Never destroy from the audio callback.
    pub fn deinit(self: *OwnedCurves) void {
        self.allocator.free(self.points);
        self.allocator.free(self.descriptors);
        self.* = undefined;
    }
    /// Allocation-free bounded lookup of a validated, owned curve by table index.
    pub fn evaluate(self: *const OwnedCurves, index: u32, input: f64) Error!f32 {
        if (!std.math.isFinite(input)) return error.NonFiniteInput;
        if (index >= self.descriptors.len) return error.InvalidReference;
        const range = self.descriptors[index].points;
        const points = self.points[range.first..][0..range.count];
        if (input <= points[0].position) return points[0].value;
        if (input >= points[points.len - 1].position) return points[points.len - 1].value;
        var lo: usize = 0;
        var hi: usize = points.len - 1;
        while (hi - lo > 1) {
            const middle = lo + (hi - lo) / 2;
            if (input == points[middle].position) return points[middle].value;
            if (input < points[middle].position) hi = middle else lo = middle;
        }
        const left = points[lo];
        const right = points[hi];
        if (left.value == right.value) return left.value;
        const fraction = (input - left.position) / (right.position - left.position);
        const a: f64 = left.value;
        const b: f64 = right.value;
        const value = a + (b - a) * fraction;
        return @floatCast(std.math.clamp(value, @min(a, b), @max(a, b)));
    }
};
