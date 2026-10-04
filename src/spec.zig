const std = @import("std");
const exit = @import("exit");
const scheduler = @import("scheduler");
const c = @import("jq");
const build = @import("build");

const source_path = build.name ++ ".zon";

var singleton: Spec = undefined;

pub fn init(arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
    singleton.init(arena_instance, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn parse(executed_rule: []const u8) void {
    singleton.parse(executed_rule);
}

fn jvFromAny(gpa: std.mem.Allocator, input: anytype) std.mem.Allocator.Error!c.jv {
    const source = try gpa.printSentinel("{f}", .{std.json.fmt(input, .{})}, 0);
    defer gpa.free(source);
    return c.jv_parse(source);
}

const ZonParsingError = error{
    UnexpectedToken,
    UnexpectedNode,
    StringLiteralParseWriteFailed,
};

const Dependencies = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, dependencies: *std.ArrayList([]const u8), str_buf: *std.ArrayList(u8), module_name: []const u8) void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const array_init = ast.fullArrayInit(&buf, node) orelse {
            const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly("Expecting an array when parsing \"dependencies\" into \"{s}\" module", .{module_name});
            if (struct_init.ast.fields.len > 0) exit.expectedly("Expecting an array when parsing \"dependencies\" into \"{s}\" module", .{module_name});
            return;
        };

        for (0..array_init.ast.elements.len) |i| {
            const name_token = ast.firstToken(array_init.ast.elements[i]) + 1;
            const dep_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse a dependency identifier into \"{s}\" module", .{module_name}),
            };
            dependencies.append(gpa, dep_name) catch |err| switch (err) {
                error.OutOfMemory => exit.unexpectedly("Out of memory when appending this dependency for \"{s}\" module: \"{s}\"", .{ module_name, dep_name }),
            };
        }
    }
};

const DockerParameters = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, parameters: *std.array_hash_map.String([]const u8), str_buf: *std.ArrayList(u8), module_name: []const u8) void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly("Expecting a struct when parsing docker parameters into \"{s}\" module", .{module_name});

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const param_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse a docker parameter key into \"{s}\" module", .{module_name}),
            };
            const param_value = parseString(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse a docker parameter value into \"{s}\" module", .{module_name}),
            };
            parameters.put(gpa, param_name, param_value) catch |err| switch (err) {
                error.OutOfMemory => exit.unexpectedly("Out of memory when appending this docker parameter for \"{s}\" module: \"{s}\"", .{ module_name, param_name }),
            };
        }
    }
};

const DockerModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
        var have_version = false;
        var have_endpoint = false;
        var have_method = false;
        var version: []const u8 = undefined;
        defer {
            if (have_version) gpa.free(version);
        }
        var endpoint: []const u8 = undefined;
        defer {
            if (have_endpoint) gpa.free(endpoint);
        }
        var method: []const u8 = undefined;
        defer {
            if (have_method) gpa.free(method);
        }
        var parameters: std.array_hash_map.String([]const u8) = .empty;
        defer {
            var it = parameters.iterator();
            while (it.next()) |entry| {
                gpa.free(entry.key_ptr.*);
                gpa.free(entry.value_ptr.*);
            }
            parameters.deinit(gpa);
        }
        var dependencies: std.ArrayList([]const u8) = .empty;
        defer {
            for (0..dependencies.items.len) |i| gpa.free(dependencies.items[i]);
            dependencies.deinit(gpa);
        }

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly("Expected \"{s}\" module expression to be a struct", .{module_name});

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = parseIdentifier(gpa, ast, field_name_token, str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Invalid field name into \"{s}\" module", .{module_name}),
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) exit.expectedly("Duplicated \"version\" field name into \"{s}\" module", .{module_name});
                have_version = true;
                version = parseString(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| switch (err) {
                    error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse \"version\" into \"{s}\" module", .{module_name}),
                };
            } else if (std.mem.eql(u8, field_name, "endpoint")) {
                if (have_endpoint) exit.expectedly("Duplicated \"endpoint\" field name into \"{s}\" module", .{module_name});
                have_endpoint = true;
                endpoint = parseString(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| switch (err) {
                    error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse \"endpoint\" into \"{s}\" module", .{module_name}),
                };
            } else if (std.mem.eql(u8, field_name, "method")) {
                if (have_method) exit.expectedly("Duplicated \"method\" field name into \"{s}\" module", .{module_name});
                have_method = true;
                const method_name_token = ast.firstToken(struct_init.ast.fields[i]) + 1;
                method = parseIdentifier(gpa, ast, method_name_token, str_buf) catch |err| switch (err) {
                    error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse \"method\" into \"{s}\" module", .{module_name}),
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (parameters.count() > 0) exit.expectedly("Duplicated \"parameters\" field name into \"{s}\" module", .{module_name});
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, str_buf, module_name);
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (dependencies.items.len > 0) exit.expectedly("Duplicated \"dependencies\" field name into \"{s}\" module", .{module_name});
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf, module_name);
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) exit.expectedly("Missing \"version\" field into \"{s}\" module", .{module_name});
        if (!have_endpoint) exit.expectedly("Missing \"endpoint\" field into \"{s}\" module", .{module_name});
        if (!have_method) exit.expectedly("Missing \"method\" field into \"{s}\" module", .{module_name});

        scheduler.addRequestTask(module_name, jvFromAny(gpa, .{
            .docker = .{
                .version = version,
                .endpoint = endpoint,
                .method = std.meta.stringToEnum(std.http.Method, method) orelse exit.expectedly("Invalid method field into \"{s}\"", .{module_name}),
                .parameters = std.json.ArrayHashMap([]const u8){
                    .map = parameters,
                },
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly("Out of memory when casting Zig object into jv object for \"{s}\" module", .{module_name}),
        }, dependencies.items);
    }
};

const DockerBuildModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
        var have_version = false;
        var have_ctx = false;
        var have_t = false;
        var version: []const u8 = undefined;
        defer {
            if (have_version) gpa.free(version);
        }
        var ctx: []const u8 = undefined;
        var ctx_path: []const u8 = undefined;
        defer {
            if (have_ctx) {
                gpa.free(ctx);
                gpa.free(ctx_path);
            }
        }
        var t: []const u8 = undefined;
        defer {
            if (have_t) gpa.free(t);
        }
        var parameters: std.array_hash_map.String([]const u8) = .empty;
        defer {
            var it = parameters.iterator();
            while (it.next()) |entry| {
                gpa.free(entry.key_ptr.*);
                gpa.free(entry.value_ptr.*);
            }
            parameters.deinit(gpa);
        }
        var dependencies: std.ArrayList([]const u8) = .empty;
        defer {
            for (0..dependencies.items.len) |i| gpa.free(dependencies.items[i]);
            dependencies.deinit(gpa);
        }

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly("Expected \"{s}\" module expression to be a struct", .{module_name});

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Invalid field name into \"{s}\" module", .{module_name}),
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) exit.expectedly("Duplicated \"version\" field name into \"{s}\" module", .{module_name});
                have_version = true;
                version = parseString(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| switch (err) {
                    error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse \"version\" into \"{s}\" module", .{module_name}),
                };
            } else if (std.mem.eql(u8, field_name, "ctx")) {
                if (have_ctx) exit.expectedly("Duplicated \"ctx\" field name into \"{s}\" module", .{module_name});
                have_ctx = true;
                ctx_path = parseString(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| switch (err) {
                    error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse \"ctx\" into \"{s}\" module", .{module_name}),
                };
                ctx = std.fs.path.resolve(gpa, &.{ctx_path}) catch |err| switch (err) {
                    error.OutOfMemory => exit.unexpectedly("Out of memory when resolving \"ctx\" path into \"{s}\" module", .{module_name}),
                };
            } else if (std.mem.eql(u8, field_name, "t")) {
                if (have_t) exit.expectedly("Duplicated \"t\" field name into \"{s}\" module", .{module_name});
                have_t = true;
                t = parseString(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| switch (err) {
                    error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse \"t\" into \"{s}\" module", .{module_name}),
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (parameters.count() > 0) exit.expectedly("Duplicated \"parameters\" field name into \"{s}\" module", .{module_name});
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, str_buf, module_name);
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (dependencies.items.len > 0) exit.expectedly("Duplicated \"dependencies\" field name into \"{s}\" module", .{module_name});
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf, module_name);
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) exit.expectedly("Missing \"version\" field into \"{s}\" module", .{module_name});
        if (!have_ctx) exit.expectedly("Missing \"ctx\" field into \"{s}\" module", .{module_name});
        if (!have_t) exit.expectedly("Missing \"t\" field into \"{s}\" module", .{module_name});

        scheduler.addRequestTask(module_name, jvFromAny(gpa, .{
            .docker = .{
                .version = version,
                .ctx = ctx,
                .t = t,
                .parameters = std.json.ArrayHashMap([]const u8){
                    .map = parameters,
                },
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly("Out of memory when casting Zig object into jv object for \"{s}\" module", .{module_name}),
        }, dependencies.items);
    }
};

const JqModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
        var have_filter = false;
        var filter: []const u8 = undefined;
        defer {
            if (have_filter) gpa.free(filter);
        }
        var dependencies: std.ArrayList([]const u8) = .empty;
        defer {
            for (0..dependencies.items.len) |i| gpa.free(dependencies.items[i]);
            dependencies.deinit(gpa);
        }

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly("Expected \"{s}\" module expression to be a struct", .{module_name});

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Invalid field name into \"{s}\" module", .{module_name}),
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "filter")) {
                if (have_filter) exit.expectedly("Duplicated \"filter\" field name into \"{s}\" module", .{module_name});
                have_filter = true;
                filter = parseString(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| switch (err) {
                    error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Failed to parse \"filter\" into \"{s}\" module", .{module_name}),
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (dependencies.items.len > 0) exit.expectedly("Duplicated \"dependencies\" field name into \"{s}\" module", .{module_name});
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf, module_name);
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_filter) exit.expectedly("Missing \"filter\" field into \"{s}\" module", .{module_name});

        scheduler.addJSONQueryTask(module_name, filter, dependencies.items);
    }
};

const Module = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
        if (std.mem.findScalar(u8, module_name, '/') == null) exit.expectedly("A module identifier must contain a slash character between module type and module id: \"{s}\"", .{module_name});

        if (std.mem.startsWith(u8, module_name, "jq/")) {
            JqModule.parse(gpa, ast, node, module_name, str_buf);
        } else if (std.mem.startsWith(u8, module_name, "docker/")) {
            DockerModule.parse(gpa, ast, node, module_name, str_buf);
        } else if (std.mem.startsWith(u8, module_name, "docker_build/")) {
            DockerBuildModule.parse(gpa, ast, node, module_name, str_buf);
        } else exit.expectedly("Unknown module type \"{s}\"", .{module_name[0..std.mem.findScalar(u8, module_name, '/').?]});
    }
};

const Rule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, rule_name: []const u8, str_buf: *std.ArrayList(u8)) void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly("Expected \"{s}\" rule expression to be a struct", .{rule_name});

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const module_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Invalid module name into \"{s}\" module", .{rule_name}),
            };
            defer gpa.free(module_name);
            Module.parse(gpa, ast, struct_init.ast.fields[i], module_name, str_buf);
        }
    }
};

const Spec = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn init(self: *@This(), arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
        scheduler.init(arena_instance, gpa, io, environ);
        self.arena = arena_instance;
        self.gpa = gpa;
        self.io = io;
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
        scheduler.deinit();
    }

    pub fn parse(self: *@This(), executed_rule: []const u8) void {
        const cwd = std.Io.Dir.cwd();
        const source = cwd.readFileAllocOptions(self.io, source_path, self.gpa, .unlimited, .of(u8), 0) catch |err| switch (err) {
            error.FileNotFound => exit.expectedly("Did not found mana.zon", .{}),
            else => exit.unexpectedly("{s} when reading {s}", .{ @errorName(err), source_path }),
        };
        defer self.gpa.free(source);

        var ast = std.zig.Ast.parse(self.gpa, source, .{ .mode = .zon }) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly("Out of memory during Zon Ast parsing", .{}),
        };
        defer ast.deinit(self.gpa);
        if (ast.errors.len > 0) std.zig.printAstErrorsToStderr(self.gpa, self.io, ast, source_path, .auto) catch |err| exit.unexpectedly("{s} during Zon Ast errors printing", .{@errorName(err)});

        var str_buf: std.ArrayList(u8) = .empty;
        defer str_buf.deinit(self.gpa);
        const node = ast.nodeData(.root).node;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly("Expected top level expression to be a struct", .{});

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const rule_name = parseIdentifier(self.gpa, ast, name_token, &str_buf) catch |err| switch (err) {
                error.UnexpectedToken, error.UnexpectedNode, error.StringLiteralParseWriteFailed => exit.expectedly("Invalid rule name", .{}),
            };
            defer self.gpa.free(rule_name);
            if (std.mem.eql(u8, executed_rule, rule_name)) Rule.parse(self.gpa, ast, struct_init.ast.fields[i], rule_name, &str_buf);
        }

        scheduler.run();
    }
};

fn parseIdentifier(gpa: std.mem.Allocator, ast: std.zig.Ast, token: std.zig.Ast.TokenIndex, str_buf: *std.ArrayList(u8)) ZonParsingError![]const u8 {
    const token_tag = ast.tokenTag(token);
    if (token_tag != .identifier) {
        std.log.err("Expecting an identifier but getting {s} instead", .{@tagName(token_tag)});
        return error.UnexpectedToken;
    }
    const ident_name = ast.tokenSlice(token);
    if (!std.mem.startsWith(u8, ident_name, "@")) return gpa.dupe(u8, ident_name) catch |err| switch (err) {
        error.OutOfMemory => exit.unexpectedly("Out of memory when duping this identifier: \"{s}\"", .{ident_name}),
    };
    str_buf.clearRetainingCapacity();
    try parseStringLiteral(gpa, str_buf, ident_name, 1);
    return gpa.dupe(u8, str_buf.items) catch |err| switch (err) {
        error.OutOfMemory => exit.unexpectedly("Out of memory when duping this identifier: \"{s}\"", .{str_buf.items}),
    };
}

fn parseString(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, str_buf: *std.ArrayList(u8)) ZonParsingError![]const u8 {
    const node_tag = ast.nodeTag(node);
    if (node_tag != .string_literal) {
        std.log.err("Expecting a string literal but getting {s} instead", .{@tagName(node_tag)});
        return error.UnexpectedNode;
    }
    const str_lit_token = ast.nodeMainToken(node);
    const token_bytes = ast.tokenSlice(str_lit_token);
    str_buf.clearRetainingCapacity();
    try parseStringLiteral(gpa, str_buf, token_bytes, 0);
    return gpa.dupe(u8, str_buf.items) catch |err| switch (err) {
        error.OutOfMemory => exit.unexpectedly("Out of memory when duping this string literal: \"{s}\"", .{str_buf.items}),
    };
}

fn parseStringLiteral(gpa: std.mem.Allocator, str_buf: *std.ArrayList(u8), bytes: []const u8, offset: u32) ZonParsingError!void {
    const raw_string = bytes[offset..];
    const result = r: {
        var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, str_buf);
        defer str_buf.* = aw.toArrayList();
        break :r std.zig.string_literal.parseWrite(&aw.writer, raw_string) catch |err| switch (err) {
            error.WriteFailed => exit.unexpectedly("Write failed when duping this string literal: {s}", .{raw_string}),
        };
    };
    switch (result) {
        .success => {},
        .failure => |err| {
            std.log.err("String literal failed to be parsed with this error: {f}", .{err.fmt("")});
            return error.StringLiteralParseWriteFailed;
        },
    }
}
