const std = @import("std");
const EntrypointGetter = @import("entrypoint").EntrypointGetter;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const verbose = init.minimal.environ.containsConstant("VERBOSE");

    if (!args.skip()) unreachable;
    const dynlib_path = args.next().?;

    var inputs_json: std.json.Value = .{ .array = .init(gpa) };
    defer inputs_json.array.deinit();
    var diag: std.json.Diagnostics = .{};
    var scanner: std.json.Scanner = undefined;
    while (args.next()) |arg| {
        const source = try std.Io.Dir.cwd().readFileAlloc(io, arg, gpa, .unlimited);
        defer gpa.free(source);
        if (verbose) std.log.debug("{s}: {s}", .{ arg, source });
        scanner = .initCompleteInput(gpa, source);
        defer scanner.deinit();
        scanner.enableDiagnostics(&diag);
        try inputs_json.array.append(std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("{s}: line {}, column {}", .{ source, diag.getLine(), diag.getColumn() });
            return err;
        });
    }

    var inputs: std.Io.Writer.Allocating = .init(gpa);
    defer inputs.deinit();
    try std.json.Stringify.value(inputs_json, .{}, &inputs.writer);

    var dynlib = try std.DynLib.openZ(dynlib_path);
    defer dynlib.close();
    const getEntrypoint = dynlib.lookup(EntrypointGetter, "getEntrypoint").?;
    const json_processor = getEntrypoint();
    json_processor.init();
    defer json_processor.deinit();

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const inputs_str = try inputs.toOwnedSliceSentinel(0);
    defer gpa.free(inputs_str);
    const output_str = json_processor.process(inputs_str.ptr);
    defer json_processor.free(output_str);
    try stdout_writer.interface.writeAll(std.mem.span(output_str));
}
