const std = @import("std");
const docker = @import("docker");
const json = @import("json");

var mana: Mana = undefined;

pub fn init(arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
    mana.init(arena, gpa, io, environ);
}

pub fn deinit() void {
    mana.deinit();
}

pub fn processJSON(comptime Impl: type, inputs: std.json.Value) !std.json.Value {
    return mana.processJSON(Impl, inputs);
}

pub fn sendRequestValue(allocator: std.mem.Allocator, input: std.json.Value) !std.json.Value {
    return mana.sendRequestValue(allocator, input);
}

pub fn sendRequestAny(allocator: std.mem.Allocator, input: anytype) !std.json.Value {
    return mana.sendRequestAny(allocator, input);
}

pub fn sendDockerDefaultRequest(allocator: std.mem.Allocator, endpoint: DockerEndpoint, method: std.http.Method, parameters: anytype) !std.json.Value {
    return mana.sendDockerDefaultRequest(allocator, endpoint, method, parameters);
}

pub fn sendDockerBuildRequest(allocator: std.mem.Allocator, context: []const u8, tag: []const u8) !void {
    try mana.sendDockerBuildRequest(allocator, context, tag);
}

pub fn free(allocator: std.mem.Allocator, mem: *std.json.Value) void {
    json.freeValue(allocator, mem);
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

const JSONProcessor = struct {
    const VTable = struct {
        init_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io) void,
        deinit_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io) void,
        process_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io, std.json.Value) std.json.Value,
    };

    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn implement(comptime T: type, impl: *T) @This() {
        return .{
            .ptr = impl,
            .vtable = &.{
                .init_fn = T.init,
                .deinit_fn = T.deinit,
                .process_fn = T.process,
            },
            .allocator = undefined,
            .io = undefined,
        };
    }

    pub fn init(self: *@This(), allocator: std.mem.Allocator, io: std.Io) void {
        self.allocator = allocator;
        self.io = io;
        self.vtable.init_fn(self.ptr, allocator, io);
    }

    pub fn deinit(self: *@This()) void {
        self.vtable.deinit_fn(self.ptr, self.allocator, self.io);
    }

    pub fn process(self: *@This(), inputs: std.json.Value) std.json.Value {
        std.debug.assert(std.meta.activeTag(inputs) == .array);
        return self.vtable.process_fn(self.ptr, self.allocator, self.io, inputs);
    }
};

const Mana = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    docker_client: docker.Client,

    fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
        self.arena = arena.allocator();
        self.gpa = gpa;
        self.io = io;
        self.docker_client = .init(arena, gpa, io, environ);
    }

    fn deinit(self: *@This()) void {
        self.docker_client.deinit();
    }

    fn processJSON(self: *@This(), comptime Impl: type, inputs: std.json.Value) !std.json.Value {
        var impl_instance: Impl = undefined;
        var json_processor: JSONProcessor = .implement(Impl, &impl_instance);
        json_processor.init(self.gpa, self.io);
        defer json_processor.deinit();

        return json_processor.process(inputs);
    }

    fn sendRequestValue(self: *@This(), allocator: std.mem.Allocator, input: std.json.Value) !std.json.Value {
        std.debug.assert(std.meta.activeTag(input) == .object);

        if (input.object.getPtr("docker")) |req_body| {
            return self.docker_client.send(allocator, req_body);
        } else if (input.object.getPtr("docker_build")) |req_body| {
            return self.docker_client.sendBuild(allocator, req_body);
        } else unreachable;
    }

    fn sendRequestAny(self: *@This(), allocator: std.mem.Allocator, input: anytype) !std.json.Value {
        const source = try self.gpa.print("{f}", .{std.json.fmt(input, .{})});
        defer self.gpa.free(source);

        var diag: std.json.Diagnostics = .{};
        var scanner: std.json.Scanner = .initCompleteInput(self.gpa, source);
        defer scanner.deinit();
        scanner.enableDiagnostics(&diag);

        const parsed = std.json.parseFromTokenSourceLeaky(std.json.Value, self.arena, &scanner, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("{s}: line {}, column {}", .{ source, diag.getLine(), diag.getColumn() });
            return err;
        };
        return self.sendRequestValue(allocator, parsed);
    }

    fn sendDockerDefaultRequest(self: *@This(), allocator: std.mem.Allocator, endpoint: DockerEndpoint, method: std.http.Method, parameters: anytype) !std.json.Value {
        return self.sendRequestAny(allocator, .{
            .docker = .{
                .version = docker_api_version,
                .endpoint = endpoint.toURL(),
                .method = @tagName(method),
                .parameters = parameters,
            },
        });
    }

    fn sendDockerBuildRequest(self: *@This(), allocator: std.mem.Allocator, context: []const u8, tag: []const u8) !void {
        _ = try self.sendRequestAny(allocator, .{
            .docker_build = .{
                .version = docker_api_version,
                .ctx = context,
                .t = tag,
            },
        });
    }
};
