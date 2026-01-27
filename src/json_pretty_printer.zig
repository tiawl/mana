const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    if (!args.skip()) unreachable;
    const input = args.next().?;
    if (args.skip()) unreachable;

    const source = try std.Io.Dir.cwd().readFileAlloc(io, input, gpa, .unlimited);
    defer gpa.free(source);

    const stderr = std.debug.lockStderr(&.{});
    defer std.debug.unlockStderr();

    if (source.len > 0 and init.minimal.environ.containsConstant("VERBOSE")) {
        var diag: std.json.Diagnostics = .{};
        var scanner = std.json.Scanner.initCompleteInput(gpa, source);
        defer scanner.deinit();

        scanner.enableDiagnostics(&diag);

        const parsed = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("{s}: line {}, column {}", .{ source, diag.getLine(), diag.getColumn() });
            return err;
        };

        try std.json.Stringify.value(parsed, .{ .whitespace = .indent_2 }, &stderr.file_writer.interface);
        try stderr.file_writer.interface.writeByte('\n');
    }
}
