const std = @import("std");
const scheduler = @import("scheduler");
const c = @import("jq");
const build = @import("build");

const source_path = build.name ++ ".zon";

var singleton: Spec = undefined;

pub fn init(arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) !void {
    try singleton.init(arena_instance, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn parse(executed_rule: []const u8) !void {
    try singleton.parse(executed_rule);
}

fn jvFromAny(gpa: std.mem.Allocator, input: anytype) !c.jv {
    const source = try gpa.printSentinel("{f}", .{std.json.fmt(input, .{})}, 0);
    defer gpa.free(source);
    return c.jv_parse(source);
}

const Dependencies = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, dependencies: *std.ArrayList([]const u8), str_buf: *std.ArrayList(u8)) !void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const array_init = ast.fullArrayInit(&buf, node) orelse {
            const struct_init = ast.fullStructInit(&buf, node) orelse return error.ZonParsingFailed;
            if (struct_init.ast.fields.len > 0) return error.ZonParsingFailed;
            return;
        };

        for (0..array_init.ast.elements.len) |i| {
            const name_token = ast.firstToken(array_init.ast.elements[i]) + 1;
            const dep_name = try parseIdentifier(gpa, ast, name_token, str_buf);
            try dependencies.append(gpa, dep_name);
        }
    }
};

const DockerParameters = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, parameters: *std.array_hash_map.String([]const u8), str_buf: *std.ArrayList(u8)) !void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse return error.ZonParsingFailed;

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const param_name = try parseIdentifier(gpa, ast, name_token, str_buf);
            const param_value = try parseString(gpa, ast, struct_init.ast.fields[i], str_buf);
            try parameters.put(gpa, param_name, param_value);
        }
    }
};

const DockerModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) !void {
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
        const struct_init = ast.fullStructInit(&buf, node) orelse {
            std.log.err("Expected \"{s}\" module expression to be a struct", .{module_name});
            return error.ZonParsingFailed;
        };

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = parseIdentifier(gpa, ast, field_name_token, str_buf) catch |err| {
                switch (err) {
                    error.ZonParsingFailed => std.log.err("Invalid field name into \"{s}\" module", .{module_name}),
                    else => {},
                }
                return err;
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) {
                    std.log.err("Duplicated \"version\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                have_version = true;
                version = try parseString(gpa, ast, struct_init.ast.fields[i], str_buf);
            } else if (std.mem.eql(u8, field_name, "endpoint")) {
                if (have_endpoint) {
                    std.log.err("Duplicated \"endpoint\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                have_endpoint = true;
                endpoint = try parseString(gpa, ast, struct_init.ast.fields[i], str_buf);
            } else if (std.mem.eql(u8, field_name, "method")) {
                if (have_method) {
                    std.log.err("Duplicated \"method\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                have_method = true;
                const method_name_token = ast.firstToken(struct_init.ast.fields[i]) + 1;
                method = try parseIdentifier(gpa, ast, method_name_token, str_buf);
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (parameters.count() > 0) {
                    std.log.err("Duplicated \"parameters\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, str_buf) catch |err| {
                    switch (err) {
                        error.ZonParsingFailed => std.log.err("Invalid parameter into \"{s}\" module", .{module_name}),
                        else => {},
                    }
                    return err;
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (dependencies.items.len > 0) {
                    std.log.err("Duplicated \"dependencies\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf) catch |err| {
                    switch (err) {
                        error.ZonParsingFailed => std.log.err("Invalid dependency into \"{s}\" module", .{module_name}),
                        else => {},
                    }
                    return err;
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) {
            std.log.err("Missing \"version\" field into \"{s}\" module", .{module_name});
            return error.ZonParsingFailed;
        }

        if (!have_endpoint) {
            std.log.err("Missing \"endpoint\" field into \"{s}\" module", .{module_name});
            return error.ZonParsingFailed;
        }

        if (!have_method) {
            std.log.err("Missing \"method\" field into \"{s}\" module", .{module_name});
            return error.ZonParsingFailed;
        }

        try scheduler.addRequestTask(module_name, try jvFromAny(gpa, .{
            .docker = .{
                .version = version,
                .endpoint = endpoint,
                .method = std.meta.stringToEnum(std.http.Method, method) orelse {
                    std.log.err("Invalid method field into \"{s}\"", .{module_name});
                    return error.ZonParsingFailed;
                },
                .parameters = std.json.ArrayHashMap([]const u8){
                    .map = parameters,
                },
            },
        }), dependencies.items);
    }
};

const DockerBuildModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) !void {
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
        const struct_init = ast.fullStructInit(&buf, node) orelse {
            std.log.err("Expected \"{s}\" module expression to be a struct", .{module_name});
            return error.ZonParsingFailed;
        };

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| {
                switch (err) {
                    error.ZonParsingFailed => std.log.err("Invalid field name into \"{s}\" module", .{module_name}),
                    else => {},
                }
                return err;
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) {
                    std.log.err("Duplicated \"version\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                have_version = true;
                version = try parseString(gpa, ast, struct_init.ast.fields[i], str_buf);
            } else if (std.mem.eql(u8, field_name, "ctx")) {
                if (have_ctx) {
                    std.log.err("Duplicated \"ctx\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                have_ctx = true;
                ctx_path = try parseString(gpa, ast, struct_init.ast.fields[i], str_buf);
                ctx = try std.fs.path.resolve(gpa, &.{ctx_path});
            } else if (std.mem.eql(u8, field_name, "t")) {
                if (have_t) {
                    std.log.err("Duplicated \"t\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                have_t = true;
                t = try parseString(gpa, ast, struct_init.ast.fields[i], str_buf);
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (parameters.count() > 0) {
                    std.log.err("Duplicated \"parameters\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, str_buf) catch |err| {
                    switch (err) {
                        error.ZonParsingFailed => std.log.err("Invalid parameter into \"{s}\" module", .{module_name}),
                        else => {},
                    }
                    return err;
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (dependencies.items.len > 0) {
                    std.log.err("Duplicated \"dependencies\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf) catch |err| {
                    switch (err) {
                        error.ZonParsingFailed => std.log.err("Invalid dependency into \"{s}\" module", .{module_name}),
                        else => {},
                    }
                    return err;
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) {
            std.log.err("Missing \"version\" field into \"{s}\" module", .{module_name});
            return error.ZonParsingFailed;
        }

        if (!have_ctx) {
            std.log.err("Missing \"ctx\" field into \"{s}\" module", .{module_name});
            return error.ZonParsingFailed;
        }

        if (!have_t) {
            std.log.err("Missing \"t\" field into \"{s}\" module", .{module_name});
            return error.ZonParsingFailed;
        }

        try scheduler.addRequestTask(module_name, try jvFromAny(gpa, .{
            .docker = .{
                .version = version,
                .ctx = ctx,
                .t = t,
                .parameters = std.json.ArrayHashMap([]const u8){
                    .map = parameters,
                },
            },
        }), dependencies.items);
    }
};

const JqModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) !void {
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
        const struct_init = ast.fullStructInit(&buf, node) orelse {
            std.log.err("Expected \"{s}\" module expression to be a struct", .{module_name});
            return error.ZonParsingFailed;
        };

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| {
                switch (err) {
                    error.ZonParsingFailed => std.log.err("Invalid field name into \"{s}\" module", .{module_name}),
                    else => {},
                }
                return err;
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "filter")) {
                if (have_filter) {
                    std.log.err("Duplicated \"filter\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                have_filter = true;
                filter = try parseString(gpa, ast, struct_init.ast.fields[i], str_buf);
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (dependencies.items.len > 0) {
                    std.log.err("Duplicated \"dependencies\" field name into \"{s}\" module", .{module_name});
                    return error.ZonParsingFailed;
                }
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf) catch |err| {
                    switch (err) {
                        error.ZonParsingFailed => std.log.err("Invalid dependency into \"{s}\" module", .{module_name}),
                        else => {},
                    }
                    return err;
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_filter) {
            std.log.err("Missing \"filter\" field into \"{s}\" module", .{module_name});
            return error.ZonParsingFailed;
        }

        try scheduler.addJSONQueryTask(module_name, filter, dependencies.items);
    }
};

const Module = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) !void {
        if (std.mem.findScalar(u8, module_name, '/') == null) {
            std.log.err("A module identifier must contain a slash character between module type and module id: \"{s}\"", .{module_name});
            return error.ZonParsingFailed;
        }

        if (std.mem.startsWith(u8, module_name, "jq/")) {
            try JqModule.parse(gpa, ast, node, module_name, str_buf);
        } else if (std.mem.startsWith(u8, module_name, "docker/")) {
            try DockerModule.parse(gpa, ast, node, module_name, str_buf);
        } else if (std.mem.startsWith(u8, module_name, "docker_build/")) {
            try DockerBuildModule.parse(gpa, ast, node, module_name, str_buf);
        } else {
            std.log.err("Unknown module type \"{s}\"", .{module_name[0..std.mem.findScalar(u8, module_name, '/').?]});
            return error.ZonParsingFailed;
        }
    }
};

const Rule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, rule_name: []const u8, str_buf: *std.ArrayList(u8)) !void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse {
            std.log.err("Expected \"{s}\" rule expression to be a struct", .{rule_name});
            return error.ZonParsingFailed;
        };

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const module_name = parseIdentifier(gpa, ast, name_token, str_buf) catch |err| {
                switch (err) {
                    error.ZonParsingFailed => std.log.err("Invalid module name into \"{s}\"", .{rule_name}),
                    else => {},
                }
                return err;
            };
            defer gpa.free(module_name);
            try Module.parse(gpa, ast, struct_init.ast.fields[i], module_name, str_buf);
        }
    }
};

const Spec = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn init(self: *@This(), arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) !void {
        try scheduler.init(arena_instance, gpa, io, environ);
        self.arena = arena_instance;
        self.gpa = gpa;
        self.io = io;
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
        scheduler.deinit();
    }

    pub fn parse(self: *@This(), executed_rule: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        const source = try cwd.readFileAllocOptions(self.io, source_path, self.gpa, .unlimited, .of(u8), 0);
        defer self.gpa.free(source);

        var ast = try std.zig.Ast.parse(self.gpa, source, .{ .mode = .zon });
        defer ast.deinit(self.gpa);
        if (ast.errors.len > 0) try std.zig.printAstErrorsToStderr(self.gpa, self.io, ast, source_path, .auto);

        var str_buf: std.ArrayList(u8) = .empty;
        defer str_buf.deinit(self.gpa);
        const node = ast.nodeData(.root).node;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse {
            std.log.err("Expected top level expression to be a struct", .{});
            return error.ZonParsingFailed;
        };

        for (0..struct_init.ast.fields.len) |i| {
            const name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const rule_name = parseIdentifier(self.gpa, ast, name_token, &str_buf) catch |err| {
                switch (err) {
                    error.ZonParsingFailed => std.log.err("Invalid rule name", .{}),
                    else => {},
                }
                return err;
            };
            defer self.gpa.free(rule_name);
            if (std.mem.eql(u8, executed_rule, rule_name)) try Rule.parse(self.gpa, ast, struct_init.ast.fields[i], rule_name, &str_buf);
        }

        try scheduler.run();
    }
};

fn parseIdentifier(gpa: std.mem.Allocator, ast: std.zig.Ast, token: std.zig.Ast.TokenIndex, str_buf: *std.ArrayList(u8)) ![]const u8 {
    if (ast.tokenTag(token) != .identifier) return error.ZonParsingFailed;
    const ident_name = ast.tokenSlice(token);
    if (!std.mem.startsWith(u8, ident_name, "@")) return gpa.dupe(u8, ident_name);
    str_buf.clearRetainingCapacity();
    try parseStringLiteral(gpa, str_buf, ident_name, 1);
    return gpa.dupe(u8, str_buf.items);
}

fn parseString(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, str_buf: *std.ArrayList(u8)) ![]const u8 {
    if (ast.nodeTag(node) != .string_literal) return error.ZonParsingFailed;
    const str_lit_token = ast.nodeMainToken(node);
    const token_bytes = ast.tokenSlice(str_lit_token);
    str_buf.clearRetainingCapacity();
    try parseStringLiteral(gpa, str_buf, token_bytes, 0);
    return gpa.dupe(u8, str_buf.items);
}

fn parseStringLiteral(gpa: std.mem.Allocator, str_buf: *std.ArrayList(u8), bytes: []const u8, offset: u32) !void {
    const raw_string = bytes[offset..];
    const result = r: {
        var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, str_buf);
        defer str_buf.* = aw.toArrayList();
        break :r std.zig.string_literal.parseWrite(&aw.writer, raw_string) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
    };
    switch (result) {
        .success => {},
        .failure => return error.ZonParsingFailed,
    }
}
