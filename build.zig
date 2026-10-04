const std = @import("std");
const zon = @import("build.zig.zon");
const name = @tagName(zon.name);
const protobuf = @import("protobuf");
const RunProtocStep = protobuf.RunProtocStep;

fn buildOptionsModule(builder: *std.Build) *std.Build.Module {
    const options = builder.addOptions();

    const zon_version_sem = std.SemanticVersion.parse(zon.version) catch |err| std.debug.panic(
        \\std.SemanticVersion.parse("{s}"): {s} when parsing build.zig.zon version
    , .{ @errorName(err), zon.version });

    const raw_git_describe = blk: {
        const git = builder.findProgram(.{ .names = &.{"git"} }) orelse break :blk zon.version;
        const argv = [_][]const u8{
            git, "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags", "--abbrev=9",
        };
        break :blk switch (builder.runFallible(&argv, .{ .cwd = .{ .dir = builder.root.root_dir.handle } })) {
            .success => |stdout| stdout,
            .spawn_failed, .bad_exit_code, .crashed => zon.version,
        };
    };
    const git_describe = std.mem.trim(u8, raw_git_describe, &std.ascii.whitespace);

    var it = std.mem.splitScalar(u8, git_describe, '-');
    const tagged_ancestor = it.first();

    const tagged_ancestor_sem = std.SemanticVersion.parse(tagged_ancestor) catch |err| std.debug.panic(
        \\std.SemanticVersion.parse("{s}"): {s} when parsing tagged ancestor
    , .{ tagged_ancestor, @errorName(err) });
    if (zon_version_sem.order(tagged_ancestor_sem) != .eq) {
        std.debug.panic("build.zig.zon version '{}.{}.{}' must be equal to tagged ancestor '{}.{}.{}'\n", .{
            zon_version_sem.major, zon_version_sem.minor, zon_version_sem.patch, tagged_ancestor_sem.major, tagged_ancestor_sem.minor, tagged_ancestor_sem.patch,
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
        zon_version_sem.major, zon_version_sem.minor, zon_version_sem.patch, suffix,
    });
    options.addOption([:0]const u8, "name", name);
    options.addOption([:0]const u8, "version", builder.graph.arena.dupeSentinel(u8, version_option, 0) catch @panic("OOM"));
    return options.createModule();
}

fn buildProtogenExecutable(builder: *std.Build) *std.Build.Step.Compile {
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

fn buildBuildkitModule(builder: *std.Build) struct { *RunProtocStep, *std.Build.Module } {
    const protobuf_generator_exe = buildProtogenExecutable(builder);

    const generated_zig = builder.addWriteFiles().add("generated.zig",
        \\pub const v1 = @import("moby/buildkit/v1.pb.zig");
    );

    const protobuf_generator = builder.addRunArtifact(protobuf_generator_exe);
    const proto_dir = protobuf_generator.addOutputDirectoryArg2("proto", .{});

    const protobuf_dep = builder.dependency("protobuf", .{});
    var protobuf_compiler: *RunProtocStep = .create(protobuf_dep.builder, builder.graph.host, .{
        .destination_directory = generated_zig.dirname(),
        .source_files = &.{
            proto_dir.path(builder, builder.pathJoin(&[_][]const u8{
                "vendor", "api", "services", "control", "control.proto",
            })),
        },
        .include_directories = &.{proto_dir},
    });
    protobuf_compiler.verbose = true;

    protobuf_compiler.step.dependOn(&protobuf_generator.step);

    return .{
        protobuf_compiler,
        builder.createModule(.{
            .root_source_file = generated_zig,
            .target = builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
            },
        }),
    };
}

fn buildJSONModule(builder: *std.Build) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "json.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{},
    });
}

fn buildDockerModule(builder: *std.Build, options_mod: *std.Build.Module, buildkit_mod: *std.Build.Module, json_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "docker.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "build", .module = options_mod },
            .{ .name = "buildkit", .module = buildkit_mod },
            .{ .name = "json", .module = json_mod },
        },
    });
}

fn buildManaModule(builder: *std.Build, docker_mod: *std.Build.Module, json_mod: *std.Build.Module) *std.Build.Module {
    return builder.addModule("mana", .{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "mana.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "docker", .module = docker_mod },
            .{ .name = "json", .module = json_mod },
        },
    });
}

fn buildFrontendModule(builder: *std.Build, mana_mod: *std.Build.Module) *std.Build.Module {
    return builder.createModule(.{
        .root_source_file = builder.path(builder.pathResolve(&.{ "src", "frontend.zig" })),
        .target = builder.graph.host,
        .optimize = .debug,
        .imports = &.{
            .{ .name = "mana", .module = mana_mod },
        },
    });
}

fn buildManaExecutable(builder: *std.Build) void {
    const options_mod = buildOptionsModule(builder);
    const protobuf_compiler, const buildkit_mod = buildBuildkitModule(builder);
    const json_mod = buildJSONModule(builder);
    const docker_mod = buildDockerModule(builder, options_mod, buildkit_mod, json_mod);
    const mana_mod = buildManaModule(builder, docker_mod, json_mod);
    const frontend_mod = buildFrontendModule(builder, mana_mod);

    var mana_exe = builder.addExecutable(.{
        .name = "mana",
        .root_module = frontend_mod,
    });

    mana_exe.step.dependOn(protobuf_compiler.step);

    const mana_install = builder.addInstallArtifact(mana_exe, .{});
    builder.getInstallStep().dependOn(&mana_install.step);
}

pub fn build(builder: *std.Build) void {
    buildManaExecutable(builder);
}
