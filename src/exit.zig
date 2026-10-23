const std = @import("std");

fn Error(comptime Details: type) type {
    return struct {
        id: anyerror,
        message: []const u8,
        details: Details,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            var serializer: std.zon.Serializer = .{
                .writer = writer,
                .options = .{ .whitespace = true },
            };

            var outer = try serializer.beginStruct(.{});
            var inner = try outer.beginStructField("error", .{});
            try inner.fieldPrefix("id");
            try serializer.ident(@errorName(self.id));
            try inner.field("message", self.message, .{});
            try inner.field("details", self.details, .{});
            try inner.end();
            try outer.end();
        }
    };
}

fn log_and_exit(err: anyerror, comptime message: []const u8, details: anytype, code: u8) noreturn {
    std.debug.print("{f}\n", .{Error(@TypeOf(details)){
        .id = err,
        .message = message,
        .details = details,
    }});
    std.process.exit(code);
}

pub fn expectedly(err: anyerror, comptime message: []const u8, details: anytype) noreturn {
    log_and_exit(err, message, details, 1);
}

pub fn unexpectedly(err: anyerror, comptime message: []const u8, details: anytype) noreturn {
    log_and_exit(err, message, details, 2);
}
