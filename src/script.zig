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
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "Child argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const child_id = vm.toString(1) catch |err| log.fatal(err, "Can't find child argument in lua VM stack", @src());
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Parent argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(2) });
    const parent_id = vm.toString(2) catch |err| log.fatal(err, "Can't find parent argument in lua VM stack", @src());
    scheduler.taskDependsOn(child_id, parent_id);
    return 0;
}

fn schedulerNewDockerTask(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "New task argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const new_task_id = vm.toString(1) catch |err| log.fatal(err, "Can't find new task argument in lua VM stack", @src());
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Docker API version argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(2) });
    const api_version = vm.toString(2) catch |err| log.fatal(err, "Can't find Docker API version argument in lua VM stack", @src());
    if (vm.typeOf(3) != .string) log.err(error.ExpectedString, "Docker endpoint argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(3) });
    const endpoint = vm.toString(3) catch |err| log.fatal(err, "Can't find Docker endpoint argument in lua VM stack", @src());
    if (vm.typeOf(4) != .string) log.err(error.ExpectedString, "HTTP method argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(4) });
    const method = vm.toString(4) catch |err| log.fatal(err, "Can't find HTTP method argument in lua VM stack", @src());
    if (vm.typeOf(5) != .string) log.err(error.ExpectedString, "Parameters argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(5) });
    const parameters = vm.toString(5) catch |err| log.fatal(err, "Can't find parameters argument in lua VM stack", @src());
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
    , .{ api_version, endpoint, method, parameters }, 0) catch |err| log.fatal(err, @src().fn_name ++ "(): Occured when allocating for string", .{});
    defer gpa.free(source);
    const parsed = c.jv_parse(source);
    if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.err(error.UnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .src = @src(), .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
    scheduler.newRequestTask(new_task_id, parsed);
    return 0;
}

fn schedulerNewDockerBuildTask(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "New task argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const new_task_id = vm.toString(1) catch |err| log.fatal(err, "Can't find new task argument in lua VM stack", @src());
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Docker API version argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(2) });
    const api_version = vm.toString(2) catch |err| log.fatal(err, "Can't find Docker API version argument in lua VM stack", @src());
    if (vm.typeOf(3) != .string) log.err(error.ExpectedString, "Context argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(3) });
    const ctx = vm.toString(3) catch |err| log.fatal(err, "Can't find context argument in lua VM stack", @src());
    if (vm.typeOf(4) != .string) log.err(error.ExpectedString, "Tag argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(4) });
    const t = vm.toString(4) catch |err| log.fatal(err, "Can't find tag argument in lua VM stack", @src());
    if (vm.typeOf(5) != .string) log.err(error.ExpectedString, "Parameters argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(5) });
    const parameters = vm.toString(5) catch |err| log.fatal(err, "Can't find parameters argument in lua VM stack", @src());
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
    , .{ api_version, ctx, t, parameters }, 0) catch |err| log.fatal(err, @src().fn_name ++ "(): Occured when allocating for string", .{});
    defer gpa.free(source);
    const parsed = c.jv_parse(source);
    if (c.jv_get_kind(parsed) != c.JV_KIND_OBJECT) log.err(error.UnexpectedJsonKind, "Expecting an object json kind after jv parsing", .{ .src = @src(), .kind = std.mem.span(c.jv_kind_name(c.jv_get_kind(parsed))) });
    scheduler.newRequestTask(new_task_id, parsed);
    return 0;
}

fn schedulerNewJSONQueryTask(vm: *zlua.Lua) i32 {
    if (vm.typeOf(1) != .string) log.err(error.ExpectedString, "New task argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(1) });
    const new_task_id = vm.toString(1) catch |err| log.fatal(err, @src().fn_name ++ "(): can't find new task argument in lua VM stack", .{});
    if (vm.typeOf(2) != .string) log.err(error.ExpectedString, "Filter argument should be a string in lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(2) });
    const filter = vm.toString(2) catch |err| log.fatal(err, @src().fn_name ++ "(): can't find filter argument in lua VM stack", .{});
    scheduler.newJSONQueryTask(new_task_id, filter);
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
        self.vm = zlua.Lua.init(gpa) catch |err| log.fatal(err, "Occured when initializing lua VM", .{});
        self.vm.openLibs();
    }

    pub fn deinit(self: *@This()) void {
        self.vm.deinit();
        scheduler.deinit();
    }

    const build_header_script =
        \\build = {}
        \\build.__index = build
        \\
        \\function build:new(argv)
        \\   local b = {}
        \\   setmetatable(b, build)
        \\   b.argv = argv
        \\   return b
        \\end
        \\
        \\Scheduler = {}
        \\Scheduler.__index = Scheduler
        \\
        \\function Scheduler:taskDependsOn(child, parent)
        \\   schedulerTaskDependsOn(child, parent);
        \\end
        \\
        \\function Scheduler:newDockerTask(id, version, endpoint, method, parameters)
        \\   schedulerNewDockerTask(id, version, endpoint, method, parameters);
        \\end
        \\
        \\function Scheduler:newDockerBuildTask(id, version, ctx, t, parameters)
        \\   schedulerNewDockerBuildTask(id, version, ctx, t, parameters)
        \\end
        \\
        \\function Scheduler:newJsonQueryTask(id, filter)
        \\   schedulerNewJsonQueryTask(id, filter)
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

        const build_script = std.mem.joinZ(self.gpa, "\n", &.{ build_header_script, user_config_script, call_script }) catch |err| log.fatal(err, "Occured when gathering scripts into build Lua script", .{});
        defer self.gpa.free(build_script);

        self.vm.pushAny(args) catch |err| log.fatal(err, "Occured when pushing args to Lua VM stack", .{});
        self.vm.setGlobal("argv");
        self.vm.pushFunction(zlua.wrap(schedulerTaskDependsOn));
        self.vm.setGlobal("schedulerTaskDependsOn");
        self.vm.pushFunction(zlua.wrap(schedulerNewDockerTask));
        self.vm.setGlobal("schedulerNewDockerTask");
        self.vm.pushFunction(zlua.wrap(schedulerNewDockerBuildTask));
        self.vm.setGlobal("schedulerNewDockerBuildTask");
        self.vm.pushFunction(zlua.wrap(schedulerNewJSONQueryTask));
        self.vm.setGlobal("schedulerNewJsonQueryTask");

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
