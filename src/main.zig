const std = @import("std");
const scheduler = @import("frontend");
const builtin = @import("builtin");
const c = @import("jq");

var safe_allocator_instance: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
const use_safe_allocator = switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

// TODO: remove this later
fn jvFromAny(arena: std.mem.Allocator, input: anytype) !c.jv {
    return c.jv_parse(try arena.printSentinel("{f}", .{std.json.fmt(input, .{})}, 0));
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

    threaded.setAsyncLimit(.limited((std.Thread.getCpuCount() catch 0) + 1));

    try scheduler.init(&arena_instance, gpa, io, &init.environ);
    defer scheduler.deinit();

    try scheduler.addRequestTask("docker_version", try jvFromAny(arena, .{
        .docker = .{
            .version = "v1.56",
            .endpoint = "/version",
            .method = "GET",
            .parameters = .{
                .hello = "world",
            },
        },
    }), &.{});
    // TODO: remove dependencies here ??
    try scheduler.addJSONQueryTask("get_api_version", ".docker_version[0].ApiVersion", &.{"docker_version"});
    try scheduler.addRequestTask("docker_image_build_base_latest", try jvFromAny(arena, .{
        .docker_build = .{
            .version = "v1.56",
            .ctx = "dockerfiles/base",
            .t = "base:latest",
        },
    }), &.{});

    try scheduler.run();

    //try mana.schedule(.{
    //    .@"json_processor/dummy" = .{
    //        .hello = "world",
    //    },
    //});
}
