//! SME build extension v1. New tasks add independent *.zon fragments in
//! build_support/sme_tasks and tests/sme/*.zig; never edit a shared test list.
//! All discovery and registration is lexical and duplicate/unknown input is fatal.
//! Native inputs and system commands are actual Zig build operations, not stubs.
const std = @import("std");

pub const schema_version: u32 = 1;
pub const Import = struct { name: []const u8, module: []const u8 };
pub const CSource = struct { file: []const u8, flags: []const []const u8 = &.{} };
pub const Define = struct { name: []const u8, value: []const u8 = "1" };
pub const NativeInputs = struct {
    c_sources: []const CSource = &.{},
    include_paths: []const []const u8 = &.{},
    defines: []const Define = &.{},
    system_libraries: []const []const u8 = &.{},
    library_paths: []const []const u8 = &.{},
    object_files: []const []const u8 = &.{},
    link_libc: bool = false,
};
pub const Module = struct {
    name: []const u8,
    root_source_file: []const u8,
    imports: []const Import = &.{},
    native: NativeInputs = .{},
};
pub const Target = struct {
    name: []const u8,
    root_source_file: []const u8,
    kind: enum { executable, static_library },
    imports: []const Import = &.{},
    native: NativeInputs = .{},
    args: []const []const u8 = &.{},
    run_in_test: bool = false,
    install: bool = false,
    causal_resource_profile: CausalResourceProfile = .baseline256,
};
pub const CausalResourceProfile = enum { baseline256, partitioned544 };
pub const Check = struct {
    name: []const u8,
    /// Automatically discovered tests/sme paths, or explicit registered module
    /// source roots under src/ or tools/. Source roots reuse their existing module identity.
    tests: []const []const u8,
    /// Opt-in compilation root; never changes the default test graph's layout.
    causal_resource_profile: CausalResourceProfile = .baseline256,
    /// Explicit .zig adapter beside its one discovered suite. Only this
    /// registered adapter is omitted as a standalone default test artifact.
    causal_resource_root: ?[]const u8 = null,
};
pub const Command = struct {
    name: []const u8,
    argv: []const []const u8,
    /// Explicit source dependencies for independently owned helper programs.
    inputs: []const []const u8,
    /// Commands are opt-in unless the task explicitly joins the headless gate.
    run_in_test: bool = false,
};
pub const Fragment = struct {
    schema_version: u32,
    task_id: []const u8,
    modules: []const Module = &.{},
    /// Named dependencies consumed by future implemented facade exports.
    music_imports: []const Import = &.{},
    /// Optional named dependencies used by implemented legacy dispatch bridges.
    audio_imports: []const Import = &.{},
    targets: []const Target = &.{},
    checks: []const Check = &.{},
    commands: []const Command = &.{},
    /// Codec/compiler flags added to the actual shared bugu_audio module.
    audio_native: NativeInputs = .{},
};

/// Configure another compilation graph (for example the existing visualizer)
/// with the same independently registered music/module/native dependencies.
/// No steps or tests are duplicated in that graph.
pub fn configureMusicModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, audio: *std.Build.Module) void {
    _ = loadModuleGraph(b, target, optimize, audio) catch |err| {
        std.debug.panic("SME module registration failed: {s}", .{@errorName(err)});
    };
}

pub fn addSmeSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    audio: *std.Build.Module,
    test_step: *std.Build.Step,
) void {
    add(b, target, optimize, audio, test_step) catch |err| {
        std.debug.panic("SME registration failed: {s}", .{@errorName(err)});
    };
}

const ModuleGraph = struct {
    fragments: []const Fragment,
    modules: std.StringHashMap(*std.Build.Module),
    music: *std.Build.Module,
};
fn loadModuleGraph(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, audio: *std.Build.Module) !ModuleGraph {
    const fragment_paths = try discover(b, "build_support/sme_tasks", ".zon");
    if (fragment_paths.len == 0) return error.EmptySmeRegistration;
    var fragments: std.ArrayList(Fragment) = .empty;
    var tasks: std.StringHashMap(void) = .init(b.allocator);
    var module_sources: std.StringHashMap(void) = .init(b.allocator);
    try module_sources.put("src/music/api.zig", {});
    try module_sources.put("src/bugu_audio.zig", {});
    var modules: std.StringHashMap(*std.Build.Module) = .init(b.allocator);
    try modules.put("bugu_audio", audio);
    const music = b.createModule(.{ .root_source_file = b.path("src/music/api.zig"), .target = target, .optimize = optimize });
    try modules.put("music", music);
    configureResourceProfile(b, music, .baseline256);
    audio.addImport("music", music);

    for (fragment_paths) |path| {
        const bytes = try b.build_root.handle.readFileAllocOptions(b.graph.io, path, b.allocator, .limited(1024 * 1024), .of(u8), 0);
        // Unknown fields are errors, including misspelled fields that might omit a gate.
        const fragment = std.zon.parse.fromSliceAlloc(Fragment, b.allocator, bytes, null, .{}) catch |err| {
            std.debug.print("Invalid SME fragment {s}: {s}\n", .{ path, @errorName(err) });
            return error.InvalidSmeFragment;
        };
        if (fragment.schema_version != schema_version) return error.UnsupportedSmeFragmentVersion;
        if (fragment.task_id.len != 8 or !std.mem.startsWith(u8, fragment.task_id, "TASK-")) return error.InvalidTaskId;
        for (fragment.task_id[5..]) |c| if (c < '0' or c > '9') return error.InvalidTaskId;
        const entry = try tasks.getOrPut(fragment.task_id);
        if (entry.found_existing) return error.DuplicateSmeTask;
        try fragments.append(b.allocator, fragment);
        try applyNative(b, audio, fragment.audio_native);
        for (fragment.modules) |module| {
            try validName(module.name);
            try sourceFile(b, module.root_source_file);
            if (modules.contains(module.name)) return error.DuplicateSmeModule;
            const source_entry = try module_sources.getOrPut(module.root_source_file);
            if (source_entry.found_existing) return error.DuplicateSmeModuleSource;
            const m = b.createModule(.{ .root_source_file = b.path(module.root_source_file), .target = target, .optimize = optimize });
            try applyNative(b, m, module.native);
            try modules.put(module.name, m);
        }
    }
    // Resolve after registering every module, allowing cross-fragment references
    // without depending on filesystem enumeration or task ordering.
    for (fragments.items) |fragment| {
        try applyImports(music, fragment.music_imports, &modules);
        try applyImports(audio, fragment.audio_imports, &modules);
        for (fragment.modules) |module| {
            try applyImports(modules.get(module.name).?, module.imports, &modules);
        }
    }

    return .{ .fragments = try fragments.toOwnedSlice(b.allocator), .modules = modules, .music = music };
}

fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, audio: *std.Build.Module, test_step: *std.Build.Step) !void {
    const install_authoring_host = b.option(bool, "sme-authoring-install", "Install the authoring host archive; false builds the same target into cache only") orelse true;
    const graph = try loadModuleGraph(b, target, optimize, audio);
    const fragments = graph.fragments;
    var modules = graph.modules;
    const music = graph.music;
    // Explicit test-backed SERIAL qualification runner. This step installs one
    // filtered artifact only; it neither runs it nor joins the default gate or
    // default install step. The launcher owns its two separate processes.
    // This optional historical runner is available only when its explicit
    // source suite is included. Do not suppress any other filesystem error.
    const serial_suite_present = blk: {
        const stat = b.build_root.handle.statFile(b.graph.io, "tests/fixtures/sme/semantic_owner_capture/serial_replay_probe.zig", .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        if (stat.kind != .file) return error.InvalidSmeSource;
        break :blk true;
    };
    if (serial_suite_present) {
        const serial_root = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/sme/semantic_owner_capture/serial_replay_probe.zig"),
            .target = target,
            .optimize = optimize,
        });
        var serial_modules = modules.iterator();
        while (serial_modules.next()) |entry| serial_root.addImport(entry.key_ptr.*, entry.value_ptr.*);
        const serial_runner = b.addTest(.{
            .name = "sme-semantic-serial-runner",
            .root_module = serial_root,
            .filters = &.{"semantic serial independent process bounded recipe entry"},
        });
        const serial_install = b.addInstallArtifact(serial_runner, .{});
        b.step("sme-semantic-serial-build", "Build the restricted test-backed serial capture/replay runner")
            .dependOn(&serial_install.step);
    }
    const discovered_test_paths = try discover(b, "tests/sme", ".zig");
    if (discovered_test_paths.len == 0) return error.EmptySmeRegistration;
    // Source-local tests must run in their existing named module. Arbitrary
    // source files cannot become second roots: the same file might already
    // belong to a transitive dependency in this canonical graph.
    var collected_test_paths: std.ArrayList([]const u8) = .empty;
    try collected_test_paths.appendSlice(b.allocator, discovered_test_paths);
    var source_test_paths: std.StringHashMap(void) = .init(b.allocator);
    for (fragments) |fragment| for (fragment.checks) |check| for (check.tests) |path| {
        if (!std.mem.startsWith(u8, path, "src/") and !std.mem.startsWith(u8, path, "tools/")) continue;
        if (!std.mem.endsWith(u8, path, ".zig")) return error.InvalidSmeTestSource;
        try sourceFile(b, path);
        const registered = blk: {
            if (std.mem.eql(u8, path, "src/music/api.zig") or
                std.mem.eql(u8, path, "src/bugu_audio.zig")) break :blk true;
            for (fragments) |owner| for (owner.modules) |module| {
                if (std.mem.eql(u8, module.root_source_file, path)) break :blk true;
            };
            break :blk false;
        };
        if (!registered) return error.UnregisteredSmeTestModuleSource;
        const entry = try source_test_paths.getOrPut(path);
        if (!entry.found_existing) try collected_test_paths.append(b.allocator, path);
    };
    const test_paths = try collected_test_paths.toOwnedSlice(b.allocator);
    var names: std.StringHashMap(void) = .init(b.allocator);
    var test_runs: std.StringHashMap(*std.Build.Step) = .init(b.allocator);
    var test_modules: std.StringHashMap(*std.Build.Module) = .init(b.allocator);
    var partitioned_test_runs: std.StringHashMap(*std.Build.Step) = .init(b.allocator);
    const test_use_llvm = b.option(bool, "sme-test-use-llvm", "Explicit LLVM backend for named SME test roots; unset preserves the default backend");
    const partitioned_test_filter = b.option([]const u8, "sme-partitioned544-test-filter", "Compile only matching tests in named partitioned544 checks; default checks are unchanged");
    var resource_roots: std.StringHashMap(void) = .init(b.allocator);
    for (fragments) |fragment| for (fragment.checks) |check| {
        if (check.causal_resource_profile == .baseline256) {
            if (check.causal_resource_root != null) return error.InvalidSmeResourceRoot;
            continue;
        }
        if (check.tests.len != 1) return error.InvalidSmeResourceRoot;
        const path = check.causal_resource_root orelse return error.InvalidSmeResourceRoot;
        const expected = b.fmt("tests/sme/{s}_partitioned544.zig", .{std.fs.path.stem(check.tests[0])});
        if (!std.mem.eql(u8, path, expected) or
            !std.mem.eql(u8, std.fs.path.dirname(check.tests[0]) orelse "", "tests/sme") or
            std.mem.eql(u8, path, check.tests[0])) return error.InvalidSmeResourceRoot;
        var discovered = false;
        for (test_paths) |candidate| {
            if (std.mem.eql(u8, candidate, path)) {
                discovered = true;
                break;
            }
        }
        if (!discovered) return error.UnregisteredSmeTest;
        const entry = try resource_roots.getOrPut(path);
        if (entry.found_existing) return error.DuplicateSmeResourceRoot;
    };
    for (test_paths) |path| {
        // Only explicitly registered resource adapters are opt-in. Every
        // original suite and every other discovered .zig file stays gated.
        if (resource_roots.contains(path)) continue;
        // A test may itself be an independently registered module. Reuse it;
        // compiling its source again as a second root breaks cyclic identity.
        const root = blk: {
            if (std.mem.eql(u8, path, "src/music/api.zig")) break :blk music;
            if (std.mem.eql(u8, path, "src/bugu_audio.zig")) break :blk audio;
            for (fragments) |fragment| for (fragment.modules) |module| {
                if (std.mem.eql(u8, module.root_source_file, path)) break :blk modules.get(module.name).?;
            };
            break :blk b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize });
        };
        // Existing source modules retain exactly their registered imports;
        // harness-only fixtures must not leak into production module graphs.
        if (!source_test_paths.contains(path)) {
            try addTestImport(root, "bugu_audio", audio);
            try addTestImport(root, "music", music);
            // Additional modules are explicit test-harness dependencies, not public API.
            var module_iterator = modules.iterator();
            while (module_iterator.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, "bugu_audio") and !std.mem.eql(u8, entry.key_ptr.*, "music"))
                    try addTestImport(root, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        const executable = b.addTest(.{ .name = std.fs.path.stem(path), .root_module = root, .use_llvm = test_use_llvm });
        const run = b.addRunArtifact(executable);
        test_step.dependOn(&run.step);
        try test_runs.put(path, &run.step);
        try test_modules.put(path, root);
    }

    // Ordinary Host compatibility only. Keep all original test bodies and the
    // full legacy target unchanged; exclude the two private forensic captures.
    if (test_modules.get("tests/sme/author_live_owner_test.zig")) |ordinary_owner_root| {
        const ordinary_owner_name = "sme-author-live-ordinary-owner-test";
        try registerName(b, &names, ordinary_owner_name);
        const ordinary_owner = b.addTest(.{
            .name = ordinary_owner_name,
            .root_module = ordinary_owner_root,
            .use_llvm = test_use_llvm,
            .filters = &.{ "live author", "live active background" },
        });
        const ordinary_owner_run = b.addRunArtifact(ordinary_owner);
        b.step(ordinary_owner_name, "Run the eight ordinary Host compatibility tests without private forensic captures")
            .dependOn(&ordinary_owner_run.step);

    }

    // Build-only compatibility artifact: the external launcher owns distinct
    // record/replay processes and selects the retained lifecycle test. This
    // neither executes the 92-test root nor changes any default check.
    if (test_modules.get("tests/sme/live_tick_test.zig")) |lifecycle_root| {
        const lifecycle_runner = b.addTest(.{
            .name = "sme-live-lifecycle-process-runner",
            .root_module = lifecycle_root,
            .use_llvm = test_use_llvm,
            .filters = &.{"private lifecycle files use explicit record-only or replay-only process branch"},
        });
        const lifecycle_install = b.addInstallArtifact(lifecycle_runner, .{});
        b.step("sme-live-lifecycle-process-build", "Build only the retained lifecycle process compatibility test")
            .dependOn(&lifecycle_install.step);

    }

    // Clone only after canonical test imports are complete. All defaults keep
    // the original graph; an extended artifact gets one disjoint graph using
    // the same sources/native inputs, including its own audio -> music link.
    var partitioned_graph = try cloneResourceGraph(b, &graph, .partitioned544);
    for (fragments) |fragment| {
        for (fragment.checks) |check| {
            try registerName(b, &names, check.name);
            if (check.tests.len == 0) return error.EmptySmeCheck;
            const resource_root = check.causal_resource_root;
            const step = b.step(check.name, "Run independently registered SME tests");
            var claimed: std.StringHashMap(void) = .init(b.allocator);
            for (check.tests) |path| {
                const default_run = test_runs.get(path) orelse return error.UnregisteredSmeTest;
                const entry = try claimed.getOrPut(path);
                if (entry.found_existing) return error.DuplicateSmeTestReference;
                const run = switch (check.causal_resource_profile) {
                    .baseline256 => default_run,
                    .partitioned544 => partitioned_test_runs.get(resource_root.?) orelse blk: {
                        // A relative source import shares the compilation-root
                        // module, which Zig requires for test discovery.
                        const root = try cloneTestRoot(b, test_modules.get(path).?, b.path(resource_root.?), &partitioned_graph.copies);
                        const filters: []const []const u8 = if (partitioned_test_filter) |filter| &.{ filter, "partitioned544 suite registration" } else &.{};
                        const executable = b.addTest(.{
                            .name = b.fmt("{s}-partitioned544", .{std.fs.path.stem(path)}),
                            .root_module = root,
                            .filters = filters,
                            .use_llvm = test_use_llvm,
                        });
                        const extended_run = b.addRunArtifact(executable);
                        try partitioned_test_runs.put(resource_root.?, &extended_run.step);
                        break :blk &extended_run.step;
                    },
                };
                step.dependOn(run);
            }
        }
        for (fragment.targets) |item| {
            try registerName(b, &names, item.name);
            try sourceFile(b, item.root_source_file);
            // Targets must use a separate harness instead of compiling a named
            // module's source again as a second root in the same graph.
            if (std.mem.eql(u8, item.root_source_file, "src/music/api.zig") or
                std.mem.eql(u8, item.root_source_file, "src/bugu_audio.zig")) return error.TargetOverlapsSmeModuleSource;
            for (fragments) |owner| for (owner.modules) |module| {
                if (std.mem.eql(u8, item.root_source_file, module.root_source_file)) return error.TargetOverlapsSmeModuleSource;
            };
            if (item.kind == .static_library and (item.run_in_test or item.args.len != 0)) return error.UnsupportedLibraryRun;
            const root = b.createModule(.{ .root_source_file = b.path(item.root_source_file), .target = target, .optimize = optimize });
            try applyNative(b, root, item.native);
            const target_modules = switch (item.causal_resource_profile) {
                .baseline256 => &modules,
                .partitioned544 => &partitioned_graph.modules,
            };
            try applyImports(root, item.imports, target_modules);
            const artifact = switch (item.kind) {
                .executable => b.addExecutable(.{ .name = item.name, .root_module = root }),
                .static_library => b.addLibrary(.{ .name = item.name, .linkage = .static, .root_module = root }),
            };
            // The authoring archive is finally linked by the native C/C++
            // toolchain, so it must carry Zig's required runtime helpers.
            if (std.mem.eql(u8, item.name, "sme-authoring-build")) {
                artifact.bundle_compiler_rt = true;
                // Zig 0.16 packages UBSan separately from compiler-rt. The
                // native final link does not automatically add these helpers.
                artifact.bundle_ubsan_rt = true;
            }
            // This opt-out applies only to the authoring host; default and all
            // other registered target installation behavior remain unchanged.
            const install_target = item.install and (install_authoring_host or !std.mem.eql(u8, item.name, "sme-authoring-build"));
            // Compile.step alone can be semantic-only (-fno-emit-bin). Request
            // this host's cache artifact even when installation is deferred.
            if (!install_authoring_host and std.mem.eql(u8, item.name, "sme-authoring-build")) {
                _ = artifact.getEmittedBin();
            }
            const installation = if (install_target) b.addInstallArtifact(artifact, .{}) else null;
            if (installation) |install| b.getInstallStep().dependOn(&install.step);
            const step = b.step(item.name, "Build or run independently registered SME target");
            // An explicitly installed named target produces its own stable
            // artifact without invoking unrelated default install targets.
            if (installation) |install| step.dependOn(&install.step);
            switch (item.kind) {
                .executable => {
                    const run = b.addRunArtifact(artifact);
                    run.addArgs(item.args);
                    if (b.args) |args| run.addArgs(args);
                    step.dependOn(&run.step);
                    if (item.run_in_test) test_step.dependOn(&run.step);
                },
                .static_library => step.dependOn(&artifact.step),
            }
        }
        for (fragment.commands) |command| {
            try registerName(b, &names, command.name);
            if (command.argv.len == 0 or command.argv[0].len == 0 or command.inputs.len == 0) return error.InvalidSmeCommand;
            const run = b.addSystemCommand(command.argv);
            run.setCwd(b.path("."));
            for (command.inputs) |input| {
                try sourceFile(b, input);
                run.addFileInput(b.path(input));
            }
            const step = b.step(command.name, "Run independently registered SME helper");
            step.dependOn(&run.step);
            if (command.run_in_test) test_step.dependOn(&run.step);
        }
    }
}

fn configureResourceProfile(b: *std.Build, music: *std.Build.Module, profile: CausalResourceProfile) void {
    const options = b.addOptions();
    options.addOption(CausalResourceProfile, "resource_profile", profile);
    music.addOptions("sme-causal-resource-options", options);
}

const ModuleCopies = std.array_hash_map.Auto(*std.Build.Module, *std.Build.Module);
const ResourceGraph = struct {
    modules: std.StringHashMap(*std.Build.Module),
    copies: ModuleCopies,
};

/// Preserve all scalar and native/link configuration without reapplying any
/// audio_native input. Shared native lists are read-only after this copy.
/// Import maps and graph caches are fresh, never cleared through shared state.
fn cloneConfiguredModule(b: *std.Build, canonical: *std.Build.Module) !*std.Build.Module {
    const copy = try b.allocator.create(std.Build.Module);
    copy.init(b, .{ .existing = canonical });
    copy.import_table = .empty;
    copy.cached_graph = .{ .modules = &.{}, .names = &.{} };
    return copy;
}

fn cloneResourceGraph(b: *std.Build, canonical: *const ModuleGraph, profile: CausalResourceProfile) !ResourceGraph {
    var result: ResourceGraph = .{ .modules = .init(b.allocator), .copies = .empty };
    var registered = canonical.modules.iterator();
    while (registered.next()) |entry| {
        const original = entry.value_ptr.*;
        const copy = result.copies.get(original) orelse blk: {
            const created = try cloneConfiguredModule(b, original);
            try result.copies.put(b.allocator, original, created);
            break :blk created;
        };
        try result.modules.put(entry.key_ptr.*, copy);
    }
    // Close over every import, including generated options or external helper
    // modules. No dependency can lead an extended artifact back into the
    // original audio/music graph. Each original pointer has exactly one copy.
    var index: usize = 0;
    while (index < result.copies.count()) : (index += 1) {
        const original = result.copies.keys()[index];
        const copy = result.copies.values()[index];
        for (original.import_table.keys(), original.import_table.values()) |name, dependency| {
            const remapped = result.copies.get(dependency) orelse blk: {
                const created = try cloneConfiguredModule(b, dependency);
                try result.copies.put(b.allocator, dependency, created);
                break :blk created;
            };
            copy.addImport(name, remapped);
        }
    }
    configureResourceProfile(b, result.modules.get("music").?, profile);
    return result;
}

fn cloneTestRoot(b: *std.Build, canonical: *std.Build.Module, source: std.Build.LazyPath, copies: *const ModuleCopies) !*std.Build.Module {
    const root = try cloneConfiguredModule(b, canonical);
    root.root_source_file = source.dupe(b);
    for (canonical.import_table.keys(), canonical.import_table.values()) |name, module| {
        root.addImport(name, copies.get(module) orelse return error.UnmappedSmeResourceImport);
    }
    return root;
}

fn addTestImport(root: *std.Build.Module, name: []const u8, module: *std.Build.Module) !void {
    if (root == module) return;
    if (root.import_table.get(name)) |existing| {
        if (existing != module) return error.DuplicateSmeImport;
        return;
    }
    root.addImport(name, module);
}

fn validName(name: []const u8) !void {
    if (!std.mem.startsWith(u8, name, "sme-") or name.len == 4) return error.InvalidSmeName;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return error.InvalidSmeName;
}
fn registerName(b: *std.Build, names: *std.StringHashMap(void), name: []const u8) !void {
    try validName(name);
    if (b.top_level_steps.contains(name)) return error.DuplicateSmeStep;
    const entry = try names.getOrPut(name);
    if (entry.found_existing) return error.DuplicateSmeStep;
}
fn safePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, ':') != null) return error.InvalidSmePath;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.InvalidSmePath;
    }
}
fn sourceFile(b: *std.Build, path: []const u8) !void {
    try safePath(path);
    const stat = try b.build_root.handle.statFile(b.graph.io, path, .{});
    if (stat.kind != .file) return error.InvalidSmeSource;
}
// The main graph and the optional acoustic visualizer both configure this
// module graph in one std.Build. Declare the shared option once per Build.
fn gpuSourceOption(b: *std.Build) ?[]const u8 {
    const name = "sme-gpu-source";
    if (!b.available_options_map.contains(name))
        return b.option([]const u8, name, "Explicit local GPU source overlay (must match native linker graph)");
    const input = b.user_input_options.get(name) orelse return null;
    // The initial b.option call has already validated the type and marked an
    // invalid value as a build error. Do not re-declare or invent a fallback.
    return switch (input.value) {
        .scalar => |value| value,
        else => null,
    };
}

fn applyNative(b: *std.Build, module: *std.Build.Module, inputs: NativeInputs) !void {
    for (inputs.c_sources) |source| {
        try sourceFile(b, source.file);
        module.addCSourceFile(.{ .file = b.path(source.file), .flags = source.flags });
    }
    for (inputs.include_paths) |path| {
        try safePath(path);
        // Explicit local source overlay for the sole GPU include root. The
        // pinned default remains untouched and never competes on the include
        // search path with the selected source. Linking must use that same
        // exact overlay; this option neither fetches nor changes gitlinks.
        if (std.mem.eql(u8, path, "third_party/in_dreaming_gpu/src")) {
            if (gpuSourceOption(b)) |overlay| {
                if (!std.fs.path.isAbsolute(overlay)) return error.InvalidGpuOverlay;
                const header = b.pathJoin(&.{ overlay, "src/gpu/platform/gpu_platform.h" });
                const file = try std.Io.Dir.cwd().openFile(b.graph.io, header, .{});
                file.close(b.graph.io);
                module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ overlay, "src" }) });
                continue;
            }
        }
        module.addIncludePath(b.path(path));
    }
    for (inputs.defines) |define| {
        if (define.name.len == 0 or (!std.ascii.isAlphabetic(define.name[0]) and define.name[0] != '_')) return error.InvalidSmeDefine;
        for (define.name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.InvalidSmeDefine;
        module.addCMacro(define.name, define.value);
    }
    for (inputs.system_libraries) |library| {
        if (library.len == 0) return error.InvalidSmeLibrary;
        module.linkSystemLibrary(library, .{});
    }
    for (inputs.library_paths) |path| {
        try safePath(path);
        module.addLibraryPath(b.path(path));
    }
    for (inputs.object_files) |path| {
        try sourceFile(b, path);
        module.addObjectFile(b.path(path));
    }
    if (inputs.link_libc) module.link_libc = true;
}
fn applyImports(module: *std.Build.Module, imports: []const Import, modules: *const std.StringHashMap(*std.Build.Module)) !void {
    var names: std.StringHashMap(void) = .init(module.owner.allocator);
    for (imports) |item| {
        if (item.name.len == 0) return error.InvalidSmeImport;
        const entry = try names.getOrPut(item.name);
        if (entry.found_existing or module.import_table.contains(item.name)) return error.DuplicateSmeImport;
        module.addImport(item.name, modules.get(item.module) orelse return error.UnknownSmeModule);
    }
}
fn discover(b: *std.Build, directory: []const u8, extension: []const u8) ![]const []const u8 {
    var dir = try b.build_root.handle.openDir(b.graph.io, directory, .{ .iterate = true });
    defer dir.close(b.graph.io);
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(b.graph.io)) |entry| {
        if (entry.kind == .directory) continue;
        // Hidden or nested source files are never silently excluded from the gate.
        const is_source = std.mem.endsWith(u8, entry.basename, ".zig") or std.mem.endsWith(u8, entry.basename, ".zon");
        if (!is_source) continue;
        if (entry.kind != .file or entry.depth() != 1 or !std.mem.endsWith(u8, entry.basename, extension)) {
            std.debug.print("Unregistered SME source: {s}/{s}\n", .{ directory, entry.path });
            return error.UnregisteredSmeSource;
        }
        try paths.append(b.allocator, b.fmt("{s}/{s}", .{ directory, entry.basename }));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return paths.toOwnedSlice(b.allocator);
}
