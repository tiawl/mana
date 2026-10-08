const std = @import("std");
const scheduler = @import("frontend");
const builtin = @import("builtin");

var safe_allocator_instance: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
const use_safe_allocator = switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

const GetAPIVersion = struct {
    pub fn init(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) void {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, allocator, io };
    }

    pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) void {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, allocator, io };
    }

    pub fn process(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, inputs: std.json.Value) std.json.Value {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, allocator, io };
        return inputs.array.items[0].array.items[0].object.get("ApiVersion").?;
    }
};

// TODO: remove this later
fn valueFromAny(allocator: std.mem.Allocator, input: anytype) !std.json.Value {
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, try allocator.print("{f}", .{std.json.fmt(input, .{})}), .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = if (use_safe_allocator) safe_allocator_instance.allocator() else std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator_instance.deinit();
    };

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    //_ = arena;

    threaded.setAsyncLimit(.limited(std.Thread.getCpuCount() catch 1));

    scheduler.init(&arena_instance, gpa, io, &init.environ);
    defer scheduler.deinit();

    try scheduler.addRequestTask("docker_version", try valueFromAny(arena, .{
        .docker = .{
            .version = "v1.56",
            .endpoint = "/version",
            .method = "GET",
        },
    }), &.{});
    try scheduler.addJSONProcessTask(GetAPIVersion, "get_api_version", &.{"docker_version"});

    //var api_version_instance: JSONProcessTask(GetAPIVersion) = undefined;
    //var api_version_task = try scheduler.root_task.dependOn(JSONProcessTask(GetAPIVersion), &api_version_instance);

    //var docker_version_request_instance: RequestTask = .{
    //    .gpa = undefined,
    //    .input = try valueFromAny(arena, .{
    //        .docker = .{
    //            .version = "v1.56",
    //            .endpoint = "/version",
    //            .method = "GET",
    //        },
    //    }),
    //    .output = undefined,
    //};
    //var docker_version_task = try api_version_task.dependOn(RequestTask, &docker_version_request_instance);

    try scheduler.run();
    //docker_version_task.getOutput().?.dump();
    //std.debug.print("\n", .{});
    //api_version_task.getOutput().?.dump();
    //std.debug.print("\n", .{});

    //var docker_version = try mana.sendDockerDefaultRequest(gpa, .version, .GET, .{ .hello = "world" });
    //defer mana.free(gpa, &docker_version);

    //_ = try mana.sendDockerBuildRequest(gpa, "dockerfiles/base", "base:latest");
    //const process_api_version = try mana.processJSON(GetAPIVersion, &.{docker_version.array.items[0]});
    //process_api_version.dump();

    //try mana.schedule(.{
    //    .@"json_processor/dummy" = .{
    //        .hello = "world",
    //    },
    //});
}
