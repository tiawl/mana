const std = @import("std");
const mana = @import("mana.zig");

pub fn build(builder: *std.Build) !void {
    mana.init(builder);

    const src_json_processor_impl_dir = try builder.root.root_dir.handle.openDir(builder.graph.io, builder.pathResolve(&.{ "src", "json_processor", "impl" }), .{ .iterate = true });
    defer src_json_processor_impl_dir.close(builder.graph.io);

    var json_processor_dynlibs: std.StringHashMap(*std.Build.Step.Compile) = .init(builder.graph.arena);
    var it = src_json_processor_impl_dir.iterate();
    while (try it.next(builder.graph.io)) |entry| {
        switch (entry.kind) {
            .file => {
                const dynlib_name = std.fs.path.stem(entry.name);
                const dynlib_path = builder.path(builder.pathResolve(&.{ "src", "json_processor", "impl", entry.name }));
                const dynlib = mana.buildJSONProcessorDynamicLibrary(dynlib_name, dynlib_path);
                json_processor_dynlibs.put(builder.dupe(dynlib_name), dynlib) catch @panic("OOM");
            },
            else => unreachable,
        }
    }

    const docker_version = mana.sendDockerDefaultRequest(.version, .GET, .{ .hello = "world" }, &.{});
    const docker_build_base_latest = mana.sendDockerBuildRequest("dockerfiles/base", "base:latest", &.{});
    _ = docker_build_base_latest;
    const process_api_version = mana.processJSON(json_processor_dynlibs.get("docker_version_get_api_version").?, &.{docker_version});
    _ = process_api_version;
}
