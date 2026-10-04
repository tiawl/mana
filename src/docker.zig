const std = @import("std");
const build = @import("build");
const buildkit = @import("buildkit").v1;
const json = @import("json");

const user_agent = build.name ++ "-" ++ build.version;

fn trim(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, &std.ascii.whitespace);
}

const Plain = struct {
    connection: std.http.Client.Connection,

    fn create(http_client: *std.http.Client, remote_host: []const u8, port: u16, stream: std.Io.net.Stream) error{OutOfMemory}!*@This() {
        const io = http_client.io;
        const gpa = http_client.allocator;
        const alloc_len = allocLen(http_client, remote_host.len);
        const base = try gpa.alignedAlloc(u8, .of(@This()), alloc_len);
        const host_buffer = base[@sizeOf(@This())..][0..remote_host.len];
        const socket_read_buffer = host_buffer.ptr[host_buffer.len..][0..http_client.read_buffer_size];
        const socket_write_buffer = socket_read_buffer.ptr[socket_read_buffer.len..][0..http_client.write_buffer_size];
        std.debug.assert(base.ptr + alloc_len == socket_write_buffer.ptr + socket_write_buffer.len);
        @memcpy(host_buffer, remote_host);
        const plain: *@This() = @ptrCast(base);
        plain.* = .{
            .connection = .{
                .client = http_client,
                .stream_writer = stream.writer(io, socket_write_buffer),
                .stream_reader = stream.reader(io, socket_read_buffer),
                .pool_node = .{},
                .port = port,
                .host_len = @intCast(remote_host.len),
                .proxied = false,
                .closing = false,
                .protocol = .plain,
            },
        };
        return plain;
    }

    fn destroy(plain: *@This()) void {
        const c = &plain.connection;
        const gpa = c.client.allocator;
        const base: [*]align(@alignOf(@This())) u8 = @ptrCast(plain);
        gpa.free(base[0..allocLen(c.client, c.host_len)]);
    }

    fn allocLen(http_client: *std.http.Client, host_len: usize) usize {
        return @sizeOf(@This()) + host_len + http_client.read_buffer_size + http_client.write_buffer_size;
    }
};

fn checkUnixSocket(io: std.Io, path: []const u8) !void {
    if (path.len == 0) return error.FileNotFound;
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{});
    if (stat.kind != .unix_domain_socket) return error.NotAUnixSocket;
}

inline fn toHeaderCase(snake_case_str: []u8) void {
    snake_case_str[0] = std.ascii.toUpper(snake_case_str[0]);
    while (std.mem.indexOfScalar(u8, snake_case_str, '_')) |i| {
        snake_case_str[i] = '-';
        snake_case_str[i + 1] = std.ascii.toUpper(snake_case_str[i + 1]);
    }
}

const Host = struct {
    const DEFAULT_SCHEME: Scheme = .unix;
    const DEFAULT_UNIX_HOST = "/var/run/docker.sock";
    const DEFAULT_TCP_PORT = 2375;

    const Scheme = enum {
        unix,
        tcp,
    };

    const default: @This() = .{
        .scheme = DEFAULT_SCHEME,
        .name = DEFAULT_UNIX_HOST,
        .port = 0,
    };

    scheme: Scheme,
    name: []const u8,
    port: u16,

    fn unix(path: []const u8) @This() {
        return .{
            .scheme = .unix,
            .name = path,
            .port = 0,
        };
    }

    fn tcp(hostname: []const u8, port: ?u16) @This() {
        return .{
            .scheme = .tcp,
            .name = hostname,
            .port = port orelse DEFAULT_TCP_PORT,
        };
    }
};

pub const Client = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    http_client: std.http.Client,
    connection: *std.http.Client.Connection,
    host: Host,
    verbose: bool,

    pub fn init(arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) @This() {
        var self: @This() = .{
            .arena = arena.allocator(),
            .gpa = gpa,
            .http_client = .{
                .allocator = gpa,
                .io = io,
            },
            .connection = undefined,
            .host = .default,
            .verbose = environ.containsConstant("VERBOSE"),
        };

        if (environ.getAlloc(self.gpa, "DOCKER_HOST")) |*docker_host| {
            defer self.gpa.free(docker_host.*);
            const trimmed_host = trim(docker_host.*);

            if (trimmed_host.len == 0) {
                std.log.warn("DOCKER_HOST is empty. Using default host.", .{});
                return self;
            }

            const uri = std.Uri.parse(trimmed_host) catch std.Uri.parse(std.fmt.allocPrint(self.gpa, "{s}://{s}", .{ @tagName(Host.DEFAULT_SCHEME), trimmed_host }) catch {
                std.log.warn("OutOfMemory when allocating prefix for DOCKER_HOST. Using default host.", .{});
                return self;
            }) catch |err| {
                std.log.warn("{s}: DOCKER_HOST can't be parsed: \"{s}\". Using default host.", .{ @errorName(err), trimmed_host });
                return self;
            };
            const uri_path = uri.path.toRawMaybeAlloc(self.gpa) catch {
                std.log.warn("OutOfMemory when allocating for DOCKER_HOST uri path. Using default host.", .{});
                return self;
            };
            var uri_host: std.Io.net.HostName = undefined;
            var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
            if (uri_path.len == 0) {
                uri_host = std.Io.net.HostName.fromUri(uri, &host_buf) catch |err| {
                    std.log.warn("{s}: DOCKER_HOST uri hostname can't be parsed. Using default host.", .{@errorName(err)});
                    return self;
                };
                if (uri_host.bytes.len == 0) {
                    std.log.warn("DOCKER_HOST uri hostname is empty. Using default host.", .{});
                    return self;
                }
            }

            if (std.meta.stringToEnum(Host.Scheme, uri.scheme)) |scheme| {
                switch (scheme) {
                    .unix => {
                        checkUnixSocket(self.http_client.io, uri_path) catch |err| {
                            std.log.warn("{s}: DOCKER_HOST uri path \"{s}\". Using default host.", .{ @errorName(err), uri_path });
                            return self;
                        };
                        self.host = .unix(uri_path);
                    },
                    .tcp => self.host = .tcp(uri_host.bytes, uri.port),
                }
            } else unreachable;
        } else |_| {}

        return self;
    }

    pub fn deinit(self: *@This()) void {
        self.http_client.deinit();
    }

    // fixed version of std.http.Client.connectUnix()
    fn connectUnix(self: *@This()) !void {
        const path = self.host.name;
        if (try self.http_client.connection_pool.findConnection(self.http_client.io, .{
            .host = .{ .bytes = path },
            .port = 0,
            .protocol = .plain,
        })) |conn| {
            self.connection = conn;
            return;
        }

        const ua = try std.Io.net.UnixAddress.init(path);
        var stream = try ua.connect(self.http_client.io);
        errdefer stream.close(self.http_client.io);

        const pc = try Plain.create(&self.http_client, path, 0, stream);
        errdefer pc.destroy();
        try self.http_client.connection_pool.addUsed(self.http_client.io, &pc.connection);
        self.connection = &pc.connection;
    }

    fn connectTcp(self: *@This()) !void {
        self.connection = try self.http_client.connectTcp(try .init(self.host.name), self.host.port, .plain);
    }

    fn connect(self: *@This()) !void {
        switch (self.host.scheme) {
            .unix => try self.connectUnix(),
            .tcp => try self.connectTcp(),
        }
    }

    fn verboseRequest(self: @This(), req: *const std.http.Client.Request) void {
        if (!self.verbose) return;
        std.log.debug("> {s} {s} {s}", .{
            @tagName(req.method), req.uri.path.percent_encoded, @tagName(req.version),
        });
        std.log.debug("> Host: {s}", .{req.uri.host.?.percent_encoded});
        const info = @typeInfo(@TypeOf(req.headers)).@"struct";
        inline for (0..info.field_names.len) |i| {
            if (info.field_types[i] == std.http.Client.Request.Headers.Value) {
                switch (@field(req.headers, info.field_names[i])) {
                    .override => |overriden| {
                        var header_case_field_name: [info.field_names[i].len]u8 = undefined;
                        @memcpy(&header_case_field_name, info.field_names[i]);
                        toHeaderCase(&header_case_field_name);
                        std.log.debug("> {s}: {s}", .{ header_case_field_name, overriden });
                    },
                    else => {},
                }
            }
        }
        for (req.extra_headers) |header| std.log.debug("> {s}: {s}", .{ header.name, header.value });
        for (req.privileged_headers) |header| std.log.debug("> {s}: {s}", .{ header.name, header.value });
    }

    fn verboseResponse(self: @This(), http_response: *const std.http.Client.Response) void {
        if (!self.verbose) return;
        var http_response_it = http_response.head.iterateHeaders();
        std.log.debug("< HTTP {d} {s}", .{
            @backingInt(http_response.head.status), @tagName(http_response.head.status),
        });
        while (http_response_it.next()) |header| {
            std.log.debug("< {s}: {s}", .{ header.name, header.value });
        }
    }

    fn sendInner(self: *@This(), allocator: std.mem.Allocator, response: *const Response.Interface, req_body: *std.json.Value) !std.json.Value {
        std.debug.assert(std.meta.activeTag(req_body.*) == .object);
        std.debug.assert(req_body.object.getPtr("version") != null);
        std.debug.assert(std.meta.activeTag(req_body.object.getPtr("version").?.*) == .string);
        std.debug.assert(req_body.object.getPtr("endpoint") != null);
        std.debug.assert(std.meta.activeTag(req_body.object.getPtr("endpoint").?.*) == .string);
        std.debug.assert(req_body.object.getPtr("method") != null);
        std.debug.assert(std.meta.activeTag(req_body.object.getPtr("method").?.*) == .string);
        std.debug.assert(std.meta.stringToEnum(std.http.Method, req_body.object.getPtr("method").?.string) != null);

        // If a connection is initialized without being used later, deinitialization will panic
        if (self.http_client.connection_pool.used.first == null) try self.connect();

        var url: std.Io.Writer.Allocating = .init(self.gpa);
        defer url.deinit();

        try url.writer.writeAll("http://");
        try url.writer.writeAll(req_body.object.getPtr("version").?.string);
        try url.writer.writeAll(req_body.object.getPtr("endpoint").?.string);

        if (req_body.object.getPtr("parameters")) |parameters| {
            var it = parameters.object.iterator();
            var is_first = true;
            while (it.next()) |*entry| {
                if (is_first) {
                    try url.writer.writeAll("?");
                    is_first = false;
                } else try url.writer.writeAll("&");

                try url.writer.writeAll(entry.key_ptr.*);
                try url.writer.writeAll("=");
                switch (entry.value_ptr.*) {
                    .null => {},
                    .bool => |b| try url.writer.writeAll(if (b) "true" else "false"),
                    .integer => |i| try url.writer.print("{d}", .{i}),
                    .float => |f| try url.writer.print("{d}", .{f}),
                    .string => |s| try url.writer.writeAll(s),
                    else => unreachable,
                }
            }
        }

        const uri = try std.Uri.parse(url.written());

        var req = try self.http_client.request(std.meta.stringToEnum(std.http.Method, req_body.object.getPtr("method").?.string).?, uri, .{
            .connection = self.connection,
            .headers = response.headers,
        });
        defer req.deinit();
        self.verboseRequest(&req);

        if (response.body.len > 0) try req.sendBodyComplete(response.body) else try req.sendBodiless();

        const redirect_buffer: []u8 = try self.gpa.alloc(u8, 8 * 1024);
        defer self.gpa.free(redirect_buffer);

        var http_response = try req.receiveHead(redirect_buffer);
        self.verboseResponse(&http_response);

        var http_response_body: std.Io.Writer.Allocating = .init(self.gpa);
        defer http_response_body.deinit();

        const decompress_buffer: []u8 = switch (http_response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.gpa.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.gpa.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = http_response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

        var scanner: std.json.Scanner = undefined;
        var diag: std.json.Diagnostics = .{};
        var parsed: std.json.Value = undefined;
        var output: std.json.Value = .{ .array = .init(allocator) };

        while (true) {
            _ = reader.streamDelimiter(&http_response_body.writer, '\n') catch |err| switch (err) {
                error.ReadFailed => return http_response.bodyErr().?,
                error.EndOfStream => break,
                else => return err,
            };
            _ = reader.toss(1);

            const written = http_response_body.written();
            scanner = std.json.Scanner.initCompleteInput(self.gpa, written);
            defer scanner.deinit();

            scanner.enableDiagnostics(&diag);

            parsed = std.json.parseFromTokenSourceLeaky(std.json.Value, self.arena, &scanner, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                std.log.err("{s}: line {}, column {}", .{ written, diag.getLine(), diag.getColumn() });
                return err;
            };

            try response.process(&output, &parsed);

            http_response_body.clearRetainingCapacity();
        }

        return output;
    }

    pub fn send(self: *@This(), allocator: std.mem.Allocator, req_body: *std.json.Value) !std.json.Value {
        var default_impl: Response.Impl.Default = .{};
        const response = default_impl.response();
        return try self.sendInner(allocator, &response, req_body);
    }

    fn writeCtxArchive(self: @This(), writer: *std.Io.Writer, req_body: *std.json.Value) !void {
        var archive: std.tar.Writer = .{ .underlying_writer = writer };

        try archive.writeDir(".", .{});

        var dir = try std.Io.Dir.cwd().openDir(self.http_client.io, req_body.object.getPtr("ctx").?.string, .{ .iterate = true });
        defer dir.close(self.http_client.io);

        var walker = try dir.walk(self.gpa);
        defer walker.deinit();
        var file: std.Io.File = undefined;
        var read_buf: [1024]u8 = undefined;
        var file_reader: std.Io.File.Reader = undefined;
        var file_content: std.Io.Writer.Allocating = undefined;

        while (try walker.next(self.http_client.io)) |entry| {
            const full_path = try std.fs.path.join(self.gpa, &[_][]const u8{ req_body.object.getPtr("ctx").?.string, entry.path });
            defer self.gpa.free(full_path);

            switch (entry.kind) {
                .directory => try archive.writeDir(entry.path, .{}),
                .file => {
                    file = try std.Io.Dir.cwd().openFile(self.http_client.io, full_path, .{ .mode = .read_only });
                    defer file.close(self.http_client.io);

                    file_reader = file.reader(self.http_client.io, &read_buf);
                    file_content = .init(self.gpa);
                    defer file_content.deinit();

                    _ = try file_reader.interface.stream(&file_content.writer, .unlimited);

                    try archive.writeFileBytes(entry.path, file_content.written(), .{});
                },
                else => unreachable,
            }
        }
    }

    pub fn sendBuild(self: *@This(), allocator: std.mem.Allocator, req_body: *std.json.Value) !std.json.Value {
        std.debug.assert(std.meta.activeTag(req_body.*) == .object);
        std.debug.assert(req_body.object.getPtr("ctx") != null);
        std.debug.assert(std.meta.activeTag(req_body.object.getPtr("ctx").?.*) == .string);
        std.debug.assert(req_body.object.getPtr("version") != null);
        std.debug.assert(std.meta.activeTag(req_body.object.getPtr("version").?.*) == .string);
        const cwd = std.Io.Dir.cwd();
        const stat = try cwd.statFile(self.http_client.io, req_body.object.getPtr("ctx").?.string, .{});
        std.debug.assert(stat.kind == .directory);
        std.debug.assert(req_body.object.getPtr("t") != null);
        std.debug.assert(std.meta.activeTag(req_body.object.getPtr("t").?.*) == .string);

        var archive_buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer archive_buf.deinit();

        try self.writeCtxArchive(&archive_buf.writer, req_body);

        var req_body_json: std.json.Value = .{ .object = .empty };
        defer req_body_json.object.deinit(self.gpa);
        try req_body_json.object.put(self.gpa, "version", .{ .string = try self.gpa.dupe(u8, req_body.object.getPtr("version").?.string) });
        defer self.gpa.free(req_body_json.object.getPtr("version").?.string);
        try req_body_json.object.put(self.gpa, "endpoint", .{ .string = "/build" });
        try req_body_json.object.put(self.gpa, "method", .{ .string = "POST" });

        try req_body_json.object.put(self.gpa, "parameters", try json.cloneValue(self.gpa, req_body.object.getPtr("parameters") orelse &.{ .object = .empty }));
        defer json.freeValue(self.gpa, req_body_json.object.getPtr("parameters").?);

        try req_body_json.object.getPtr("parameters").?.object.put(self.gpa, "version", .{ .integer = 2 });
        defer _ = req_body_json.object.getPtr("parameters").?.object.swapRemove("version");
        try req_body_json.object.getPtr("parameters").?.object.put(self.gpa, "t", .{ .string = try self.gpa.dupe(u8, req_body.object.getPtr("t").?.string) });
        defer {
            self.gpa.free(req_body_json.object.getPtr("parameters").?.object.getPtr("t").?.string);
            _ = req_body_json.object.getPtr("parameters").?.object.swapRemove("t");
        }

        var build_impl: Response.Impl.Build = .{
            .arena = self.arena,
        };
        const response = build_impl.response(&archive_buf);
        return try self.sendInner(allocator, &response, &req_body_json);
    }

    const Response = struct {
        const Interface = struct {
            const VTable = struct {
                process_fn: *const fn (*anyopaque, *std.json.Value, *const std.json.Value) anyerror!void,
            };

            ptr: *anyopaque,
            vtable: *const VTable,
            body: []u8 = "",
            headers: std.http.Client.Request.Headers,

            fn process(self: @This(), output: *std.json.Value, parsed: *const std.json.Value) !void {
                std.debug.assert(std.meta.activeTag(output.*) == .array);
                try self.vtable.process_fn(self.ptr, output, parsed);
            }
        };

        const Impl = struct {
            const Default = struct {
                fn process(ptr: *anyopaque, output: *std.json.Value, parsed: *const std.json.Value) !void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    _ = self;
                    try output.array.append(try json.cloneValue(output.array.allocator, parsed));
                }

                fn response(self: *@This()) Client.Response.Interface {
                    return .{
                        .ptr = self,
                        .vtable = &.{
                            .process_fn = @This().process,
                        },
                        .headers = .{
                            .user_agent = .{
                                .override = user_agent,
                            },
                        },
                    };
                }
            };

            const Build = struct {
                arena: std.mem.Allocator,
                b64_buffer: [1024]u8 = undefined,
                proto_reader: std.Io.Reader = undefined,
                status_resp: buildkit.StatusResponse = undefined,

                fn process(ptr: *anyopaque, output: *std.json.Value, parsed: *const std.json.Value) !void {
                    _ = output;
                    const self: *@This() = @ptrCast(@alignCast(ptr));

                    if (parsed.object.get("id")) |id| {
                        if (std.mem.eql(u8, id.string, "moby.buildkit.trace")) {
                            const b64_encoded = parsed.object.get("aux").?;
                            const decoded = self.b64_buffer[0..try std.base64.standard.Decoder.calcSizeForSlice(b64_encoded.string)];
                            try std.base64.standard.Decoder.decode(decoded, b64_encoded.string);
                            self.proto_reader = .fixed(decoded);
                            self.status_resp = try buildkit.StatusResponse.decode(&self.proto_reader, self.arena);
                            if (self.status_resp.vertexes.items.len > 0) {
                                for (self.status_resp.vertexes.items) |v| {
                                    if (v.@"error".len > 0) {
                                        std.debug.print("[ERROR] {s}\n", .{trim(v.@"error")});
                                        return error.BuildkitError;
                                    } else if (v.started != null and v.completed != null) std.debug.print("{s}\n", .{trim(v.name)});
                                }
                            } else if (self.status_resp.statuses.items.len > 0) {
                                for (self.status_resp.statuses.items) |s| {
                                    if (s.started != null and s.completed != null) std.debug.print("{s}\n", .{trim(s.ID)});
                                }
                            } else if (self.status_resp.logs.items.len > 0) {
                                for (self.status_resp.logs.items) |l| std.debug.print("{s}\n", .{trim(l.msg)});
                            } else if (self.status_resp.warnings.items.len > 0) {
                                for (self.status_resp.warnings.items) |w| std.debug.print("{s}\n", .{trim(w.short)});
                            } else unreachable;
                        } else if (std.mem.eql(u8, id.string, "moby.image.id")) {
                            std.debug.print("Image ID: {s}\n", .{parsed.object.get("aux").?.object.get("ID").?.string});
                        } else unreachable;
                    } else if (parsed.object.get("errorDetail")) |err| {
                        std.log.err("{s}", .{err.object.get("message").?.string});
                        return error.DockerBuild;
                    } else unreachable;
                }

                fn response(self: *@This(), w: *std.Io.Writer.Allocating) Client.Response.Interface {
                    return .{
                        .ptr = self,
                        .vtable = &.{
                            .process_fn = @This().process,
                        },
                        .body = w.written(),
                        .headers = .{
                            .user_agent = .{
                                .override = user_agent,
                            },
                            .content_type = .{
                                .override = "application/x-tar",
                            },
                        },
                    };
                }
            };
        };
    };
};
