const std = @import("std");

fn log_and_exit(comptime fmt: []const u8, args: anytype, code: u8) noreturn {
    if (fmt.len > 0) std.log.err(fmt, args);
    std.process.exit(code);
}

pub fn expectedly(comptime fmt: []const u8, args: anytype) noreturn {
    log_and_exit(fmt, args, 1);
}

pub fn unexpectedly(comptime fmt: []const u8, args: anytype) noreturn {
    log_and_exit(fmt, args, 2);
}
