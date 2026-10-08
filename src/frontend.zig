const std = @import("std");
const mana = @import("mana");

var singleton: Scheduler = undefined;

pub fn init(arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
    singleton.init(arena, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn addJSONProcessTask(comptime Impl: type, key: []const u8, inputs: []const []const u8) !void {
    try singleton.addJSONProcessTask(Impl, key, inputs);
}

pub fn addRequestTask(key: []const u8, input: std.json.Value, dependencies: []const []const u8) !void {
    try singleton.addRequestTask(key, input, dependencies);
}

pub fn run() !void {
    try singleton.run();
}

// TODO: It should take std.Io.Group for potential async loops
fn JSONProcessTask(comptime Impl: type) type {
    return struct {
        arena: std.mem.Allocator,
        gpa: std.mem.Allocator,
        inputs: std.ArrayList(*const std.json.Value),
        output: std.json.Value,

        pub fn init(ptr: *anyopaque, arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io) void {
            var self: *@This() = @ptrCast(@alignCast(ptr));
            _ = io;
            self.arena = arena.allocator();
            self.gpa = gpa;
            self.inputs = .empty;
        }

        pub fn deinit(ptr: *anyopaque) void {
            var self: *@This() = @ptrCast(@alignCast(ptr));
            self.inputs.deinit(self.gpa);
        }

        pub fn run(ptr: *anyopaque) !void {
            var self: *@This() = @ptrCast(@alignCast(ptr));

            var inputs: std.json.Value = .{
                .array = .init(self.gpa),
            };
            defer inputs.array.deinit();

            for (self.inputs.items) |input| try inputs.array.append(input.*);

            const source = try self.gpa.print("{f}", .{std.json.fmt(inputs, .{})});
            defer self.gpa.free(source);

            var diag: std.json.Diagnostics = .{};
            var scanner: std.json.Scanner = .initCompleteInput(self.gpa, source);
            defer scanner.deinit();
            scanner.enableDiagnostics(&diag);

            const parsed = std.json.parseFromTokenSourceLeaky(std.json.Value, self.arena, &scanner, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.err("{s}: line {}, column {}", .{ source, diag.getLine(), diag.getColumn() });
                return err;
            };
            self.output = try mana.processJSON(Impl, parsed);
        }

        pub fn dependOn(ptr: *anyopaque, child: *const Task) !void {
            var self: *@This() = @ptrCast(@alignCast(ptr));
            try self.inputs.append(self.gpa, child.getOutput().?);
        }

        pub fn getOutput(ptr: *const anyopaque) ?*const std.json.Value {
            const self: *const @This() = @ptrCast(@alignCast(ptr));
            return &self.output;
        }

        pub fn task(self: *@This()) Task {
            return .implement(@This(), self);
        }
    };
}

const RequestTask = struct {
    gpa: std.mem.Allocator,
    input: std.json.Value,
    output: std.json.Value,

    pub fn init(ptr: *anyopaque, arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{ arena, io };
        self.gpa = gpa;
    }

    pub fn deinit(ptr: *anyopaque) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        mana.free(self.gpa, &self.output);
    }

    pub fn run(ptr: *anyopaque) !void {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        self.output = try mana.sendRequestValue(self.gpa, self.input);
    }

    pub fn dependOn(ptr: *anyopaque, child: *const Task) !void {
        _ = .{ ptr, child };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const std.json.Value {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
    }

    pub fn task(self: *@This()) Task {
        return .implement(@This(), self);
    }
};

const InitTask = struct {
    pub fn init(ptr: *anyopaque, arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io) void {
        _ = .{ ptr, arena, gpa, io };
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

    pub fn getOutput(ptr: *const anyopaque) ?*const std.json.Value {
        _ = ptr;
        return null;
    }

    pub fn task(self: *@This()) Task {
        return .implement(@This(), self);
    }
};

const Task = struct {
    const VTable = struct {
        init_fn: *const fn (*anyopaque, *std.heap.ArenaAllocator, std.mem.Allocator, std.Io) void,
        deinit_fn: *const fn (*anyopaque) void,
        run_fn: *const fn (*anyopaque) anyerror!void,
        depend_on_fn: *const fn (*anyopaque, *const Task) anyerror!void,
        get_output_fn: *const fn (*const anyopaque) ?*const std.json.Value,
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
        };
    }

    pub fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io) void {
        self.arena = arena;
        self.gpa = gpa;
        self.io = io;
        self.vtable.init_fn(self.ptr, arena, gpa, io);
    }

    pub fn deinit(self: *@This()) void {
        self.vtable.deinit_fn(self.ptr);
        for (0..self.children.items.len) |i| {
            self.children.items[i].deinit();
            self.gpa.destroy(self.children.items[i]);
        }
        self.children.deinit(self.gpa);
        self.parents.deinit(self.gpa);
    }

    pub fn dependOn(self: *@This(), child: *@This()) !void {
        try self.children.append(self.gpa, try self.gpa.create(@This()));
        self.children.last().?.* = child.*;
        self.children.last().?.init(self.arena, self.gpa, self.io);
        try self.children.last().?.parents.append(self.gpa, self);
        try self.vtable.depend_on_fn(self.ptr, self.children.last().?);
    }

    pub fn getOutput(self: *const @This()) ?*const std.json.Value {
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

    fn spawn(self: *@This(), group: *std.Io.Group) void {
        self.pending = .init(self.children.items.len);
        self.ready = .unset;

        group.async(self.io, @This().run, .{self});
        for (self.children.items) |child| child.spawn(group);
    }

    fn run(self: *@This()) error{Canceled}!void {
        if (self.pending.load(.acquire) > 0) try self.ready.wait(self.io);

        self.vtable.run_fn(self.ptr) catch |err| {
            std.log.err("{s} happened when run asynchronously", .{@errorName(err)});
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

    pub fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
        mana.init(arena, gpa, io, environ);
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
        while (it.next()) |*entry| self.gpa.free(entry.key_ptr.*);
        self.tasks.deinit();
        mana.deinit();
    }

    // TODO: hash the key
    fn addTask(self: *@This(), comptime TaskImpl: type, key: []const u8, instance: *TaskImpl, dependencies: []const []const u8) !void {
        var task = instance.task();
        try self.init_task.dependOn(&task);
        try self.tasks.put(try self.gpa.dupe(u8, key), &task);
        for (dependencies) |dep_key| {
            try self.tasks.get(key).?.dependOn(self.tasks.get(dep_key).?);
        }
    }

    pub fn addJSONProcessTask(self: *@This(), comptime Impl: type, key: []const u8, inputs: []const []const u8) !void {
        const instance = try self.arena.allocator().create(JSONProcessTask(Impl));

        try self.addTask(JSONProcessTask(Impl), key, instance, inputs);
    }

    pub fn addRequestTask(self: *@This(), key: []const u8, input: std.json.Value, dependencies: []const []const u8) !void {
        const instance = try self.arena.allocator().create(RequestTask);
        instance.* = .{
            .gpa = undefined,
            .input = input,
            .output = undefined,
        };

        try self.addTask(RequestTask, key, instance, dependencies);
    }

    pub fn run(self: *@This()) !void {
        if (!try self.init_task.isAcyclic()) return error.DependencyLoopDetected;

        self.group = .init;
        defer self.group.cancel(self.io);

        self.init_task.spawn(&self.group);
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
