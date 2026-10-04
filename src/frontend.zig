const std = @import("std");
const builtin = @import("builtin");
const mana = @import("mana");

var safe_allocator_instance: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
const use_safe_allocator = switch (builtin.mode) {
    .debug, .safe => true,
    .fast, .small => false,
};

const GetAPIVersion = struct {
    pub fn init(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, allocator, io };
    }

    pub fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, allocator, io };
    }

    pub fn process(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, inputs: []const std.json.Value) std.json.Value {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, allocator, io };
        return inputs[0].object.get("ApiVersion").?;
    }
};

const RootTask = struct {
    fn run(ptr: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{self};
    }

    fn task(self: *@This()) Task {
        return .implement(@This(), self);
    }
};

const Task = struct {
    const VTable = struct {
        run_fn: *const fn (*anyopaque) anyerror!void,
    };

    ptr: *anyopaque,
    vtable: *const VTable,
    gpa: std.mem.Allocator,
    children: std.ArrayList(*@This()),
    parents: std.ArrayList(*@This()),
    pending: std.atomic.Value(usize),
    ready: std.Io.Event,

    pub fn implement(comptime T: type, impl: *T) @This() {
        return .{
            .ptr = impl,
            .vtable = &.{
                .run_fn = T.run,
            },
            .gpa = undefined,
            .children = .empty,
            .parents = .empty,
            .pending = undefined,
            .ready = undefined,
        };
    }

    pub fn init(self: *@This(), gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        self.children = .init(self.gpa);
        self.parents = .init(self.gpa);
    }

    pub fn deinit(self: *@This()) void {
        self.children.deinit();
        self.parents.deinit();
    }

    pub fn dependOn(self: *@This(), child: *@This()) !void {
        try self.children.append(child);
        try child.parents.append(self);
    }

    pub fn run(self: *@This(), io: std.Io, group: *std.Io.Group) !void {
        if (self.isAcyclic) return error.DependencyLoopDetected;
        self.pending = .init(self.children.items.len);
        self.ready = .unset;
        try self.spawn(io, group);
        try group.await(io);
    }

    fn isAcyclic(self: @This()) !bool {
        var visited = std.AutoHashMap(*const @This(), void).init(self.gpa);
        defer visited.deinit();
        var on_path = std.AutoHashMap(*const @This(), void).init(self.gpa);
        defer on_path.deinit();

        return try self.isAcyclicInner(&visited, &on_path);
    }

    fn isAcyclicInner(self: @This(), visited: *std.AutoHashMap(*const @This(), void), on_path: *std.AutoHashMap(*const @This(), void)) !bool {
        if (on_path.contains(self)) return false;
        if (visited.contains(self)) return true;

        try visited.put(self, {});
        try on_path.put(self, {});

        for (self.children.items) |child| {
            if (!try child.isAcyclicInner(visited, on_path)) return false;
        }

        _ = on_path.remove(self);
        return true;
    }

    fn spawn(self: *@This(), io: std.Io, group: *std.Io.Group) void {
        group.async(io, runInner, .{ self, io });
        for (self.children.items) |child| child.spawn(io, group);
    }

    fn runInner(self: *@This(), io: std.Io) !void {
        if (self.pending.load(.acquire) > 0) try self.ready.wait(io);

        try self.vtable.run_fn(self.ptr);

        for (self.parents.items) |parent| {
            if (parent.pending.fetchSub(1, .acq_rel) == 1) parent.ready.set(io);
        }
    }
};

pub fn main(init: std.process.Init.Minimal) !void {
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
    const arena = arena_instance.allocator();
    _ = arena;

    threaded.setAsyncLimit(.limited(std.Thread.getCpuCount() catch 1));

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    var root_instance: RootTask = .{};
    const graph = root_instance.task();

    mana.init(&arena_instance, gpa, io, &init.environ);
    defer mana.deinit();

    // TODO: try graph.dependOn();
    _ = graph;

    var docker_version = try mana.sendDockerDefaultRequest(gpa, .version, .GET, .{ .hello = "world" });
    defer mana.free(gpa, &docker_version);

    _ = try mana.sendDockerBuildRequest(gpa, "dockerfiles/base", "base:latest");
    const process_api_version = try mana.processJSON(GetAPIVersion, &.{docker_version.array.items[0]});
    process_api_version.dump();

    //try mana.schedule(.{
    //    .@"json_processor/dummy" = .{
    //        .hello = "world",
    //    },
    //});

    // 1. Fill graph
    // 2. check it is not acyclic
    // 3. Reverse Breadth-first search and run only when all children are ready
}
