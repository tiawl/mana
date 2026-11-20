const std = @import("std");

pub const ExitCode = enum(@typeInfo(@TypeOf(std.process.exit)).@"fn".param_types[0].?) {
    ok = 0,
    err = 1,
    fatal = 2,
    info = 3,
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
            writer.writeAll("\x1b[38;5;201m") catch return error.WriteFailed;
            var outer = try serializer.beginStruct(.{});
            try outer.field("debug", self.details, .{});
            try outer.end();
            term.setColor(.reset) catch return error.WriteFailed;
        }
    };
}

fn Warning(comptime Details: type) type {
    return struct {
        id: anyerror,
        message: []const u8,
        details: Details,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            var serializer, var term = init(writer);
            writer.writeAll("\x1b[38;5;226m") catch return error.WriteFailed;
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

fn Error(comptime Details: type) type {
    return struct {
        id: anyerror,
        message: []const u8,
        details: Details,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            var serializer, var term = init(writer);
            writer.writeAll("\x1b[38;5;196m") catch return error.WriteFailed;
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

fn Fatal(comptime Details: type) type {
    return struct {
        id: anyerror,
        message: []const u8,
        details: Details,

        pub fn format(self: @This(), writer: *std.Io.Writer) !void {
            var serializer, var term = init(writer);
            writer.writeAll("\x1b[38;5;214m") catch return error.WriteFailed;
            var outer = try serializer.beginStruct(.{});
            var inner = try outer.beginStructField("fatal", .{});
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

pub const Logger = struct {
    pub fn debug(details: anytype) void {
        std.debug.print("{f}\n", .{Debug(@TypeOf(details)){
            .details = details,
        }});
    }

    pub fn warn(e: anyerror, message: []const u8, details: anytype) void {
        std.debug.print("{f}\n", .{Warning(@TypeOf(details)){
            .id = e,
            .message = message,
            .details = details,
        }});
    }

    pub fn fatal(e: anyerror, message: []const u8, details: anytype) void {
        std.debug.print("{f}\n", .{Fatal(@TypeOf(details)){
            .id = e,
            .message = message,
            .details = details,
        }});
    }

    pub fn err(e: anyerror, message: []const u8, details: anytype) void {
        std.debug.print("{f}\n", .{Error(@TypeOf(details)){
            .id = e,
            .message = message,
            .details = details,
        }});
    }
};

pub const debug = Logger.debug;
pub const warn = Logger.warn;

fn exit(id: anyerror, message: []const u8, details: anytype, code: u8) noreturn {
    Logger.err(id, message, details);
    std.process.exit(code);
}

pub fn err(e: anyerror, comptime message: []const u8, details: anytype) noreturn {
    exit(e, message, details, @backingInt(ExitCode.err));
}

pub fn fatal(e: anyerror, comptime message: []const u8, details: anytype) noreturn {
    exit(e, message, details, @backingInt(ExitCode.fatal));
}
