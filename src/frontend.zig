const std = @import("std");
const mana = @import("mana");
const c = @import("jq");

var singleton: Scheduler = undefined;

pub fn init(arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) !void {
    try singleton.init(arena, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn addJSONQueryTask(key: []const u8, filter: []const u8, inputs: []const []const u8) !void {
    try singleton.addJSONQueryTask(key, filter, inputs);
}

pub fn addRequestTask(key: []const u8, input: c.jv, dependencies: []const []const u8) !void {
    try singleton.addRequestTask(key, input, dependencies);
}

pub fn run() !void {
    try singleton.run();
}

const JSONQueryTask = struct {
    filter: []const u8,
    inputs: *const std.StringHashMap(*Task),
    output: c.jv,
    interface: *const Task,

    pub fn task(self: *@This(), filter: []const u8, inputs: *const std.StringHashMap(*Task)) Task {
        self.filter = filter;
        self.inputs = inputs;
        self.output = c.jv_null();
        return .implement(@This(), self);
    }

    pub fn init(ptr: *anyopaque, interface: *const Task) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.interface = interface;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const dump = c.jv_dump_string(c.jv_copy(self.output), c.JV_PRINT_INVALID);
        defer c.jv_free(dump);
        std.log.debug("{s}", .{c.jv_string_value(dump)});
        c.jv_free(self.output);
    }

    pub fn run(ptr: *anyopaque) !void {
        var self: *@This() = @ptrCast(@alignCast(ptr));

        var inputs = c.jv_object();
        defer c.jv_free(inputs);

        var it = self.inputs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.getOutput()) |output| {
                // TODO: remove arena here:
                inputs = c.jv_object_set(inputs, c.jv_string(try self.interface.arena.allocator().dupeSentinel(u8, entry.key_ptr.*, 0)), c.jv_copy(output.*));
            }
        }

        c.jv_free(self.output);
        self.output = try mana.queryJSON(self.filter, inputs);
    }

    pub fn dependOn(ptr: *anyopaque, child: *const Task) !void {
        _ = .{ ptr, child };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
    }
};

const RequestTask = struct {
    input: c.jv,
    output: c.jv,
    interface: *const Task,

    pub fn task(self: *@This(), input: c.jv) Task {
        self.input = input;
        self.output = c.jv_null();
        return .implement(@This(), self);
    }

    pub fn init(ptr: *anyopaque, interface: *const Task) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.interface = interface;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const dump = c.jv_dump_string(c.jv_copy(self.output), c.JV_PRINT_INVALID);
        defer c.jv_free(dump);
        std.log.debug("{s}", .{c.jv_string_value(dump)});
        c.jv_free(self.input);
        c.jv_free(self.output);
    }

    pub fn run(ptr: *anyopaque) !void {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        c.jv_free(self.output);
        self.output = try mana.sendRequestValue(self.input);
    }

    pub fn dependOn(ptr: *anyopaque, child: *const Task) !void {
        _ = .{ ptr, child };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
    }
};

// TODO: split this into GroupTask + CallTask
const InitTask = struct {
    pub fn task(self: *@This()) Task {
        return .implement(@This(), self);
    }

    pub fn init(ptr: *anyopaque, interface: *const Task) void {
        _ = .{ ptr, interface };
    }

    pub fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn run(ptr: *anyopaque) !void {
        _ = ptr;
    }

    pub fn dependOn(ptr: *anyopaque, child: *const Task) !void {
        _ = .{ ptr, child };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        _ = ptr;
        return null;
    }
};

const Task = struct {
    const VTable = struct {
        init_fn: *const fn (*anyopaque, *const Task) void,
        deinit_fn: *const fn (*anyopaque) void,
        run_fn: *const fn (*anyopaque) anyerror!void,
        depend_on_fn: *const fn (*anyopaque, *const Task) anyerror!void,
        get_output_fn: *const fn (*const anyopaque) ?*const c.jv,
    };

    ptr: *anyopaque,
    vtable: *const VTable,
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    children: std.ArrayList(*@This()),
    parents: std.ArrayList(*@This()),
    pending: std.atomic.Value(usize),
    ready: std.Io.Event,
    spawned: bool,
    mutex: std.Io.Mutex,

    pub fn implement(comptime T: type, impl: *T) @This() {
        return .{
            .ptr = impl,
            .vtable = &.{
                .init_fn = T.init,
                .deinit_fn = T.deinit,
                .run_fn = T.run,
                .depend_on_fn = T.dependOn,
                .get_output_fn = T.getOutput,
            },
            .arena = undefined,
            .gpa = undefined,
            .io = undefined,
            .children = .empty,
            .parents = .empty,
            .pending = undefined,
            .ready = undefined,
            .spawned = undefined,
            .mutex = undefined,
        };
    }

    pub fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io) void {
        self.arena = arena;
        self.gpa = gpa;
        self.io = io;
        self.spawned = false;
        self.mutex = .init;
        self.vtable.init_fn(self.ptr, self);
    }

    pub fn deinit(self: *@This()) void {
        self.vtable.deinit_fn(self.ptr);
        self.children.deinit(self.gpa);
        self.parents.deinit(self.gpa);
    }

    pub fn dependOn(self: *@This(), child: *@This()) !void {
        try self.children.append(self.gpa, child);
        try child.parents.append(self.gpa, self);
        try self.vtable.depend_on_fn(self.ptr, child);
    }

    pub fn getOutput(self: *const @This()) ?*const c.jv {
        return self.vtable.get_output_fn(self.ptr);
    }

    pub fn isAcyclic(self: *@This()) !bool {
        var visited = std.AutoHashMap(*const @This(), void).init(self.gpa);
        defer visited.deinit();
        var on_path = std.AutoHashMap(*const @This(), void).init(self.gpa);
        defer on_path.deinit();

        return try self.isAcyclicInner(&visited, &on_path);
    }

    fn isAcyclicInner(self: *@This(), visited: *std.AutoHashMap(*const @This(), void), on_path: *std.AutoHashMap(*const @This(), void)) !bool {
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

    fn spawn(self: *@This(), group: *std.Io.Group) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.spawned) return;
        self.spawned = true;

        self.pending = .init(self.children.items.len);
        self.ready = .unset;

        group.async(self.io, @This().run, .{self, group});
        for (self.children.items) |child| try child.spawn(group);
    }

    fn run(self: *@This(), group: *std.Io.Group) error{Canceled}!void {
        if (self.pending.load(.acquire) > 0) try self.ready.wait(self.io);

        self.vtable.run_fn(self.ptr) catch |err| {
            std.log.err("{s} happened when run asynchronously", .{@errorName(err)});
            group.cancel(self.io);
            return error.Canceled;
        };

        for (self.parents.items) |parent| {
            if (parent.pending.fetchSub(1, .acq_rel) == 1) parent.ready.set(self.io);
        }
    }
};

const Scheduler = struct {
    init_instance: InitTask,
    init_task: Task,
    tasks: std.StringHashMap(*Task),
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    group: std.Io.Group,

    pub fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) !void {
        try mana.init(arena, gpa, io, environ);
        self.arena = arena;
        self.gpa = gpa;
        self.io = io;
        self.init_instance = .{};
        self.init_task = self.init_instance.task();
        self.init_task.init(self.arena, self.gpa, self.io);
        self.tasks = .init(self.gpa);
    }

    pub fn deinit(self: *@This()) void {
        self.init_task.deinit();
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.gpa.destroy(entry.value_ptr.*);
            self.gpa.free(entry.key_ptr.*);
        }
        self.tasks.deinit();
        mana.deinit();
    }

    // TODO: hash the key
    fn addTask(self: *@This(), key: []const u8, task_ptr: *Task, dependencies: []const []const u8) !void {
        task_ptr.init(self.arena, self.gpa, self.io);
        if (self.tasks.contains(key)) {
            task_ptr.deinit();
            return error.DuplicatedId;
        }
        try self.init_task.dependOn(task_ptr);
        try self.tasks.put(try self.gpa.dupe(u8, key), task_ptr);
        for (dependencies) |dep_key| {
            try self.tasks.get(key).?.dependOn(self.tasks.get(dep_key).?);
        }
    }

    pub fn addJSONQueryTask(self: *@This(), key: []const u8, filter: []const u8, dependencies: []const []const u8) !void {
        const instance = try self.arena.allocator().create(JSONQueryTask);
        const task_ptr = try self.gpa.create(Task);
        task_ptr.* = instance.task(filter, &self.tasks);
        try self.addTask(key, task_ptr, dependencies);
    }

    pub fn addRequestTask(self: *@This(), key: []const u8, input: c.jv, dependencies: []const []const u8) !void {
        const instance = try self.arena.allocator().create(RequestTask);
        const task_ptr = try self.gpa.create(Task);
        task_ptr.* = instance.task(input);
        try self.addTask(key, task_ptr, dependencies);
    }

    pub fn run(self: *@This()) !void {
        if (!try self.init_task.isAcyclic()) return error.DependencyLoopDetected;

        self.group = .init;
        defer self.group.cancel(self.io);

        try self.init_task.spawn(&self.group);
        try self.group.await(self.io);
    }
};

//fn schedule(self: *@This(), unknown_typed: anytype) !void {
//    switch (@typeInfo(@TypeOf(unknown_typed))) {
//        .@"struct" => try self.scheduleInner(unknown_typed),
//        else => {
//            std.log.err("schedule() only accept struct typed input");
//            return error.UnsupportedInput;
//        },
//    }
//}

//fn scheduleInner(self: *@This(), input: anytype) !void {
//    std.debug.assert(std.meta.activeTag(@typeInfo(@TypeOf(input))) == .@"struct");

//    const source = self.builder.fmt("{f}", .{std.json.fmt(input, .{})});

//    var diag: std.json.Diagnostics = .{};
//    var scanner = std.json.Scanner.initCompleteInput(self.builder.graph.arena, source);

//    scanner.enableDiagnostics(&diag);

//    const parsed = std.json.parseFromTokenSourceLeaky(std.json.Value, self.builder.graph.arena, &scanner, .{
//        .ignore_unknown_fields = true,
//    }) catch |err| {
//        std.log.err("{s}: line {}, column {}", .{ source, diag.getLine(), diag.getColumn() });
//        return err;
//    };

//    var ids: std.StringHashMap([]const u8) = .init(self.builder.graph.arena);

//    var it = parsed.object.iterator();
//    while (it.next()) |*task| {
//        const id = task.key_ptr.*;
//        if (std.mem.findScalar(u8, id, '/') == null) {
//            std.log.err("A valid id must contain at least a slash caracter right after module kind: {s}", .{id});
//            return error.InvalidId;
//        }
//        ids.put(self.builder.graph.dupeString(id), undefined) catch @panic("OOM");
//    }

//    it.reset();
//    while (it.next()) |*task| {
//        const id = task.key_ptr.*;
//        const module_str, _ = std.mem.cutScalar(u8, id, '/').?;
//        const module = std.meta.stringToEnum(Module, module_str) orelse {
//            std.log.err(
//                \\A valid module is one of these values {f} but yours is: "{s}"
//            , .{ std.json.fmt(@typeInfo(Module).@"enum".field_names, .{}), module_str });
//            return error.InvalidModule;
//        };
//        switch (task.value_ptr.*) {
//            .object => {},
//            else => {
//                std.log.err(
//                    \\"{s}" task isn't struct typed
//                , .{id});
//                return error.InvalidInput;
//            },
//        }
//        _ = module;
//    }
//}
