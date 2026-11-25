const std = @import("std");
const zlua = @import("zlua");
const aro = @import("aro");
const c = @import("libffi");
const log = @import("log");

var singleton: Ffi = undefined;

pub fn init(arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
    singleton.init(arena_instance, gpa, io, environ);
}

pub fn deinit() void {
    singleton.deinit();
}

pub fn setBuildGlobals(vm: *zlua.Lua) void {
    singleton.setBuildGlobals(vm);
}

pub fn setRunGlobals(vm: *zlua.Lua) void {
    singleton.setRunGlobals(vm);
}

const ffi = struct {
    fn cdef(vm: *zlua.Lua) i32 {
        return singleton.cdef(vm);
    }

    fn ctype(vm: *zlua.Lua) i32 {
        return singleton.ctype(vm);
    }

    fn load(vm: *zlua.Lua) i32 {
        return singleton.load(vm);
    }

    fn namespace(vm: *zlua.Lua) i32 {
        return singleton.namespace(vm);
    }

    fn new(vm: *zlua.Lua) i32 {
        return singleton.new(vm);
    }

    fn string(vm: *zlua.Lua) i32 {
        return singleton.string(vm);
    }

    const CData = struct {
        fn __call(vm: *zlua.Lua) i32 {
            return singleton.cdataCall(vm);
        }
    };

    const CNamespace = struct {
        fn __index(vm: *zlua.Lua) i32 {
            return singleton.cnamespaceIndex(vm);
        }
    };

    const index = struct {
        fn __index(vm: *zlua.Lua) i32 {
            return singleton.indexIndex(vm);
        }
    };
};

const CType = struct {
    const Attr = struct {
        is_const: bool,
        is_volatile: bool,
    };

    const Func = struct {
        return_type: *CType,
        params: []const Param,
        is_variadic: bool,
        cc: aro.TypeStore.Type.Func.CallingConvention = .default,

        pub const Param = struct {
            name: []const u8,
            type: *CType,
            attr: Attr,
        };
    };

    const Pointer = struct {
        child: *CType,
        attr: Attr,
    };

    const Array = struct {
        child: *CType,
        len: u64,
    };

    const Vector = struct {
        child: *CType,
        len: u64,
    };

    const Record = struct {
        fields: []const Field,
        is_union: bool,

        const Field = struct {
            name: []const u8,
            type: *CType,
            attr: Attr,
        };
    };

    const Enum = struct {
        fields: []const Field,

        const Field = struct {
            name: []const u8,
            attr: Attr,
        };
    };

    inner: union(enum) {
        void,
        bool,
        nullptr_t,

        int: aro.TypeStore.Type.Int,
        float: aro.TypeStore.Type.Float,
        // TODO: storage_float: StorageFloat,
        // TODO: complex: QualType,
        bit_int: aro.TypeStore.Type.BitInt,
        // TODO: atomic: QualType,

        // TODO: block: Block,
        func: Func,
        pointer: Pointer,
        array: Array,
        vector: Vector,

        @"struct": Record,
        @"union": Record,
        @"enum": Enum,

        // TODO: typeof: TypeOf,
        // TODO: typedef: TypeDef,
    },
    ffi_type: ?*c.ffi_type = null,

    fn getFfiType(self: *@This()) !*c.ffi_type {
        if (self.ffi_type) |ft| return ft;

        const ft: *c.ffi_type = switch (self.inner) {
            .void => &c.ffi_type_void,
            .bool => &c.ffi_type_uint8,
            .nullptr_t => &c.ffi_type_pointer,
            .int => |i| switch (i) {
                .char, .schar => &c.ffi_type_sint8,
                .uchar => &c.ffi_type_uint8,
                .short => &c.ffi_type_sint16,
                .ushort => &c.ffi_type_uint16,
                .int => &c.ffi_type_sint32,
                .uint => &c.ffi_type_uint32,
                .long => if (@sizeOf(c_long) == 8) &c.ffi_type_sint64 else &c.ffi_type_sint32,
                .ulong => if (@sizeOf(c_ulong) == 8) &c.ffi_type_uint64 else &c.ffi_type_uint32,
                .long_long => &c.ffi_type_sint64,
                .ulong_long => &c.ffi_type_uint64,
                .int128, .uint128, .int24, .uint24 => return error.UnsupportedFfiType,
            },
            .float => |f| switch (f) {
                .float => &c.ffi_type_float,
                .double => &c.ffi_type_double,
                .long_double => &c.ffi_type_longdouble,
                else => return error.UnsupportedFfiType,
            },
            .pointer => &c.ffi_type_pointer,
            .func => &c.ffi_type_pointer,
            else => return error.UnsupportedFfiType,
        };
        self.ffi_type = ft;
        return ft;
    }
};

const CData = struct {
    ctype: *CType,
    ptr: *const anyopaque,

    fn push(vm: *zlua.Lua, ct: *CType, ptr: *const anyopaque) void {
        const TOP_OF_STACK = -1;
        const FFITABLE_NPOS = -2;
        const CDATA_NPOS = -2;
        var userdata = vm.newUserdata(@This(), 1);
        userdata.ctype = ct;
        userdata.ptr = ptr;
        _ = vm.getGlobal("ffi");
        _ = vm.getField(TOP_OF_STACK, "CData");
        vm.remove(FFITABLE_NPOS);
        vm.setMetatable(CDATA_NPOS);
    }
};

const MAX_ARGS = 16;

// Integer results from libffi are written as ffi_arg-sized values.
const Storage = extern union {
    sint: c.ffi_sarg,
    uint: c.ffi_arg,
    i64: i64,
    u64: u64,
    f32: f32,
    f64: f64,
    ld: c_longdouble,
    ptr: ?*anyopaque,
    bytes: [@sizeOf(c.ffi_arg)]u8,
};

fn cFromLua(vm: *zlua.Lua, idx: i32, ct: *const CType, storage: *Storage) ?*anyopaque {
    switch (ct.inner) {
        .int => |i| {
            const n = vm.toInteger(idx) catch |err| log.fatal(err, "Expected integer argument", .{});
            switch (i) {
                .char, .schar, .short, .int, .long, .long_long, .int24, .int128 => {
                    storage.sint = @intCast(n);
                    return &storage.sint;
                },
                .uchar, .ushort, .uint, .ulong, .ulong_long, .uint24, .uint128 => {
                    storage.uint = @intCast(n);
                    return &storage.uint;
                },
            }
        },
        .float => |f| {
            const n = vm.toNumber(idx) catch |err| log.fatal(err, "Expected number argument", .{});
            switch (f) {
                .float => {
                    storage.f32 = @floatCast(n);
                    return &storage.f32;
                },
                .double => {
                    storage.f64 = n;
                    return &storage.f64;
                },
                .long_double => {
                    storage.ld = @floatCast(n);
                    return &storage.ld;
                },
                else => log.err(error.UnsupportedFfiType, "Unsupported float type for argument conversion", .{}),
            }
        },
        .bool => {
            storage.uint = if (vm.toBoolean(idx)) 1 else 0;
            return &storage.uint;
        },
        .pointer, .nullptr_t => {
            switch (vm.typeOf(idx)) {
                .nil => storage.ptr = null,
                .light_userdata => storage.ptr = @ptrCast(@constCast(vm.toPointer(idx))),
                .string => {
                    const s = vm.toString(idx) catch |err| log.fatal(err, "Expected string argument for pointer parameter", .{});
                    storage.ptr = @ptrCast(@constCast(s.ptr));
                },
                else => log.err(error.UnsupportedFfiType, "Only nil, lightuserdata or string supported as pointer arguments for now", .{}),
            }
            return @ptrCast(&storage.ptr);
        },
        else => log.err(error.UnsupportedFfiType, "Unsupported type for argument conversion", .{ .type = @tagName(ct.inner) }),
    }
}

fn luaFromC(vm: *zlua.Lua, ct: *const CType, storage: *const Storage) void {
    switch (ct.inner) {
        .void => {},
        .int => |i| {
            const n: i64 = switch (i) {
                .char, .schar, .short, .int, .long, .long_long, .int24, .int128 => @intCast(storage.sint),
                .uchar, .ushort, .uint, .ulong, .ulong_long, .uint24, .uint128 => @intCast(storage.uint),
            };
            vm.pushInteger(n);
        },
        .float => |f| {
            const n: f64 = switch (f) {
                .float => storage.f32,
                .double => storage.f64,
                .long_double => @floatCast(storage.ld),
                else => 0,
            };
            vm.pushNumber(n);
        },
        .bool => {
            vm.pushBoolean(storage.uint != 0);
        },
        .pointer, .nullptr_t => {
            if (storage.ptr) |p| {
                vm.pushLightUserdata(@ptrCast(p));
            } else {
                vm.pushNil();
            }
        },
        else => log.err(error.UnsupportedCtype, "Unsupported C type for Lua conversion", .{ .type = @tagName(ct.inner) }),
    }
}

const CNamespace = struct {
    gpa: std.mem.Allocator,
    dynlib: ?std.DynLib,
    defs: std.StringHashMap(*CType),

    pub fn init(self: *@This(), gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        self.defs = .init(self.gpa);
    }

    pub fn deinit(self: *@This()) void {
        if (self.dynlib) |*dynlib| dynlib.close();
        var it = self.defs.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        self.defs.deinit();
    }
};

const Ffi = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ,
    index: std.StringHashMap(CNamespace),
    end_implicit_defs: usize,

    pub fn init(self: *@This(), arena_instance: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ) void {
        self.arena = arena_instance;
        self.gpa = gpa;
        self.io = io;
        self.environ = environ;
        self.index = .init(self.gpa);

        self.end_implicit_defs = blk: {
            var diag: aro.Diagnostics = .{ .output = .ignore };
            var comp = aro.Compilation.init(.{
                .gpa = self.gpa,
                .arena = self.arena.allocator(),
                .io = self.io,
                .diagnostics = &diag,
                .environ_map = null,
            }) catch |err| log.fatal(err, "Occured when initializing a compilation unit to compute end of implicit definitions", .{});
            defer comp.deinit();
            const dummy_source = self.gpa.dupeSentinel(u8, "", 0) catch |err| log.fatal(err, "Occured when duping an empty string to compute end of implicit definitions", .{});
            const src = comp.addSourceFromOwnedBuffer("<dummy>", dummy_source, .user) catch |err| log.fatal(err, "Occured when adding C source to compute end of implicit definitions", .{});
            var pp = aro.Preprocessor.init(&comp, .{ .base_file = src.id }) catch |err| log.fatal(err, "Occured when initializing preprocessor to compute end of implicit definitions", .{});
            defer pp.deinit();
            const eof = pp.preprocess(src) catch |err| log.fatal(err, "Occured when preprocessing C source to compute end of implicit definitions", .{});
            pp.addToken(eof) catch |err| log.fatal(err, "Occured when adding EOF token to compute end of implicit definitions", .{});
            var c_tree = pp.parse() catch |err| log.fatal(err, "Occured when parsing C into an AST to compute end of implicit definitions", .{});
            defer c_tree.deinit();
            break :blk c_tree.root_decls.items.len;
        };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.index.iterator();
        while (it.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.index.deinit();
    }

    pub fn setBuildGlobals(self: *@This(), vm: *zlua.Lua) void {
        _ = self;
        const FFITABLE_NPOS = -2;
        const FFICDATATABLE_NPOS = -2;
        const FFICNAMESPACETABLE_NPOS = -2;
        const FFIINDEXTABLE_NPOS = -2;
        const FFIINDEX_INSTANCE_NPOS = -2;
        vm.newTable();
        vm.newTable();
        vm.pushFunction(zlua.wrap(ffi.CData.__call));
        vm.setField(FFICDATATABLE_NPOS, "__call");
        vm.setField(FFITABLE_NPOS, "CData");
        vm.newTable();
        vm.setField(FFITABLE_NPOS, "CType");
        vm.newTable();
        vm.pushFunction(zlua.wrap(ffi.index.__index));
        vm.setField(FFIINDEXTABLE_NPOS, "__index");
        vm.setField(FFITABLE_NPOS, "index");
        vm.newTable();
        vm.pushFunction(zlua.wrap(ffi.CNamespace.__index));
        vm.setField(FFICNAMESPACETABLE_NPOS, "__index");
        vm.setField(FFITABLE_NPOS, "CNamespace");
        vm.pushFunction(zlua.wrap(ffi.cdef));
        vm.setField(FFITABLE_NPOS, "cdef");
        vm.pushFunction(zlua.wrap(ffi.ctype));
        vm.setField(FFITABLE_NPOS, "ctype");
        vm.pushFunction(zlua.wrap(ffi.load));
        vm.setField(FFITABLE_NPOS, "load");
        vm.pushFunction(zlua.wrap(ffi.new));
        vm.setField(FFITABLE_NPOS, "new");
        vm.pushFunction(zlua.wrap(ffi.string));
        vm.setField(FFITABLE_NPOS, "string");
        vm.pushFunction(zlua.wrap(ffi.namespace));
        vm.setField(FFITABLE_NPOS, "namespace");
        vm.newTable();

        _ = vm.getField(FFITABLE_NPOS, "index");
        vm.setMetatable(FFIINDEX_INSTANCE_NPOS);
        vm.setField(FFITABLE_NPOS, "C");
        vm.setGlobal("ffi");
    }

    pub fn setRunGlobals(self: *@This(), vm: *zlua.Lua) void {
        // TODO
        _ = .{ self, vm };
    }

    fn translateQualType(self: *@This(), qt: aro.QualType, comp: *const aro.Compilation) !*CType {
        if (qt.isInvalid()) return error.InvalidAroType;
        const base = qt.base(comp);
        const ty = base.type;
        const quals = base.qt;

        // TODO: remove arena usage here
        const ct = try self.arena.allocator().create(CType);
        ct.* = .{
            .inner = undefined,
        };

        ct.inner = switch (ty) {
            .void => .void,
            .bool => .bool,
            .nullptr_t => .nullptr_t,

            .int => |i| .{ .int = i },

            .float => |f| .{ .float = f },

            .bit_int => |bi| .{ .bit_int = bi },

            .pointer => |p| .{
                .pointer = .{
                    .child = try self.translateQualType(p.child, comp),
                    .attr = .{
                        .is_const = quals.@"const",
                        .is_volatile = quals.@"volatile",
                    },
                },
            },

            .array => |a| blk: {
                const len: u64 = switch (a.len) {
                    .fixed, .static => |n| n,
                    .incomplete, .variable, .unspecified_variable => 0, // TODO: or error ?
                };
                break :blk .{
                    .array = .{
                        .child = try self.translateQualType(a.elem, comp),
                        .len = len,
                    },
                };
            },

            .vector => |v| .{
                .vector = .{
                    .child = try self.translateQualType(v.elem, comp),
                    .len = v.len,
                },
            },

            .func => |f| blk: {
                // TODO: remove arena calls
                const params = try self.arena.allocator().alloc(CType.Func.Param, f.params.len);
                for (f.params, 0..) |p, i| {
                    params[i] = .{
                        .name = try self.arena.allocator().dupe(u8, p.name.lookup(comp)),
                        .type = try self.translateQualType(p.qt, comp),
                        .attr = .{
                            .is_const = false, // TODO
                            .is_volatile = false, // TODO
                        },
                    };
                }
                break :blk .{
                    .func = .{
                        .return_type = try self.translateQualType(f.return_type, comp),
                        .params = params,
                        .is_variadic = f.kind == .variadic,
                        .cc = f.cc,
                    },
                };
            },

            .@"struct", .@"union" => |rec| blk: {
                // TODO: remove arena calls
                const fields = try self.arena.allocator().alloc(CType.Record.Field, rec.fields.len);
                for (rec.fields, 0..) |field, i| {
                    fields[i] = .{
                        .name = try self.arena.allocator().dupe(u8, field.name.lookup(comp)),
                        .type = try self.translateQualType(field.qt, comp),
                        .attr = .{ .is_const = false, .is_volatile = false },
                    };
                }
                if (ty == .@"struct") {
                    break :blk .{ .@"struct" = .{ .fields = fields, .is_union = false } };
                } else {
                    break :blk .{ .@"union" = .{ .fields = fields, .is_union = true } };
                }
            },

            .@"enum" => |e| blk: {
                // For FFI you usually only care about the underlying integer tag.
                // You can also store the enumerators if you want them in Lua.
                const tag_qt = e.tag orelse aro.QualType.int; // fallback
                const tag_ctype = try self.translateQualType(tag_qt, comp);
                // simplest useful representation:
                break :blk tag_ctype.inner;
                // or keep a proper .@"enum" payload if you prefer
            },

            // typedef / typeof / atomic / complex / attributed should have been
            // stripped by .base(); if any remain, recurse or error.
            .typedef, .typeof => unreachable,
            .storage_float, .complex, .atomic, .block => return error.UnsupportedAroType,
        };

        return ct;
    }

    pub fn ctype(self: *@This(), vm: *zlua.Lua) i32 {
        _ = .{self, vm};
        return 0;
    }

    pub fn new(self: *@This(), vm: *zlua.Lua) i32 {
        _ = .{self, vm};
        return 0;
    }

    pub fn string(self: *@This(), vm: *zlua.Lua) i32 {
        _ = .{self, vm};
        return 0;
    }

    pub fn cdef(self: *@This(), vm: *zlua.Lua) i32 {
        const NAMESPACE = 1;
        const SOURCE = 2;
        if (vm.typeOf(NAMESPACE) != .string) log.err(error.FfiCdefNamespaceExpectedString, "Namespace argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(NAMESPACE) });
        const ns = vm.toString(NAMESPACE) catch |err| log.fatal(err, "Occured when reading namespace argument from main Lua VM stack", @src());
        if (vm.typeOf(SOURCE) != .string) log.err(error.FfiCdefSourceExpectedString, "Source argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(SOURCE) });
        const source = vm.toString(SOURCE) catch |err| log.fatal(err, "Occured when reading source argument from main Lua VM stack", @src());

        if (!self.index.contains(ns)) log.err(error.FfiCdefUnknownNamespace, "This namespace does not exist", .{ .key = ns });

        // Here we don't free memory because aro.Compilation frees it for us
        const owned = self.gpa.dupeSentinel(u8, source, 0) catch |err| log.fatal(err, "Occured when duping the cdef source", .{});
        var diag: aro.Diagnostics = .{
            .output = .{
                .to_list = .{
                    .messages = .empty,
                    .arena = self.arena.*,
                },
            },
        };

        var environ_map = self.environ.createMap(self.gpa) catch |err| log.fatal(err, "Occured when creating Environ Map", .{});
        defer environ_map.deinit();

        var comp = aro.Compilation.init(.{
            .gpa = self.gpa,
            .arena = self.arena.allocator(),
            .io = self.io,
            .diagnostics = &diag,
            .environ_map = &environ_map,
        }) catch |err| log.fatal(err, "Occured when initializing a compilation unit", .{});
        defer comp.deinit();

        const src = comp.addSourceFromOwnedBuffer("<ffi.cdef>", owned, .user) catch |err| log.fatal(err, "Occured when adding C source", .{});

        var pp = aro.Preprocessor.init(&comp, .{ .base_file = src.id }) catch |err| log.fatal(err, "Occured when initializing preprocessor", .{});
        defer pp.deinit();

        const eof = pp.preprocess(src) catch |err| log.fatal(err, "Occured when preprocessing C source", .{});
        pp.addToken(eof) catch |err| log.fatal(err, "Occured when adding EOF token", .{});

        var c_tree = pp.parse() catch |err| log.err(err, "Occured when parsing C into an AST", .{});
        defer c_tree.deinit();

        if (comp.diagnostics.errors != 0) log.err(error.CdefCompilationFailed, "aro can't parse cdef sources", .{ .messages = comp.diagnostics.output.to_list.messages.items });

        var name: []const u8 = undefined;
        var name_tok: aro.Tree.TokenIndex = undefined;
        var ct: *CType = undefined;
        for (self.end_implicit_defs..c_tree.root_decls.items.len) |i| {
            switch (c_tree.root_decls.items[i].get(&c_tree)) {
                .function => |f| {
                    name_tok = f.name_tok;
                    ct = self.translateQualType(f.qt, &comp) catch |err| log.fatal(err, "Occured when translating function qualtype", .{ .name = c_tree.tokSlice(name_tok) });
                },
                .variable => |v| {
                    name_tok = v.name_tok;
                    ct = self.translateQualType(v.qt, &comp) catch |err| log.fatal(err, "Occured when translating variable qualtype", .{ .name = c_tree.tokSlice(name_tok) });
                },
                .typedef => |td| {
                    name_tok = td.name_tok;
                    ct = self.translateQualType(td.qt, &comp) catch |err| log.fatal(err, "Occured when translating typedef qualtype", .{ .name = c_tree.tokSlice(name_tok) });
                },
                .struct_decl, .union_decl, .enum_decl => |cd| {
                    name_tok = cd.name_or_kind_tok;
                    ct = self.translateQualType(cd.container_qt, &comp) catch |err| log.fatal(err, "Occured when translating struct, union or enum qualtype", .{ .name = c_tree.tokSlice(name_tok) });
                },
                else => continue, // TODO: list here: empty_decl, static_assert, forward decls, etc.
            }
            name = self.gpa.dupe(u8, c_tree.tokSlice(name_tok)) catch |err| log.fatal(err, "Occured when allocating CType name", .{});

            if (self.index.getPtr(ns).?.defs.contains(name)) log.err(error.FfiCdefDefinitionsAlreadyExists, "You can't redefined a definition", .{ .namespace = ns, .key = name });

            self.index.getPtr(ns).?.defs.put(name, ct) catch |err| log.fatal(err, "Occured when adding CType definition", .{ .namespace = ns, .key = name });
        }

        return 0;
    }

    pub fn load(self: *@This(), vm: *zlua.Lua) i32 {
        const NAMESPACE = 1;
        const PATH = 2;
        if (vm.typeOf(NAMESPACE) != .string) log.err(error.FfiLoadNamespaceExpectedString, "Namespace argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(NAMESPACE) });
        const ns = vm.toString(NAMESPACE) catch |err| log.fatal(err, "Occured when reading namespace argument from main Lua VM stack", @src());
        if (vm.typeOf(PATH) != .string) log.err(error.FfiLoadPathExpectedString, "Path argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(PATH) });
        const path = vm.toString(PATH) catch |err| log.fatal(err, "Occured when reading path argument from main Lua VM stack", @src());

        if (!self.index.contains(ns)) log.err(error.FfiLoadUnknownNamespace, "This namespace does not exist", .{ .key = ns });

        self.index.getPtr(ns).?.dynlib = std.DynLib.open(path) catch |err| switch (err) {
            // TODO: use log.err here for some error cases
            else => log.fatal(err, "Occured when opening dynamic library", .{ .path = path }),
        };

        return 0;
    }

    pub fn namespace(self: *@This(), vm: *zlua.Lua) i32 {
        const NAMESPACE = 1;
        if (vm.typeOf(NAMESPACE) != .string) log.err(error.FfiNamespaceNamespaceExpectedString, "Namespace argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(NAMESPACE) });
        const ns = vm.toString(NAMESPACE) catch |err| log.fatal(err, "Occured when reading namespace argument from main Lua VM stack", @src());

        const duped = self.gpa.dupe(u8, ns) catch |err| log.fatal(err, "Occured when duping namespace key", .{});

        if (self.index.contains(ns)) log.err(error.FfiNamespaceNamespaceAlreadyExist, "This namespace is already used", .{ .key = ns });

        self.index.put(duped, undefined) catch |err| log.fatal(err, "Occured when adding namespace", .{});
        self.index.getPtr(ns).?.init(self.gpa);

        return 0;
    }

    pub fn cnamespaceIndex(self: *@This(), vm: *zlua.Lua) i32 {
        const NAMESPACE_TABLE = 1;
        const NAME = 2;
        if (vm.typeOf(NAMESPACE_TABLE) != .table) log.err(error.FfiCNamespaceIndexNamespaceTableExpectedTable, "Namespace table argument should be a table from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(NAMESPACE_TABLE) });
        if (vm.typeOf(NAME) != .string) log.err(error.FfiCNamespaceIndexNameExpectedString, "Name argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(NAME) });
        const name = vm.toString(NAME) catch |err| log.fatal(err, "Occured when reading name argument from main Lua VM stack", @src());

        const TOP_OF_STACK = -1;
        _ = vm.getField(NAMESPACE_TABLE, "__name");
        if (vm.typeOf(TOP_OF_STACK) != .string) log.err(error.FfiCNamespaceIndexMissingName, "cnamespace table is missing its __name field", .{});
        const ns = vm.toString(TOP_OF_STACK) catch |err| log.fatal(err, "Occured when reading __name from cnamespace table", .{});
        vm.pop(1);

        if (!self.index.contains(ns)) log.err(error.FfiCnamespaceIndexUnknownNamespace, "This namespace does not exist", .{ .key = ns });

        if (self.index.getPtr(ns).?.dynlib == null) log.err(error.FfiCnamespaceIndexUnloadedLibrary, "You must load a dynamic library before using it", .{ .key = ns });

        const ptr = self.index.getPtr(ns).?.dynlib.?.lookup(*const anyopaque, name) orelse log.err(error.SymbolNotFound, "Symbol not found", .{ .namespace = ns, .symbol = name });

        // TODO: remove this: std.log.debug("test {d}", .{@as(*const fn (c_int) callconv(.c) c_int, @ptrCast(ptr.?))(-8)});

        const ct = self.index.getPtr(ns).?.defs.get(name) orelse log.err(error.MissingDefinition, "Missing definition for symbol", .{ .namespace = ns, .symbol = name });

        CData.push(vm, ct, ptr);
        return 1;
    }

    pub fn indexIndex(self: *@This(), vm: *zlua.Lua) i32 {
        const INDEX = 1;
        const NAME = 2;
        if (vm.typeOf(INDEX) != .table) log.err(error.FfiIndexIndexIndexExpectedTable, "Index argument should be a table from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(INDEX) });
        if (vm.typeOf(NAME) != .string) log.err(error.FfiIndexIndexNameExpectedString, "Name argument should be a string from main Lua VM stack", .{ .src = @src(), .lua_type = vm.typeOf(NAME) });
        const name = vm.toString(NAME) catch |err| log.fatal(err, "Occured when reading name argument from main Lua VM stack", @src());

        if (!self.index.contains(name)) log.err(error.FfiIndexIndexUnknownNamespace, "This namespace does not exist", .{ .key = name });

        const TOP_OF_STACK = -1;
        const FFI_CNAMESPACETABLE_INSTANCE_NPOS = -2;
        const FFITABLE_NPOS = -2;
        vm.newTable();
        _ = vm.pushString(name);
        vm.setField(FFI_CNAMESPACETABLE_INSTANCE_NPOS, "__name");

        _ = vm.getGlobal("ffi");
        _ = vm.getField(TOP_OF_STACK, "CNamespace");
        vm.remove(FFITABLE_NPOS);
        vm.setMetatable(FFI_CNAMESPACETABLE_INSTANCE_NPOS);

        return 1;
    }

    pub fn cdataCall(self: *@This(), vm: *zlua.Lua) i32 {
        _ = self;
        const CDATA = 1;

        if (vm.typeOf(CDATA) != .userdata) {
            log.err(error.FfiCdataCallCdataExpectedUserdata, "cdata __call expected userdata", .{ .src = @src(), .lua_type = vm.typeOf(CDATA) });
        }

        const cd = vm.toUserdata(CData, CDATA) catch |err| log.fatal(err, "Occured when getting CData userdata", .{});

        if (cd.ctype.inner != .func) log.err(error.FfiCdataCallNotAFunction, "Attempt to call a non-function cdata", .{});
        const func = cd.ctype.inner.func;

        const nargs = func.params.len;
        if (vm.getTop() - 1 != @as(i32, @intCast(nargs))) {
            log.err(error.FfiCdataCallWrongNumberOfArguments, "Wrong number of arguments", .{ .expected = nargs, .got = vm.getTop() - 1 });
        }

        var arg_types: [MAX_ARGS]?*c.ffi_type = undefined;
        for (func.params, 0..) |param, i| {
            arg_types[i] = param.type.getFfiType() catch |err| log.fatal(err, "Occured when getting ffi_type for parameter", .{});
        }

        const ret_type = func.return_type.getFfiType() catch |err| log.fatal(err, "Occured when getting ffi_type for return type", .{});

        var cif: c.ffi_cif = undefined;
        const status = c.ffi_prep_cif(
            &cif,
            c.FFI_DEFAULT_ABI,
            @intCast(nargs),
            ret_type,
            if (nargs > 0) &arg_types else null
        );
        if (status != c.FFI_OK) {
            log.err(error.FfiPrepCifFailed, "ffi_prep_cif failed", .{ .status = status });
        }

        var arg_storage: [MAX_ARGS]Storage = undefined;
        var arg_values: [MAX_ARGS]?*anyopaque = undefined;
        for (func.params, 0..) |param, i| {
            const lua_idx: i32 = @intCast(i + 2);
            arg_values[i] = cFromLua(vm, lua_idx, param.type, &arg_storage[i]);
        }

        var ret_storage: Storage = undefined;
        const fn_ptr: *const fn () callconv(.c) void = @ptrCast(cd.ptr);

        c.ffi_call(
            &cif,
            fn_ptr,
            if (func.return_type.inner == .void) null else &ret_storage,
            if (nargs > 0) @ptrCast(&arg_values) else null
        );

        if (func.return_type.inner == .void) return 0;

        luaFromC(vm, func.return_type, &ret_storage);
        return 1;
    }
};
