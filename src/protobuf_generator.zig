const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    if (!args.skip()) return error.MissingExeArgument;
    const proto_path = if (args.next()) |arg| arg else return error.MissingInputArgument;
    if (args.skip()) return error.UnknownArgument;

    const cwd = std.Io.Dir.cwd();

    for (&[_][]const u8{
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "google" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "google", "rpc" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "google", "protobuf" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "sourcepolicy" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "sourcepolicy", "pb" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "api" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "api", "services" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "api", "services", "control" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "api", "types" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "solver" }),
        try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "solver", "pb" }),
    }) |subpath| {
        defer init.gpa.free(subpath);
        cwd.createDir(init.io, subpath, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var client = std.http.Client{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();

    var uri: std.Uri = undefined;
    const method: std.http.Method = .GET;
    var req: std.http.Client.Request = undefined;
    var response: std.http.Client.Response = undefined;
    var response_body: std.Io.Writer.Allocating = undefined;

    for (&[_]struct { url: []const u8, dest: []const u8 }{
        .{
            .url = "https://raw.githubusercontent.com/protocolbuffers/protobuf/refs/heads/main/src/google/protobuf/any.proto",
            .dest = try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "google", "protobuf", "any.proto" }),
        },
        .{
            .url = "https://raw.githubusercontent.com/protocolbuffers/protobuf/refs/heads/main/src/google/protobuf/timestamp.proto",
            .dest = try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "google", "protobuf", "timestamp.proto" }),
        },
        .{
            .url = "https://raw.githubusercontent.com/googleapis/googleapis/master/google/rpc/status.proto",
            .dest = try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "google", "rpc", "status.proto" }),
        },
        .{
            .url = "https://raw.githubusercontent.com/moby/buildkit/master/api/services/control/control.proto",
            .dest = try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "api", "services", "control", "control.proto" }),
        },
        .{
            .url = "https://raw.githubusercontent.com/moby/buildkit/master/api/types/worker.proto",
            .dest = try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "api", "types", "worker.proto" }),
        },
        .{
            .url = "https://raw.githubusercontent.com/moby/buildkit/master/solver/pb/ops.proto",
            .dest = try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "solver", "pb", "ops.proto" }),
        },
        .{
            .url = "https://raw.githubusercontent.com/moby/buildkit/master/sourcepolicy/pb/policy.proto",
            .dest = try std.fs.path.resolve(init.gpa, &.{ proto_path, "vendor", "sourcepolicy", "pb", "policy.proto" }),
        },
    }) |entry| {
        defer init.gpa.free(entry.dest);
        uri = try std.Uri.parse(entry.url);
        req = try client.request(method, uri, .{});
        defer req.deinit();

        try req.sendBodiless();

        const redirect_buffer: []u8 = try init.gpa.alloc(u8, 8 * 1024);
        defer init.gpa.free(redirect_buffer);

        response = try req.receiveHead(redirect_buffer);

        response_body = std.Io.Writer.Allocating.init(init.gpa);
        defer response_body.deinit();

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try init.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try init.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer init.gpa.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        _ = reader.streamRemaining(&response_body.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => return err,
        };

        var file_content: []const u8 = try init.gpa.dupe(u8, response_body.written());
        defer init.gpa.free(file_content);

        var dupe: []const u8 = undefined;

        for (&[_]struct { search: []const u8, replace: []const u8 }{
            .{
                .search = "github.com/moby/buildkit/",
                .replace = "vendor/",
            },
            .{
                .search = "google/rpc/",
                .replace = "vendor/google/rpc/",
            },
            .{
                .search = "google/protobuf/",
                .replace = "vendor/google/protobuf/",
            },
        }) |entry2| {
            dupe = try std.mem.replaceOwned(u8, init.gpa, file_content, entry2.search, entry2.replace);
            defer init.gpa.free(dupe);
            init.gpa.free(file_content);
            file_content = try init.gpa.dupe(u8, dupe);
        }

        try cwd.writeFile(init.io, .{
            .sub_path = entry.dest,
            .data = file_content,
        });
    }
}
