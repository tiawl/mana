const std = @import("std");
const exit = @import("exit");
const mana = @import("mana");
const c = @import("jq");

var singleton: Scheduler = undefined;

pub fn init(arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
    singleton.init(arena, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn addJSONQueryTask(key: []const u8, filter: []const u8, inputs: []const []const u8) void {
    singleton.addJSONQueryTask(key, filter, inputs);
}

pub fn addRequestTask(key: []const u8, input: c.jv, dependencies: []const []const u8) void {
    singleton.addRequestTask(key, input, dependencies);
}

pub fn run() void {
    singleton.run();
}

const JSONQueryTask = struct {
    gpa: std.mem.Allocator,
    filter: []const u8,
    inputs: *const std.StringHashMap(*Task),
    output: c.jv,

    pub fn task(self: *@This(), gpa: std.mem.Allocator, filter: []const u8, inputs: *const std.StringHashMap(*Task)) std.mem.Allocator.Error!Task {
        self.gpa = gpa;
        self.filter = try self.gpa.dupe(u8, filter);
        self.inputs = inputs;
        self.output = c.jv_null();
        return .implement(@This(), self);
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const dump = c.jv_dump_string(c.jv_copy(self.output), c.JV_PRINT_INVALID);
        defer c.jv_free(dump);
        c.jv_free(self.output);
        self.gpa.free(self.filter);
    }

    pub fn run(ptr: *anyopaque) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));

        var inputs = c.jv_object();
        defer c.jv_free(inputs);

        var it = self.inputs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.getOutput()) |output| {
                inputs = c.jv_object_set(inputs, c.jv_string_sized(entry.key_ptr.*.ptr, @intCast(entry.key_ptr.*.len)), c.jv_copy(output.*));
            }
        }

        c.jv_free(self.output);
        self.output = mana.jsonQuery(self.filter, inputs) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when trying to produce a JSON query with mana", .{}),
            error.IncorrectJqFilter => exit.expectedly(err, "The provided jq filter is incorrect", .{}),
            error.JqHalted, error.JqInvalidMsg => exit.expectedly(err, "A jq error occured", .{}),
        };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
    }
};

const RequestTask = struct {
    input: c.jv,
    output: c.jv,

    pub fn task(self: *@This(), input: c.jv) Task {
        self.input = input;
        self.output = c.jv_null();
        return .implement(@This(), self);
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const dump = c.jv_dump_string(c.jv_copy(self.output), c.JV_PRINT_INVALID);
        defer c.jv_free(dump);
        c.jv_free(self.input);
        c.jv_free(self.output);
    }

    pub fn run(ptr: *anyopaque) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        c.jv_free(self.output);
        self.output = mana.sendRequestValue(self.input) catch |err| exit.unexpectedly(err, "Occured when trying to send a request with mana", .{});
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
    }
};

const PlaceHolderTask = struct {
    name: []const u8,

    pub fn task(self: *@This(), name: []const u8) Task {
        self.name = name;
        return .implement(@This(), self);
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        exit.expectedly(error.UndefinedTaskId, "Undefined task id", .{ .task = self.name });
    }

    pub fn run(ptr: *anyopaque) void {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        exit.expectedly(error.UndefinedTaskId, "Undefined task id", .{ .task = self.name });
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        exit.expectedly(error.UndefinedTaskId, "Undefined task id", .{ .task = self.name });
    }
};

const InitTask = struct {
    pub fn task(self: *@This()) Task {
        return .implement(@This(), self);
    }

    pub fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn run(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        _ = ptr;
        return null;
    }
};

const Task = struct {
    const VTable = struct {
        deinit_fn: *const fn (*anyopaque) void,
        run_fn: *const fn (*anyopaque) void,
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
    is_place_holder: bool,

    pub fn implement(comptime T: type, impl: *T) @This() {
        return .{
            .ptr = impl,
            .vtable = &.{
                .deinit_fn = T.deinit,
                .run_fn = T.run,
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
            .is_place_holder = (T == PlaceHolderTask),
        };
    }

    pub fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io) void {
        self.arena = arena;
        self.gpa = gpa;
        self.io = io;
        self.spawned = false;
        self.mutex = .init;
    }

    pub fn deinit(self: *@This()) void {
        self.vtable.deinit_fn(self.ptr);
        self.children.deinit(self.gpa);
        self.parents.deinit(self.gpa);
    }

    pub fn dependOn(self: *@This(), child: *@This()) void {
        self.children.append(self.gpa, child) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when appending child dependency", .{}),
        };
        child.parents.append(self.gpa, self) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when appending parent dependency", .{}),
        };
    }

    pub fn getOutput(self: *const @This()) ?*const c.jv {
        return self.vtable.get_output_fn(self.ptr);
    }

    pub fn isAcyclic(self: *@This()) bool {
        var visited = std.AutoHashMap(*const @This(), void).init(self.gpa);
        defer visited.deinit();
        var on_path = std.AutoHashMap(*const @This(), void).init(self.gpa);
        defer on_path.deinit();

        return self.isAcyclicInner(&visited, &on_path);
    }

    fn isAcyclicInner(self: *@This(), visited: *std.AutoHashMap(*const @This(), void), on_path: *std.AutoHashMap(*const @This(), void)) bool {
        if (on_path.contains(self)) return false;
        if (visited.contains(self)) return true;

        visited.put(self, {}) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured memory when trying to add a new key into visited HashMap to determine if dependency graph is acyclic", .{}),
        };
        on_path.put(self, {}) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when trying to add a new key into on_path HashMap to determine if dependency graph is acyclic", .{}),
        };

        for (self.children.items) |child| {
            if (!child.isAcyclicInner(visited, on_path)) return false;
        }

        _ = on_path.remove(self);
        return true;
    }

    fn spawn(self: *@This(), group: *std.Io.Group) void {
        self.mutex.lock(self.io) catch |err| {
            group.cancel(self.io);
            switch (err) {
                error.Canceled => exit.unexpectedly(err, "Occured while mutex was locked", .{}),
            }
        };
        defer self.mutex.unlock(self.io);
        if (self.spawned) return;
        self.spawned = true;

        self.pending = .init(self.children.items.len);
        self.ready = .unset;

        group.async(self.io, @This().run, .{ self, group });
        for (self.children.items) |child| child.spawn(group);
    }

    fn run(self: *@This(), group: *std.Io.Group) void {
        if (self.pending.load(.acquire) > 0) self.ready.wait(self.io) catch |err| {
            group.cancel(self.io);
            switch (err) {
                error.Canceled => exit.unexpectedly(err, "Occured while event waits", .{}),
            }
        };

        self.vtable.run_fn(self.ptr);

        for (self.parents.items) |parent| {
            if (parent.pending.fetchSub(1, .acq_rel) == 1) parent.ready.set(self.io);
        }
    }
};

const Scheduler = struct {
    init_instance: InitTask,
    init_task: Task,
    tasks: std.StringHashMap(*Task),
    arena_instance: *std.heap.ArenaAllocator,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    group: std.Io.Group,

    pub fn init(self: *@This(), arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
        mana.init(arena_instance, gpa, io, environ) catch |err| switch (err) {
            error.JqInit, error.JqUtilInputInit => exit.unexpectedly(err, "Occured when initializing jq. This is certainly a memory allocation failure", .{}),
        };
        self.arena_instance = arena_instance;
        self.arena = self.arena_instance.allocator();
        self.gpa = gpa;
        self.io = io;
        self.init_instance = .{};
        self.init_task = self.init_instance.task();
        self.init_task.init(self.arena_instance, self.gpa, self.io);
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

    fn addTask(self: *@This(), key: []const u8, task_ptr: *Task, dependencies: []const []const u8) void {
        std.debug.assert(!task_ptr.is_place_holder);
        if (self.tasks.get(key)) |task| {
            if (!task.is_place_holder) {
                task_ptr.deinit();
                exit.expectedly(error.DuplicatedTaskId, "Duplicated task id", .{ .task = key });
            }
            task.ptr = task_ptr.ptr;
            task.vtable = task_ptr.vtable;
            task.is_place_holder = false;
            self.gpa.destroy(task_ptr);
        } else {
            task_ptr.init(self.arena_instance, self.gpa, self.io);
            self.init_task.dependOn(task_ptr);
            const duped = self.gpa.dupe(u8, key) catch |err| switch (err) {
                error.OutOfMemory => exit.unexpectedly(err, "Occured when duping the task id", .{ .task = key }),
            };
            self.tasks.put(duped, task_ptr) catch |err| switch (err) {
                error.OutOfMemory => exit.unexpectedly(err, "Occured when putting the task", .{ .task = key }),
            };
        }
        for (dependencies) |dep_key| {
            if (!self.tasks.contains(dep_key)) {
                const instance = self.arena.create(PlaceHolderTask) catch |err| switch (err) {
                    error.OutOfMemory => exit.unexpectedly(err, "Occured when creating place holder task", .{
                        .task = key,
                        .dependency = dep_key,
                    }),
                };
                const place_holder_ptr = self.gpa.create(Task) catch |err| switch (err) {
                    error.OutOfMemory => exit.unexpectedly(err, "Occured when creating place holder task interface", .{
                        .task = key,
                        .dependency = dep_key,
                    }),
                };
                const duped = self.gpa.dupe(u8, dep_key) catch |err| switch (err) {
                    error.OutOfMemory => exit.unexpectedly(err, "Occured when duping the dependency task id", .{
                        .task = key,
                        .dependency = dep_key,
                    }),
                };
                place_holder_ptr.* = instance.task(duped);
                place_holder_ptr.init(self.arena_instance, self.gpa, self.io);
                self.init_task.dependOn(place_holder_ptr);
                self.tasks.put(duped, place_holder_ptr) catch |err| switch (err) {
                    error.OutOfMemory => exit.unexpectedly(err, "Occured when putting the place holder task dependency \"{s}\" for the task \"{s}\"", .{
                        .task = key,
                        .dependency = dep_key,
                    }),
                };
            }
            self.tasks.get(key).?.dependOn(self.tasks.get(dep_key).?);
        }
    }

    pub fn addJSONQueryTask(self: *@This(), key: []const u8, filter: []const u8, dependencies: []const []const u8) void {
        const instance = self.arena.create(JSONQueryTask) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when creating JSON query task", .{ .task = key }),
        };
        const task_ptr = self.gpa.create(Task) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when creating JSON query task interface", .{ .task = key }),
        };
        task_ptr.* = instance.task(self.gpa, filter, &self.tasks) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when duping JSON query filter", .{ .task = key }),
        };
        self.addTask(key, task_ptr, dependencies);
    }

    pub fn addRequestTask(self: *@This(), key: []const u8, input: c.jv, dependencies: []const []const u8) void {
        const instance = self.arena.create(RequestTask) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when creating Request task: \"{s}\"", .{ .task = key }),
        };
        const task_ptr = self.gpa.create(Task) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when creating Request task interface: \"{s}\"", .{ .task = key }),
        };
        task_ptr.* = instance.task(input);
        self.addTask(key, task_ptr, dependencies);
    }

    pub fn run(self: *@This()) void {
        if (!self.init_task.isAcyclic()) exit.expectedly(error.DependencyLoopDetected, "Dependency loop detected between tasks", .{});

        self.group = .init;
        defer self.group.cancel(self.io);

        self.init_task.spawn(&self.group);
        self.group.await(self.io) catch |err| {
            self.group.cancel(self.io);
            switch (err) {
                error.Canceled => exit.unexpectedly(err, "Occured while group awaits", .{}),
            }
        };
    }
};
