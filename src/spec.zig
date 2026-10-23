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

    fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, token: std.zig.Ast.TokenIndex, str_buf: *std.ArrayList(u8)) ParsingError![]const u8 {
        const token_tag = ast.tokenTag(token);
        if (token_tag != .identifier) return error.UnexpectedToken;
        const ident_name = ast.tokenSlice(token);
        if (!std.mem.startsWith(u8, ident_name, "@")) return gpa.dupe(u8, ident_name);
        str_buf.clearRetainingCapacity();
        try StringLiteral.parse(gpa, str_buf, ident_name, 1);
        return gpa.dupe(u8, str_buf.items);
    }
};

const String = struct {
    const ParsingError = error{
        UnexpectedNode,
    } || std.mem.Allocator.Error || StringLiteral.ParsingError;

    fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, str_buf: *std.ArrayList(u8)) ParsingError![]const u8 {
        const node_tag = ast.nodeTag(node);
        if (node_tag != .string_literal) return error.UnexpectedNode;
        const str_lit_token = ast.nodeMainToken(node);
        const token_bytes = ast.tokenSlice(str_lit_token);
        str_buf.clearRetainingCapacity();
        try StringLiteral.parse(gpa, str_buf, token_bytes, 0);
        return gpa.dupe(u8, str_buf.items);
    }
};

const StringLiteral = struct {
    const ParsingError = error{
        StringLiteralParseWriteFailed,
    } || std.Io.Writer.Error;

    fn parse(gpa: std.mem.Allocator, str_buf: *std.ArrayList(u8), bytes: []const u8, offset: u32) ParsingError!void {
        const raw_string = bytes[offset..];
        const result = r: {
            var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, str_buf);
            defer str_buf.* = aw.toArrayList();
            break :r try std.zig.string_literal.parseWrite(&aw.writer, raw_string);
        };
        switch (result) {
            .success => {},
            .failure => |err| {
                std.log.err("{f}", .{err.fmt(raw_string)}); //TODO: remove this
                return error.StringLiteralParseWriteFailed;
            },
        }
    }
};

const Dependencies = struct {
    const ParsingError = error{
        UnexpectedDependenciesType,
        UnexpectedDependenciesStruct,
        UnexpectedTokenDependencyIdentifier,
        StringLiteralParseWriteFailedDependencyIdentifier,
    } || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, dependencies: *std.ArrayList([]const u8), str_buf: *std.ArrayList(u8), err_node: *std.zig.Ast.Node.Index) ParsingError!void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const array_init = ast.fullArrayInit(&buf, node) orelse {
            const struct_init = ast.fullStructInit(&buf, node) orelse return error.UnexpectedDependenciesType;
            if (struct_init.ast.fields.len > 0) return error.UnexpectedDependenciesStruct;
            return;
        };

        for (0..array_init.ast.elements.len) |i| {
            const dep_name_token = ast.firstToken(array_init.ast.elements[i]) + 1;
            const dep_name = Identifier.parse(gpa, ast, dep_name_token, str_buf) catch |err| {
                err_node.* = array_init.ast.elements[i];
                switch (err) {
                    error.UnexpectedToken => return error.UnexpectedTokenDependencyIdentifier,
                    error.StringLiteralParseWriteFailed => return error.StringLiteralParseWriteFailedDependencyIdentifier,
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
        UnexpectedTokenDockerParameterNameIdentifier,
        StringLiteralParseWriteFailedDockerParameterNameIdentifier,
        UnexpectedNodeDockerParameterValueString,
        StringLiteralParseWriteFailedDockerParameterValueString,
    } || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, parameters: *std.array_hash_map.String([]const u8), str_buf: *std.ArrayList(u8), err_node: *std.zig.Ast.Node.Index) ParsingError!void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse return error.UnexpectedDockerParametersType;

        for (0..struct_init.ast.fields.len) |i| {
            const param_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const param_name = Identifier.parse(gpa, ast, param_name_token, str_buf) catch |err| {
                err_node.* = struct_init.ast.fields[i];
                switch (err) {
                    error.UnexpectedToken => return error.UnexpectedTokenDockerParameterNameIdentifier,
                    error.StringLiteralParseWriteFailed => return error.StringLiteralParseWriteFailedDockerParameterNameIdentifier,
                    error.OutOfMemory, error.WriteFailed => |e| return e,
                }
            };
            const param_value = String.parse(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| {
                err_node.* = struct_init.ast.fields[i];
                switch (err) {
                    error.UnexpectedNode => return error.UnexpectedNodeDockerParameterValueString,
                    error.StringLiteralParseWriteFailed => return error.StringLiteralParseWriteFailedDockerParameterValueString,
                    error.OutOfMemory, error.WriteFailed => |e| return e,
                }
            };
            try parameters.put(gpa, param_name, param_value);
        }
    }
};

const DockerModule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
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
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.UnexpectedTypeDockerModule, "Expected docker module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, str_buf) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.UnexpectedTokenForUndeterminedFieldIntoDockerModule, "Invalid field name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(field_name_token),
                    }),
                    error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForUndeterminedFieldIntoDockerModule, "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) exit.expectedly(error.DuplicatedVersionIntoDockerModule, "Duplicated \"version\" field name", .{ .module = module_name });
                have_version = true;
                version = String.parse(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.UnexpectedTokenForVersionIntoDockerModule, "Failed to parse \"version\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForVersionIntoDockerModule, "Failed to parse \"version\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"version\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "endpoint")) {
                if (have_endpoint) exit.expectedly(error.DuplicatedEndpointIntoDockerModule, "Duplicated \"endpoint\" field name", .{ .module = module_name });
                have_endpoint = true;
                endpoint = String.parse(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.UnexpectedTokenForEndpointIntoDockerModule, "Failed to parse \"endpoint\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForEndpointIntoDockerModule, "Failed to parse \"endpoint\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"endpoint\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "method")) {
                if (have_method) exit.expectedly(error.DuplicatedMethodIntoDockerModule, "Duplicated \"method\" field name", .{ .module = module_name });
                have_method = true;
                const method_name_token = ast.firstToken(struct_init.ast.fields[i]) + 1;
                method = Identifier.parse(gpa, ast, method_name_token, str_buf) catch |err| {
                    switch (err) {
                        error.UnexpectedToken => exit.expectedly(error.UnexpectedTokenForMethodIntoDockerModule, "Failed to parse \"method\". Expected .identifier token", .{
                            .module = module_name,
                            .token = ast.tokenTag(method_name_token),
                        }),
                        error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForMethodIntoDockerModule, "Failed to parse \"method\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"method\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (have_parameters) exit.expectedly(error.DuplicatedParametersIntoDockerModule, "Duplicated \"parameters\" field name", .{ .module = module_name });
                have_parameters = true;
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, str_buf, &err_node) catch |err| switch (err) {
                    error.UnexpectedDockerParametersType => exit.expectedly(error.UnexpectedDockerParametersTypeIntoDockerModule, "Expecting a struct when parsing docker parameters", .{ .module = module_name }),
                    error.UnexpectedTokenDockerParameterNameIdentifier => exit.expectedly(error.UnexpectedTokenDockerParameterNameIdentifierIntoDockerModule, "Failed to parse a docker parameter key. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.StringLiteralParseWriteFailedDockerParameterNameIdentifier => exit.expectedly(error.StringLiteralParseWriteFailedDockerParameterNameIdentifierIntoDockerModule, "Failed to parse a docker parameter key", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.UnexpectedNodeDockerParameterValueString => exit.expectedly(error.UnexpectedNodeDockerParameterValueStringIntoDockerModule, "Failed to parse a docker parameter value. Expected .string_literal node", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.StringLiteralParseWriteFailedDockerParameterValueString => exit.expectedly(error.StringLiteralParseWriteFailedDockerParameterValueStringIntoDockerModule, "Failed to parse a docker parameter value", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"parameters\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) exit.expectedly(error.DuplicatedDependenciesIntoDockerModule, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => exit.expectedly(error.UnexpectedDependenciesTypeIntoDockerModule, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => exit.expectedly(error.UnexpectedDependenciesStructIntoDockerModule, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedTokenDependencyIdentifier => exit.expectedly(error.UnexpectedTokenDependencyIdentifierIntoDockerModule, "Failed to parse a dependency identifier. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.StringLiteralParseWriteFailedDependencyIdentifier => exit.expectedly(error.StringLiteralParseWriteFailedDependencyIdentifierIntoDockerModule, "Failed to parse a dependency identifier", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) exit.expectedly(error.MissingVersionIntoDockerModule, "Missing mandatory \"version\" field name", .{ .module = module_name });
        if (!have_endpoint) exit.expectedly(error.MissingEndpointIntoDockerModule, "Missing mandatory \"endpoint\" field name", .{ .module = module_name });
        if (!have_method) exit.expectedly(error.MissingMethodIntoDockerModule, "Missing mandatory \"method\" field name", .{ .module = module_name });

        scheduler.addRequestTask(module_name, jvFromAny(gpa, .{
            .docker = .{
                .version = version,
                .endpoint = endpoint,
                .method = std.meta.stringToEnum(std.http.Method, method) orelse exit.expectedly(error.InvalidMethodIntoDockerModule, "Invalid method. Possible values: " ++ std.fmt.comptimePrint("{any}", .{std.meta.tags(std.http.Method).*}), .{ .module = module_name, .method = method }),
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
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
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
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.UnexpectedTypeDockerBuildModule, "Expected docker build module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, str_buf) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.UnexpectedTokenForUndeterminedFieldIntoDockerBuildModule, "Invalid field name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(field_name_token),
                    }),
                    error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForUnUndetermineFieldIntoDockerBuildModule, "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) exit.expectedly(error.DuplicatedVersionIntoDockerBuildModule, "Duplicated \"version\" field name", .{ .module = module_name });
                have_version = true;
                version = String.parse(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.UnexpectedTokenForVersionIntoDockerBuildModule, "Failed to parse \"version\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForVersionIntoDockerBuildModule, "Failed to parse \"version\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"version\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "ctx")) {
                if (have_ctx) exit.expectedly(error.DuplicatedCtxIntoDockerBuildModule, "Duplicated \"ctx\" field name", .{ .module = module_name });
                have_ctx = true;
                ctx_path = String.parse(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.UnexpectedTokenForCtxIntoDockerBuildModule, "Failed to parse \"ctx\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForCtxIntoDockerBuildModule, "Failed to parse \"ctx\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"ctx\"", .{ .module = module_name }),
                    }
                };
                ctx = std.fs.path.resolve(gpa, &.{ctx_path}) catch |err| switch (err) {
                    error.OutOfMemory => exit.unexpectedly(err, "Occured when parsing \"ctx\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "t")) {
                if (have_t) exit.expectedly(error.DuplicatedTIntoDockerBuildModule, "Duplicated \"t\" field name", .{ .module = module_name });
                have_t = true;
                t = String.parse(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.UnexpectedTokenForTIntoDockerBuildModule, "Failed to parse \"t\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForTIntoDockerBuildModule, "Failed to parse \"t\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"t\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (have_parameters) exit.expectedly(error.DuplicatedParametersIntoDockerBuildModule, "Duplicated \"parameters\" field name", .{ .module = module_name });
                have_parameters = true;
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, str_buf, &err_node) catch |err| switch (err) {
                    error.UnexpectedDockerParametersType => exit.expectedly(error.UnexpectedDockerParametersTypeIntoDockerBuildModule, "Expecting a struct when parsing docker parameters", .{ .module = module_name }),
                    error.UnexpectedTokenDockerParameterNameIdentifier => exit.expectedly(error.UnexpectedTokenDockerParameterNameIdentifierIntoDockerBuildModule, "Failed to parse a docker parameter key. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.StringLiteralParseWriteFailedDockerParameterNameIdentifier => exit.expectedly(error.StringLiteralParseWriteFailedDockerParameterNameIdentifierIntoDockerBuildModule, "Failed to parse a docker parameter key", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) - 2),
                    }),
                    error.UnexpectedNodeDockerParameterValueString => exit.expectedly(error.UnexpectedNodeDockerParameterValueStringIntoDockerBuildModule, "Failed to parse a docker parameter value. Expected .string_literal node", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.StringLiteralParseWriteFailedDockerParameterValueString => exit.expectedly(error.StringLiteralParseWriteFailedDockerParameterValueStringIntoDockerBuildModule, "Failed to parse a docker parameter value", .{
                        .module = module_name,
                        .node = ast.nodeTag(err_node),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"parameters\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) exit.expectedly(error.DuplicatedDependenciesIntoDockerBuildModule, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => exit.expectedly(error.UnexpectedDependenciesTypeIntoDockerBuildModule, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => exit.expectedly(error.UnexpectedDependenciesStructIntoDockerBuildModule, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedTokenDependencyIdentifier => exit.expectedly(error.UnexpectedTokenDependencyIdentifierIntoDockerBuildModule, "Failed to parse a dependency identifier. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.StringLiteralParseWriteFailedDependencyIdentifier => exit.expectedly(error.StringLiteralParseWriteFailedDependencyIdentifierIntoDockerBuildModule, "Failed to parse a dependency identifier", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_version) exit.expectedly(error.MissingVersionIntoDockerBuildModule, "Missing mandatory \"version\" field name", .{ .module = module_name });
        if (!have_ctx) exit.expectedly(error.MissingCtxIntoDockerBuildModule, "Missing mandatory \"ctx\" field name", .{ .module = module_name });
        if (!have_t) exit.expectedly(error.MissingTIntoDockerBuildModule, "Missing mandatory \"t\" field name", .{ .module = module_name });

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
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
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
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.UnexpectedTypeJqModule, "Expected jq module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, str_buf) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.UnexpectedTokenForUndeterminedFieldIntoJqModule, "Invalid field name. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(field_name_token),
                    }),
                    error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForUndeterminedFieldIntoJqModule, "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "filter")) {
                if (have_filter) exit.expectedly(error.DuplicatedFilterIntoJqModule, "Duplicated \"filter\" field name", .{ .module = module_name });
                have_filter = true;
                filter = String.parse(gpa, ast, struct_init.ast.fields[i], str_buf) catch |err| {
                    switch (err) {
                        error.UnexpectedNode => exit.expectedly(error.UnexpectedTokenForFilterIntoJqModule, "Failed to parse \"filter\". Expected .string_literal node", .{
                            .module = module_name,
                            .node = ast.nodeTag(struct_init.ast.fields[i]),
                        }),
                        error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedForFilterIntoJqModule, "Failed to parse \"filter\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"filter\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) exit.expectedly(error.DuplicatedDependenciesIntoJqModule, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, str_buf, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => exit.expectedly(error.UnexpectedDependenciesTypeIntoJqModule, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => exit.expectedly(error.UnexpectedDependenciesStructIntoJqModule, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedTokenDependencyIdentifier => exit.expectedly(error.UnexpectedTokenDependencyIdentifierIntoJqModule, "Failed to parse a dependency identifier. Expected .identifier token", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.StringLiteralParseWriteFailedDependencyIdentifier => exit.expectedly(error.StringLiteralParseWriteFailedDependencyIdentifierIntoJqModule, "Failed to parse a dependency identifier", .{
                        .module = module_name,
                        .token = ast.tokenTag(ast.firstToken(err_node) + 1),
                    }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else std.log.warn("Unknown \"{s}\" field into \"{s}\" module", .{ field_name, module_name });
        }

        if (!have_filter) exit.expectedly(error.MissingFilterIntoJqModule, "Missing mandatory \"filter\" field name", .{ .module = module_name });

        scheduler.addJSONQueryTask(module_name, filter, dependencies.items);
    }
};

const Module = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, str_buf: *std.ArrayList(u8)) void {
        if (std.mem.findScalar(u8, module_name, '/') == null) exit.expectedly(error.MissingSlashIntoModuleName, "A module identifier must contain a slash character between module type and module id", .{ .module = module_name });

        if (std.mem.startsWith(u8, module_name, "jq/")) {
            JqModule.parse(gpa, ast, node, module_name, str_buf);
        } else if (std.mem.startsWith(u8, module_name, "docker/")) {
            DockerModule.parse(gpa, ast, node, module_name, str_buf);
        } else if (std.mem.startsWith(u8, module_name, "docker_build/")) {
            DockerBuildModule.parse(gpa, ast, node, module_name, str_buf);
        } else exit.expectedly(error.UnknownModuleType, "Unknown module type", .{ .module = module_name });
    }
};

const Rule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, rule_name: []const u8, str_buf: *std.ArrayList(u8)) void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.UnexpectedTypeRule, "Expected rule to be a struct", .{ .rule = rule_name });

        for (0..struct_init.ast.fields.len) |i| {
            const module_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const module_name = Identifier.parse(gpa, ast, module_name_token, str_buf) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.UnexpectedTokenIntoUndeterminedModuleName, "Invalid module name. Expected .identifier token", .{
                        .rule = rule_name,
                        .token = ast.tokenTag(module_name_token),
                    }),
                    error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedIntoUndeterminedModuleName, "Invalid module name", .{ .rule = rule_name }),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined module name", .{ .rule = rule_name }),
                }
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
            error.FileNotFound => exit.expectedly(error.MissingManaZon, "Did not found mana.zon", .{}),
            else => exit.unexpectedly(err, "Occured when reading " ++ source_path, .{}),
        };
        defer self.gpa.free(source);

        var ast = std.zig.Ast.parse(self.gpa, source, .{ .mode = .zon }) catch |err| switch (err) {
            error.OutOfMemory => exit.unexpectedly(err, "Occured during Zon Ast parsing", .{}),
        };
        defer ast.deinit(self.gpa);
        if (ast.errors.len > 0) std.zig.printAstErrorsToStderr(self.gpa, self.io, ast, source_path, .auto) catch |err| exit.unexpectedly(err, "Occured during Zon Ast errors printing", .{});

        var str_buf: std.ArrayList(u8) = .empty;
        defer str_buf.deinit(self.gpa);
        const node = ast.nodeData(.root).node;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse exit.expectedly(error.UnexpectedTypeRoot, "Expected top level to be a struct", .{});

        for (0..struct_init.ast.fields.len) |i| {
            const rule_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const rule_name = Identifier.parse(self.gpa, ast, rule_name_token, &str_buf) catch |err| {
                switch (err) {
                    error.UnexpectedToken => exit.expectedly(error.UnexpectedTokenIntoUndeterminedRuleName, "Invalid rule name. Expected .identifier token", .{
                        .token = ast.tokenTag(rule_name_token),
                    }),
                    error.StringLiteralParseWriteFailed => exit.expectedly(error.StringLiteralParseWriteFailedIntoUndeterminedModuleName, "Invalid rule name", .{}),
                    error.OutOfMemory, error.WriteFailed => exit.unexpectedly(err, "Occured when parsing an undetermined rule name", .{}),
                }
            };
            defer self.gpa.free(rule_name);
            if (std.mem.eql(u8, executed_rule, rule_name)) Rule.parse(self.gpa, ast, struct_init.ast.fields[i], rule_name, &str_buf);
        }

        scheduler.run();
    }
};
