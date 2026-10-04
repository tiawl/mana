const std = @import("std");
const build = @import("build");

fn enumConcatenatedBackingInt(comptime T: type) []const u8 {
    std.debug.assert(std.meta.activeTag(@typeInfo(T)) == .@"enum");
    std.debug.assert(@typeInfo(T).@"enum".tag_type == noreturn or @typeInfo(T).@"enum".tag_type == u8);
    const field_values = @typeInfo(T).@"enum".field_values;
    var result: [field_values.len]u8 = undefined;
    for (&result, field_values) |*r, f_value| r.* = @intCast(f_value);
    const final = result;
    return &final;
}

fn short(comptime field: Options) []const u8 {
    return "-" ++ std.fmt.comptimePrint("{c}", .{@backingInt(field)});
}

fn long(comptime field: Options) []const u8 {
    return "--" ++ @tagName(field);
}

fn isUsed(comptime field: Options, arg: [:0]const u8) bool {
    return std.mem.eql(u8, arg, short(field)) or std.mem.eql(u8, arg, long(field));
}

fn desc(self: Options) []const u8 {
    return switch (self) {
        .help => "Print help information",
        .version => "Print version information",
    };
}

fn param(comptime self: Options) []const u8 {
    return switch (self) {
        inline .help, .version => "",
    };
}

const Options = @Enum(
    u8,
    .exhaustive,
    @typeInfo(OptionsWith1Param).@"enum".field_names ++ @typeInfo(OptionsWithoutParam).@"enum".field_names,
    enumConcatenatedBackingInt(OptionsWith1Param) ++ enumConcatenatedBackingInt(OptionsWithoutParam),
);

const OptionsWith1Param = enum(noreturn) {
    const tags = enumConcatenatedBackingInt(@This());

    fn is(str: []const u8) bool {
        _ = std.meta.stringToEnum(@This(), str) orelse return false;
        return true;
    }
};

const OptionsWithoutParam = enum(u8) {
    const tags = enumConcatenatedBackingInt(@This());

    help = 'h',
    version = 'V',
};

const ArgIterator = struct {
    gpa: std.mem.Allocator,
    deque: std.Deque([:0]const u8),
    args: []const [:0]const u8,
    i: usize,

    pub fn init(gpa: std.mem.Allocator, args: []const [:0]const u8) @This() {
        return .{
            .gpa = gpa,
            .deque = .empty,
            .args = args,
            .i = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        while (self.deque.len > 0) self.popFront();
        self.deque.deinit(self.gpa);
    }

    fn popFront(self: *@This()) void {
        std.debug.assert(self.deque.len > 0);
        self.gpa.free(self.deque.popFront().?);
    }

    fn append(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        std.debug.assert(self.deque.len < 2);
        try self.deque.pushBack(self.gpa, try std.fmt.allocPrintSentinel(self.gpa, fmt, args, 0));
    }

    // Handle '-abc' the same as '-a -bc' for short-form no-arg options
    fn handleContractedShortOptionsWithoutParam(self: *@This()) !void {
        var arg = if (self.deque.len > 0) self.deque.front().? else self.args[self.i];

        if (!std.mem.startsWith(u8, arg, "-") or arg.len <= 2 or std.mem.findAny(u8, arg[1..], OptionsWithoutParam.tags) != 0) return;

        var allocated = false;
        defer if (allocated) self.gpa.free(arg);
        if (self.deque.len > 0) {
            arg = try self.gpa.dupeSentinel(u8, self.deque.front().?, 0);
            allocated = true;
            self.popFront();
        }

        try self.append("{s}", .{arg[0..2]});
        try self.append("-{s}", .{arg[2..]});
    }

    // Handle '-foo' the same as '-f oo' for short-form 1-arg options
    fn handleContractedShortOptionsWith1Param(self: *@This()) !void {
        var arg = if (self.deque.len > 0) self.deque.front().? else self.args[self.i];

        if (!std.mem.startsWith(u8, arg, "-") or arg.len <= 2 or std.mem.findAny(u8, arg[1..], OptionsWith1Param.tags) != 0) return;

        var allocated = false;
        defer if (allocated) self.gpa.free(arg);
        if (self.deque.len > 0) {
            arg = try self.gpa.dupeSentinel(u8, self.deque.front().?, 0);
            allocated = true;
            self.popFront();
        }

        try self.append("{s}", .{arg[0..2]});
        try self.append("{s}", .{arg[2..]});
    }

    // Handle '--file=file1' the same as '--file file1' for long-form 1-arg options
    fn handleEqualLongOptionsWith1Param(self: *@This()) !void {
        var arg = if (self.deque.len > 0) self.deque.front().? else self.args[self.i];
        const equal_index = std.mem.findScalar(u8, arg, '=');

        if (!std.mem.startsWith(u8, arg, "--") or arg.len <= 3 or equal_index == null or !OptionsWith1Param.is(arg[2..equal_index.?])) return;

        var allocated = false;
        defer if (allocated) self.gpa.free(arg);
        if (self.deque.len > 0) {
            arg = try self.gpa.dupeSentinel(u8, self.deque.front().?, 0);
            allocated = true;
            self.popFront();
        }

        try self.append("{s}", .{arg[0..equal_index.?]});
        if (arg[equal_index.? + 1 ..].len > 0) try self.append("{s}", .{arg[equal_index.? + 1 ..]});
    }

    pub fn next(self: *@This()) !?[:0]const u8 {
        if (self.deque.len == 2) {
            self.popFront();
        } else if (self.deque.len == 1) {
            self.popFront();
            self.i += 1;
        }

        if (self.i >= self.args.len and self.deque.len == 0) return null;

        try self.handleContractedShortOptionsWithoutParam();
        if (self.deque.len < 2) try self.handleContractedShortOptionsWith1Param();
        if (self.deque.len < 2) try self.handleEqualLongOptionsWith1Param();

        if (self.deque.len > 0) {
            return self.deque.front().?;
        } else {
            defer self.i += 1;
            return self.args[self.i];
        }
    }
};

pub const OptionsParser = struct {
    gpa: std.mem.Allocator,
    help: bool,
    version: bool,
    rule: std.Io.Writer.Allocating,

    pub fn init(gpa: std.mem.Allocator) @This() {
        return .{
            .gpa = gpa,
            .help = false,
            .version = false,
            .rule = .init(gpa),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.rule.deinit();
    }

    fn needHelp(self: *@This()) void {
        self.help = true;
    }

    fn needVersion(self: *@This()) void {
        self.version = true;
    }

    pub fn parse(self: *@This(), args: []const [:0]const u8) !void {
        var it = ArgIterator.init(self.gpa, args);
        defer it.deinit();

        _ = try it.next();
        while (try it.next()) |arg_z| {
            const arg = std.mem.span(arg_z.ptr);
            if (isUsed(.help, arg_z)) {
                self.needHelp();
            } else if (isUsed(.version, arg_z)) {
                self.needVersion();
            } else {
                if (self.rule.written().len > 0) try self.rule.writer.writeByte(' ');
                try self.rule.writer.writeAll(arg);
            }
        }
    }

    pub fn printVersion(self: @This()) void {
        _ = self;
        std.debug.print("{s} {s}\n", .{ build.name, build.version });
    }

    pub fn printHelp(self: @This()) void {
        _ = self;
        comptime var max: usize = 0;
        std.debug.print(
            \\{s}
            \\
            \\Usage:
            \\    {s} [options] rule
            \\
            \\Options:
            \\
        , .{ build.description, build.name });
        inline for (std.enums.values(Options)) |opt| max = @max(@tagName(opt).len + 1 + comptime param(opt).len, max);
        inline for (std.enums.values(Options)) |opt| {
            const nb_spaces = max - @tagName(opt).len - 1 - comptime param(opt).len;
            const spaces: [nb_spaces]u8 = @splat(' ');
            std.debug.print("    -{c}, -{s} {s}{s}   {s}\n", .{
                @backingInt(opt), @tagName(opt), param(opt), spaces, desc(opt),
            });
        }
    }
};
