const std = @import("std");
const builtin = @import("builtin");
const script = @import("script");
const log = @import("log");
const opt = @import("opt.zig");

var safe_allocator_instance: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
const use_safe_allocator = switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

pub fn main(init: std.process.Init.Minimal) void {
    const gpa = if (use_safe_allocator) safe_allocator_instance.allocator() else std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator_instance.deinit();
    };

    var threaded: std.Io.Threaded = .init(gpa, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();

    threaded.setAsyncLimit(.limited((std.Thread.getCpuCount() catch 0) + 1));

    var options = opt.OptionsParser.init(&arena_instance, gpa);
    defer options.deinit();
    options.parse(&init.args);

    if (options.version) {
        options.printVersion();
        if (!options.help) std.process.exit(log.ExitCode.info.backingInt());
    }

    if (options.help) {
        options.printHelp();
        std.process.exit(log.ExitCode.info.backingInt());
    }

    script.init(&arena_instance, gpa, io, &init.environ);
    defer script.deinit();

    script.build(options.rule, options.args.items);
    script.run();
}
