const std = @import("std");
const docker = @import("docker");
const c = @import("jq");

var singleton: Mana = undefined;

pub fn init(arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) !void {
    try singleton.init(arena, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn queryJSON(filter: []const u8, inputs: c.jv) !c.jv {
    return singleton.queryJSON(filter, inputs);
}

pub fn sendRequestValue(input: c.jv) !c.jv {
    return singleton.sendRequestValue(input);
}

pub fn sendRequestAny(input: anytype) !c.jv {
    return singleton.sendRequestAny(input);
}

pub fn sendDockerDefaultRequest(endpoint: DockerEndpoint, method: std.http.Method, parameters: anytype) !c.jv {
    return singleton.sendDockerDefaultRequest(endpoint, method, parameters);
}

pub fn sendDockerBuildRequest(context: []const u8, tag: []const u8) !void {
    try singleton.sendDockerBuildRequest(context, tag);
}

const docker_api_version = "v1.56";

const DockerEndpoint = enum(u32) {
    version,

    fn toURL(self: @This()) []const u8 {
        return switch (self) {
            .version => "/version",
        };
    }
};

const JSONQuery = struct {
    gpa: std.mem.Allocator,
    jq: *c.jq_state,
    filter: [:0]const u8,

    pub fn init(self: *@This(), gpa: std.mem.Allocator, jq: *c.jq_state, filter: []const u8) !void {
        self.gpa = gpa;
        self.jq = jq;
        self.filter = try self.gpa.dupeSentinel(u8, filter, 0);
    }

    pub fn deinit(self: *@This()) void {
        defer self.gpa.free(self.filter);
    }

    pub fn query(self: *@This(), inputs: c.jv) !c.jv {
        std.debug.assert(c.jv_get_kind(inputs) == c.JV_KIND_OBJECT);
        if (c.jq_compile(self.jq, self.filter) != @intFromBool(true)) return error.MalformedJqFilter;
        c.jq_start(self.jq, c.jv_copy(inputs), 0);
        var output = c.jv_array();
        var result = c.jq_next(self.jq);
        defer c.jv_free(result);

        while (c.jv_is_valid(result) == @intFromBool(true)) {
            output = c.jv_array_append(output, result);
            result = c.jq_next(self.jq);
        }

        if (c.jq_halted(self.jq) == @intFromBool(true)) {
            var msg = c.jq_get_error_message(self.jq);
            defer c.jv_free(msg);
            const exit_code = c.jq_get_exit_code(self.jq);
            defer c.jv_free(exit_code);
            if (c.jv_is_valid(exit_code) == @intFromBool(true)) {
                if (c.jv_get_kind(msg) != c.JV_KIND_STRING) {
                    const dump = c.jv_dump_string(msg, c.JV_PRINT_INVALID);
                    defer c.jv_free(dump);
                    c.jv_free(msg);
                    msg = dump;
                }
                std.log.err("jq halted with {d} exit code: {s}", .{ c.jv_number_value(exit_code), c.jv_string_value(msg) });
                return error.JqHalted;
            }
        } else if (c.jv_invalid_has_msg(c.jv_copy(result)) == @intFromBool(true)) {
            var msg = c.jv_invalid_get_msg(c.jv_copy(result));
            defer c.jv_free(msg);
            const pos = c.jq_util_input_get_position(self.jq);
            defer c.jv_free(pos);
            if (c.jv_get_kind(msg) != c.JV_KIND_STRING) {
                const dump = c.jv_dump_string(msg, c.JV_PRINT_INVALID);
                defer c.jv_free(dump);
                c.jv_free(msg);
                msg = dump;
            }
            std.log.err("jq error at {s}: {s}", .{ c.jv_string_value(pos), c.jv_string_value(msg) });
            return error.JqReturnInvalidMsg;
        }

        return output;
    }
};

const Mana = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    docker_client: docker.Client,
    jq: *c.jq_state,
    jq_util_input: *c.jq_util_input_state,

    fn init(self: *@This(), arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) !void {
        self.arena = arena.allocator();
        self.gpa = gpa;
        self.io = io;
        self.docker_client = .init(arena, gpa, io, environ);
        if (c.jq_init()) |jq| {
            self.jq = jq;
        } else return error.JqInit;
        if (c.jq_util_input_init(null, null)) |jq_util_input| {
            self.jq_util_input = jq_util_input;
        } else return error.JqUtilInputInit;
        c.jq_set_input_cb(self.jq, c.jq_util_input_next_input_cb, self.jq_util_input);
        c.jq_util_input_set_parser(self.jq_util_input, c.jv_parser_new(0), 0);
    }

    fn deinit(self: *@This()) void {
        c.jq_util_input_free(@ptrCast(&self.jq_util_input));
        c.jq_teardown(@ptrCast(&self.jq));
        self.docker_client.deinit();
    }

    fn queryJSON(self: *@This(), filter: []const u8, inputs: c.jv) !c.jv {
        var json_query: JSONQuery = undefined;
        try json_query.init(self.gpa, self.jq, filter);
        defer json_query.deinit();

        return json_query.query(inputs);
    }

    fn sendRequestValue(self: *@This(), input: c.jv) !c.jv {
        std.debug.assert(c.jv_get_kind(input) == c.JV_KIND_OBJECT);

        if (c.jv_object_has(c.jv_copy(input), c.jv_string("docker")) == @intFromBool(true)) {
            const req_body = c.jv_object_get(c.jv_copy(input), c.jv_string("docker"));
            defer c.jv_free(req_body);
            return self.docker_client.send(&req_body);
        } else if (c.jv_object_has(c.jv_copy(input), c.jv_string("docker_build")) == @intFromBool(true)) {
            const req_body = c.jv_object_get(c.jv_copy(input), c.jv_string("docker_build"));
            defer c.jv_free(req_body);
            return self.docker_client.sendBuild(&req_body);
        } else unreachable;
    }

    fn sendRequestAny(self: *@This(), input: anytype) !c.jv {
        const source = try self.gpa.printSentinel("{f}", .{std.json.fmt(input, .{})}, 0);
        defer self.gpa.free(source);

        const parsed = c.jv_parse(source.ptr);
        defer c.jv_free(parsed);
        return self.sendRequestValue(parsed);
    }

    fn sendDockerDefaultRequest(self: *@This(), endpoint: DockerEndpoint, method: std.http.Method, parameters: anytype) !c.jv {
        return self.sendRequestAny(.{
            .docker = .{
                .version = docker_api_version,
                .endpoint = endpoint.toURL(),
                .method = @tagName(method),
                .parameters = parameters,
            },
        });
    }

    fn sendDockerBuildRequest(self: *@This(), context: []const u8, tag: []const u8) !void {
        _ = try self.sendRequestAny(.{
            .docker_build = .{
                .version = docker_api_version,
                .ctx = context,
                .t = tag,
            },
        });
    }
};
