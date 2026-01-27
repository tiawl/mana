const std = @import("std");
const zon = @import("build.zig.zon");
const name = @tagName(zon.name);
const protobuf = @import("protobuf");
const RunProtocStep = protobuf.RunProtocStep;

const Root = struct {
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
    zon_dep: *std.Build.Dependency,
    protoc: *RunProtocStep,
};

fn run(root: *Root, argv: []const []const u8, cwd: std.process.Child.Cwd) ![]u8 {
    return switch (root.builder.runFallible(argv, .{ .stderr_behavior = .ignore, .cwd = cwd })) {
        .success => |stdout| return stdout,
        .spawn_failed => |err| return err,
        .bad_exit_code => return error.ExitCodeFailure,
        .crashed => return error.ProcessTerminated,
    };
}

fn buildOptionsModule(root: *Root) !*std.Build.Module {
    const options = root.builder.addOptions();

    const git = root.builder.findProgram(.{ .names = &.{"git"} }) orelse return error.ProgramNotFound;
    const raw_taglist = try run(root, &[_][]const u8{
        git, "--git-dir", ".git", "tag", "-l", "0.0.0",
    }, .{ .dir = root.builder.root.root_dir.handle });
    if (std.mem.eql(u8, "0.0.0", std.mem.trim(u8, raw_taglist, &std.ascii.whitespace))) {
        _ = try run(root, &[_][]const u8{
            git, "--git-dir", ".git", "tag", "-d", "0.0.0",
        }, .{ .dir = root.builder.root.root_dir.handle });
    }
    const raw_init_commit = try run(root, &[_][]const u8{
        git, "--git-dir", ".git", "rev-list", "--max-parents=0", "HEAD",
    }, .{ .dir = root.builder.root.root_dir.handle });
    const init_commit = std.mem.trim(u8, raw_init_commit, &std.ascii.whitespace);
    _ = try run(root, &[_][]const u8{
        git, "--git-dir", ".git", "tag", "0.0.0", init_commit,
    }, .{ .dir = root.builder.root.root_dir.handle });
    const raw_git_describe = try run(root, &[_][]const u8{
        git, "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags", "--abbrev=9",
    }, .{ .dir = root.builder.root.root_dir.handle });
    const git_describe = std.mem.trim(u8, raw_git_describe, &std.ascii.whitespace);

    const zon_version_sem = try std.SemanticVersion.parse(zon.version);

    var it = std.mem.splitScalar(u8, git_describe, '-');
    const tagged_ancestor = it.first();

    const tagged_ancestor_sem = try std.SemanticVersion.parse(tagged_ancestor);
    if (zon_version_sem.order(tagged_ancestor_sem) != .eq) {
        std.debug.print("build.zig.zon version '{}.{}.{}' must be equal to tagged ancestor '{}.{}.{}'\n", .{
            zon_version_sem.major, zon_version_sem.minor, zon_version_sem.patch, tagged_ancestor_sem.major, tagged_ancestor_sem.minor, tagged_ancestor_sem.patch,
        });
        return error.UnsynchronizedGitAndZON;
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
                std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
                return error.UnexpectedSystemCommandOutput;
            }

            _ = try std.fmt.parseUnsigned(u32, commit_height, 10);
            break :blk root.builder.fmt("-nightly.{s}+{s}", .{ commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{git_describe});
            return error.UnexpectedSystemCommandOutput;
        },
    };

    const version_option = root.builder.fmt("{d}.{d}.{d}{s}", .{
        zon_version_sem.major, zon_version_sem.minor, zon_version_sem.patch, suffix,
    });
    options.addOption([:0]const u8, "name", name);
    options.addOption([:0]const u8, "version", root.builder.allocator.dupeSentinel(u8, version_option, 0) catch @panic("OOM"));
    options.addOption([:0]const u8, "docker_api_version", "v1.56");
    return options.createModule();
}

fn buildProtogenExecutable(root: *Root) *std.Build.Step.Compile {
    return root.builder.addExecutable(.{
        .name = "protogen",
        .root_module = root.builder.createModule(.{
            .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "protogen.zig" })),
            .target = root.target,
            .optimize = .Debug,
            .imports = &.{},
        }),
    });
}

pub fn buildBuildkitModule(root: *Root) *std.Build.Module {
    const protogen_exe = buildProtogenExecutable(root);

    const tmp = root.builder.addWriteFiles();
    const tmp_dir = tmp.getDirectory();
    const generated_dir = tmp_dir.path(root.builder, "generated");
    const generated_root_zig = tmp.add(root.builder.pathResolve(&.{ "generated", "root.zig" }), "pub const v1 = @import(\"moby/buildkit/v1.pb.zig\");");

    const protogen_install = root.builder.addInstallArtifact(protogen_exe, .{});
    const protogen = root.builder.addRunArtifact(protogen_exe);
    const proto_dir = protogen.addOutputDirectoryArg2("proto", .{});

    const protobuf_dep = root.builder.dependency("protobuf", .{});
    root.protoc = RunProtocStep.create(protobuf_dep.builder, root.target, .{
        .destination_directory = generated_dir,
        .source_files = &.{
            proto_dir.path(root.builder, root.builder.pathJoin(&[_][]const u8{
                "vendor", "api", "services", "control", "control.proto",
            })),
        },
        .include_directories = &.{proto_dir},
    });
    root.protoc.verbose = true;

    protogen.step.dependOn(&protogen_install.step);
    root.protoc.step.dependOn(&protogen.step);

    return root.builder.createModule(.{
        .root_source_file = generated_root_zig,
        .target = root.target,
        .optimize = root.mode,
        .imports = &.{
            .{
                .name = "protobuf",
                .module = protobuf_dep.module("protobuf"),
            },
        },
    });
}

fn buildDockerModule(root: *Root, options_mod: *std.Build.Module, buildkit_mod: *std.Build.Module) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "docker.zig" })),
        .target = root.target,
        .optimize = root.mode,
        .imports = &.{
            .{
                .name = "build",
                .module = options_mod,
            },
            .{
                .name = "buildkit",
                .module = buildkit_mod,
            },
            .{
                .name = "zon",
                .module = root.zon_dep.module("zon"),
            },
        },
    });
}

fn buildRequesterModule(root: *Root, options_mod: *std.Build.Module, docker_mod: *std.Build.Module) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "frontend.zig" })),
        .target = root.target,
        .optimize = root.mode,
        .imports = &.{
            .{
                .name = "build",
                .module = options_mod,
            },
            .{
                .name = "docker",
                .module = docker_mod,
            },
            .{
                .name = "zon",
                .module = root.zon_dep.module("zon"),
            },
        },
    });
}

fn buildRequesterExecutable(root: *Root) !*std.Build.Step.Compile {
    const options_mod = try buildOptionsModule(root);
    const buildkit_mod = buildBuildkitModule(root);
    const docker_mod = buildDockerModule(root, options_mod, buildkit_mod);
    const requester_mod = buildRequesterModule(root, options_mod, docker_mod);

    const requester_exe = root.builder.addExecutable(.{
        .name = "requester",
        .version = try std.SemanticVersion.parse(zon.version),
        .root_module = requester_mod,
    });

    requester_exe.step.dependOn(root.protoc.step);

    const requester_install = root.builder.addInstallArtifact(requester_exe, .{});
    root.builder.getInstallStep().dependOn(&requester_install.step);

    return requester_exe;
}

pub fn build(builder: *std.Build) !void {
    var root: Root = .{
        .builder = builder,
        .target = builder.standardTargetOptions(.{}),
        .mode = builder.standardOptimizeOption(.{}),
        .zon_dep = builder.dependency("zon", .{}),
        .protoc = undefined,
    };

    _ = try buildRequesterExecutable(&root);
}
