const std = @import("std");
const docker = @import("docker");
const zon = @import("zon");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    if (!args.skip()) return error.MissingExeArgument;
    const source = if (args.next()) |arg| arg else return error.MissingInputArgument;
    if (args.skip()) return error.UnknownArgument;

    var doc = try zon.parse(init.gpa, source);
    defer doc.deinit();
    std.debug.assert(std.meta.activeTag(doc.root) == .object);

    var stdout_writer = std.Io.File.stdout().writer(init.io, &.{});

    if (doc.root.object.get("docker")) |req_body| {
        var docker_client = docker.Client.init(init);
        defer docker_client.deinit();

        try docker_client.send(&stdout_writer.interface, req_body);
    } else if (doc.root.object.get("docker_build")) |req_body| {
        var docker_client = docker.Client.init(init);
        defer docker_client.deinit();

        try docker_client.sendBuild(req_body);
    } else unreachable;
}
// pub fn main(init: std.process.Init) !void {
//     const arena_allocator = init.arena.allocator();
//
//     var uri = try std.Uri.parse("unix:///dummy/parsing");
//     var uri_path: []const u8 = undefined;
//     var client: docker.Client = undefined;
//     var child: std.process.Child = undefined;
//
//     for ([_]?[:0]const u8{
//         null, "unix:///var/run/docker.sock", "tcp://127.0.0.1:2375",
//     }) |host| {
//         if (host) |h| {
//             uri = std.Uri.parse(h) catch |err| blk: {
//                 switch (err) {
//                     error.UnexpectedCharacter => break :blk try std.Uri.parseAfterScheme("", h),
//                     else => return err,
//                 }
//             };
//             uri_path = try uri.path.toRawMaybeAlloc(arena_allocator);
//         } else uri_path = "";
//         if (uri_path.len == 0) {
//             child = try std.process.spawn(init.io, .{
//                 .argv = &[_][]const u8{
//                     "socat", "TCP-LISTEN:2375,bind=127.0.0.1,reuseaddr,fork", "UNIX-CONNECT:/var/run/docker.sock",
//                 },
//                 .cwd = .inherit,
//                 .environ_map = null,
//                 .expand_arg0 = .no_expand,
//                 .progress_node = .none,
//                 .create_no_window = false,
//                 .disable_aslr = false,
//
//                 .stdin = .ignore,
//                 .stdout = .ignore,
//                 .stderr = .ignore,
//             });
//
//             // Give socat a tiny moment to start
//             try init.io.sleep(.{ .nanoseconds = 150 * std.time.ns_per_ms }, .real);
//         }
//
//         client.init(arena_allocator, init.io);
//         try client.parseHost(host);
//         defer client.deinit();
//
//         var doc = try zon.parse(arena_allocator, try std.fmt.allocPrint(arena_allocator,
//             \\.{{
//             \\    .raw = .{{
//             \\        .version = "{s}",
//             \\        .endpoint = "/version",
//             \\        .method = std.http.Method.GET,
//             \\    }},
//             \\}}
//             , .{docker.api_version}
//         ));
//
//         const responses = try client.send(&doc.root);
//
//         for (responses) |*response| {
//             const dump = try std.json.Stringify.valueAlloc(arena_allocator, response, .{ .whitespace = .indent_2 });
//
//             std.debug.print("{s}\n", .{dump});
//         }
//
//         if (std.mem.eql(u8, uri.scheme, "tcp")) child.kill(init.io);
//     }
//
//     const ctx: []const u8 = try std.fs.path.join(arena_allocator, &[_][]const u8{
//         "dockerfiles", "base",
//     });
//
//     client.init(arena_allocator, init.io);
//     try client.parseHost(null);
//     defer client.deinit();
//
//     var doc = try zon.parse(arena_allocator, try std.fmt.allocPrint(arena_allocator,
//         \\.{{
//         \\    .build = .{{
//         \\        .version = "{s}",
//         \\        .ctx = "{s}",
//         \\        .t = "{s}/{s}:latest",
//         \\    }},
//         \\}}
//         , .{ docker.api_version, ctx, @import("build").name, ctx }
//     ));
//
//     _ = try client.send(&doc.root);
// }
