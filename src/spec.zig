const std = @import("std");
const log = @import("log");
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
    const ParsingError = std.mem.Allocator.Error || StringLiteral.ParsingError;

    fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, token: std.zig.Ast.TokenIndex, diag: *StringLiteral.Diagnostic) ParsingError![]const u8 {
        const token_tag = ast.tokenTag(token);
        std.debug.assert(token_tag == .identifier);
        const ident_name = ast.tokenSlice(token);
        if (!std.mem.startsWith(u8, ident_name, "@")) return gpa.dupe(u8, ident_name);
        try StringLiteral.parse(gpa, ident_name, 1, diag);
        return gpa.dupe(u8, diag.buf.items);
    }
};

const String = struct {
    const ParsingError = std.mem.Allocator.Error || StringLiteral.ParsingError;

    fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, diag: *StringLiteral.Diagnostic) ParsingError![]const u8 {
        const node_tag = ast.nodeTag(node);
        std.debug.assert(node_tag == .string_literal);
        const str_lit_token = ast.nodeMainToken(node);
        const token_bytes = ast.tokenSlice(str_lit_token);
        try StringLiteral.parse(gpa, token_bytes, 0, diag);
        return gpa.dupe(u8, diag.buf.items);
    }
};

const StringLiteral = struct {
    const ParsingError = error{StringLiteralParseFailed} || std.mem.Allocator.Error || std.Io.Writer.Error;

    const Diagnostic = struct {
        result: std.zig.string_literal.Result = .success,
        raw_str: []const u8 = "",
        buf: std.ArrayList(u8) = .empty,

        fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(self.raw_str);
            self.buf.deinit(gpa);
        }

        fn fail(self: @This(), comptime prefix: [:0]const u8, comptime msg: []const u8, details: anytype) noreturn {
            std.debug.assert(std.meta.activeTag(@typeInfo(@TypeOf(details))) == .@"struct");
            const Details = @typeInfo(@TypeOf(details)).@"struct";
            const DiagDetails = @Struct(
                Details.layout,
                Details.backing_integer,
                Details.field_names ++ &[_][]const u8{"diagnostic"},
                Details.field_types ++ &[_]type{[]const []const u8},
                Details.field_attrs ++ &[_]std.lang.Type.Struct.FieldAttributes{.{}},
            );
            var buf: [124]u8 = undefined;
            var diag_and_details: DiagDetails = undefined;
            switch (self.result) {
                .success => unreachable,
                .failure => |err| {
                    diag_and_details.diagnostic = &.{std.mem.print(&buf, "{f}", .{err.fmt(self.raw_str)}) catch unreachable};

                    inline for (Details.field_names) |field_name| @field(diag_and_details, field_name) = @field(details, field_name);
                    switch (err) {
                        inline else => |_, tag| log.exitExpectedly(@field(anyerror, error_name: {
                            const tagname = @tagName(tag);
                            var name: [tagname.len:0]u8 = undefined;
                            var i = std.math.minInt(usize);
                            var j = std.math.minInt(usize);
                            while (i < tagname.len) {
                                switch (tagname[i]) {
                                    'a'...'z' => name[j] = if (i == std.math.minInt(usize)) std.ascii.toUpper(tagname[i]) else tagname[i],
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
                        }), msg, diag_and_details),
                    }
                },
            }
        }
    };

    fn parse(gpa: std.mem.Allocator, bytes: []const u8, offset: u32, diag: *Diagnostic) ParsingError!void {
        diag.buf.clearRetainingCapacity();
        if (diag.raw_str.len > 0) gpa.free(diag.raw_str);
        diag.raw_str = try gpa.dupe(u8, bytes[offset..]);
        diag.result = r: {
            var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &diag.buf);
            defer diag.buf = aw.toArrayList();
            break :r try std.zig.string_literal.parseWrite(&aw.writer, diag.raw_str);
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
        StringLiteralParseFailedDockerParameterName,
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
                    error.StringLiteralParseFailed => return error.StringLiteralParseFailedDockerParameterName,
                    error.OutOfMemory, error.WriteFailed => |e| return e,
                }
            };
            const param_value = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                err_node.* = struct_init.ast.fields[i];
                switch (err) {
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
        const struct_init = ast.fullStructInit(&buf, node) orelse log.exitExpectedly(error.DockerModuleUnexpectedType, "Expected docker module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, diag) catch |err| {
                switch (err) {
                    error.StringLiteralParseFailed => diag.fail("DockerModuleUndeterminedField", "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) log.exitExpectedly(error.DockerModuleVersionDuplicated, "Duplicated \"version\" field name", .{ .module = module_name });
                have_version = true;
                version = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.StringLiteralParseFailed => diag.fail("DockerModuleVersion", "Failed to parse \"version\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"version\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "endpoint")) {
                if (have_endpoint) log.exitExpectedly(error.DockerModuleEndpointDuplicated, "Duplicated \"endpoint\" field name", .{ .module = module_name });
                have_endpoint = true;
                endpoint = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.StringLiteralParseFailed => diag.fail("DockerModuleEndpoint", "Failed to parse \"endpoint\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"endpoint\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "method")) {
                if (have_method) log.exitExpectedly(error.DockerModuleMethodDuplicated, "Duplicated \"method\" field name", .{ .module = module_name });
                have_method = true;
                const method_name_token = ast.firstToken(struct_init.ast.fields[i]) + 1;
                method = Identifier.parse(gpa, ast, method_name_token, diag) catch |err| {
                    switch (err) {
                        error.StringLiteralParseFailed => diag.fail("DockerModuleMethod", "Failed to parse \"method\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"method\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (have_parameters) log.exitExpectedly(error.DockerModuleParametersDuplicated, "Duplicated \"parameters\" field name", .{ .module = module_name });
                have_parameters = true;
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDockerParametersType => log.exitExpectedly(error.DockerModuleParametersUnexpectedType, "Expecting a struct when parsing docker parameters", .{ .module = module_name }),
                    error.StringLiteralParseFailedDockerParameterName => diag.fail("DockerModuleParameterName", "Failed to parse a docker parameter name", .{ .module = module_name }),
                    error.StringLiteralParseFailedDockerParameterValue => diag.fail("DockerModuleParameterValue", "Failed to parse a docker parameter value", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"parameters\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) log.exitExpectedly(error.DockerModuleDependenciesDuplicated, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => log.exitExpectedly(error.DockerModuleDependenciesUnexpectedType, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => log.exitExpectedly(error.DockerModuleDependenciesUnexpectedStruct, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.StringLiteralParseFailedDependency => diag.fail("DockerModuleDependency", "Failed to parse a dependency identifier", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else log.warn(error.DockerModuleUnknownField, "Unknown field", .{
                .field = field_name,
                .module = module_name,
            });
        }

        if (!have_version) log.exitExpectedly(error.DockerModuleVersionMissing, "Missing mandatory \"version\" field name", .{ .module = module_name });
        if (!have_endpoint) log.exitExpectedly(error.DockerModuleEndpointMissing, "Missing mandatory \"endpoint\" field name", .{ .module = module_name });
        if (!have_method) log.exitExpectedly(error.DockerModuleMethodMissing, "Missing mandatory \"method\" field name", .{ .module = module_name });

        scheduler.addRequestTask(module_name, jvFromAny(gpa, .{
            .docker = .{
                .version = version,
                .endpoint = endpoint,
                .method = std.meta.stringToEnum(std.http.Method, method) orelse log.exitExpectedly(error.DockerModuleMethodUnknown, "Unknown method. Possible values: " ++ std.fmt.comptimePrint("{any}", .{std.meta.tags(std.http.Method).*}), .{ .module = module_name, .method = method }),
                .parameters = std.json.ArrayHashMap([]const u8){
                    .map = parameters,
                },
            },
        }) catch |err| switch (err) {
            error.OutOfMemory => log.exitUnexpectedly(err, "Occured when casting Zig object into jv object", .{ .module = module_name }),
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
        const struct_init = ast.fullStructInit(&buf, node) orelse log.exitExpectedly(error.DockerBuildModuleUnexpectedType, "Expected docker build module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, diag) catch |err| {
                switch (err) {
                    error.StringLiteralParseFailed => diag.fail("DockerBuildModuleUndeterminedField", "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "version")) {
                if (have_version) log.exitExpectedly(error.DockerBuildModuleVersionDuplicated, "Duplicated \"version\" field name", .{ .module = module_name });
                have_version = true;
                version = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.StringLiteralParseFailed => diag.fail("DockerBuildModuleVersion", "Failed to parse \"version\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"version\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "ctx")) {
                if (have_ctx) log.exitExpectedly(error.DockerBuildModuleCtxDuplicated, "Duplicated \"ctx\" field name", .{ .module = module_name });
                have_ctx = true;
                ctx_path = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.StringLiteralParseFailed => diag.fail("DockerBuildModuleCtx", "Failed to parse \"ctx\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"ctx\"", .{ .module = module_name }),
                    }
                };
                ctx = std.fs.path.resolve(gpa, &.{ctx_path}) catch |err| switch (err) {
                    error.OutOfMemory => log.exitUnexpectedly(err, "Occured when parsing \"ctx\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "t")) {
                if (have_t) log.exitExpectedly(error.DockerBuildModuleTDuplicated, "Duplicated \"t\" field name", .{ .module = module_name });
                have_t = true;
                t = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.StringLiteralParseFailed => diag.fail("DockerBuildModuleT", "Failed to parse \"t\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"t\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                if (have_parameters) log.exitExpectedly(error.DockerBuildModuleParametersDuplicated, "Duplicated \"parameters\" field name", .{ .module = module_name });
                have_parameters = true;
                DockerParameters.parse(gpa, ast, struct_init.ast.fields[i], &parameters, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDockerParametersType => log.exitExpectedly(error.DockerBuildModuleParametersUnexpectedType, "Expecting a struct when parsing docker parameters", .{ .module = module_name }),
                    error.StringLiteralParseFailedDockerParameterName => diag.fail("DockerBuildModuleParameterName", "Failed to parse a docker parameter name", .{ .module = module_name }),
                    error.StringLiteralParseFailedDockerParameterValue => diag.fail("DockerBuildModuleParameterValue", "Failed to parse a docker parameter value", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"parameters\"", .{ .module = module_name }),
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) log.exitExpectedly(error.DockerBuildModuleDependenciesDuplicated, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => log.exitExpectedly(error.DockerBuildModuleDependenciesUnexpectedType, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => log.exitExpectedly(error.DockerBuildModuleDependenciesUnexpectedStruct, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.StringLiteralParseFailedDependency => diag.fail("DockerBuildModuleDependency", "Failed to parse a dependency identifier", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else log.warn(error.DockerBuildModuleUnknownField, "Unknown field", .{
                .field = field_name,
                .module = module_name,
            });
        }

        if (!have_version) log.exitExpectedly(error.DockerBuildModuleVersionMissing, "Missing mandatory \"version\" field name", .{ .module = module_name });
        if (!have_ctx) log.exitExpectedly(error.DockerBuildModuleCtxMissing, "Missing mandatory \"ctx\" field name", .{ .module = module_name });
        if (!have_t) log.exitExpectedly(error.DockerBuildModuleTMissing, "Missing mandatory \"t\" field name", .{ .module = module_name });

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
            error.OutOfMemory => log.exitUnexpectedly(err, "Occured when casting Zig object into jv object", .{ .module = module_name }),
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
        const struct_init = ast.fullStructInit(&buf, node) orelse log.exitExpectedly(error.JqModuleUnexpectedType, "Expected jq module to be a struct", .{ .module = module_name });
        var err_node: std.zig.Ast.Node.Index = undefined;

        for (0..struct_init.ast.fields.len) |i| {
            const field_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const field_name = Identifier.parse(gpa, ast, field_name_token, diag) catch |err| {
                switch (err) {
                    error.StringLiteralParseFailed => diag.fail("JqModuleUndeterminedField", "Invalid field name", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing an undetermined field name", .{ .module = module_name }),
                }
            };
            defer gpa.free(field_name);

            if (std.mem.eql(u8, field_name, "filter")) {
                if (have_filter) log.exitExpectedly(error.JqModuleFilterDuplicated, "Duplicated \"filter\" field name", .{ .module = module_name });
                have_filter = true;
                filter = String.parse(gpa, ast, struct_init.ast.fields[i], diag) catch |err| {
                    switch (err) {
                        error.StringLiteralParseFailed => diag.fail("JqModuleFilter", "Failed to parse \"filter\"", .{ .module = module_name }),
                        error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"filter\"", .{ .module = module_name }),
                    }
                };
            } else if (std.mem.eql(u8, field_name, "dependencies")) {
                if (have_dependencies) log.exitExpectedly(error.JqModuleDependenciesDuplicated, "Duplicated \"dependencies\" field name", .{ .module = module_name });
                have_dependencies = true;
                Dependencies.parse(gpa, ast, struct_init.ast.fields[i], &dependencies, diag, &err_node) catch |err| switch (err) {
                    error.UnexpectedDependenciesType => log.exitExpectedly(error.JqModuleDependenciesUnexpectedType, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.UnexpectedDependenciesStruct => log.exitExpectedly(error.JqModuleDependenciesUnexpectedStruct, "Expecting an array when parsing \"dependencies\"", .{ .module = module_name }),
                    error.StringLiteralParseFailedDependency => diag.fail("JqModuleDependency", "Failed to parse a dependency identifier", .{ .module = module_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing \"dependencies\"", .{ .module = module_name }),
                };
            } else log.warn(error.JqModuleUnknownField, "Unknown field", .{
                .field = field_name,
                .module = module_name,
            });
        }

        if (!have_filter) log.exitExpectedly(error.JqModuleFilterMissing, "Missing mandatory \"filter\" field name", .{ .module = module_name });

        scheduler.addJSONQueryTask(module_name, filter, dependencies.items);
    }
};

const Module = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, module_name: []const u8, diag: *StringLiteral.Diagnostic) void {
        if (std.mem.findScalar(u8, module_name, '/') == null) log.exitExpectedly(error.ModuleNameMissingSlash, "A module identifier must contain a slash character between module type and module id", .{ .module = module_name });

        if (std.mem.startsWith(u8, module_name, "jq/")) {
            JqModule.parse(gpa, ast, node, module_name, diag);
        } else if (std.mem.startsWith(u8, module_name, "docker/")) {
            DockerModule.parse(gpa, ast, node, module_name, diag);
        } else if (std.mem.startsWith(u8, module_name, "docker-build/")) {
            DockerBuildModule.parse(gpa, ast, node, module_name, diag);
        } else log.exitExpectedly(error.ModuleTypeUnknown, "Unknown module type", .{ .module = module_name });
    }
};

const Rule = struct {
    pub fn parse(gpa: std.mem.Allocator, ast: std.zig.Ast, node: std.zig.Ast.Node.Index, rule_name: []const u8, diag: *StringLiteral.Diagnostic) void {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse log.exitExpectedly(error.RuleUnexpectedType, "Expected rule to be a struct", .{ .rule = rule_name });

        for (0..struct_init.ast.fields.len) |i| {
            const module_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const module_name = Identifier.parse(gpa, ast, module_name_token, diag) catch |err| {
                switch (err) {
                    error.StringLiteralParseFailed => diag.fail("RuleUndeterminedModule", "Invalid module name", .{ .rule = rule_name }),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing an undetermined module name", .{ .rule = rule_name }),
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
            error.FileNotFound => log.exitExpectedly(error.SpecMissingManaZon, "Did not found " ++ source_path, .{}),
            else => log.exitUnexpectedly(err, "Occured when reading " ++ source_path, .{}),
        };
        defer self.gpa.free(source);

        var ast = std.zig.Ast.parse(self.gpa, source, .{ .mode = .zon }) catch |err| switch (err) {
            error.OutOfMemory => log.exitUnexpectedly(err, "Occured during Zon Ast parsing", .{}),
        };
        defer ast.deinit(self.gpa);
        if (ast.errors.len > 0) {
            var wip_errors = std.zig.ErrorBundle.Wip.init(self.gpa) catch |err| log.exitUnexpectedly(err, "Occured during Zon Ast errors printing", .{});
            defer wip_errors.deinit();

            std.zig.putAstErrorsIntoBundle(self.gpa, ast, source_path, &wip_errors) catch |err| log.exitUnexpectedly(err, "Occured during Zon Ast errors printing", .{});

            var error_bundle = wip_errors.toOwnedBundle("") catch |err| log.exitUnexpectedly(err, "Occured during Zon Ast errors printing", .{});
            defer error_bundle.deinit(self.gpa);

            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();

            error_bundle.renderToWriter(.{}, &aw.writer) catch |err| log.exitUnexpectedly(err, "Occured during Zon Ast errors printing", .{});

            var lines: std.ArrayList([]const u8) = .empty;
            defer lines.deinit();

            var it = std.mem.splitScalar(u8, std.mem.trim(u8, aw.written(), "\n"), '\n');
            while (it.next()) |line| lines.append(self.gpa, line) catch |err| log.exitUnexpectedly(err, "Occured during Zon Ast errors printing", .{});
            log.exitExpectedly(error.SpecInvalidManaZon, "Invalid " ++ source_path, .{ .diagnostic = lines.items });
        }

        const node = ast.nodeData(.root).node;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const struct_init = ast.fullStructInit(&buf, node) orelse log.exitExpectedly(error.SpecUnexpectedType, "Expected top level to be a struct", .{});

        var diag: StringLiteral.Diagnostic = .{};
        defer diag.deinit(self.gpa);

        for (0..struct_init.ast.fields.len) |i| {
            const rule_name_token = ast.firstToken(struct_init.ast.fields[i]) - 2;
            const rule_name = Identifier.parse(self.gpa, ast, rule_name_token, &diag) catch |err| {
                switch (err) {
                    error.StringLiteralParseFailed => diag.fail("SpecUndeterminedRule", "Invalid rule name", .{}),
                    error.OutOfMemory, error.WriteFailed => log.exitUnexpectedly(err, "Occured when parsing an undetermined rule name", .{}),
                }
            };
            defer self.gpa.free(rule_name);
            if (std.mem.eql(u8, executed_rule, rule_name)) {
                Rule.parse(self.gpa, ast, struct_init.ast.fields[i], rule_name, &diag);
                break;
            }
        } else log.exitExpectedly(error.UnknownRule, "The called rule can't be find into " ++ source_path, .{ .rule = executed_rule }); 

        scheduler.run();
    }
};
