const std = @import("std");
const docker = @import("docker");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const verbose = init.minimal.environ.containsConstant("VERBOSE");

    if (!args.skip()) unreachable;
    const input = args.next().?;
    if (args.skip()) unreachable;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, input, gpa, .unlimited);
    defer gpa.free(source);
    if (verbose) std.log.debug("{s}: {s}", .{ input, source });

    var diag: std.json.Diagnostics = .{};
    var scanner: std.json.Scanner = .initCompleteInput(gpa, source);
    defer scanner.deinit();
    scanner.enableDiagnostics(&diag);
    const parsed = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.err("{s}: line {}, column {}", .{ source, diag.getLine(), diag.getColumn() });
        return err;
    };
    std.debug.assert(std.meta.activeTag(parsed) == .object);

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});

    if (parsed.object.getPtr("docker")) |req_body| {
        var docker_client = docker.Client.init(arena, gpa, io, &init.minimal.environ);
        defer docker_client.deinit();

        try docker_client.send(&stdout_writer.interface, req_body);
    } else if (parsed.object.getPtr("docker_build")) |req_body| {
        var docker_client = docker.Client.init(arena, gpa, io, &init.minimal.environ);
        defer docker_client.deinit();

        try docker_client.sendBuild(req_body);
    } else unreachable;
}
