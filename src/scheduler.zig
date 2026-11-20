const std = @import("std");
const log = @import("log");
const sync = @import("sync").Sync(log.Logger);
const c = @import("jq");

var singleton: Scheduler = undefined;

pub fn init(arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
    singleton.init(arena, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn taskDependsOn(child_id: []const u8, parent_id: []const u8) void {
    singleton.taskDependsOn(child_id, parent_id);
}

pub fn newJSONQueryTask(key: []const u8, filter: []const u8) void {
    singleton.newJSONQueryTask(key, filter);
}

pub fn newRequestTask(key: []const u8, input: c.jv) void {
    singleton.newRequestTask(key, input);
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
        self.output = sync.jsonQuery(self.filter, inputs) catch |err| switch (err) {
            error.OutOfMemory => log.fatal(err, "Occured when trying to produce a JSON query", .{}),
            error.IncorrectJqFilter => log.err(err, "The provided jq filter is incorrect", .{}),
            error.JqHalted, error.JqInvalidMsg => log.err(err, "A jq error occured", .{}),
            error.UnexpectedInputJsonKind => unreachable,
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
        c.jv_free(self.input);
        c.jv_free(self.output);
    }

    pub fn run(ptr: *anyopaque) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        c.jv_free(self.output);
        self.output = sync.sendRequestValue(self.input) catch |err| switch (err) {
            error.UnexpectedInputJsonKind, error.UnexpectedVersionJsonKind, error.UnexpectedEndpointJsonKind, error.UnexpectedMethodJsonKind, error.MissingVersion, error.MissingEndpoint, error.MissingMethod, error.UnexpectedCtxJsonKind, error.MissingCtx, error.MissingT, error.UnexpectedTJsonKind, error.UnexpectedParametersJsonKind, error.UnknownHttpMethod, error.UnknownDockerApiVersion, error.CtxIsNotDir => log.err(err, "Occured when trying to send a request", .{}),
            else => log.fatal(err, "Occured when trying to send a request", .{}),
        };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const c.jv {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
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

    pub fn dependsOn(self: *@This(), child: *@This()) void {
        self.children.append(self.gpa, child) catch |err| log.fatal(err, "Occured when appending child dependency", .{});
        child.parents.append(self.gpa, self) catch |err| log.fatal(err, "Occured when appending parent dependency", .{});
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

        visited.put(self, {}) catch |err| log.fatal(err, "Occured memory when trying to add a new key into visited HashMap to determine if dependency graph is acyclic", .{});
        on_path.put(self, {}) catch |err| log.fatal(err, "Occured when trying to add a new key into on_path HashMap to determine if dependency graph is acyclic", .{});

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
                error.Canceled => log.fatal(err, "Occured while mutex was locked", .{}),
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
                error.Canceled => log.fatal(err, "Occured while event waits", .{}),
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
        sync.init(arena_instance, gpa, io, environ) catch |err| switch (err) {
            error.JqInit, error.JqUtilInputInit => log.fatal(err, "Occured when initializing jq. This is certainly a memory allocation failure", .{}),
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
        sync.deinit();
    }

    fn taskDependsOn(self: *@This(), child_id: []const u8, parent_id: []const u8) void {
        if (!self.tasks.contains(child_id)) log.err(error.UndefinedChildTaskId, "Undefined child task id", .{});
        if (!self.tasks.contains(parent_id)) log.err(error.UndefinedParentTaskId, "Undefined parent task id", .{});
        self.tasks.get(child_id).?.dependsOn(self.tasks.get(parent_id).?);
    }

    fn addTask(self: *@This(), key: []const u8, task_ptr: *Task) void {
        if (self.tasks.contains(key)) {
            task_ptr.deinit();
            log.err(error.DuplicatedTaskId, "Duplicated task id", .{ .task = key });
        }
        task_ptr.init(self.arena_instance, self.gpa, self.io);
        self.init_task.dependsOn(task_ptr);
        const duped = self.gpa.dupe(u8, key) catch |err| log.fatal(err, "Occured when duping the task id", .{ .task = key });
        self.tasks.put(duped, task_ptr) catch |err| log.fatal(err, "Occured when adding the task", .{ .task = key });
    }

    pub fn newJSONQueryTask(self: *@This(), key: []const u8, filter: []const u8) void {
        const instance = self.arena.create(JSONQueryTask) catch |err| log.fatal(err, "Occured when creating JSON query task", .{ .task = key });
        const task_ptr = self.gpa.create(Task) catch |err| log.fatal(err, "Occured when creating JSON query task interface", .{ .task = key });
        task_ptr.* = instance.task(self.gpa, filter, &self.tasks) catch |err| log.fatal(err, "Occured when duping JSON query filter", .{ .task = key });
        self.addTask(key, task_ptr);
    }

    pub fn newRequestTask(self: *@This(), key: []const u8, input: c.jv) void {
        const instance = self.arena.create(RequestTask) catch |err| log.fatal(err, "Occured when creating Request task: \"{s}\"", .{ .task = key });
        const task_ptr = self.gpa.create(Task) catch |err| log.fatal(err, "Occured when creating Request task interface: \"{s}\"", .{ .task = key });
        task_ptr.* = instance.task(input);
        self.addTask(key, task_ptr);
    }

    pub fn run(self: *@This()) void {
        if (!self.init_task.isAcyclic()) log.err(error.DependencyLoopDetected, "Dependency loop detected between tasks", .{});

        self.group = .init;
        defer self.group.cancel(self.io);

        self.init_task.spawn(&self.group);
        self.group.await(self.io) catch |err| {
            self.group.cancel(self.io);
            switch (err) {
                error.Canceled => log.fatal(err, "Occured while group awaits", .{}),
            }
        };
    }
};
