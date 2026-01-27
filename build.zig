const std = @import("std");
const zon = @import("build.zig.zon");
const name = @tagName(zon.name);
const protobuf = @import("protobuf");
const RunProtocStep = protobuf.RunProtocStep;
const Function = @import("src/json_processor.zig").Function;

const Root = struct {
    builder: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sem_version: std.SemanticVersion,
    protobuf_compiler: *RunProtocStep,
    http_api_requester_exe: *std.Build.Step.Compile,
    json_processor_exe: *std.Build.Step.Compile,
    json_processor_dynlibs: std.StringHashMap(std.Build.LazyPath),
    json_pretty_printer_exe: *std.Build.Step.Compile,
    incr: u128 = 1,
};

const docker_api_version = "v1.56";

const DockerEndpoint = enum(u32) {
    version,

    fn toURL(self: @This()) []const u8 {
        return switch (self) {
            .version => "/version",
        };
    }
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
    options.addOption([:0]const u8, "version", root.builder.graph.arena.dupeSentinel(u8, version_option, 0) catch @panic("OOM"));
    return options.createModule();
}

fn buildProtogenExecutable(root: *Root) *std.Build.Step.Compile {
    return root.builder.addExecutable(.{
        .name = "protobuf_generator",
        .root_module = root.builder.createModule(.{
            .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "protobuf_generator.zig" })),
            .target = root.target,
            .optimize = .Debug,
            .imports = &.{},
        }),
    });
}

pub fn buildBuildkitModule(root: *Root) *std.Build.Module {
    const protobuf_generator_exe = buildProtogenExecutable(root);

    const tmp = root.builder.addWriteFiles();
    const tmp_dir = tmp.getDirectory();
    const generated_dir = tmp_dir.path(root.builder, "generated");
    const generated_root_zig = tmp.add(root.builder.pathResolve(&.{ "generated", "root.zig" }), "pub const v1 = @import(\"moby/buildkit/v1.pb.zig\");");

    const protobuf_generator = root.builder.addRunArtifact(protobuf_generator_exe);
    const proto_dir = protobuf_generator.addOutputDirectoryArg2("proto", .{});

    const protobuf_dep = root.builder.dependency("protobuf", .{});
    root.protobuf_compiler = .create(protobuf_dep.builder, root.target, .{
        .destination_directory = generated_dir,
        .source_files = &.{
            proto_dir.path(root.builder, root.builder.pathJoin(&[_][]const u8{
                "vendor", "api", "services", "control", "control.proto",
            })),
        },
        .include_directories = &.{proto_dir},
    });
    root.protobuf_compiler.verbose = true;

    root.protobuf_compiler.step.dependOn(&protobuf_generator.step);

    return root.builder.createModule(.{
        .root_source_file = generated_root_zig,
        .target = root.target,
        .optimize = root.optimize,
        .imports = &.{
            .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
        },
    });
}

fn buildDockerModule(root: *Root, options_mod: *std.Build.Module, buildkit_mod: *std.Build.Module) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "docker.zig" })),
        .target = root.target,
        .optimize = root.optimize,
        .imports = &.{
            .{ .name = "build", .module = options_mod },
            .{ .name = "buildkit", .module = buildkit_mod },
        },
    });
}

fn buildHTTPAPIRequesterModule(root: *Root, options_mod: *std.Build.Module, docker_mod: *std.Build.Module) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "http_api_requester.zig" })),
        .target = root.target,
        .optimize = root.optimize,
        .imports = &.{
            .{ .name = "build", .module = options_mod },
            .{ .name = "docker", .module = docker_mod },
        },
    });
}

fn buildHTTPAPIRequesterExecutable(root: *Root, options_mod: *std.Build.Module) void {
    const buildkit_mod = buildBuildkitModule(root);
    const docker_mod = buildDockerModule(root, options_mod, buildkit_mod);
    const http_api_requester_mod = buildHTTPAPIRequesterModule(root, options_mod, docker_mod);

    root.http_api_requester_exe = root.builder.addExecutable(.{
        .name = "http_api_requester",
        .version = root.sem_version,
        .root_module = http_api_requester_mod,
    });

    root.http_api_requester_exe.step.dependOn(root.protobuf_compiler.step);
}

fn buildJSONPrettyPrinterModule(root: *Root) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "json_pretty_printer.zig" })),
        .target = root.target,
        .optimize = root.optimize,
        .imports = &.{},
    });
}

fn buildJSONPrettyPrinterExecutable(root: *Root) void {
    const json_pretty_printer_mod = buildJSONPrettyPrinterModule(root);

    root.json_pretty_printer_exe = root.builder.addExecutable(.{
        .name = "json_pretty_printer",
        .version = root.sem_version,
        .root_module = json_pretty_printer_mod,
    });
}

fn buildJSONProcessorInitModule(root: *Root) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "json_processor", "init.zig" })),
        .target = root.target,
        .optimize = root.optimize,
        .link_libc = true,
        .imports = &.{},
    });
}

fn buildJSONProcessorInterfaceModule(root: *Root, json_processor_init_mod: *std.Build.Module) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "json_processor", "interface.zig" })),
        .target = root.target,
        .optimize = root.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "init", .module = json_processor_init_mod },
        },
    });
}

fn buildJSONProcessorImplModule(root: *Root, json_processor_init_mod: *std.Build.Module, root_source_file: []const u8) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "json_processor", root_source_file })),
        .target = root.target,
        .optimize = root.optimize,
        .imports = &.{
            .{ .name = "init", .module = json_processor_init_mod },
        },
    });
}

fn buildJSONProcessorEntrypointModule(root: *Root, json_processor_impl_mod: *std.Build.Module, json_processor_interface_mod: *std.Build.Module) *std.Build.Module {
    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "json_processor", "entrypoint.zig" })),
        .target = root.target,
        .optimize = root.optimize,
        .imports = &.{
            .{ .name = "impl", .module = json_processor_impl_mod },
            .{ .name = "interface", .module = json_processor_interface_mod },
        },
    });
}

fn buildJSONProcessorDynamicLibraries(root: *Root, json_processor_init_mod: *std.Build.Module, json_processor_interface_mod: *std.Build.Module) !void {
    const src_json_processor_dir = try root.builder.root.root_dir.handle.openDir(root.builder.graph.io, root.builder.pathResolve(&.{ "src", "json_processor" }), .{ .iterate = true });
    defer src_json_processor_dir.close(root.builder.graph.io);
    var it = src_json_processor_dir.iterate();
    while (try it.next(root.builder.graph.io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (std.mem.eql(u8, "entrypoint.zig", entry.name) or std.mem.eql(u8, entry.name, "init.zig") or std.mem.eql(u8, entry.name, "interface.zig")) continue;
                const json_processor_impl_mod = buildJSONProcessorImplModule(root, json_processor_init_mod, entry.name);
                const json_processor_entrypoint_mod = buildJSONProcessorEntrypointModule(root, json_processor_impl_mod, json_processor_interface_mod);

                const json_processor_dynlib = root.builder.addLibrary(.{
                    .linkage = .dynamic,
                    .name = root.builder.fmt("json_processor.{s}", .{std.fs.path.stem(entry.name)}),
                    .root_module = json_processor_entrypoint_mod,
                });

                root.json_processor_dynlibs.put(root.builder.dupe(std.fs.path.stem(entry.name)), json_processor_dynlib.getEmittedBin()) catch @panic("OOM");
            },
            else => unreachable,
        }
    }
}

fn buildJSONProcessorModule(root: *Root, json_processor_init_mod: *std.Build.Module, json_processor_interface_mod: *std.Build.Module) *std.Build.Module {
    const dummy_mod = root.builder.createModule(.{
        .root_source_file = root.builder.addWriteFiles().add("dummy.zig",
            \\const std = @import("std");
            \\const Init = @import("init").Init;
            \\pub const Impl = Dummy;
            \\const Dummy = struct {
            \\    pub fn init(_: *anyopaque, _: *const Init) void {}
            \\    pub fn deinit(_: *anyopaque, _: *const Init) void {}
            \\    pub fn process(_: *anyopaque, _: *const std.json.Array, _: *const Init) std.json.Value {
            \\        @panic("dummy implementation");
            \\    }
            \\};
        ),
        .target = root.target,
        .optimize = root.optimize,
        .imports = &.{
            .{ .name = "init", .module = json_processor_init_mod },
        },
    });
    const json_processor_entrypoint_mod = buildJSONProcessorEntrypointModule(root, dummy_mod, json_processor_interface_mod);

    return root.builder.createModule(.{
        .root_source_file = root.builder.path(root.builder.pathResolve(&.{ "src", "json_processor.zig" })),
        .target = root.target,
        .optimize = root.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "entrypoint", .module = json_processor_entrypoint_mod },
        },
    });
}

fn buildJSONProcessorExecutable(root: *Root, json_processor_init_mod: *std.Build.Module, json_processor_interface_mod: *std.Build.Module) void {
    const json_processor_mod = buildJSONProcessorModule(root, json_processor_init_mod, json_processor_interface_mod);

    root.json_processor_exe = root.builder.addExecutable(.{
        .name = "json_processor",
        .version = root.sem_version,
        .root_module = json_processor_mod,
    });
}

pub fn build(builder: *std.Build) !void {
    var root: Root = .{
        .builder = builder,
        .target = builder.standardTargetOptions(.{}),
        .optimize = builder.standardOptimizeOption(.{}),
        .sem_version = try std.SemanticVersion.parse(zon.version),
        .protobuf_compiler = undefined,
        .http_api_requester_exe = undefined,
        .json_processor_exe = undefined,
        .json_processor_dynlibs = .init(builder.graph.arena),
        .json_pretty_printer_exe = undefined,
    };

    const options_mod = try buildOptionsModule(&root);
    buildHTTPAPIRequesterExecutable(&root, options_mod);
    buildJSONPrettyPrinterExecutable(&root);
    const json_processor_init_mod = buildJSONProcessorInitModule(&root);
    const json_processor_interface_mod = buildJSONProcessorInterfaceModule(&root, json_processor_init_mod);
    try buildJSONProcessorDynamicLibraries(&root, json_processor_init_mod, json_processor_interface_mod);
    buildJSONProcessorExecutable(&root, json_processor_init_mod, json_processor_interface_mod);
    try makeInfra(&root);
}

const ManaStep = struct {
    step: *std.Build.Step,
    output: std.Build.LazyPath,
};

fn processJSON(root: *Root, dynlib: std.Build.LazyPath, inputs: []const ManaStep) !ManaStep {
    var json_processor = root.builder.addRunArtifact(root.json_processor_exe);
    var json_pretty_printer = root.builder.addRunArtifact(root.json_pretty_printer_exe);
    if (root.builder.graph.verbose) {
        json_processor.setEnvironmentVariable("VERBOSE", "true");
        json_pretty_printer.setEnvironmentVariable("VERBOSE", "true");
    } else {
        json_processor.removeEnvironmentVariable("VERBOSE");
        json_pretty_printer.removeEnvironmentVariable("VERBOSE");
    }
    json_processor.addFileArg2(dynlib, .{});
    for (0..inputs.len) |i| {
        json_processor.addFileArg2(inputs[i].output, .{});
        json_processor.step.dependOn(inputs[i].step);
    }
    json_processor.has_side_effects = true;
    const stdout = root.builder.addWriteFiles().addCopyFile(json_processor.captureStdOut(.{}), root.builder.fmt("json_processor-{d}-output.json", .{root.incr}));
    root.incr += 1;
    json_pretty_printer.addFileArg2(stdout, .{});
    json_pretty_printer.step.dependOn(&json_processor.step);
    root.builder.getInstallStep().dependOn(&json_pretty_printer.step);
    return .{
        .step = &json_pretty_printer.step,
        .output = stdout,
    };
}

fn sendRequest(root: *Root, input: std.Build.LazyPath, dependencies: []const *std.Build.Step) !ManaStep {
    var http_api_requester = root.builder.addRunArtifact(root.http_api_requester_exe);
    var json_pretty_printer = root.builder.addRunArtifact(root.json_pretty_printer_exe);
    if (root.builder.graph.verbose) {
        http_api_requester.setEnvironmentVariable("VERBOSE", "true");
        json_pretty_printer.setEnvironmentVariable("VERBOSE", "true");
    } else {
        http_api_requester.removeEnvironmentVariable("VERBOSE");
        json_pretty_printer.removeEnvironmentVariable("VERBOSE");
    }
    http_api_requester.addFileArg2(input, .{});
    http_api_requester.has_side_effects = true;
    for (0..dependencies.len) |i| http_api_requester.step.dependOn(dependencies[i]);
    const stdout = root.builder.addWriteFiles().addCopyFile(http_api_requester.captureStdOut(.{}), root.builder.fmt("http_api_requester-{d}-output.json", .{root.incr}));
    root.incr += 1;
    json_pretty_printer.addFileArg2(stdout, .{});
    json_pretty_printer.step.dependOn(&http_api_requester.step);
    root.builder.getInstallStep().dependOn(&json_pretty_printer.step);
    return .{
        .step = &json_pretty_printer.step,
        .output = stdout,
    };
}

fn sendDefaultDockerRequest(root: *Root, endpoint: DockerEndpoint, method: std.http.Method, parameters: anytype, dependencies: []const *std.Build.Step) !ManaStep {
    const content = root.builder.fmt(
        \\{{"docker":{{"version":"{s}","endpoint":"{s}","method":"{s}","parameters":{f}}}}}
    , .{ docker_api_version, endpoint.toURL(), @tagName(method), std.json.fmt(parameters, .{}) });
    const input_name = root.builder.fmt("http_api_requester-{d}-input.json", .{root.incr});
    return sendRequest(root, root.builder.addWriteFiles().add(input_name, content), dependencies);
}

fn sendDockerBuildRequest(root: *Root, context: []const u8, tag: []const u8, dependencies: []const *std.Build.Step) !ManaStep {
    const content = root.builder.fmt(
        \\{{"docker_build":{{"version":"{s}","ctx":"{s}","t":"{s}"}}}}
    , .{ docker_api_version, context, tag });
    const input_name = root.builder.fmt("http_api_requester-{d}-input.json", .{root.incr});
    return sendRequest(root, root.builder.addWriteFiles().add(input_name, content), dependencies);
}

fn makeInfra(root: *Root) !void {
    const docker_version = try sendDefaultDockerRequest(root, .version, .GET, .{ .hello = "world" }, &.{});
    //const docker_build_base_latest = try sendDockerBuildRequest(root, "dockerfiles/base", "base:latest", &.{});
    //_ = docker_build_base_latest;
    const process_api_version = try processJSON(root, root.json_processor_dynlibs.get("docker_version_get_api_version").?, &.{docker_version});
    _ = process_api_version;
}
