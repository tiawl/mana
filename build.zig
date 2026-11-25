const std = @import("std");
const pkg = @import("build.zig.zon");
const name = @tagName(pkg.name);
const protobuf = @import("protobuf");
const RunProtocStep = protobuf.RunProtocStep;
const TranslateC = @import("translate_c").Translator;
const log = @import("src/log.zig");

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

fn buildProtobufGeneratorExecutable(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    return builder.addExecutable(.{
        .name = "protobuf_generator",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path(builder.pathResolve(&.{ "src", "protobuf_generator.zig" })),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
}

fn buildBuildkitModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, protobuf_dep: *std.Build.Dependency, protobuf_mod: *std.Build.Module) struct { *RunProtocStep, *std.Build.Module } {
    const protobuf_generator_exe = buildProtobufGeneratorExecutable(builder, target, optimize);

    const generated_zig = builder.addWriteFiles().add("generated.zig",
        \\pub const v1 = @import("moby/buildkit/v1.pb.zig");
    );

    const protobuf_generator = builder.addRunArtifact(protobuf_generator_exe);
    const proto_dir = protobuf_generator.addOutputDirectoryArg2("proto", .{});

    var protobuf_compiler: *RunProtocStep = .create(protobuf_dep.builder, target, .{
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
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf_mod },
            },
        }),
    };
}

fn buildJQModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, translate_c_dep: *std.Build.Dependency) !*std.Build.Module {
    const jq_builder = builder.dependency("jq", .{}).builder;
    const flags = [_][]const u8{
        "-DIEEE_8087=1", "-D_GNU_SOURCE=1", "-DUSE_DECNUM=1", // TODO: "-DHAVE_LIBONIG=1",
    };

    const translate_jq = TranslateC.init(translate_c_dep, .{
        .c_source_file = jq_builder.path(jq_builder.pathResolve(&.{ "src", "jq.h" })),
        .target = target,
        .optimize = optimize,
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

fn buildDockerModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, options_mod: *std.Build.Module, protobuf_mod: *std.Build.Module, buildkit_mod: *std.Build.Module, jq_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "docker.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build", .module = options_mod },
            .{ .name = "buildkit", .module = buildkit_mod },
            .{ .name = "jq", .module = jq_mod },
            .{ .name = "protobuf", .module = protobuf_mod },
        },
    });
}

fn buildClientModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, docker_mod: *std.Build.Module, jq_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "client.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "docker", .module = docker_mod },
            .{ .name = "jq", .module = jq_mod },
        },
    });
}

fn buildLogModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "log.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{},
    });
}

fn buildZluaModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const zlua_dep = builder.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua55,
    });
    return zlua_dep.module("zlua");
}

fn buildJsonLuaModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, zlua_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "jl.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zlua", .module = zlua_mod },
        },
    });
}

fn buildFfiModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, translate_c_dep: *std.Build.Dependency, zlua_mod: *std.Build.Module, log_mod: *std.Build.Module) *std.Build.Module {
    const aro_dep = translate_c_dep.builder.dependency("aro", .{ .target = target, .optimize = optimize });
    const libffi_dep = builder.dependency("libffi", .{ .target = target, .optimize = optimize });

    const translate_libffi = TranslateC.init(translate_c_dep, .{
        .c_source_file = builder.addWriteFiles().add("ffi_mod.h",
            \\#include "ffi.h"
        ),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const libffi_lib = libffi_dep.artifact("ffi");
    translate_libffi.addIncludePath(libffi_lib.getEmittedIncludeTree());
    translate_libffi.linkLibrary(libffi_lib);

    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "ffi.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "aro", .module = aro_dep.module("aro") },
            .{ .name = "zlua", .module = zlua_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "libffi", .module = translate_libffi.mod },
        },
    });
}

fn buildSchedulerModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, client_mod: *std.Build.Module, jq_mod: *std.Build.Module, zlua_mod: *std.Build.Module, jl_mod: *std.Build.Module, log_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "scheduler.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "client", .module = client_mod },
            .{ .name = "jq", .module = jq_mod },
            .{ .name = "zlua", .module = zlua_mod },
            .{ .name = "jl", .module = jl_mod },
            .{ .name = "log", .module = log_mod },
        },
    });
}

fn buildScriptModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, options_mod: *std.Build.Module, client_mod: *std.Build.Module, scheduler_mod: *std.Build.Module, jq_mod: *std.Build.Module, ffi_mod: *std.Build.Module, zlua_mod: *std.Build.Module, jl_mod: *std.Build.Module, log_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "script.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "client", .module = client_mod },
            .{ .name = "scheduler", .module = scheduler_mod },
            .{ .name = "build", .module = options_mod },
            .{ .name = "log", .module = log_mod },
            .{ .name = "zlua", .module = zlua_mod },
            .{ .name = "ffi", .module = ffi_mod },
            .{ .name = "jl", .module = jl_mod },
            .{ .name = "jq", .module = jq_mod },
        },
    });
}

fn buildManaModule(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, options_mod: *std.Build.Module, script_mod: *std.Build.Module, log_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "mana.zig" })),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "script", .module = script_mod },
            .{ .name = "build", .module = options_mod },
            .{ .name = "log", .module = log_mod },
        },
    });
}

fn buildManaExecutable(builder: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) !struct { *std.Build.Step.Compile, *std.Build.Step.InstallArtifact, *std.Build.Module, *std.Build.Module } {
    const options_mod = buildOptionsModule(builder);
    const protobuf_dep = builder.dependency("protobuf", .{});
    const protobuf_mod = protobuf_dep.module("protobuf");
    const protobuf_compiler, const buildkit_mod = buildBuildkitModule(builder, target, optimize, protobuf_dep, protobuf_mod);
    const translate_c_dep = builder.dependency("translate_c", .{});
    const jq_mod = try buildJQModule(builder, target, optimize, translate_c_dep);
    const docker_mod = buildDockerModule(builder, target, optimize, options_mod, protobuf_mod, buildkit_mod, jq_mod);
    const client_mod = buildClientModule(builder, target, optimize, docker_mod, jq_mod);
    const log_mod = buildLogModule(builder, target, optimize);
    const zlua_mod = buildZluaModule(builder, target, optimize);
    const jl_mod = buildJsonLuaModule(builder, target, optimize, zlua_mod);
    const scheduler_mod = buildSchedulerModule(builder, target, optimize, client_mod, jq_mod, zlua_mod, jl_mod, log_mod);
    const ffi_mod = buildFfiModule(builder, target, optimize, translate_c_dep, zlua_mod, log_mod);
    const script_mod = buildScriptModule(builder, target, optimize, options_mod, client_mod, scheduler_mod, jq_mod, ffi_mod, zlua_mod, jl_mod, log_mod);
    const mana_mod = buildManaModule(builder, target, optimize, options_mod, script_mod, log_mod);

    var mana_exe = builder.addExecutable(.{
        .name = "mana",
        .root_module = mana_mod,
    });

    mana_exe.step.dependOn(protobuf_compiler.step);

    const mana_install = builder.addInstallArtifact(mana_exe, .{});
    builder.getInstallStep().dependOn(&mana_install.step);

    return .{ mana_exe, mana_install, zlua_mod, jl_mod };
}

pub fn build(builder: *std.Build) !void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{}) orelse .debug;
    const mana_exe, const mana_install, const zlua_mod, const jl_mod = try buildManaExecutable(builder, target, optimize);

    const test_step = builder.step("test", "Run tests");
    test_step.dependOn(&mana_install.step);

    try runManaExecutableTests(builder, test_step, mana_exe);
    try runJsonLuaModuleTests(builder, test_step, zlua_mod, jl_mod);
}

const TestEnvironment = struct {
    DOCKER_HOST: ?[]const u8 = null,
};

const TestOptions = struct {
    args: []const []const u8,
    stderrEqual: ?[]const u8 = null,
    stderrMatch: ?[]const u8 = null,
    err: ?[]const u8 = null,
    runs: []const TestEnvironment,
};

fn runManaExecutableTest(builder: *std.Build, mana_exe: *std.Build.Step.Compile, test_step: *std.Build.Step, tests_dir: std.Io.Dir, start_redirect_step: *std.Build.Step, stop_redirect_step: *std.Build.Step, options_zon: []const u8) !void {
    const test_dir = std.fs.path.dirname(options_zon).?;
    var it = std.fs.path.componentIterator(test_dir);
    const exit_code = it.first().?.name;
    const options_source = try tests_dir.readFileAllocOptions(builder.graph.io, options_zon, builder.graph.arena, .unlimited, .of(u8), 0);
    var diag: std.zon.parse.Diagnostics = undefined;
    const options = try std.zon.parse.fromSlice(TestOptions, .{
        .gpa = builder.allocator,
        .arena = builder.graph.arena,
        .source = options_source,
        .diagnostics = &diag,
    });
    var mana: *std.Build.Step.Run = undefined;
    for (0..options.runs.len) |i| {
        mana = builder.addRunArtifact(mana_exe);
        mana.has_side_effects = true;
        mana.addArgs(options.args);
        mana.setCwd(builder.path(builder.pathResolve(&.{ "tests", "integration", test_dir })));
        mana.expectExitCode((std.meta.stringToEnum(log.ExitCode, exit_code) orelse unreachable).backingInt());
        if (std.mem.eql(u8, exit_code, "ok")) {
            if (options.stderrEqual) |stderr| {
                mana.expectStdErrEqual(builder.fmt("{s}\n", .{stderr}));
            } else if (options.stderrMatch) |stderr| {
                mana.expectStdErrMatch(builder.fmt("{s}\n", .{stderr}));
            } else unreachable;
        } else if (std.mem.eql(u8, exit_code, "err")) {
            mana.expectStdErrMatch(builder.fmt("    .id = .{s},", .{options.err.?}));
        } else if (std.mem.eql(u8, exit_code, "info")) {
            _ = mana.captureStdErr(.{});
        } else unreachable;
        test_step.dependOn(&mana.step);
        inline for (@typeInfo(TestEnvironment).@"struct".field_names) |field_name| {
            if (@field(options.runs[i], field_name)) |env_var| {
                mana.setEnvironmentVariable(field_name, env_var);
            }
        }
        if (options.runs[i].DOCKER_HOST != null) {
            mana.step.dependOn(start_redirect_step);
            stop_redirect_step.dependOn(&mana.step);
        }
    }
}

fn runManaExecutableTests(builder: *std.Build, test_step: *std.Build.Step, mana_exe: *std.Build.Step.Compile) !void {
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

    const tests_dir = try builder.root.openDir(builder.graph.io, builder.pathResolve(&.{ "tests", "integration" }), .{ .iterate = true });
    defer tests_dir.close(builder.graph.io);

    var walker = try tests_dir.walk(builder.graph.arena);
    defer walker.deinit();

    while (try walker.next(builder.graph.io)) |entry| {
        switch (entry.kind) {
            .file => if (std.mem.eql(u8, entry.basename, "options.zon")) {
                try runManaExecutableTest(builder, mana_exe, test_step, tests_dir, &start_redirect.step, &stop_redirect.step, entry.path);
            },
            else => {},
        }
    }
}

fn runJsonLuaModuleTests(builder: *std.Build, test_step: *std.Build.Step, zlua_mod: *std.Build.Module, jl_mod: *std.Build.Module) !void {
    const tester_mod = builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "tests", "unit", "jl", "tester.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "zlua", .module = zlua_mod },
            .{ .name = "jl", .module = jl_mod },
        },
    });

    const tester_exe = builder.addExecutable(.{
        .name = "jl_tester",
        .root_module = tester_mod,
    });

    var tester = builder.addRunArtifact(tester_exe);
    tester.has_side_effects = true;
    tester.addFileArg2(builder.path(builder.pathResolve(&.{ "tests", "unit", "jl", "test_suite.json" })), .{});
    tester.addFileArg2(builder.path(builder.pathResolve(&.{ "tests", "unit", "jl", "test_suite.lua" })), .{});
    tester.expectExitCode(3);
    tester.addCheck(.{ .expect_stdout_exact = tester.step.owner.graph.dupeString("") });

    test_step.dependOn(&tester.step);
}
