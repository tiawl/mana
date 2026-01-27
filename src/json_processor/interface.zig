const builtin = @import("builtin");
const std = @import("std");
const Init = @import("init").Init;

pub const JSONProcessor = struct {
    const use_safe_allocator = switch (builtin.mode) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    var arena_instance: std.heap.ArenaAllocator = undefined;
    var safe_allocator_instance: std.heap.SafeAllocator = undefined;
    var threaded: std.Io.Threaded = undefined;

    const VTable = struct {
        init_fn: *const fn (*anyopaque, *const Init) void,
        deinit_fn: *const fn (*anyopaque, *const Init) void,
        process_fn: *const fn (*anyopaque, *const std.json.Array, *const Init) std.json.Value,
    };

    ptr: *anyopaque,
    vtable: *const VTable,
    processor_init: Init,

    pub fn implement(comptime T: type, impl: *T) @This() {
        return .{
            .ptr = impl,
            .vtable = &.{
                .init_fn = T.init,
                .deinit_fn = T.deinit,
                .process_fn = T.process,
            },
            .processor_init = undefined,
        };
    }

    pub fn init(self: *@This()) void {
        safe_allocator_instance = .init(std.heap.page_allocator, .{});
        self.processor_init.gpa = if (use_safe_allocator) safe_allocator_instance.allocator() else std.heap.smp_allocator;
        threaded = .init(self.processor_init.gpa, .{});
        arena_instance = .init(std.heap.page_allocator);
        self.processor_init.io = threaded.io();
        self.processor_init.arena = arena_instance.allocator();
        self.vtable.init_fn(self.ptr, &self.processor_init);
    }

    pub fn deinit(self: *@This()) void {
        self.vtable.deinit_fn(self.ptr, &self.processor_init);
        if (use_safe_allocator) {
            _ = safe_allocator_instance.deinit();
        }
        threaded.deinit();
        arena_instance.deinit();
    }

    pub fn free(self: @This(), output_str: [*:0]const u8) void {
        self.processor_init.gpa.free(std.mem.span(output_str));
    }

    pub fn process(self: *@This(), inputs_str: [*:0]const u8) [*:0]const u8 {
        var diag: std.json.Diagnostics = .{};
        var scanner: std.json.Scanner = .initCompleteInput(self.processor_init.gpa, std.mem.span(inputs_str));
        defer scanner.deinit();
        scanner.enableDiagnostics(&diag);
        const inputs_json = std.json.parseFromTokenSourceLeaky(std.json.Value, self.processor_init.arena, &scanner, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.debug.panic("{s} line {}, column {} into:\n{s}", .{ @errorName(err), diag.getLine(), diag.getColumn(), std.mem.span(inputs_str) });
        };
        var output: std.Io.Writer.Allocating = .init(self.processor_init.gpa);
        defer output.deinit();

        const output_json = self.vtable.process_fn(self.ptr, &inputs_json.array, &self.processor_init);
        std.json.Stringify.value(output_json, .{}, &output.writer) catch |err| {
            std.debug.panic("std.json.Stringify.value() triggered {s}", .{@errorName(err)});
        };
        const output_str = output.toOwnedSliceSentinel(0) catch |err| {
            std.debug.panic("std.Io.Writer.Allocating.toOwnedSliceSentinel() triggered {s}", .{@errorName(err)});
        };

        return output_str.ptr;
    }
};
