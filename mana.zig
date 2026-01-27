const std = @import("std");
const zon = @import("build.zig.zon");
const name = @tagName(zon.name);
const protobuf = @import("protobuf");
const RunProtocStep = protobuf.RunProtocStep;

var mana: Mana = undefined;

const JSONString = struct {
    step: *std.Build.Step,
    output: std.Build.LazyPath,
};

pub fn init(builder: *std.Build) void {
    mana.init(builder);
}

pub fn buildJSONProcessorDynamicLibrary(dynlib_name: []const u8, impl_root_source_file: std.Build.LazyPath) *std.Build.Step.Compile {
    return mana.buildJSONProcessorDynamicLibrary(dynlib_name, impl_root_source_file);
}

pub fn processJSON(dynlib: *std.Build.Step.Compile, inputs: []const JSONString) JSONString {
    return mana.processJSON(dynlib, inputs);
}

pub fn sendRequestLazyPath(input: std.Build.LazyPath, dependencies: []const *std.Build.Step) JSONString {
    return mana.sendRequestLazyPath(input, dependencies);
}

pub fn sendRequestAny(input: std.Build.LazyPath, dependencies: []const *std.Build.Step) JSONString {
    return mana.sendRequestAny(input, dependencies);
}

pub fn sendDockerDefaultRequest(endpoint: DockerEndpoint, method: std.http.Method, parameters: anytype, dependencies: []const *std.Build.Step) JSONString {
    return mana.sendDockerDefaultRequest(endpoint, method, parameters, dependencies);
}

pub fn sendDockerBuildRequest(context: []const u8, tag: []const u8, dependencies: []const *std.Build.Step) JSONString {
    return mana.sendDockerBuildRequest(context, tag, dependencies);
}

const docker_api_version = "v1.56";

const DockerEndpoint = enum(u32) {
    version,

    fn toURL(self: @This()) []const u8 {
        return switch (self) {
            .version => "/version",
        };
    }
};

const Mana = struct {
    builder: *std.Build,
    protobuf_compiler: *RunProtocStep,
    http_api_requester_exe: *std.Build.Step.Compile,
    json_pretty_printer_exe: *std.Build.Step.Compile,
    json_processor_init_mod: *std.Build.Module,
    json_processor_interface_mod: *std.Build.Module,
    json_processor_exe: *std.Build.Step.Compile,
    incr: u128,

    fn init(self: *@This(), builder: *std.Build) void {
        self.builder = builder;
        self.incr = 1;
        const options_mod = self.buildOptionsModule();
        self.buildHTTPAPIRequesterExecutable(options_mod);
        self.buildJSONPrettyPrinterExecutable();
        self.json_processor_init_mod = self.buildJSONProcessorInitModule();
        self.json_processor_interface_mod = self.buildJSONProcessorInterfaceModule();
        self.buildJSONProcessorExecutable();
    }

    fn buildOptionsModule(self: @This()) *std.Build.Module {
        const options = self.builder.addOptions();

        const zon_version_sem = std.SemanticVersion.parse(zon.version) catch |err| std.debug.panic(
            \\std.SemanticVersion.parse("{s}"): {s} when parsing build.zig.zon version
        , .{ @errorName(err), zon.version });

        const raw_git_describe = blk: {
            const git = self.builder.findProgram(.{ .names = &.{"git"} }) orelse break :blk zon.version;
            const argv = [_][]const u8{
                git, "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags", "--abbrev=9",
            };
            break :blk switch (self.builder.runFallible(&argv, .{ .cwd = .{ .dir = self.builder.root.root_dir.handle } })) {
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
                break :blk self.builder.fmt("-nightly.{s}+{s}", .{ commit_height, commit_id[1..] });
            },
            else => std.debug.panic("Unexpected `git describe` output: {s}\n", .{git_describe}),
        };

        const version_option = self.builder.fmt("{d}.{d}.{d}{s}", .{
            zon_version_sem.major, zon_version_sem.minor, zon_version_sem.patch, suffix,
        });
        options.addOption([:0]const u8, "name", name);
        options.addOption([:0]const u8, "version", self.builder.graph.arena.dupeSentinel(u8, version_option, 0) catch @panic("OOM"));
        return options.createModule();
    }

    fn buildProtogenExecutable(self: @This()) *std.Build.Step.Compile {
        return self.builder.addExecutable(.{
            .name = "protobuf_generator",
            .root_module = self.builder.createModule(.{
                .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "protobuf_generator.zig" })),
                .target = self.builder.graph.host,
                .optimize = .debug,
                .imports = &.{},
            }),
        });
    }

    fn buildBuildkitModule(self: *@This()) *std.Build.Module {
        const protobuf_generator_exe = self.buildProtogenExecutable();

        const generated_zig = self.builder.addWriteFiles().add("generated.zig",
            \\pub const v1 = @import("moby/buildkit/v1.pb.zig");
        );

        const protobuf_generator = self.builder.addRunArtifact(protobuf_generator_exe);
        const proto_dir = protobuf_generator.addOutputDirectoryArg2("proto", .{});

        const protobuf_dep = self.builder.dependency("protobuf", .{});
        self.protobuf_compiler = .create(protobuf_dep.builder, self.builder.graph.host, .{
            .destination_directory = generated_zig.dirname(),
            .source_files = &.{
                proto_dir.path(self.builder, self.builder.pathJoin(&[_][]const u8{
                    "vendor", "api", "services", "control", "control.proto",
                })),
            },
            .include_directories = &.{proto_dir},
        });
        self.protobuf_compiler.verbose = true;

        self.protobuf_compiler.step.dependOn(&protobuf_generator.step);

        return self.builder.createModule(.{
            .root_source_file = generated_zig,
            .target = self.builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
            },
        });
    }

    fn buildDockerModule(self: @This(), options_mod: *std.Build.Module, buildkit_mod: *std.Build.Module) *std.Build.Module {
        return self.builder.createModule(.{
            .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "docker.zig" })),
            .target = self.builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "build", .module = options_mod },
                .{ .name = "buildkit", .module = buildkit_mod },
            },
        });
    }

    fn buildHTTPAPIRequesterModule(self: @This(), docker_mod: *std.Build.Module) *std.Build.Module {
        return self.builder.createModule(.{
            .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "http_api_requester.zig" })),
            .target = self.builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "docker", .module = docker_mod },
            },
        });
    }

    fn buildHTTPAPIRequesterExecutable(self: *@This(), options_mod: *std.Build.Module) void {
        const buildkit_mod = self.buildBuildkitModule();
        const docker_mod = self.buildDockerModule(options_mod, buildkit_mod);
        const http_api_requester_mod = self.buildHTTPAPIRequesterModule(docker_mod);

        self.http_api_requester_exe = self.builder.addExecutable(.{
            .name = "mana.http_api_requester",
            .root_module = http_api_requester_mod,
        });

        self.http_api_requester_exe.step.dependOn(self.protobuf_compiler.step);
    }

    fn buildJSONPrettyPrinterModule(self: @This()) *std.Build.Module {
        return self.builder.createModule(.{
            .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "json_pretty_printer.zig" })),
            .target = self.builder.graph.host,
            .optimize = .debug,
            .imports = &.{},
        });
    }

    fn buildJSONPrettyPrinterExecutable(self: *@This()) void {
        const json_pretty_printer_mod = self.buildJSONPrettyPrinterModule();

        self.json_pretty_printer_exe = self.builder.addExecutable(.{
            .name = "mana.json_pretty_printer",
            .root_module = json_pretty_printer_mod,
        });
    }

    fn buildJSONProcessorInitModule(self: @This()) *std.Build.Module {
        return self.builder.createModule(.{
            .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "json_processor", "init.zig" })),
            .target = self.builder.graph.host,
            .optimize = .debug,
            .link_libc = true,
            .imports = &.{},
        });
    }

    fn buildJSONProcessorImplModule(self: @This(), root_source_file: std.Build.LazyPath) *std.Build.Module {
        return self.builder.createModule(.{
            .root_source_file = root_source_file,
            .target = self.builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "init", .module = self.json_processor_init_mod },
            },
        });
    }

    fn buildJSONProcessorInterfaceModule(self: @This()) *std.Build.Module {
        return self.builder.createModule(.{
            .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "json_processor", "interface.zig" })),
            .target = self.builder.graph.host,
            .optimize = .debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "init", .module = self.json_processor_init_mod },
            },
        });
    }

    fn buildJSONProcessorEntrypointModule(self: @This(), json_processor_impl_mod: *std.Build.Module) *std.Build.Module {
        return self.builder.createModule(.{
            .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "json_processor", "entrypoint.zig" })),
            .target = self.builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "impl", .module = json_processor_impl_mod },
                .{ .name = "interface", .module = self.json_processor_interface_mod },
            },
        });
    }

    fn buildJSONProcessorModule(self: @This()) *std.Build.Module {
        const dummy_mod = self.builder.createModule(.{
            .root_source_file = self.builder.addWriteFiles().add("dummy.zig",
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
            .target = self.builder.graph.host,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "init", .module = self.json_processor_init_mod },
            },
        });
        const json_processor_entrypoint_mod = self.buildJSONProcessorEntrypointModule(dummy_mod);

        return self.builder.createModule(.{
            .root_source_file = self.builder.path(self.builder.pathResolve(&.{ "src", "json_processor.zig" })),
            .target = self.builder.graph.host,
            .optimize = .debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "entrypoint", .module = json_processor_entrypoint_mod },
            },
        });
    }

    fn buildJSONProcessorExecutable(self: *@This()) void {
        const json_processor_mod = self.buildJSONProcessorModule();

        self.json_processor_exe = self.builder.addExecutable(.{
            .name = "mana.json_processor",
            .root_module = json_processor_mod,
        });
    }

    fn buildJSONProcessorDynamicLibrary(self: @This(), dynlib_name: []const u8, impl_root_source_file: std.Build.LazyPath) *std.Build.Step.Compile {
        const json_processor_impl_mod = self.buildJSONProcessorImplModule(impl_root_source_file);
        const json_processor_entrypoint_mod = self.buildJSONProcessorEntrypointModule(json_processor_impl_mod);

        return self.builder.addLibrary(.{
            .linkage = .dynamic,
            .name = self.builder.fmt("json_processor.{s}", .{dynlib_name}),
            .root_module = json_processor_entrypoint_mod,
        });
    }

    fn processJSON(self: *@This(), dynlib: *std.Build.Step.Compile, inputs: []const JSONString) JSONString {
        std.debug.assert(dynlib.kind == .lib);
        std.debug.assert(dynlib.linkage.? == .dynamic);
        var json_processor = self.builder.addRunArtifact(self.json_processor_exe);
        var json_pretty_printer = self.builder.addRunArtifact(self.json_pretty_printer_exe);
        if (self.builder.graph.verbose) {
            json_processor.setEnvironmentVariable("VERBOSE", "true");
            json_pretty_printer.setEnvironmentVariable("VERBOSE", "true");
        } else {
            json_processor.removeEnvironmentVariable("VERBOSE");
            json_pretty_printer.removeEnvironmentVariable("VERBOSE");
        }
        json_processor.step.dependOn(&dynlib.step);
        json_processor.addFileArg2(dynlib.getEmittedBin(), .{});
        const output = json_processor.addOutputFileArg2(self.builder.fmt(name ++ "-json_processor-{d}-output.json", .{self.incr}), .{});
        self.incr += 1;
        for (0..inputs.len) |i| {
            json_processor.addFileArg2(inputs[i].output, .{});
            json_processor.step.dependOn(inputs[i].step);
        }
        json_processor.has_side_effects = true;
        json_pretty_printer.addFileArg2(output, .{});
        json_pretty_printer.step.dependOn(&json_processor.step);
        self.builder.getInstallStep().dependOn(&json_pretty_printer.step);
        return .{
            .step = &json_pretty_printer.step,
            .output = output,
        };
    }

    fn sendRequestLazyPath(self: *@This(), input: std.Build.LazyPath, dependencies: []const *std.Build.Step) JSONString {
        var http_api_requester = self.builder.addRunArtifact(self.http_api_requester_exe);
        var json_pretty_printer = self.builder.addRunArtifact(self.json_pretty_printer_exe);
        if (self.builder.graph.verbose) {
            http_api_requester.setEnvironmentVariable("VERBOSE", "true");
            json_pretty_printer.setEnvironmentVariable("VERBOSE", "true");
        } else {
            http_api_requester.removeEnvironmentVariable("VERBOSE");
            json_pretty_printer.removeEnvironmentVariable("VERBOSE");
        }
        http_api_requester.addFileArg2(input, .{});
        const output = http_api_requester.addOutputFileArg2(self.builder.fmt(name ++ "-http_api_requester-{d}-output.json", .{self.incr}), .{});
        http_api_requester.has_side_effects = true;
        for (0..dependencies.len) |i| http_api_requester.step.dependOn(dependencies[i]);
        self.incr += 1;
        json_pretty_printer.addFileArg2(output, .{});
        json_pretty_printer.step.dependOn(&http_api_requester.step);
        self.builder.getInstallStep().dependOn(&json_pretty_printer.step);
        return .{
            .step = &json_pretty_printer.step,
            .output = output,
        };
    }

    fn sendRequestAny(self: *@This(), input: anytype, dependencies: []const *std.Build.Step) JSONString {
        const content = self.builder.fmt("{f}", .{std.json.fmt(input, .{})});
        const input_name = self.builder.fmt(name ++ "-http_api_requester-{d}-input.json", .{self.incr});
        return self.sendRequestLazyPath(self.builder.addWriteFiles().add(input_name, content), dependencies);
    }

    fn sendDockerDefaultRequest(self: *@This(), endpoint: DockerEndpoint, method: std.http.Method, parameters: anytype, dependencies: []const *std.Build.Step) JSONString {
        return self.sendRequestAny(.{
            .docker = .{
                .version = docker_api_version,
                .endpoint = endpoint.toURL(),
                .method = @tagName(method),
                .parameters = parameters,
            },
        }, dependencies);
    }

    fn sendDockerBuildRequest(self: *@This(), context: []const u8, tag: []const u8, dependencies: []const *std.Build.Step) JSONString {
        return self.sendRequestAny(.{
            .docker_build = .{
                .version = docker_api_version,
                .ctx = context,
                .t = tag,
            },
        }, dependencies);
    }
};
