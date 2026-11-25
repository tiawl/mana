const std = @import("std");
const zlua = @import("zlua");
const jl = @import("jl");
const log = @import("log");
const client = @import("client").Client(log.Logger);
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

pub fn newJSONQueryTask(id: []const u8, filter: []const u8) void {
    singleton.newJSONQueryTask(id, filter);
}

pub fn newRequestTask(id: []const u8, input: c.jv) void {
    singleton.newRequestTask(id, input);
}

pub fn newCustomTask(id: []const u8, thread: *zlua.Lua, func_ref: i32, build_data_ref: i32) void {
    singleton.newCustomTask(id, thread, func_ref, build_data_ref);
}

pub fn run() void {
    singleton.run();
}

const CustomTask = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    id: [:0]const u8,
    thread: *zlua.Lua,
    func_ref: i32,
    build_data_ref: i32,
    tasks: *const std.StringHashMap(*Task),
    output: std.json.Value,

    pub fn task(self: *@This(), arena: std.mem.Allocator, gpa: std.mem.Allocator, id: []const u8, thread: *zlua.Lua, func_ref: i32, build_data_ref: i32, tasks: *const std.StringHashMap(*Task)) std.mem.Allocator.Error!Task {
        self.arena = arena;
        self.gpa = gpa;
        self.thread = thread;
        self.thread.openLibs();
        self.id = try self.gpa.dupeSentinel(u8, id, 0);
        errdefer self.gpa.free(self.id);
        self.func_ref = func_ref;
        self.build_data_ref = build_data_ref;
        self.tasks = tasks;
        self.output = .{ .null = {} };
        return .implement(@This(), self);
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.gpa.free(self.id);
        jl.free(self.gpa, &self.output);
    }

    pub fn run(ptr: *anyopaque) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));

        const RETURNED_VALUE = -1;
        const RUN_INSTANCE_NPOS = -2;

        _ = self.thread.getIndexRaw(zlua.registry_index, self.func_ref);

        self.thread.newTable();
        _ = self.thread.getGlobal("run");
        self.thread.setMetatable(RUN_INSTANCE_NPOS);

        self.thread.newTable();
        const table = self.thread.getTop();
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.finished.load(.acquire)) {
                if (entry.value_ptr.*.getOutput()) |output| {
                    _ = self.thread.pushString(entry.key_ptr.*);
                    jl.luaFromJson(self.thread, output) catch |err| log.fatal(err, "Occured when converting Json to Lua value", .{ .task = self.id });
                    self.thread.setTable(table);
                }
            }
        }

        if (self.build_data_ref != zlua.ref_nil) {
            _ = self.thread.getIndexRaw(zlua.registry_index, self.build_data_ref);
        } else self.thread.pushNil();

        const MSG_NPOS = -1;
        const MSG_LEN = 1;
        const status, _ = self.thread.resumeThread(null, 3) catch |err| {
            const msg = if (self.thread.getTop() > 0) self.thread.toString(MSG_NPOS) catch "Unknown error" else "Unknown error";
            defer self.thread.pop(MSG_LEN);

            switch (err) {
                error.LuaRuntime => log.err(error.RunContextLuaResumeThread, "Occured when running custom task", .{ .msg = msg, .task = self.id, .err = @errorName(err) }),
                else => log.fatal(err, "Occured when running custom task", .{ .msg = msg, .task = self.id }),
            }
        };
        if (status != .ok) log.fatal(error.RunContextYield, "The thread running the custom task yields", .{ .task = self.id });

        self.output = jl.jsonFromLua(self.thread, RETURNED_VALUE) catch |err| switch (err) {
            error.UnsupportedLuaType => log.err(error.RunContextUnsupportedLuaType, "Occured when reading and converting to Json the returned value from function used by custom stask from Lua thread stack", .{ .task = self.id }),
            error.UnsupportedLuaKeyType => log.err(error.RunContextUnsupportedLuaKeyType, "Occured when reading and converting to Json the returned value from function used by custom stask from Lua thread stack", .{ .task = self.id }),
            else => log.fatal(err, "Occured when reading and converting to Json the returned value from function used by custom stask from Lua thread stack", .{ .task = self.id }),
        };

        self.thread.pop(1);
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const std.json.Value {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
    }
};

const JSONQueryTask = struct {
    gpa: std.mem.Allocator,
    id: []const u8,
    filter: []const u8,
    inputs: *const std.StringHashMap(*Task),
    output: std.json.Value,

    pub fn task(self: *@This(), gpa: std.mem.Allocator, id: []const u8, filter: []const u8, inputs: *const std.StringHashMap(*Task)) std.mem.Allocator.Error!Task {
        self.gpa = gpa;
        self.id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(self.id);
        self.filter = try self.gpa.dupe(u8, filter);
        errdefer self.gpa.free(self.filter);
        self.inputs = inputs;
        self.output = .{ .null = {} };
        return .implement(@This(), self);
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.gpa.free(self.id);
        self.gpa.free(self.filter);
        if (std.meta.activeTag(self.output) == .array) self.output.array.deinit();
    }

    pub fn run(ptr: *anyopaque) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));

        var inputs: std.json.Value = .{ .object = .empty };
        defer inputs.object.deinit(self.gpa);

        var it = self.inputs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.finished.load(.acquire)) {
                if (entry.value_ptr.*.getOutput()) |output| {
                    inputs.object.put(self.gpa, entry.key_ptr.*, output.*) catch |err| log.fatal(err, "Occured when putting new value to produce a JSON query", .{ .task = self.id });
                }
            }
        }

        self.output = client.jsonQuery(self.filter, &inputs) catch |err| switch (err) {
            error.IncorrectJqFilter => log.err(err, "The provided jq filter is incorrect", .{ .task = self.id }),
            error.JqHalted, error.JqInvalidMsg => log.err(err, "A jq error occured", .{ .task = self.id }),
            error.UnexpectedInputJsonKind => unreachable,
            else => log.fatal(err, "Occured when trying to produce a JSON query", .{ .task = self.id }),
        };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const std.json.Value {
        const self: *const @This() = @ptrCast(@alignCast(ptr));
        return &self.output;
    }
};

const RequestTask = struct {
    gpa: std.mem.Allocator,
    id: []const u8,
    input: c.jv,
    output: std.json.Value,

    pub fn task(self: *@This(), gpa: std.mem.Allocator, id: []const u8, input: c.jv) std.mem.Allocator.Error!Task {
        self.gpa = gpa;
        self.id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(self.id);
        self.input = input;
        self.output = .{ .null = {} };
        return .implement(@This(), self);
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        c.jv_free(self.input);
        self.gpa.free(self.id);
        if (std.meta.activeTag(self.output) == .array) self.output.array.deinit();
    }

    pub fn run(ptr: *anyopaque) void {
        var self: *@This() = @ptrCast(@alignCast(ptr));
        self.output = client.sendRequestValue(self.input) catch |err| switch (err) {
            error.UnexpectedInputJsonKind, error.UnexpectedVersionJsonKind, error.UnexpectedEndpointJsonKind, error.UnexpectedMethodJsonKind, error.MissingVersion, error.MissingEndpoint, error.MissingMethod, error.UnexpectedCtxJsonKind, error.MissingCtx, error.MissingT, error.UnexpectedTJsonKind, error.UnexpectedParametersJsonKind, error.UnknownHttpMethod, error.UnknownDockerApiVersion, error.CtxIsNotDir => log.err(err, "Occured when trying to send a request", .{ .task = self.id }),
            else => log.fatal(err, "Occured when trying to send a request", .{ .task = self.id }),
        };
    }

    pub fn getOutput(ptr: *const anyopaque) ?*const std.json.Value {
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

    pub fn getOutput(ptr: *const anyopaque) ?*const std.json.Value {
        _ = ptr;
        return null;
    }
};

const Task = struct {
    const VTable = struct {
        deinit_fn: *const fn (*anyopaque) void,
        run_fn: *const fn (*anyopaque) void,
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
    spawned: bool,
    mutex: std.Io.Mutex,
    finished: std.atomic.Value(bool),

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
            .finished = undefined,
        };
    }

    pub fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io) void {
        self.arena = arena;
        self.gpa = gpa;
        self.io = io;
        self.spawned = false;
        self.mutex = .init;
        self.finished = .init(false);
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

    pub fn getOutput(self: *const @This()) ?*const std.json.Value {
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
        self.finished.store(true, .release);

        for (self.parents.items) |parent| {
            if (parent.pending.fetchSub(1, .acq_rel) == 1) parent.ready.set(self.io);
        }
    }
};

// Manage, build and run tasks, orchestrate dependencies and operations
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
        client.init(arena_instance, gpa, io, environ) catch |err| switch (err) {
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
        client.deinit();
    }

    fn taskDependsOn(self: *@This(), child_id: []const u8, parent_id: []const u8) void {
        if (!self.tasks.contains(child_id)) log.err(error.UndefinedChildTaskId, "Undefined child task id", .{});
        if (!self.tasks.contains(parent_id)) log.err(error.UndefinedParentTaskId, "Undefined parent task id", .{});
        self.tasks.get(child_id).?.dependsOn(self.tasks.get(parent_id).?);
    }

    fn addTask(self: *@This(), id: []const u8, task_ptr: *Task) void {
        if (self.tasks.contains(id)) {
            task_ptr.deinit();
            log.err(error.DuplicatedTaskId, "Duplicated task id", .{ .task = id });
        }
        task_ptr.init(self.arena_instance, self.gpa, self.io);
        self.init_task.dependsOn(task_ptr);
        const duped = self.gpa.dupe(u8, id) catch |err| log.fatal(err, "Occured when duping the task id", .{ .task = id });
        self.tasks.put(duped, task_ptr) catch |err| log.fatal(err, "Occured when adding the task", .{ .task = id });
    }

    pub fn newJSONQueryTask(self: *@This(), id: []const u8, filter: []const u8) void {
        const instance = self.arena.create(JSONQueryTask) catch |err| log.fatal(err, "Occured when creating JSON query task", .{ .task = id });
        const task_ptr = self.gpa.create(Task) catch |err| log.fatal(err, "Occured when creating JSON query task interface", .{ .task = id });
        task_ptr.* = instance.task(self.gpa, id, filter, &self.tasks) catch |err| log.fatal(err, "Occured when implementing JSON query task", .{ .task = id });
        self.addTask(id, task_ptr);
    }

    pub fn newRequestTask(self: *@This(), id: []const u8, input: c.jv) void {
        const instance = self.arena.create(RequestTask) catch |err| log.fatal(err, "Occured when creating Request task: \"{s}\"", .{ .task = id });
        const task_ptr = self.gpa.create(Task) catch |err| log.fatal(err, "Occured when creating Request task interface: \"{s}\"", .{ .task = id });
        task_ptr.* = instance.task(self.gpa, id, input) catch |err| log.fatal(err, "Occured when implementing Request task", .{ .task = id });
        self.addTask(id, task_ptr);
    }

    pub fn newCustomTask(self: *@This(), id: []const u8, thread: *zlua.Lua, func_ref: i32, build_data_ref: i32) void {
        const instance = self.arena.create(CustomTask) catch |err| log.fatal(err, "Occured when creating Custom task: \"{s}\"", .{ .task = id });
        const task_ptr = self.gpa.create(Task) catch |err| log.fatal(err, "Occured when creating Custom task interface: \"{s}\"", .{ .task = id });
        task_ptr.* = instance.task(self.arena, self.gpa, id, thread, func_ref, build_data_ref, &self.tasks) catch |err| log.fatal(err, "Occured when implementing Custom task", .{ .task = id });
        self.addTask(id, task_ptr);
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
