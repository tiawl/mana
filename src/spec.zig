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

const Identifier = struct {
    const ParsingError = error{
        UnexpectedToken,
    } || std.mem.Allocator.Error || StringLiteral.ParsingError;

    fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, token: std.zig.Ast.TokenIndex, diag: *StringLiteral.Diagnostic) ParsingError![]const u8 {
        const token_tag = ast.tokenTag(token);
        if (token_tag != .identifier) return error.UnexpectedToken;
        const ident_name = ast.tokenSlice(token);
        if (!std.mem.startsWith(u8, ident_name, "@")) return gpa.dupe(u8, ident_name);
        try StringLiteral.parse(gpa, ident_name, 1, diag);
        return gpa.dupe(u8, diag.buf.items);
    }
};

const String = struct {
    const ParsingError = error{
        UnexpectedNode,
    } || std.mem.Allocator.Error || StringLiteral.ParsingError;

    fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, diag: *StringLiteral.Diagnostic) ParsingError![]const u8 {
        const node_tag = ast.nodeTag(node);
        if (node_tag != .string_literal) return error.UnexpectedNode;
        const str_lit_token = ast.nodeMainToken(node);
        const token_bytes = ast.tokenSlice(str_lit_token);
        try StringLiteral.parse(gpa, token_bytes, 0, diag);
        return gpa.dupe(u8, diag.buf.items);
    }
};

const StringLiteral = struct {
    const ParsingError = error{
        StringLiteralParseFailed,
    } || std.Io.Writer.Error;

    const Diagnostic = struct {
        result: std.zig.string_literal.Result,
        buf: std.ArrayList(u8),

        fn fail(self: @This(), comptime prefix: [:0]const u8, comptime msg: []const u8, details: anytype) noreturn {
            switch (self.result) {
                .success => unreachable,
                .failure => |err| switch (err) {
                    inline else => |_, tag| exit.expectedly(@field(anyerror, error_name: {
                        const tagname = @tagName(tag);
                        var name: [tagname.len:0]u8 = undefined;
                        var i: usize = 0;
                        var j: usize = 0;
                        while (i < tagname.len) {
                            switch (tagname[i]) {
                                'a'...'z' => name[j] = if (i == 0) std.ascii.toUpper(tagname[i]) else tagname[i],
                                '_' => {
                                    i += 1;
                                    name[j] = std.ascii.toUpper(tagname[i]);
                                },
                                else => unreachable,
                            }
                            i += 1;
                            j += 1;
                        }
                        name[j] = 0;
                        break :error_name (prefix ++ "ZigStringLiteral" ++ name[0..j]);
                    }), msg, details),
                },
            }
        }
    };

    fn parse(gpa: std.mem.Allocator, bytes: []const u8, offset: u32, diag: *Diagnostic) ParsingError!void {
        diag.buf.clearRetainingCapacity();
        const raw_str = bytes[offset..];
        diag.result = r: {
            var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &diag.buf);
            defer diag.buf = aw.toArrayList();
            break :r try std.zig.string_literal.parseWrite(&aw.writer, raw_str);
        };
        switch (diag.result) {
            .success => {},
            .failure => return error.StringLiteralParseFailed,
        }
    }
};

const Dependencies = struct {
    const ParsingError = error{
        UnexpectedDependenciesType,
        UnexpectedDependenciesStruct,
        UnexpectedTokenDependency,
        StringLiteralParseFailedDependency,
    } || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, dependencies: *std.ArrayList([]const u8), diag: *StringLiteral.Diagnostic, err_node: *std.zig.Ast.Node.Index) ParsingError!void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const array_init = ast.fullArrayInit(&buf, node) orelse {
            const struct_init = ast.fullStructInit(&buf, node) orelse return error.UnexpectedDependenciesType;
            if (struct_init.ast.fields.len > 0) return error.UnexpectedDependenciesStruct;
            return;
        };

        for (0..array_init.ast.elements.len) |i| {
            const dep_name_token = ast.firstToken(array_init.ast.elements[i]) + 1;
            const dep_name = Identifier.parse(gpa, ast, dep_name_token, diag) catch |err| {
                err_node.* = array_init.ast.elements[i];
                switch (err) {
                    error.UnexpectedToken => return error.UnexpectedTokenDependency,
                    error.StringLiteralParseFailed => return error.StringLiteralParseFailedDependency,
                    error.OutOfMemory, error.WriteFailed => |e| return e,
                }
            };
            try dependencies.append(gpa, dep_name);
        }
    }
};

const DockerParameters = struct {
    const ParsingError = error{
        UnexpectedDockerParametersType,
        UnexpectedTokenDockerParameterName,
        StringLiteralParseFailedDockerParameterName,
        UnexpectedNodeDockerParameterValue,
        StringLiteralParseFailedDockerParameterValue,
    } || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, parameters: *std.array_hash_map.String([]const u8), diag: *StringLiteral.Diagnostic, err_node: *std.zig.Ast.Node.Index) ParsingError!void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse return error.UnexpectedDockerParametersType;

        for (0..struct_init.ast.fields.len) |i| {
            const param_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const param_name = Identifier.parse(gpa, ast, param_name_token, diag) catch |err| {
                err_node.* = struct_init.ast.fields[i];
                switch (err) {
                    error.UnexpectedToken => return error.UnexpectedTokenDockerParameterName,
                    error.StringLiteralParseFailed => return error.StringLiteralParseFailedDockerParameterName,
                    error.OutOfMemory, error.WriteFailed => |e| return e,
                }
            };
            const param_value = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                err_node.* = struct_init.ast.fields[i];
                switch (err) {
                    error.UnexpectedNode => return error.UnexpectedNodeDockerParameterValue,
                    error.StringLiteralParseFailed => return error.StringLiteralParseFailedDockerParameterValue,
                    error.OutOfMemory, error.WriteFailed => |e| return e,
                }
            };
            try parameters.put(gpa, param_name, param_value);
        }
    }
};

const DockerModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, diag: *StringLiteral.Diagnostic) void {
        var have_version = false;
        var have_endpoint = false;
        var have_method = false;
        var have_parameters = false;
        var have_dependencies = false;
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
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.DockerModuleUnexpectedType, "Expected docker module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, diag) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.DockerModuleUndeterminedFieldUnexpectedToken, "Invalid field name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(field_name_token),
                    }),
                    error.StringLiteralParseFailed => diag.fail("DockerModuleUndeterminedField", "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) exit.expectedly(error.DockerModuleVersionDuplicated, "Duplicated \"version\" field name", .{ .module = module_name });
                have_version = true;
                version = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.DockerModuleVersionUnexpectedToken, "Failed to parse \"version\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseFailed => diag.fail("DockerModuleVersion", "Failed to parse \"version\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"version\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "endpoint")) {
                if (have_endpoint) exit.expectedly(error.DockerModuleEndpointDuplicated, "Duplicated \"endpoint\" field name", .{ .module = module_name });
                have_endpoint = true;
                endpoint = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.DockerModuleEndpointUnexpectedToken, "Failed to parse \"endpoint\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseFailed => diag.fail("DockerModuleEndpoint", "Failed to parse \"endpoint\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"endpoint\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "method")) {
                if (have_method) exit.expectedly(error.DockerModuleMethodDuplicated, "Duplicated \"method\" field name", .{ .module = module_name });
                have_method = true;
                const method_name_token = ast.firstToken(struct_init.ast.fields[i]) + 1;
                method = Identifier.parse(gpa, ast, method_name_token, diag) catch |err| {
                    switch (err) {
                        error.UnexpectedToken => exit.expectedly(error.DockerModuleMethodUnexpectedToken, "Failed to parse \"method\". Expected .identifier token", .{
                            .module = module_name,
                            .token = ast.tokenTag(method_name_token),
                        }),
                        error.StringLiteralParseFailed => diag.fail("DockerModuleMethod", "Failed to parse \"method\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"method\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (have_parameters) exit.expectedly(error.DockerModuleParametersDuplicated, "Duplicated \"parameters\" field name", .{ .module = module_name });
                have_parameters = true;
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDockerParametersType => exit.expectedly(error.DockerModuleParametersUnexpectedType, "Expecting a struct when parsing docker parameters", .{ .module = module_name }),
                    error.UnexpectedTokenDockerParameterName => exit.expectedly(error.DockerModuleParameterNameUnexpectedToken, "Failed to parse a docker parameter name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.StringLiteralParseFailedDockerParameterName => diag.fail("DockerModuleParameterName", "Failed to parse a docker parameter name", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.UnexpectedNodeDockerParameterValue => exit.expectedly(error.DockerModuleParameterValueUnexpectedNode, "Failed to parse a docker parameter value. Expected .string_literal node", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.StringLiteralParseFailedDockerParameterValue => diag.fail("DockerModuleParameterValue", "Failed to parse a docker parameter value", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"parameters\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) exit.expectedly(error.DockerModuleDependenciesDuplicated, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => exit.expectedly(error.DockerModuleDependenciesUnexpectedType, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => exit.expectedly(error.DockerModuleDependenciesUnexpectedStruct, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedTokenDependency => exit.expectedly(error.DockerModuleDependencyUnexpectedToken, "Failed to parse a dependency identifier. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.StringLiteralParseFailedDependency => diag.fail("DockerModuleDependency", "Failed to parse a dependency identifier", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) exit.expectedly(error.DockerModuleVersionMissing, "Missing mandatory \"version\" field name", .{ .module = module_name });
        if (!have_endpoint) exit.expectedly(error.DockerModuleEndpointMissing, "Missing mandatory \"endpoint\" field name", .{ .module = module_name });
        if (!have_method) exit.expectedly(error.DockerModuleMethodMissing, "Missing mandatory \"method\" field name", .{ .module = module_name });

        scheduler.addRequestTask(module_name, jvFromAny(gpa, .{
            .docker = .{
                .version = version,
                .endpoint = endpoint,
                .method = std.meta.stringToEnum(std.http.Method, method) orelse exit.expectedly(error.DockerModuleMethodUnknown, "Unknown method. Possible values: " ++ std.fmt.comptimePrint("{any}", .{std.meta.tags(std.http.Method).*}), .{ .module = module_name, .method = method }),
                .parameters = std.json.ArrayHashMap([]const u8){
                    .map = parameters,
                },
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured when casting Zig object into jv object", .{ .module = module_name }),
        }, dependencies.items);
    }
};

const DockerBuildModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, diag: *StringLiteral.Diagnostic) void {
        var have_version = false;
        var have_ctx = false;
        var have_t = false;
        var have_parameters = false;
        var have_dependencies = false;
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
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.DockerBuildModuleUnexpectedType, "Expected docker build module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, diag) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.DockerBuildModuleUndeterminedFieldUnexpectedToken, "Invalid field name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(field_name_token),
                    }),
                    error.StringLiteralParseFailed => diag.fail("DockerBuildModuleUndeterminedField", "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) exit.expectedly(error.DockerBuildModuleVersionDuplicated, "Duplicated \"version\" field name", .{ .module = module_name });
                have_version = true;
                version = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.DockerBuildModuleVersionUnexpectedToken, "Failed to parse \"version\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseFailed => diag.fail("DockerBuildModuleVersion", "Failed to parse \"version\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"version\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "ctx")) {
                if (have_ctx) exit.expectedly(error.DockerBuildModuleCtxDuplicated, "Duplicated \"ctx\" field name", .{ .module = module_name });
                have_ctx = true;
                ctx_path = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.DockerBuildModuleCtxUnexpectedToken, "Failed to parse \"ctx\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseFailed => diag.fail("DockerBuildModuleCtx", "Failed to parse \"ctx\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"ctx\"", .{ .module = module_name }),
                    }
                };
                ctx = std.fs.path.resolve(gpa, &.{ctx_path}) catch |err| switch (err) {
                    error.OutOfMemory => exit.unexpectedly(err, "Occured when parsing \"ctx\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "t")) {
                if (have_t) exit.expectedly(error.DockerBuildModuleTDuplicated, "Duplicated \"t\" field name", .{ .module = module_name });
                have_t = true;
                t = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.DockerBuildModuleTUnexpectedToken, "Failed to parse \"t\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseFailed => diag.fail("DockerBuildModuleT", "Failed to parse \"t\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"t\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (have_parameters) exit.expectedly(error.DockerBuildModuleParametersDuplicated, "Duplicated \"parameters\" field name", .{ .module = module_name });
                have_parameters = true;
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDockerParametersType => exit.expectedly(error.DockerBuildModuleParametersUnexpectedType, "Expecting a struct when parsing docker parameters", .{ .module = module_name }),
                    error.UnexpectedTokenDockerParameterName => exit.expectedly(error.DockerBuildModuleParameterNameUnexpectedToken, "Failed to parse a docker parameter name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.StringLiteralParseFailedDockerParameterName => diag.fail("DockerBuildModuleParameterName", "Failed to parse a docker parameter name", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.UnexpectedNodeDockerParameterValue => exit.expectedly(error.DockerBuildModuleParameterValueUnexpectedNode, "Failed to parse a docker parameter value. Expected .string_literal node", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.StringLiteralParseFailedDockerParameterValue => diag.fail("DockerBuildModuleParameterValue", "Failed to parse a docker parameter value", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"parameters\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) exit.expectedly(error.DockerBuildModuleDependenciesDuplicated, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => exit.expectedly(error.DockerBuildModuleDependenciesUnexpectedType, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => exit.expectedly(error.DockerBuildModuleDependenciesUnexpectedStruct, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedTokenDependency => exit.expectedly(error.DockerBuildModuleDependencyUnexpectedToken, "Failed to parse a dependency identifier. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.StringLiteralParseFailedDependency => diag.fail("DockerBuildModuleDependency", "Failed to parse a dependency identifier", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) exit.expectedly(error.DockerBuildModuleVersionMissing, "Missing mandatory \"version\" field name", .{ .module = module_name });
        if (!have_ctx) exit.expectedly(error.DockerBuildModuleCtxMissing, "Missing mandatory \"ctx\" field name", .{ .module = module_name });
        if (!have_t) exit.expectedly(error.DockerBuildModuleTMissing, "Missing mandatory \"t\" field name", .{ .module = module_name });

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
            error.OutOfMemory => exit.unexpectedly(err, "Occured when casting Zig object into jv object", .{ .module = module_name }),
        }, dependencies.items);
    }
};

const JqModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, diag: *StringLiteral.Diagnostic) void {
        var have_filter = false;
        var have_dependencies = false;
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
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.JqModuleUnexpectedType, "Expected jq module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, diag) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.JqModuleUndeterminedFieldUnexpectedToken, "Invalid field name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(field_name_token),
                    }),
                    error.StringLiteralParseFailed => diag.fail("JqModuleUndeterminedField", "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "filter")) {
                if (have_filter) exit.expectedly(error.JqModuleFilterDuplicated, "Duplicated \"filter\" field name", .{ .module = module_name });
                have_filter = true;
                filter = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.JqModuleFilterUnexpectedToken, "Failed to parse \"filter\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseFailed => diag.fail("JqModuleFilter", "Failed to parse \"filter\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"filter\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) exit.expectedly(error.JqModuleDependenciesDuplicated, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => exit.expectedly(error.JqModuleDependenciesUnexpectedType, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => exit.expectedly(error.JqModuleDependenciesUnexpectedStruct, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedTokenDependency => exit.expectedly(error.JqModuleDependencyUnexpectedToken, "Failed to parse a dependency identifier. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.StringLiteralParseFailedDependency => diag.fail("JqModuleDependency", "Failed to parse a dependency identifier", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_filter) exit.expectedly(error.JqModuleFilterMissing, "Missing mandatory \"filter\" field name", .{ .module = module_name });

        scheduler.addJSONQueryTask(module_name, filter, dependencies.items);
    }
};

const Module = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, diag: *StringLiteral.Diagnostic) void {
        if (std.mem.findScalar(u8, module_name, '/') == null) exit.expectedly(error.ModuleNameMissingSlash, "A module identifier must contain a slash character between module type and module id", .{ .module = module_name });

        if (std.mem.startsWith(u8, module_name, "jq/")) {
            JqModule.parse(gpa, ast, node, module_name, diag);
        } else if (std.mem.startsWith(u8, module_name, "docker/")) {
            DockerModule.parse(gpa, ast, node, module_name, diag);
        } else if (std.mem.startsWith(u8, module_name, "docker_build/")) {
            DockerBuildModule.parse(gpa, ast, node, module_name, diag);
        } else exit.expectedly(error.ModuleTypeUnknown, "Unknown module type", .{ .module = module_name });
    }
};

const Rule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, rule_name: []const u8, diag: *StringLiteral.Diagnostic) void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.RuleUnexpectedType, "Expected rule to be a struct", .{ .rule = rule_name });

        for (0..struct_init.ast.fields.len) |i| {
            const module_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const module_name = Identifier.parse(gpa, ast, module_name_token, diag) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.RuleUndeterminedModuleUnexpectedToken, "Invalid module name. Expected .identifier token", .{
                        .rule = rule_name,
                        .token = ast.tokenTag(module_name_token),
                    }),
                    error.StringLiteralParseFailed => diag.fail("RuleUndeterminedModule", "Invalid module name", .{ .rule = rule_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined module name", .{ .rule = rule_name }),
                }
            };
            defer gpa.free(module_name);
            Module.parse(gpa, ast, struct_init.ast.fields[i], module_name, diag);
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
            error.FileNotFound => exit.expectedly(error.SpecMissingManaZon, "Did not found mana.zon", .{}),
            else => exit.unexpectedly(err, "Occured when reading " ++ source_path, .{}),
        };
        defer self.gpa.free(source);

        var ast = std.zig.Ast.parse(self.gpa, source, .{ .mode = .zon }) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured during Zon Ast parsing", .{}),
        };
        defer ast.deinit(self.gpa);
        if (ast.errors.len > 0) std.zig.printAstErrorsToStderr(self.gpa, self.io, ast, source_path, .auto) catch |err| exit.unexpectedly(err, "Occured during Zon Ast errors printing", .{});

        const node = ast.nodeData(.root).node;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.SpecUnexpectedType, "Expected top level to be a struct", .{});

        var diag: StringLiteral.Diagnostic = undefined;
        diag.buf = .empty;
        defer diag.buf.deinit(self.gpa);

        for (0..struct_init.ast.fields.len) |i| {
            const rule_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const rule_name = Identifier.parse(self.gpa, ast, rule_name_token, &diag) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.SpecUndeterminedRuleUnexpectedToken, "Invalid rule name. Expected .identifier token", .{
                        .token = ast.tokenTag(rule_name_token),
                    }),
                    error.StringLiteralParseFailed => diag.fail("SpecUndeterminedRule", "Invalid rule name", .{}),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined rule name", .{}),
                }
            };
            defer self.gpa.free(rule_name);
            if (std.mem.eql(u8, executed_rule, rule_name)) Rule.parse(self.gpa, ast, struct_init.ast.fields[i], rule_name, &diag);
        }

        scheduler.run();
    }
};
