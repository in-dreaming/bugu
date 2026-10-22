//! Source-bound logic producer. Postfix expressions are nonrecursive and their
//! output is independently type checked before admission and after later passes.
const std = @import("std");
const bank = @import("sme-bank");
pub const s = bank.schema;
const logic = @import("sme-logic");
const compiler = @import("sme-compiler");
pub const Error = compiler.CompileError;
fn resolve(records: anytype, text: []const u8) Error!u32 {
    const id = std.fmt.parseInt(u64, text, 10) catch return error.InvalidSource;
    for (records, 0..) |record, i| if (record.key.id == id) return @intCast(i);
    return error.InvalidReference;
}
/// Grammar: whitespace-separated postfix operands true/false, integer:<i64>,
/// id:<u64>, scalar:<finite decimal>, state:<stable-id>, parameter:<stable-id>,
/// context:<stable-id>; eq/ne/lt/le/gt/ge/and/or/not/in_range. Terminator generated.
pub fn compileText(text: []const u8, declarations: s.Tables, out: []s.Instruction, profile: s.Platform) Error![]const s.Instruction {
    if (text.len > compiler.source_byte_limit) return error.ResourceLimitExceeded;
    var tokens = std.mem.tokenizeAny(u8, text, " \r\n\t");
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (count + 1 >= out.len or count + 1 >= profile.max_logic_instructions or count + 1 >= s.Limits.logic_instructions) return error.ResourceLimitExceeded;
        var op: s.Instruction = .{};
        if (std.mem.eql(u8, token, "true") or std.mem.eql(u8, token, "false")) {
            op.integer = @intFromBool(std.mem.eql(u8, token, "true"));
        } else if (std.mem.indexOfScalar(u8, token, ':')) |colon| {
            const prefix = token[0..colon];
            const value = token[colon + 1 ..];
            if (std.mem.eql(u8, prefix, "integer")) {
                op.op = .push_integer;
                op.integer = std.fmt.parseInt(i64, value, 10) catch return error.InvalidSource;
            } else if (std.mem.eql(u8, prefix, "id")) {
                op.op = .push_id;
                op.unsigned = std.fmt.parseInt(u64, value, 10) catch return error.InvalidSource;
            } else if (std.mem.eql(u8, prefix, "scalar")) {
                op.op = .push_number;
                const n = std.fmt.parseFloat(f64, value) catch return error.InvalidSource;
                op.number = @as(f64, @floatFromInt(try logic.validation.quantize(n))) / 65536;
            } else if (std.mem.eql(u8, prefix, "state")) {
                op.op = .load_state;
                op.reference = try resolve(declarations.states, value);
            } else if (std.mem.eql(u8, prefix, "parameter")) {
                op.op = .load_parameter;
                op.reference = try resolve(declarations.parameters, value);
            } else if (std.mem.eql(u8, prefix, "context")) {
                op.op = .load_context;
                op.reference = try resolve(declarations.contexts, value);
            } else return error.InvalidSource;
        } else {
            const Name = struct { text: []const u8, op: s.LogicOp };
            const names = [_]Name{ .{ .text = "eq", .op = .eq }, .{ .text = "ne", .op = .ne }, .{ .text = "lt", .op = .lt }, .{ .text = "le", .op = .le }, .{ .text = "gt", .op = .gt }, .{ .text = "ge", .op = .ge }, .{ .text = "and", .op = .and_op }, .{ .text = "or", .op = .or_op }, .{ .text = "not", .op = .not_op }, .{ .text = "in_range", .op = .in_range } };
            var found = false;
            for (names) |name| if (std.mem.eql(u8, token, name.text)) {
                op.op = name.op;
                found = true;
                break;
            };
            if (!found) return error.InvalidSource;
        }
        out[count] = op;
        count += 1;
    }
    if (count == 0 or count >= out.len) return error.InvalidSource;
    out[count] = .{ .op = .return_bool };
    count += 1;
    _ = try logic.validation.program(declarations, out[0..count], profile.max_logic_stack, profile);
    return out[0..count];
}
pub fn install(registry: *compiler.Registry) Error!void {
    try registry.registerPass(.logic, runPass);
    try registry.registerValidator(.logic, validateCompiledSource);
}
/// Authored typed instructions are source operands, not trusted compiled code:
/// derive terminators, fixed scalar literals, program ranges and stack peaks.
pub fn runPass(owned: *compiler.OwnedIR, ast: *const compiler.SourceAST) Error!void {
    if (ast.metadata.profile >= ast.tables.platforms.len) return error.InvalidSource;
    const profile = ast.tables.platforms[ast.metadata.profile];
    if (ast.tables.logic.len > s.Limits.logic_programs or ast.tables.instructions.len > s.Limits.logic_total_instructions) return error.ResourceLimitExceeded;
    // Orphan authored records are still input: validate before lowering can
    // discard unreferenced ranges, and repeat through the source-bound verifier.
    for (ast.tables.instructions) |instruction| try logic.validation.operand(ast.tables, instruction);
    const a = owned.arena.allocator();
    const programs = try a.alloc(s.Logic, ast.tables.logic.len);
    var code: std.ArrayList(s.Instruction) = .empty;
    for (ast.tables.logic, 0..) |source, i| {
        const source_code = try logic.validation.items(s.Instruction, ast.tables.instructions, source.instructions);
        if (source_code.len == 0 or source_code.len > profile.max_logic_instructions) return error.InvalidMusicGraph;
        const first = code.items.len;
        for (source_code) |instruction| {
            var op = instruction;
            if (op.op == .push_number) op.number = @as(f64, @floatFromInt(try logic.validation.quantize(op.number))) / 65536;
            try code.append(a, op);
        }
        if (source_code[source_code.len - 1].op != .return_bool) try code.append(a, .{ .op = .return_bool });
        if (code.items.len > s.Limits.logic_total_instructions) return error.ResourceLimitExceeded;
        const peak = try logic.validation.program(ast.tables, code.items[first..], source.stack_limit, profile);
        programs[i] = source;
        programs[i].instructions = .{ .first = @intCast(first), .count = @intCast(code.items.len - first) };
        programs[i].stack_limit = peak;
    }
    owned.ir.tables.logic = programs;
    owned.ir.tables.instructions = code.items;
}
pub fn validateCompiledSource(allocator: std.mem.Allocator, ast: *const compiler.SourceAST, ir: *const s.ValidatedIR) Error!void {
    inline for (.{ "states", "parameters", "contexts" }) |name| {
        const actual = @field(ir.tables, name);
        const authored = @field(ast.tables, name);
        if (actual.len != authored.len) return error.InvalidMusicGraph;
        for (actual, authored) |record, wanted| if (!std.meta.eql(record, wanted)) return error.InvalidMusicGraph;
    }
    var expected = compiler.OwnedIR.init(allocator);
    defer expected.deinit();
    try runPass(&expected, ast);
    if (ir.tables.logic.len != expected.ir.tables.logic.len or ir.tables.instructions.len != expected.ir.tables.instructions.len) return error.InvalidMusicGraph;
    for (ir.tables.logic, expected.ir.tables.logic) |actual, wanted| if (!std.meta.eql(actual, wanted)) return error.InvalidMusicGraph;
    for (ir.tables.instructions, expected.ir.tables.instructions) |actual, wanted| if (!std.meta.eql(actual, wanted)) return error.InvalidMusicGraph;
    if (ir.metadata.profile >= ir.tables.platforms.len) return error.InvalidMusicGraph;
    for (ir.tables.logic) |p| {
        _ = try logic.validation.program(ir.tables, try logic.validation.items(s.Instruction, ir.tables.instructions, p.instructions), p.stack_limit, ir.tables.platforms[ir.metadata.profile]);
    }
}
