const std = @import("std");
const zlua = @import("zlua");
const log = @import("log");
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

pub fn build(rule: []const u8, args: []const []const u8) void {
    singleton.build(rule, args);
}

pub fn run() void {
    singleton.run();
}

fn schedulerTaskDependsOn(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "Child argument should be a string in main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const child_id = vm.toString(1) catch |err| log.fatal(err, "Occured when popping child argument in main Lua VM stack", @src());
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Parent argument should be a string in main Lua VM stack", .{ .src = @src(), .id = child_id, .lua_type = vm.typeOf(2) });
    const parent_id = vm.toString(2) catch |err| log.fatal(err, "Occured when popping parent argument in main Lua VM stack", .{ .src = @src(), .id = child_id });
    scheduler.taskDependsOn(child_id, parent_id);
    return 0;
}

fn schedulerNewDockerTask(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "Task id argument should be a string in main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const task_id = vm.toString(1) catch |err| log.fatal(err, "Occured when popping task id argument in main Lua VM stack", @src());
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Docker API version argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(2) });
    const api_version = vm.toString(2) catch |err| log.fatal(err, "Occured when popping Docker API version argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    if (vm.typeOf(3) != .string) log.err(error.ExpectedString, "Docker endpoint argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(3) });
    const endpoint = vm.toString(3) catch |err| log.fatal(err, "Occured when popping Docker endpoint argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    if (vm.typeOf(4) != .string) log.err(error.ExpectedString, "HTTP method argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(4) });
    const method = vm.toString(4) catch |err| log.fatal(err, "Occured when popping HTTP method argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    if (vm.typeOf(5) != .string) log.err(error.ExpectedString, "Parameters argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(5) });
    const parameters = vm.toString(5) catch |err| log.fatal(err, "Occured when popping parameters argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    const gpa = vm.allocator();
    const source = gpa.printSentinel(
        \\{{
        \\    "docker": {{
        \\        "version": "{s}",
        \\        "endpoint": "{s}",
        \\        "method": "{s}",
        \\        "parameters": {s}
        \\    }}
        \\}}
    , .{ api_version, endpoint, method, parameters }, 0) catch |err| log.fatal(err, "Occured when allocating for string", .{ .src = @src(), .id = task_id });
    defer gpa.free(source);
    const parsed = c.jv_parse(source);
    if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.err(error.UnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .src = @src(), .id = task_id, .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
    scheduler.newRequestTask(task_id, parsed);
    return 0;
}

fn schedulerNewDockerBuildTask(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "Task id argument should be a string in main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const task_id = vm.toString(1) catch |err| log.fatal(err, "Occured when popping task id argument in main Lua VM stack", @src());
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Docker API version argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(2) });
    const api_version = vm.toString(2) catch |err| log.fatal(err, "Occured when popping Docker API version argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    if (vm.typeOf(3) != .string) log.err(error.ExpectedString, "Context argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(3) });
    const ctx = vm.toString(3) catch |err| log.fatal(err, "Occured when popping context argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    if (vm.typeOf(4) != .string) log.err(error.ExpectedString, "Tag argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(4) });
    const t = vm.toString(4) catch |err| log.fatal(err, "Occured when popping tag argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    if (vm.typeOf(5) != .string) log.err(error.ExpectedString, "Parameters argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(5) });
    const parameters = vm.toString(5) catch |err| log.fatal(err, "Occured when popping parameters argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    const gpa = vm.allocator();
    const source = gpa.printSentinel(
        \\{{
        \\    "docker_build": {{
        \\        "version": "{s}",
        \\        "ctx": "{s}",
        \\        "t": "{s}",
        \\        "parameters": {s}
        \\    }}
        \\}}
    , .{ api_version, ctx, t, parameters }, 0) catch |err| log.fatal(err, "Occured when allocating for string", .{ .src = @src(), .id = task_id });
    defer gpa.free(source);
    const parsed = c.jv_parse(source);
    if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.err(error.UnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .src = @src(), .id = task_id, .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
    scheduler.newRequestTask(task_id, parsed);
    return 0;
}

// TODO: here we should run the full user config instead of just the custom task function
fn schedulerNewCustomTask(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "Task id argument should be a string in main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const task_id = vm.toString(1) catch |err| log.fatal(err, "Occured when popping task id argument in main Lua VM stack", @src());
    if (vm.typeOf(2) != .function) log.err(error.ExpectedFunction, "Second argument should be a function in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(1) });

    _ = vm.getGlobal("string");
    _ = vm.getField(-1, "dump");
    vm.remove(-2); // remove "string" table
    var info: zlua.DebugInfo = .{};
    vm.pushValue(2); // push the function
    vm.getInfo(.{ .n = true }, &info);
    std.log.warn("{s}\n", .{info.name.?});
    vm.pushValue(2); // push the function
    vm.protectedCall(.{ .args = 1, .results = 1 }) catch |err| log.fatal(err, "Occured when dumping bytecode for custom task in main Lua VM stack", .{ .src = @src(), .id = task_id });

    const bytecode = vm.toString(-1) catch |err| log.fatal(err, "Occured when popping string return value in main Lua VM stack", .{ .src = @src(), .id = task_id });
    scheduler.newCustomTask(task_id, bytecode);
    vm.pop(1);
    return 0;
}

fn schedulerNewJSONQueryTask(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "Task id argument should be a string in main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const task_id = vm.toString(1) catch |err| log.fatal(err, "Occured when poping task id argument in main Lua VM stack", @src());
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Filter argument should be a string in main Lua VM stack", .{ .src = @src(), .id = task_id, .lua_type = vm.typeOf(2) });
    const filter = vm.toString(2) catch |err| log.fatal(err, "Occured when popping filter argument in main Lua VM stack", .{ .src = @src(), .id = task_id });
    scheduler.newJSONQueryTask(task_id, filter);
    return 0;
}

const Script = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    vm: *zlua.Lua,

    pub fn init(self: *@This(), arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
        scheduler.init(arena_instance, gpa, io, environ);
        self.arena = arena_instance;
        self.gpa = gpa;
        self.io = io;
        self.vm = zlua.Lua.init(gpa) catch |err| log.fatal(err, "Occured when initializing main Lua VM", .{});
        self.vm.openLibs();
    }

    pub fn deinit(self: *@This()) void {
        self.vm.deinit();
        scheduler.deinit();
    }

    const build_context_script =
        \\build = {}
        \\build.__index = build
        \\
        \\function build:new(argv)
        \\   local b = {}
        \\   setmetatable(b, build)
        \\   b.argv = argv
        \\   return b
        \\end
    ;

    pub fn build(self: @This(), rule: []const u8, args: []const []const u8) void {
        if (rule.len == 0) log.err(error.EmptyRule, "Empty rule", .{});

        const cwd = std.Io.Dir.cwd();
        const user_config_script = cwd.readFileAllocOptions(self.io, user_config_path, self.gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
            error.AccessDenied => log.err(error.ScriptAccessDenied, "Not allowed to read " ++ user_config_path, .{}),
            error.IsDir => log.err(error.ScriptIsDir, user_config_path ++ " should be a file", .{}),
            error.FileNotFound => log.err(error.ScriptMissing, "Did not found " ++ user_config_path, .{}),
            error.SymLinkLoop => log.err(error.ScriptSymLinkLoop, user_config_path ++ " is a loop symlink", .{}),
            else => log.fatal(err, "Occured when reading " ++ user_config_path, .{}),
        };
        defer self.gpa.free(user_config_script);

        const call_script = self.gpa.print(
            \\builder = build:new(argv)
            \\builder:{s}()
        , .{rule}) catch |err| log.fatal(err, "Occured when formatting calling script", .{});
        defer self.gpa.free(call_script);

        const build_script = std.mem.joinZ(self.gpa, "\n", &.{ build_context_script, user_config_script, call_script }) catch |err| log.fatal(err, "Occured when gathering scripts into build Lua script", .{});
        defer self.gpa.free(build_script);

        self.vm.pushAny(args) catch |err| log.fatal(err, "Occured when pushing args to main Lua VM stack", .{});
        self.vm.setGlobal("argv");
        self.vm.pushFunction(zlua.wrap(schedulerTaskDependsOn));
        self.vm.setGlobal("taskDependsOn");
        self.vm.pushFunction(zlua.wrap(schedulerNewDockerTask));
        self.vm.setGlobal("newDockerTask");
        self.vm.pushFunction(zlua.wrap(schedulerNewDockerBuildTask));
        self.vm.setGlobal("newDockerBuildTask");
        self.vm.pushFunction(zlua.wrap(schedulerNewCustomTask));
        self.vm.setGlobal("newCustomTask");
        self.vm.pushFunction(zlua.wrap(schedulerNewJSONQueryTask));
        self.vm.setGlobal("newJsonQueryTask");

        self.vm.doString(build_script) catch |err| {
            const msg = if (self.vm.getTop() > 0) self.vm.toString(-1) catch "Unknown error" else "Unknown error";
            var lines: std.ArrayList([]const u8) = .empty;
            var raw = false;
            defer lines.deinit();
            defer self.vm.pop(1);
            var i: u32 = 1;
            var it = std.mem.splitScalar(u8, std.mem.trim(u8, build_script, "\n"), '\n');
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
                    log.err(err, "Occured when running the build script", .{ .script = build_script, .msg = msg });
                } else {
                    log.err(err, "Occured when running the build script", .{ .script = lines.items, .msg = msg });
                },
                else => if (raw) {
                    log.fatal(err, "Occured when running the build script", .{ .script = build_script, .msg = msg });
                } else {
                    log.fatal(err, "Occured when running the build script", .{ .script = lines.items, .msg = msg });
                },
            }
        };
    }

    pub fn run(self: @This()) void {
        _ = self;
        scheduler.run();
    }
};
