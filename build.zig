const std = @import("std");
const pkg = @import("build.zig.zon");
const name = @tagName(pkg.name);
const protobuf = @import("protobuf");
const RunProtocStep = protobuf.RunProtocStep;
const TranslateC = @import("translate_c").Translator;

fn buildOptionsModule(builder: *std.Build) *std.Build.Module {
    const options = builder.addOptions();

    const pkg_version_sem = std.SemanticVersion.parse(pkg.version) catch |err| std.debug.panic(
        \\std.SemanticVersion.parse("{s}"): {s} when parsing build.zig.zon version
    , .{ @errorName(err), pkg.version });

    const raw_git_describe = blk: {
        const git = builder.findProgram(.{ .names = &.{"git"} }) orelse break :blk pkg.version;
        const argv = [_][]const u8{
            git, "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags", "--abbrev=9",
        };
        break :blk switch (builder.runFallible(&argv, .{ .cwd = .{ .dir = builder.root.root_dir.handle } })) {
            .success => |stdout| stdout,
            .spawn_failed, .bad_exit_code, .crashed => pkg.version,
        };
    };
    const git_describe = std.mem.trim(u8, raw_git_describe, &std.ascii.whitespace);

    var it = std.mem.splitScalar(u8, git_describe, '-');
    const tagged_ancestor = it.first();

    const tagged_ancestor_sem = std.SemanticVersion.parse(tagged_ancestor) catch |err| std.debug.panic(
        \\std.SemanticVersion.parse("{s}"): {s} when parsing tagged ancestor
    , .{ tagged_ancestor, @errorName(err) });
    if (pkg_version_sem.order(tagged_ancestor_sem) != .eq) {
        std.debug.panic("build.zig.zon version '{}.{}.{}' must be equal to tagged ancestor '{}.{}.{}'\n", .{
            pkg_version_sem.major, pkg_version_sem.minor, pkg_version_sem.patch, tagged_ancestor_sem.major, tagged_ancestor_sem.minor, tagged_ancestor_sem.patch,
        });
    }

    const suffix = switch (std.mem.count(u8, git_describe, "-")) {
        // Tagged commit
        0 => "",
        // Untagged commit
        2 => blk: {
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.panic("Unexpected `git describe` output: {s}\n", .{git_describe});
            }

            _ = std.fmt.parseUnsigned(u32, commit_height, 10) catch |err| std.debug.panic(
                \\std.fmt.parseUnsigned(u32, "{s}"): {s} when parsing commit height
            , .{ commit_height, @errorName(err) });
            break :blk builder.fmt("-nightly.{s}+{s}", .{ commit_height, commit_id[1..] });
        },
        else => std.debug.panic("Unexpected `git describe` output: {s}\n", .{git_describe}),
    };

    const version_option = builder.fmt("{d}.{d}.{d}{s}", .{
        pkg_version_sem.major, pkg_version_sem.minor, pkg_version_sem.patch, suffix,
    });
    options.addOption([:0]const u8, "name", name);
    options.addOption([:0]const u8, "version", builder.graph.arena.dupeSentinel(u8, version_option, 0) catch @panic("OOM"));
    options.addOption([:0]const u8, "description", pkg.description);
    return options.createModule();
}

fn buildProtobufGeneratorExecutable(builder: *std.Build) *std.Build.Step.Compile {
    return builder.addExecutable(.{
        .name = "protobuf_generator",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path(builder.pathResolve(&.{ "src", "protobuf_generator.zig" })),
            .target = builder.graph.host,
            .optimize = .debug,
            .imports = &.{},
        }),
    });
}

fn buildBuildkitModule(builder: *std.Build, protobuf_dep: *std.Build.Dependency, protobuf_mod: *std.Build.Module) struct { *RunProtocStep, *std.Build.Module } {
    const protobuf_generator_exe = buildProtobufGeneratorExecutable(builder);

    const generated_zig = builder.addWriteFiles().add("generated.zig",
        \\pub const v1 = @import("moby/buildkit/v1.pb.zig");
    );

    const protobuf_generator = builder.addRunArtifact(protobuf_generator_exe);
    const proto_dir = protobuf_generator.addOutputDirectoryArg2("proto", .{});

    var protobuf_compiler: *RunProtocStep = .create(protobuf_dep.builder, builder.graph.host, .{
        .destination_directory = generated_zig.dirname(),
        .source_files = &.{
            proto_dir.path(builder, builder.pathJoin(&[_][]const u8{
                "vendor", "api", "services", "control", "control.proto",
            })),
        },
        .include_directories = &.{proto_dir},
    });

    protobuf_compiler.step.dependOn(&protobuf_generator.step);

    return .{
        protobuf_compiler,
        builder.createModule(.{
            .root_source_file = generated_zig,
            .target = builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf_mod },
            },
        }),
    };
}

fn buildJQModule(builder: *std.Build) !*std.Build.Module {
    const translate_c_dep = builder.dependency("translate_c", .{});
    const jq_builder = builder.dependency("jq", .{}).builder;
    const flags = [_][]const u8{
        "-DIEEE_8087=1", "-D_GNU_SOURCE=1", "-DUSE_DECNUM=1", // TODO: "-DHAVE_LIBONIG=1",
    };

    const translate_jq = TranslateC.init(translate_c_dep, .{
        .c_source_file = jq_builder.path(jq_builder.pathResolve(&.{ "src", "jq.h" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .link_libc = true,
    });

    for ([_][]const u8{
        "builtin.c", "bytecode.c", "compile.c",  "execute.c",    "iso8601.c",
        "lexer.c",   "linker.c",   "locfile.c",  "parser.c",     "util.c",
        "jv.c",      "jv_alloc.c", "jv_aux.c",   "jv_dtoa.c",    "jv_dtoa_tsd.c",
        "jv_file.c", "jv_parse.c", "jv_print.c", "jv_unicode.c",
    }) |file_c| {
        translate_jq.mod.addCSourceFile(.{
            .file = jq_builder.path(jq_builder.pathResolve(&.{ "src", file_c })),
            .flags = &flags,
        });
    }

    for ([_][]const u8{
        "decContext.c", "decNumber.c",
    }) |file_c| {
        translate_jq.mod.addCSourceFile(.{
            .file = jq_builder.path(jq_builder.pathResolve(&.{ "vendor", "decNumber", file_c })),
            .flags = &flags,
        });
    }

    const builtin_jq = try jq_builder.root.root_dir.handle.readFileAlloc(builder.graph.io, jq_builder.pathResolve(&.{ "src", "builtin.jq" }), builder.graph.arena, .unlimited);
    var builtin_inc = try jq_builder.root.root_dir.handle.createFile(builder.graph.io, jq_builder.pathResolve(&.{ "src", "builtin.inc" }), .{});
    defer builtin_inc.close(builder.graph.io);

    var writer = builtin_inc.writer(builder.graph.io, &.{});

    var col: usize = 0;
    for (builtin_jq) |byte| {
        if (col == 16) {
            try writer.interface.writeByte('\n');
            col = 0;
        }

        if (byte < 0o100) {
            try writer.interface.print("  {o:0>3},", .{byte});
        } else {
            try writer.interface.print(" {o:0>4},", .{byte});
        }

        col += 1;
    }
    if (col > 0) try writer.interface.writeByte('\n');

    translate_jq.addIncludePath(jq_builder.path("."));
    translate_jq.addIncludePath(jq_builder.path("src"));
    translate_jq.addIncludePath(jq_builder.path("vendor"));

    return translate_jq.mod;
}

fn buildDockerModule(builder: *std.Build, options_mod: *std.Build.Module, protobuf_mod: *std.Build.Module, buildkit_mod: *std.Build.Module, jq_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "docker.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "build", .module = options_mod },
            .{ .name = "buildkit", .module = buildkit_mod },
            .{ .name = "jq", .module = jq_mod },
            .{ .name = "protobuf", .module = protobuf_mod },
        },
    });
}

fn buildManaModule(builder: *std.Build, docker_mod: *std.Build.Module, jq_mod: *std.Build.Module) *std.Build.Module {
    return builder.addModule("mana", .{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "mana.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "docker", .module = docker_mod },
            .{ .name = "jq", .module = jq_mod },
        },
    });
}

fn buildExitModule(builder: *std.Build) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "exit.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{},
    });
}

fn buildSchedulerModule(builder: *std.Build, mana_mod: *std.Build.Module, jq_mod: *std.Build.Module, exit_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "scheduler.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "mana", .module = mana_mod },
            .{ .name = "jq", .module = jq_mod },
            .{ .name = "exit", .module = exit_mod },
        },
    });
}

fn buildSpecModule(builder: *std.Build, options_mod: *std.Build.Module, scheduler_mod: *std.Build.Module, jq_mod: *std.Build.Module, exit_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "spec.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "scheduler", .module = scheduler_mod },
            .{ .name = "jq", .module = jq_mod },
            .{ .name = "build", .module = options_mod },
            .{ .name = "exit", .module = exit_mod },
        },
    });
}

fn buildMainModule(builder: *std.Build, options_mod: *std.Build.Module, spec_mod: *std.Build.Module, exit_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "main.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "spec", .module = spec_mod },
            .{ .name = "build", .module = options_mod },
            .{ .name = "exit", .module = exit_mod },
        },
    });
}

fn buildManaExecutable(builder: *std.Build) !struct { *std.Build.Step.Compile, *std.Build.Step.InstallArtifact } {
    const options_mod = buildOptionsModule(builder);
    const protobuf_dep = builder.dependency("protobuf", .{});
    const protobuf_mod = protobuf_dep.module("protobuf");
    const protobuf_compiler, const buildkit_mod = buildBuildkitModule(builder, protobuf_dep, protobuf_mod);
    const jq_mod = try buildJQModule(builder);
    const docker_mod = buildDockerModule(builder, options_mod, protobuf_mod, buildkit_mod, jq_mod);
    const mana_mod = buildManaModule(builder, docker_mod, jq_mod);
    const exit_mod = buildExitModule(builder);
    const scheduler_mod = buildSchedulerModule(builder, mana_mod, jq_mod, exit_mod);
    const spec_mod = buildSpecModule(builder, options_mod, scheduler_mod, jq_mod, exit_mod);
    const main_mod = buildMainModule(builder, options_mod, spec_mod, exit_mod);

    var mana_exe = builder.addExecutable(.{
        .name = "mana",
        .root_module = main_mod,
    });

    mana_exe.step.dependOn(protobuf_compiler.step);

    const mana_install = builder.addInstallArtifact(mana_exe, .{});
    builder.getInstallStep().dependOn(&mana_install.step);

    return .{ mana_exe, mana_install };
}

pub fn build(builder: *std.Build) !void {
    const mana_exe, const mana_install = try buildManaExecutable(builder);
    try testManaExecutable(builder, mana_exe, mana_install);
}

const TestOptions = struct {
    args: []const []const u8,
    stderr: ?[]const u8 = null,
    err: ?[]const u8 = null,
};

fn runTest(builder: *std.Build, mana_exe: *std.Build.Step.Compile, test_step: *std.Build.Step, tests_dir: std.Io.Dir, start_redirect_step: *std.Build.Step, stop_redirect_step: *std.Build.Step, manazon_path: []const u8) !void {
    const direct_mana = builder.addRunArtifact(mana_exe);
    const indirect_mana = builder.addRunArtifact(mana_exe);
    const manazon_dir = std.fs.path.dirname(manazon_path).?;
    var it = std.fs.path.componentIterator(manazon_path);
    const result = it.first().?.name;
    const options_source = try tests_dir.readFileAllocOptions(builder.graph.io, builder.pathResolve(&.{ manazon_dir, "options.zon" }), builder.graph.arena, .unlimited, .of(u8), 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const options = try std.zon.parse.fromSlice(TestOptions, .{
        .gpa = builder.allocator,
        .arena = builder.graph.arena,
        .source = options_source,
        .diagnostics = &diag,
    });
    for ([_]*std.Build.Step.Run{ direct_mana, indirect_mana }) |mana| {
        mana.has_side_effects = true;
        mana.addArgs(options.args);
        mana.setCwd(builder.path(builder.pathResolve(&.{ "tests", manazon_dir })));
        if (std.mem.eql(u8, result, "success")) {
            mana.expectExitCode(0);
            mana.expectStdErrEqual(builder.fmt("{s}\n", .{options.stderr.?}));
        } else if (std.mem.eql(u8, result, "failure")) {
            mana.expectExitCode(1);
            mana.expectStdErrMatch(builder.fmt("    .id = .{s},", .{options.err.?}));
        } else unreachable;
        test_step.dependOn(&mana.step);
    }
    indirect_mana.setEnvironmentVariable("DOCKER_HOST", "tcp://127.0.0.1:2375");
    indirect_mana.step.dependOn(start_redirect_step);
    stop_redirect_step.dependOn(&indirect_mana.step);
}

fn testManaExecutable(builder: *std.Build, mana_exe: *std.Build.Step.Compile, mana_install: *std.Build.Step.InstallArtifact) !void {
    const test_step = builder.step("test", "Run tests");
    test_step.dependOn(&mana_install.step);

    _ = builder.findProgram(.{ .names = &.{"sleep"} }) orelse return error.InstallSleepPlease;
    _ = builder.findProgram(.{ .names = &.{"socat"} }) orelse return error.InstallSocatPlease;
    const start_redirect = builder.addSystemCommand(&.{
        "sh", "-c", "socat TCP-LISTEN:2375,reuseaddr,fork UNIX-CLIENT:/var/run/docker.sock & sleep 0.15",
    });
    start_redirect.has_side_effects = true;

    const pkill = builder.findProgram(.{ .names = &.{"pkill"} }) orelse return error.InstallPKillPlease;
    const stop_redirect = builder.addSystemCommand(&.{
        pkill, "-f", "socat TCP-LISTEN:2375,reuseaddr,fork UNIX-CLIENT:/var/run/docker.sock",
    });
    stop_redirect.has_side_effects = true;

    test_step.dependOn(&stop_redirect.step);

    const tests_dir = try builder.root.openDir(builder.graph.io, "tests", .{ .iterate = true });
    defer tests_dir.close(builder.graph.io);

    var walker = try tests_dir.walk(builder.graph.arena);
    defer walker.deinit();

    while (try walker.next(builder.graph.io)) |entry| {
        switch (entry.kind) {
            .file => if (std.mem.eql(u8, entry.basename, "mana.zon")) {
                try runTest(builder, mana_exe, test_step, tests_dir, &start_redirect.step, &stop_redirect.step, entry.path);
            },
            else => {},
        }
    }

    try runTest(builder, mana_exe, test_step, tests_dir, &start_redirect.step, &stop_redirect.step, builder.pathResolve(&.{ "failure", "spec", "missing-mana-zon", "dummy" }));
}
