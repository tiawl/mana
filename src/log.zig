const std = @import("std");
const log = @This();

pub const Logger = struct {
    pub fn debug(details: anytype) void {
        log.debug(details);
    }

    pub fn warn(message: []const u8, details: anytype) void {
        log.warn(error.DockerClientFailed, message, details);
    }

    pub fn err(e: anyerror, message: []const u8, details: anytype) void {
        log.err(e, message, details);
    }
};

fn init(writer: *std.Io.Writer) struct { std.zon.Serializer, std.Io.Terminal } {
    return .{
        .{
            .writer = writer,
            .options = .{ .whitespace = true },
        },
        .{
            .writer = writer,
            .mode = .escape_codes,
        },
    };
}

fn Debug(comptime Details: type) type {
    return struct {
        details: Details,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            var serializer, var term = init(writer);
            term.setColor(.magenta) catch return error.WriteFailed;
            var outer = try serializer.beginStruct(.{});
            try outer.field("debug", self.details, .{});
            try outer.end();
            term.setColor(.reset) catch return error.WriteFailed;
        }
    };
}

pub fn debug(details: anytype) void {
    std.debug.print("{f}\n", .{Debug(@TypeOf(details)){
        .details = details,
    }});
}

fn Warning(comptime Details: type) type {
    return struct {
        id: anyerror,
        message: []const u8,
        details: Details,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            var serializer, var term = init(writer);
            term.setColor(.yellow) catch return error.WriteFailed;
            var outer = try serializer.beginStruct(.{});
            var inner = try outer.beginStructField("warning", .{});
            try inner.fieldPrefix("id");
            try serializer.ident(@errorName(self.id));
            try inner.field("message", self.message, .{});
            try inner.field("details", self.details, .{});
            try inner.end();
            try outer.end();
            term.setColor(.reset) catch return error.WriteFailed;
        }
    };
}

pub fn warn(id: anyerror, message: []const u8, details: anytype) void {
    std.debug.print("{f}\n", .{Warning(@TypeOf(details)){
        .id = id,
        .message = message,
        .details = details,
    }});
}

fn Error(comptime Details: type) type {
    return struct {
        id: anyerror,
        message: []const u8,
        details: Details,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            var serializer, var term = init(writer);
            term.setColor(.red) catch return error.WriteFailed;
            var outer = try serializer.beginStruct(.{});
            var inner = try outer.beginStructField("error", .{});
            try inner.fieldPrefix("id");
            try serializer.ident(@errorName(self.id));
            try inner.field("message", self.message, .{});
            try inner.field("details", self.details, .{});
            try inner.end();
            try outer.end();
            term.setColor(.reset) catch return error.WriteFailed;
        }
    };
}

fn err(id: anyerror, message: []const u8, details: anytype) void {
    std.debug.print("{f}\n", .{Error(@TypeOf(details)){
        .id = id,
        .message = message,
        .details = details,
    }});
}

fn exit(id: anyerror, message: []const u8, details: anytype, code: u8) noreturn {
    log.err(id, message, details);
    std.process.exit(code);
}

pub fn exitExpectedly(e: anyerror, comptime message: []const u8, details: anytype) noreturn {
    exit(e, message, details, 1);
}

pub fn exitUnexpectedly(e: anyerror, comptime message: []const u8, details: anytype) noreturn {
    exit(e, message, details, 2);
}
