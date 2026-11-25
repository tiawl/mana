const std = @import("std");
const zlua = @import("zlua");
const jl = @import("jl");
const log = @import("log");
const client = @import("client").Client(log.Logger);
const scheduler = @import("scheduler");
const build_options = @import("build");
const c = @import("jq");

const user_config_path = build_options.name ++ ".lua";

var singleton: Script = undefined;

pub fn init(arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
    singleton.init(arena_instance, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn build(rule: [:0]const u8, args: []const []const u8) void {
    singleton.build(rule, args);
}

pub fn run() void {
    singleton.run();
}

const lua = struct {
    const ffi = @import("ffi");

    fn buildWrongContext(vm: *zlua.Lua) i32 {
        return singleton.buildWrongContext(vm);
    }

    fn runWrongContext(vm: *zlua.Lua) i32 {
        return singleton.runWrongContext(vm);
    }

    fn docker(vm: *zlua.Lua) i32 {
        return singleton.docker(vm);
    }

    fn dockerBuild(vm: *zlua.Lua) i32 {
        return singleton.dockerBuild(vm);
    }

    fn jsonQuery(vm: *zlua.Lua) i32 {
        return singleton.jsonQuery(vm);
    }

    fn taskDependsOn(vm: *zlua.Lua) i32 {
        return singleton.taskDependsOn(vm);
    }

    fn newDockerTask(vm: *zlua.Lua) i32 {
        return singleton.newDockerTask(vm);
    }

    fn newDockerBuildTask(vm: *zlua.Lua) i32 {
        return singleton.newDockerBuildTask(vm);
    }

    fn newCustomTask(vm: *zlua.Lua) i32 {
        return singleton.newCustomTask(vm);
    }

    fn newJSONQueryTask(vm: *zlua.Lua) i32 {
        return singleton.newJSONQueryTask(vm);
    }

    fn newMutex(vm: *zlua.Lua) i32 {
        return singleton.newMutex(vm);
    }

    fn lockMutex(vm: *zlua.Lua) i32 {
        return singleton.lockMutex(vm);
    }

    fn unlockMutex(vm: *zlua.Lua) i32 {
        return singleton.unlockMutex(vm);
    }
};

// Drive the scheduler depending of user configuration
const Script = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    vm: *zlua.Lua,
    refs: std.ArrayList(i32),
    mutexes: std.StringHashMap(std.Io.Mutex),

    pub fn init(self: *@This(), arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
        scheduler.init(arena_instance, gpa, io, environ);
        lua.ffi.init(arena_instance, gpa, io, environ);
        self.arena = arena_instance;
        self.gpa = gpa;
        self.io = io;
        self.vm = zlua.Lua.init(gpa) catch |err| log.fatal(err, "Occured when initializing main Lua VM", .{});
        self.vm.openLibs();
        self.refs = .empty;
        self.mutexes = .init(self.gpa);
    }

    pub fn deinit(self: *@This()) void {
        if (user_config_script.len > 0) self.gpa.free(user_config_script);
        for (0..self.refs.items.len) |i| self.vm.unref(zlua.registry_index, self.refs.items[i]);
        self.refs.deinit(self.gpa);
        var it = self.mutexes.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.mutexes.deinit();
        self.vm.deinit();
        lua.ffi.deinit();
        scheduler.deinit();
    }

    var user_config_script: [:0]const u8 = "";

    pub fn build(self: @This(), rule: [:0]const u8, args: []const []const u8) void {
        if (rule.len == 0) log.err(error.EmptyRule, "Empty rule", .{});

        const cwd = std.Io.Dir.cwd();
        if (user_config_script.len > 0) self.gpa.free(user_config_script);
        user_config_script = cwd.readFileAllocOptions(self.io, user_config_path, self.gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
            error.AccessDenied => log.err(error.ScriptAccessDenied, "Not allowed to read " ++ user_config_path, .{}),
            error.IsDir => log.err(error.ScriptIsDir, user_config_path ++ " should be a file", .{}),
            error.FileNotFound => log.err(error.ScriptMissing, "Did not found " ++ user_config_path, .{}),
            error.SymLinkLoop => log.err(error.ScriptSymLinkLoop, user_config_path ++ " is a loop symlink", .{}),
            else => log.fatal(err, "Occured when reading " ++ user_config_path, .{}),
        };
        errdefer self.gpa.free(user_config_script);

        const call_script = self.gpa.print(
            \\builder:{s}()
        , .{rule}) catch |err| log.fatal(err, "Occured when formatting calling script", .{});
        defer self.gpa.free(call_script);

        self.vm.pushAny(args) catch |err| log.fatal(err, "Occured when pushing args to main Lua VM stack", .{});
        self.vm.setGlobal("argv");
        jl.setJsonGlobals(self.vm);

        self.vm.pushFunction(zlua.wrap(lua.buildWrongContext));
        self.vm.setGlobal("docker");
        self.vm.pushFunction(zlua.wrap(lua.buildWrongContext));
        self.vm.setGlobal("dockerBuild");
        self.vm.pushFunction(zlua.wrap(lua.buildWrongContext));
        self.vm.setGlobal("jsonQuery");
        self.vm.pushFunction(zlua.wrap(lua.buildWrongContext));
        self.vm.setGlobal("lockMutex");
        self.vm.pushFunction(zlua.wrap(lua.buildWrongContext));
        self.vm.setGlobal("unlockMutex");

        self.vm.pushFunction(zlua.wrap(lua.taskDependsOn));
        self.vm.setGlobal("taskDependsOn");
        self.vm.pushFunction(zlua.wrap(lua.newDockerTask));
        self.vm.setGlobal("newDockerTask");
        self.vm.pushFunction(zlua.wrap(lua.newDockerBuildTask));
        self.vm.setGlobal("newDockerBuildTask");
        self.vm.pushFunction(zlua.wrap(lua.newCustomTask));
        self.vm.setGlobal("newCustomTask");
        self.vm.pushFunction(zlua.wrap(lua.newJSONQueryTask));
        self.vm.setGlobal("newJsonQueryTask");
        self.vm.pushFunction(zlua.wrap(lua.newMutex));
        self.vm.setGlobal("newMutex");

        const TOP_OF_STACK = -1;
        const BUILDTABLE_NPOS = -2;
        const RUNTABLE_NPOS = -2;
        const BUILD_INSTANCE_NPOS = -2;
        const BUILD_INSTANCE_LEN = 1;

        lua.ffi.setBuildGlobals(self.vm);

        self.vm.newTable();
        self.vm.pushValue(TOP_OF_STACK);
        self.vm.setField(BUILDTABLE_NPOS, "__index");
        self.vm.setGlobal("build");

        self.vm.newTable();
        self.vm.pushValue(TOP_OF_STACK);
        self.vm.setField(RUNTABLE_NPOS, "__index");
        self.vm.setGlobal("run");

        self.vm.newTable();
        _ = self.vm.getGlobal("argv");
        self.vm.setField(BUILD_INSTANCE_NPOS, "argv");
        _ = self.vm.getGlobal("build");
        self.vm.setMetatable(BUILD_INSTANCE_NPOS);

        const MSG_NPOS = -1;
        const MSG_LEN = 1;
        self.vm.doString(user_config_script) catch |err| {
            const msg = if (self.vm.getTop() > 0) self.vm.toString(MSG_NPOS) catch "Unknown error" else "Unknown error";
            var lines: std.ArrayList([]const u8) = .empty;
            var raw = false;
            defer lines.deinit();
            defer self.vm.pop(MSG_LEN);
            var i: u32 = 1;
            var it = std.mem.splitScalar(u8, std.mem.trim(u8, user_config_script, "\n"), '\n');
            while (it.next()) |line| {
                lines.append(self.gpa, self.gpa.print("{d: <3}| {s}", .{ i, line }) catch {
                    raw = true;
                    break;
                }) catch {
                    raw = true;
                    break;
                };
                i += 1;
            }

            switch (err) {
                error.LuaSyntax, error.LuaRuntime => if (raw) {
                    log.err(error.BuildContextLuaDoString, "Occured when running the build script", .{ .script = user_config_script, .msg = msg, .err = @errorName(err) });
                } else log.err(error.BuildContextLuaDoString, "Occured when running the build script", .{ .script = lines.items, .msg = msg, .err = @errorName(err) }),
                else => if (raw) {
                    log.fatal(err, "Occured when running the build script", .{ .script = user_config_script, .msg = msg });
                } else log.fatal(err, "Occured when running the build script", .{ .script = lines.items, .msg = msg }),
            }
        };

        _ = self.vm.getGlobal("build");
        if (self.vm.getField(TOP_OF_STACK, rule) != .function) {
            log.err(error.UnknownRule, "Can't find a lua function into the build context with this name", .{ .rule = rule });
        }
        self.vm.remove(BUILDTABLE_NPOS);
        self.vm.pushValue(BUILD_INSTANCE_NPOS);
        self.vm.call(.{ .args = 1, .results = 0 });
        self.vm.pop(BUILD_INSTANCE_LEN);
    }

    pub fn run(self: @This()) void {
        self.vm.pushFunction(zlua.wrap(lua.runWrongContext));
        self.vm.setGlobal("taskDependsOn");
        self.vm.pushFunction(zlua.wrap(lua.runWrongContext));
        self.vm.setGlobal("newDockerTask");
        self.vm.pushFunction(zlua.wrap(lua.runWrongContext));
        self.vm.setGlobal("newDockerBuildTask");
        self.vm.pushFunction(zlua.wrap(lua.runWrongContext));
        self.vm.setGlobal("newCustomTask");
        self.vm.pushFunction(zlua.wrap(lua.runWrongContext));
        self.vm.setGlobal("newJsonQueryTask");
        self.vm.pushFunction(zlua.wrap(lua.runWrongContext));
        self.vm.setGlobal("newMutex");

        self.vm.pushFunction(zlua.wrap(lua.docker));
        self.vm.setGlobal("docker");
        self.vm.pushFunction(zlua.wrap(lua.dockerBuild));
        self.vm.setGlobal("dockerBuild");
        self.vm.pushFunction(zlua.wrap(lua.jsonQuery));
        self.vm.setGlobal("jsonQuery");
        self.vm.pushFunction(zlua.wrap(lua.lockMutex));
        self.vm.setGlobal("lockMutex");
        self.vm.pushFunction(zlua.wrap(lua.unlockMutex));
        self.vm.setGlobal("unlockMutex");

        scheduler.run();
    }

    pub fn buildWrongContext(self: *@This(), vm: *zlua.Lua) i32 {
        _ = .{ self, vm };
        log.err(error.BuildContextWrongContext, "You can't run this function in the build context", .{});
        return 0;
    }

    pub fn runWrongContext(self: *@This(), vm: *zlua.Lua) i32 {
        _ = .{ self, vm };
        log.err(error.RunContextWrongContext, "You can't run this function in the run context", .{});
        return 0;
    }

    pub fn docker(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const API_VERSION = 1;
        const ENDPOINT = 2;
        const METHOD = 3;
        const PARAMETERS = 4;
        const gpa = vm.allocator();
        if (vm.typeOf(API_VERSION) != .string) log.err(error.ClientDockerApiVersionExpectedString, "Docker API version argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(API_VERSION) });
        const api_version = vm.toString(API_VERSION) catch |err| log.fatal(err, "Occured when reading Docker API version argument from main Lua VM stack", @src());
        if (vm.typeOf(ENDPOINT) != .string) log.err(error.ClientDockerEndpointExpectedString, "Docker endpoint argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(ENDPOINT) });
        const endpoint = vm.toString(ENDPOINT) catch |err| log.fatal(err, "Occured when reading Docker endpoint argument from main Lua VM stack", @src());
        if (vm.typeOf(METHOD) != .string) log.err(error.ClientDockerHttpMethodExpectedString, "HTTP method argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(METHOD) });
        const method = vm.toString(METHOD) catch |err| log.fatal(err, "Occured when reading HTTP method argument from main Lua VM stack", @src());
        var parameters = jl.jsonFromLua(vm, PARAMETERS) catch |err| switch (err) {
            error.UnsupportedLuaType => log.err(error.ClientDockerParametersUnsupportedLuaType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", @src()),
            error.UnsupportedLuaKeyType => log.err(error.ClientDockerParametersUnsupportedLuaKeyType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", @src()),
            else => log.fatal(err, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", @src()),
        };
        defer jl.free(gpa, &parameters);
        if (std.meta.activeTag(parameters) != .object) log.err(error.ClientDockerParametersUnexpectedJsonKind, "Parameters argument must be an object json kind", .{ .json_kind = std.meta.activeTag(parameters), .src = @src() });
        const source = gpa.printSentinel("{f}", .{std.json.fmt(.{
            .docker = .{
                .version = api_version,
                .endpoint = endpoint,
                .method = method,
                .parameters = parameters,
            },
        }, .{})}, 0) catch |err| log.fatal(err, "Occured when allocating for string", @src());
        defer gpa.free(source);
        const parsed = c.jv_parse(source);
        if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.fatal(error.ClientDockerUnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .src = @src(), .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
        const output = client.sendRequestValue(parsed) catch |err| log.fatal(err, "Occured when trying to send a request", @src());
        defer output.array.deinit();
        jl.luaFromJson(vm, &output) catch |err| log.fatal(err, "Occured when converting output from Json to Lua value", @src());

        return 1;
    }

    pub fn dockerBuild(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const API_VERSION = 1;
        const CONTEXT = 2;
        const TAG = 3;
        const PARAMETERS = 4;
        const gpa = vm.allocator();
        if (vm.typeOf(API_VERSION) != .string) log.err(error.ClientDockerBuildApiVersionExpectedString, "Docker API version argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(API_VERSION) });
        const api_version = vm.toString(API_VERSION) catch |err| log.fatal(err, "Occured when reading Docker API version argument from main Lua VM stack", @src());
        if (vm.typeOf(CONTEXT) != .string) log.err(error.ClientDockerBuildContextExpectedString, "Docker context argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(CONTEXT) });
        const context = vm.toString(CONTEXT) catch |err| log.fatal(err, "Occured when reading Docker context argument from main Lua VM stack", @src());
        if (vm.typeOf(TAG) != .string) log.err(error.ClientDockerBuildTagExpectedString, "Tag argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(TAG) });
        const tag = vm.toString(TAG) catch |err| log.fatal(err, "Occured when reading tag argument from main Lua VM stack", @src());
        var parameters = jl.jsonFromLua(vm, PARAMETERS) catch |err| switch (err) {
            error.UnsupportedLuaType => log.err(error.ClientDockerBuildParametersUnsupportedLuaType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", @src()),
            error.UnsupportedLuaKeyType => log.err(error.ClientDockerBuildParametersUnsupportedLuaKeyType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", @src()),
            else => log.fatal(err, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", @src()),
        };
        defer jl.free(gpa, &parameters);
        if (std.meta.activeTag(parameters) != .object) log.err(error.ClientDockerBuildParametersUnexpectedJsonKind, "Parameters argument must be an object json kind", .{ .json_kind = std.meta.activeTag(parameters), .src = @src() });
        const source = gpa.printSentinel("{f}", .{std.json.fmt(.{
            .docker_build = .{
                .version = api_version,
                .ctx = context,
                .t = tag,
                .parameters = parameters,
            },
        }, .{})}, 0) catch |err| log.fatal(err, "Occured when allocating for string", @src());
        defer gpa.free(source);
        const parsed = c.jv_parse(source);
        if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.fatal(error.ClientDockerBuildUnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .src = @src(), .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
        const output = client.sendRequestValue(parsed) catch |err| log.fatal(err, "Occured when trying to send a request", @src());
        defer output.array.deinit();
        jl.luaFromJson(vm, &output) catch |err| log.fatal(err, "Occured when converting output from Json to Lua value", @src());
        return 1;
    }

    pub fn jsonQuery(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const FILTER = 1;
        const INPUT = 2;
        const gpa = vm.allocator();
        if (vm.typeOf(FILTER) != .string) log.err(error.ClientJsonQueryFilterExpectedString, "Filter argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(FILTER) });
        const filter = vm.toString(FILTER) catch |err| log.fatal(err, "Occured when reading filter argument from main Lua VM stack", @src());
        var input = jl.jsonFromLua(vm, INPUT) catch |err| switch (err) {
            error.UnsupportedLuaType => log.err(error.ClientJsonQueryInputUnsupportedLuaType, "Occured when reading and converting to Json the input argument from main Lua VM stack", @src()),
            error.UnsupportedLuaKeyType => log.err(error.ClientJsonQueryInputUnsupportedLuaKeyType, "Occured when reading and converting to Json the input argument from main Lua VM stack", @src()),
            else => log.fatal(err, "Occured when reading and converting to Json the input argument from main Lua VM stack", @src()),
        };
        defer jl.free(gpa, &input);
        const output = client.jsonQuery(filter, &input) catch |err| switch (err) {
            error.IncorrectJqFilter => log.err(err, "The provided jq filter is incorrect", @src()),
            error.JqHalted, error.JqInvalidMsg => log.err(err, "A jq error occured", @src()),
            error.UnexpectedInputJsonKind => unreachable,
            else => log.fatal(err, "Occured when trying to produce a JSON query", @src()),
        };
        defer output.array.deinit();
        jl.luaFromJson(vm, &output) catch |err| log.fatal(err, "Occured when converting output from Json to Lua value", @src());
        return 1;
    }

    pub fn taskDependsOn(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const CHILD_ID = 1;
        const PARENT_ID = 2;
        if (vm.typeOf(CHILD_ID) != .string) log.err(error.TaskDependsOnChildIdExpectedString, "Child argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(CHILD_ID) });
        const child_id = vm.toString(CHILD_ID) catch |err| log.fatal(err, "Occured when reading child argument from main Lua VM stack", @src());
        if (vm.typeOf(PARENT_ID) != .string) log.err(error.TaskDependsOnParentIdExpectedString, "Parent argument should be a string from main Lua VM stack", .{ .id = child_id, .lua_type = vm.typeOf(PARENT_ID) });
        const parent_id = vm.toString(PARENT_ID) catch |err| log.fatal(err, "Occured when reading parent argument from main Lua VM stack", .{ .id = child_id });
        scheduler.taskDependsOn(child_id, parent_id);
        return 0;
    }

    pub fn newDockerTask(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const TASK_ID = 1;
        const API_VERSION = 2;
        const ENDPOINT = 3;
        const METHOD = 4;
        const PARAMETERS = 5;
        const gpa = vm.allocator();
        if (vm.typeOf(TASK_ID) != .string) log.err(error.NewDockerTaskTaskIdExpectedString, "Task id argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(TASK_ID) });
        const task_id = vm.toString(TASK_ID) catch |err| log.fatal(err, "Occured when reading task id argument from main Lua VM stack", @src());
        if (vm.typeOf(API_VERSION) != .string) log.err(error.NewDockerTaskApiVersionExpectedString, "Docker API version argument should be a string from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(API_VERSION) });
        const api_version = vm.toString(API_VERSION) catch |err| log.fatal(err, "Occured when reading Docker API version argument from main Lua VM stack", .{ .task = task_id });
        if (vm.typeOf(ENDPOINT) != .string) log.err(error.NewDockerTaskEndpointExpectedString, "Docker endpoint argument should be a string from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(ENDPOINT) });
        const endpoint = vm.toString(ENDPOINT) catch |err| log.fatal(err, "Occured when reading Docker endpoint argument from main Lua VM stack", .{ .task = task_id });
        if (vm.typeOf(METHOD) != .string) log.err(error.NewDockerTaskHttpMethodExpectedString, "HTTP method argument should be a string from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(METHOD) });
        const method = vm.toString(METHOD) catch |err| log.fatal(err, "Occured when reading HTTP method argument from main Lua VM stack", .{ .task = task_id });
        var parameters = jl.jsonFromLua(vm, PARAMETERS) catch |err| switch (err) {
            error.UnsupportedLuaType => log.err(error.NewDockerTaskParametersUnsupportedLuaType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", .{ .task = task_id }),
            error.UnsupportedLuaKeyType => log.err(error.NewDockerTaskParametersUnsupportedLuaKeyType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", .{ .task = task_id }),
            else => log.fatal(err, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", .{ .task = task_id }),
        };
        defer jl.free(gpa, &parameters);
        if (std.meta.activeTag(parameters) != .object) log.err(error.NewDockerTaskParametersUnexpectedJsonKind, "Parameters argument must be an object json kind", .{ .json_kind = std.meta.activeTag(parameters), .task = task_id });
        const source = gpa.printSentinel("{f}", .{std.json.fmt(.{
            .docker = .{
                .version = api_version,
                .endpoint = endpoint,
                .method = method,
                .parameters = parameters,
            },
        }, .{})}, 0) catch |err| log.fatal(err, "Occured when allocating for string", .{ .task = task_id });
        defer gpa.free(source);
        const parsed = c.jv_parse(source);
        if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.fatal(error.NewDockerTaskUnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .task = task_id, .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
        scheduler.newRequestTask(task_id, parsed);
        return 0;
    }

    pub fn newDockerBuildTask(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const TASK_ID = 1;
        const API_VERSION = 2;
        const CONTEXT = 3;
        const TAG = 4;
        const PARAMETERS = 5;
        const gpa = vm.allocator();
        if (vm.typeOf(TASK_ID) != .string) log.err(error.NewDockerBuildTaskTaskIdExpectedString, "Task id argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(TASK_ID) });
        const task_id = vm.toString(TASK_ID) catch |err| log.fatal(err, "Occured when reading task id argument from main Lua VM stack", @src());
        if (vm.typeOf(API_VERSION) != .string) log.err(error.NewDockerBuildTaskApiVersionExpectedString, "Docker API version argument should be a string from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(API_VERSION) });
        const api_version = vm.toString(API_VERSION) catch |err| log.fatal(err, "Occured when reading Docker API version argument from main Lua VM stack", .{ .task = task_id });
        if (vm.typeOf(CONTEXT) != .string) log.err(error.NewDockerBuildTaskContextExpectedString, "Context argument should be a string from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(CONTEXT) });
        const ctx = vm.toString(CONTEXT) catch |err| log.fatal(err, "Occured when reading context argument from main Lua VM stack", .{ .task = task_id });
        if (vm.typeOf(TAG) != .string) log.err(error.NewDockerBuildTaskTagExpectedString, "Tag argument should be a string from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(TAG) });
        const t = vm.toString(TAG) catch |err| log.fatal(err, "Occured when reading tag argument from main Lua VM stack", .{ .task = task_id });
        var parameters = jl.jsonFromLua(vm, PARAMETERS) catch |err| switch (err) {
            error.UnsupportedLuaType => log.err(error.NewDockerBuildTaskParametersUnsupportedLuaType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", .{ .task = task_id }),
            error.UnsupportedLuaKeyType => log.err(error.NewDockerBuildTaskParametersUnsupportedLuaKeyType, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", .{ .task = task_id }),
            else => log.fatal(err, "Occured when reading and converting to Json the parameters argument from main Lua VM stack", .{ .task = task_id }),
        };
        defer jl.free(gpa, &parameters);
        if (std.meta.activeTag(parameters) != .object) log.err(error.NewDockerBuildTaskParametersUnexpectedJsonKind, "Parameters argument must be an object json kind", .{ .json_kind = std.meta.activeTag(parameters), .task = task_id });
        const source = gpa.printSentinel("{f}", .{std.json.fmt(.{
            .docker_build = .{
                .version = api_version,
                .ctx = ctx,
                .t = t,
                .parameters = parameters,
            },
        }, .{})}, 0) catch |err| log.fatal(err, "Occured when allocating for string", .{ .task = task_id });
        defer gpa.free(source);
        const parsed = c.jv_parse(source);
        if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.fatal(error.NewDockerBuildTaskUnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .task = task_id, .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
        scheduler.newRequestTask(task_id, parsed);
        return 0;
    }

    pub fn newCustomTask(self: *@This(), vm: *zlua.Lua) i32 {
        const TASK_ID = 1;
        const LUA_FUNCTION = 2;
        const BUILD_DATA = 3;
        if (vm.typeOf(TASK_ID) != .string) log.err(error.NewCustomTaskTaskIdExpectedString, "Task id argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(TASK_ID) });
        const task_id = vm.toString(TASK_ID) catch |err| log.fatal(err, "Occured when reading task id argument from main Lua VM stack", @src());
        if (vm.typeOf(LUA_FUNCTION) != .function) log.err(error.NewCustomTaskFunctionExpectedFunction, "Second argument should be a function from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(LUA_FUNCTION) });

        vm.pushValue(LUA_FUNCTION);
        const func_ref = vm.ref(zlua.registry_index);
        self.refs.append(self.gpa, func_ref) catch |err| log.fatal(err, "Occured when appending Lua ref into array list", .{ .task = task_id });

        var build_data_ref: i32 = zlua.ref_nil;
        if (vm.getTop() >= BUILD_DATA and vm.typeOf(BUILD_DATA) != .nil) {
            vm.pushValue(BUILD_DATA);
            build_data_ref = vm.ref(zlua.registry_index);
            self.refs.append(self.gpa, build_data_ref) catch |err| log.fatal(err, "Occured when appending Lua ref into array list", .{ .task = task_id });
        }

        scheduler.newCustomTask(task_id, vm.newThread(), func_ref, build_data_ref);
        return 0;
    }

    pub fn newJSONQueryTask(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const TASK_ID = 1;
        const FILTER = 2;
        if (vm.typeOf(TASK_ID) != .string) log.err(error.NewJsonQueryTaskTaskIdExpectedString, "Task id argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(TASK_ID) });
        const task_id = vm.toString(TASK_ID) catch |err| log.fatal(err, "Occured when reading task id argument from main Lua VM stack", @src());
        if (vm.typeOf(FILTER) != .string) log.err(error.NewJsonQueryTaskFilterExpectedString, "Filter argument should be a string from main Lua VM stack", .{ .task = task_id, .lua_type = vm.typeOf(FILTER) });
        const filter = vm.toString(FILTER) catch |err| log.fatal(err, "Occured when reading filter argument from main Lua VM stack", .{ .task = task_id });
        scheduler.newJSONQueryTask(task_id, filter);
        return 0;
    }

    pub fn newMutex(self: *@This(), vm: *zlua.Lua) i32 {
        const MUTEX_ID = 1;
        if (vm.typeOf(MUTEX_ID) != .string) log.err(error.NewMutexMutexIdExpectedString, "Mutex id argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(MUTEX_ID) });
        const mutex_id = vm.toString(MUTEX_ID) catch |err| log.fatal(err, "Occured when reading mutex id argument from main Lua VM stack", @src());
        if (self.mutexes.contains(mutex_id)) log.err(error.NewMutexMutexIdAlreadyExists, "This mutex ID already exists", .{ .mutex = mutex_id });
        const duped = self.gpa.dupe(u8, mutex_id) catch |err| log.fatal(err, "Occured when duping the mutex id", .{ .mutex = mutex_id });
        self.mutexes.put(duped, .init) catch |err| log.fatal(err, "Occured when adding the mutex", .{ .mutex = mutex_id });
        return 0;
    }

    pub fn lockMutex(self: *@This(), vm: *zlua.Lua) i32 {
        const MUTEX_ID = 1;
        if (vm.typeOf(MUTEX_ID) != .string) log.err(error.LockMutexMutexIdExpectedString, "Mutex id argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(MUTEX_ID) });
        const mutex_id = vm.toString(MUTEX_ID) catch |err| log.fatal(err, "Occured when reading mutex id argument from main Lua VM stack", @src());
        const mutex = self.mutexes.getPtr(mutex_id) orelse log.err(error.LockMutexMutexIdUnknown, "Unknown mutex id", .{ .mutex = mutex_id });
        mutex.lock(self.io) catch |err| log.fatal(err, "Occured when trying to lock a mutex", .{ .mutex = mutex_id });
        return 0;
    }

    pub fn unlockMutex(self: *@This(), vm: *zlua.Lua) i32 {
        const MUTEX_ID = 1;
        if (vm.typeOf(MUTEX_ID) != .string) log.err(error.UnlockMutexMutexIdExpectedString, "Mutex id argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(MUTEX_ID) });
        const mutex_id = vm.toString(MUTEX_ID) catch |err| log.fatal(err, "Occured when reading mutex id argument from main Lua VM stack", @src());
        const mutex = self.mutexes.getPtr(mutex_id) orelse log.err(error.UnlockMutexMutexIdUnknown, "Unknown mutex id", .{ .mutex = mutex_id });
        mutex.unlock(self.io);
        return 0;
    }
};
