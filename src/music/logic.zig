//! Typed, bounded, side-effect-free logic. Scalar values are signed Q16.16;
//! integers and stable IDs never convert through floating point.
const std = @import("std");
pub const s = @import("sme-bank").schema;
pub const validation = @import("sme-bank").selection_validation;
pub const Error = validation.Error;
pub const Kind = validation.Kind;
pub const Value = union(Kind) { boolean: bool, integer: i64, scalar: i32, id: u64 };
pub const Environment = struct { committed_state: u32, parameters: []const i32, contexts: []const Value };
pub const Program = struct {
    code: []const s.Instruction,
    tables: s.Tables,
    stack_limit: u16,
    pub fn init(tables: s.Tables, index: u32, profile: s.Platform) Error!Program {
        if (index >= tables.logic.len) return error.InvalidMusicGraph;
        const p = tables.logic[index];
        const code = try validation.items(s.Instruction, tables.instructions, p.instructions);
        _ = try validation.program(tables, code, p.stack_limit, profile);
        return .{ .code = code, .tables = tables, .stack_limit = p.stack_limit };
    }
    pub fn evaluate(self: Program, env: Environment) Error!bool {
        if (env.committed_state >= self.tables.states.len or env.parameters.len != self.tables.parameters.len or env.contexts.len != self.tables.contexts.len) return error.InvalidMusicGraph;
        for (env.contexts, self.tables.contexts) |value, context| {
            if (std.meta.activeTag(value) != validation.contextKind(context.kind)) return error.InvalidMusicGraph;
            if (value == .id and value.id == 0) return error.InvalidMusicGraph;
        }
        var stack: [s.Limits.logic_stack]Value = undefined;
        var depth: usize = 0;
        // Bytecode and declarations are borrowed immutable validated data.
        for (self.code) |op| {
            switch (op.op) {
                .push_bool => {
                    stack[depth] = .{ .boolean = op.integer != 0 };
                    depth += 1;
                },
                .push_number => {
                    stack[depth] = .{ .scalar = try validation.quantize(op.number) };
                    depth += 1;
                },
                .push_integer => {
                    stack[depth] = .{ .integer = op.integer };
                    depth += 1;
                },
                .push_id => {
                    stack[depth] = .{ .id = op.unsigned };
                    depth += 1;
                },
                .load_state => {
                    stack[depth] = .{ .boolean = env.committed_state == op.reference };
                    depth += 1;
                },
                .load_parameter => {
                    stack[depth] = .{ .scalar = env.parameters[op.reference] };
                    depth += 1;
                },
                .load_context => {
                    stack[depth] = env.contexts[op.reference];
                    depth += 1;
                },
                .eq, .ne, .lt, .le, .gt, .ge => {
                    const right = stack[depth - 1];
                    const left = stack[depth - 2];
                    const ordering: std.math.Order = switch (left) {
                        .boolean => |v| std.math.order(@intFromBool(v), @intFromBool(right.boolean)),
                        .integer => |v| std.math.order(v, right.integer),
                        .scalar => |v| std.math.order(v, right.scalar),
                        .id => |v| std.math.order(v, right.id),
                    };
                    const result = switch (op.op) {
                        .eq => ordering == .eq,
                        .ne => ordering != .eq,
                        .lt => ordering == .lt,
                        .le => ordering != .gt,
                        .gt => ordering == .gt,
                        .ge => ordering != .lt,
                        else => unreachable,
                    };
                    depth -= 1;
                    stack[depth - 1] = .{ .boolean = result };
                },
                .and_op, .or_op => {
                    const b = stack[depth - 1].boolean;
                    const a = stack[depth - 2].boolean;
                    depth -= 1;
                    stack[depth - 1] = .{ .boolean = if (op.op == .and_op) a and b else a or b };
                },
                .not_op => stack[depth - 1].boolean = !stack[depth - 1].boolean,
                .in_range => {
                    const hi = stack[depth - 1];
                    const lo = stack[depth - 2];
                    const v = stack[depth - 3];
                    const result = switch (v) {
                        .integer => |n| n >= lo.integer and n <= hi.integer,
                        .scalar => |n| n >= lo.scalar and n <= hi.scalar,
                        else => unreachable,
                    };
                    depth -= 2;
                    stack[depth - 1] = .{ .boolean = result };
                },
                .return_bool => return stack[0].boolean,
            }
        }
        return error.InvalidMusicGraph;
    }
};
pub fn evaluate(tables: s.Tables, index: u32, env: Environment, profile: s.Platform) Error!bool {
    if (index == s.none) return true;
    return (try Program.init(tables, index, profile)).evaluate(env);
}
pub const stack_bytes = @sizeOf([s.Limits.logic_stack]Value);

/// For immutable tables already admitted by selection_validation.validate.
/// Reuses load-time stack/type proof rather than revalidating every candidate.
pub fn evaluateAdmitted(tables: s.Tables, index: u32, env: Environment) Error!bool {
    if (index == s.none) return true;
    if (index >= tables.logic.len) return error.InvalidMusicGraph;
    const p = tables.logic[index];
    const code = try validation.items(s.Instruction, tables.instructions, p.instructions);
    const program: Program = .{ .code = code, .tables = tables, .stack_limit = p.stack_limit };
    return program.evaluate(env);
}
