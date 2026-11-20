const std = @import("std");
const zlua = @import("zlua");

const null_sentinel: *const anyopaque = &struct {
    var x: u8 = 0;
}.x;

const object_metatable_marker: *const anyopaque = &struct {
    var x: u8 = 0;
}.x;

fn isNullSentinel(vm: *zlua.Lua, index: i32) bool {
    if (vm.typeOf(index) != .light_userdata) return false;
    return (vm.toUserdata(anyopaque, index) catch return false) == null_sentinel;
}

fn isObjectMetatable(vm: *zlua.Lua, index: i32) bool {
    const METATABLE = -1;
    const MARKER = -1;
    const METATABLE_MARKER_LEN = 2;
    vm.getMetatable(index) catch return false;
    _ = vm.getPtrRaw(METATABLE, @constCast(object_metatable_marker));
    const has_metatable = (vm.typeOf(MARKER) == .boolean and vm.toBoolean(MARKER));
    vm.pop(METATABLE_MARKER_LEN);
    return has_metatable;
}

fn getOrCreateObjectMetatable(vm: *zlua.Lua) void {
    const REGISTRY_FIELD = -1;
    const REGISTRY_FIELD_LEN = 1;
    const NEW_TABLE = -2;
    const METATABLE = -1;
    _ = vm.getField(zlua.registry_index, "jl.object_metatable");
    if (vm.typeOf(REGISTRY_FIELD) == .table) return;
    vm.pop(REGISTRY_FIELD_LEN);

    vm.createTable(0, 1);
    vm.pushBoolean(true);
    vm.setPtrRaw(NEW_TABLE, @constCast(object_metatable_marker));

    vm.pushValue(METATABLE);
    vm.setField(zlua.registry_index, "jl.object_metatable");
}

fn pushJsonEmptyObject(vm: *zlua.Lua) void {
    const EMPTY_OBJECT = -2;
    vm.createTable(0, 0);
    getOrCreateObjectMetatable(vm);
    vm.setMetatable(EMPTY_OBJECT);
}

fn pushNull(vm: *zlua.Lua) void {
    vm.pushLightUserdata(@constCast(null_sentinel));
}

pub fn setJsonGlobals(vm: *zlua.Lua) void {
    pushNull(vm);
    vm.setGlobal("JSON_NULL");
    pushJsonEmptyObject(vm);
    vm.setGlobal("JSON_EMPTY_OBJECT");
}

pub fn free(gpa: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .number_string, .string => |s| gpa.free(s),
        .array => |*a| {
            for (a.items) |*item| free(gpa, item);
            a.deinit();
        },
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |*entry| {
                gpa.free(entry.key_ptr.*);
                free(gpa, entry.value_ptr);
            }
            o.deinit(gpa);
        },
        else => {},
    }
}

pub fn luaFromJson(vm: *zlua.Lua, json: *const std.json.Value) !void {
    try vm.checkStack(4);
    switch (json.*) {
        .null => vm.pushLightUserdata(@constCast(null_sentinel)),
        .bool => |b| vm.pushBoolean(b),
        .integer => |i| vm.pushInteger(i),
        .float => |f| vm.pushNumber(f),
        .number_string => |s| _ = vm.pushString(s),
        .string => |s| _ = vm.pushString(s),
        .array => |arr| {
            const ARRAY_TABLE = -2;
            vm.createTable(@intCast(arr.items.len), 0);
            for (arr.items, 0..) |item, i| {
                try luaFromJson(vm, &item);
                vm.setIndexRaw(ARRAY_TABLE, @intCast(i + 1));
            }
        },
        .object => |obj| {
            if (obj.count() == 0) {
                pushJsonEmptyObject(vm);
            } else {
                const OBJECT_TABLE = -3;
                vm.createTable(0, @intCast(obj.count()));
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try vm.checkStack(3);
                    _ = vm.pushString(entry.key_ptr.*);
                    try luaFromJson(vm, entry.value_ptr);
                    vm.setTable(OBJECT_TABLE);
                }
            }
        },
    }
}

pub fn jsonFromLua(vm: *zlua.Lua, index: i32) !std.json.Value {
    const idx = vm.absIndex(index);
    const gpa = vm.allocator();

    if (isNullSentinel(vm, idx)) return .null;

    switch (vm.typeOf(idx)) {
        .nil => return .null,
        .boolean => return .{ .bool = vm.toBoolean(idx) },
        .number => if (vm.isInteger(idx)) {
            return .{ .integer = try vm.toInteger(idx) };
        } else return .{ .float = try vm.toNumber(idx) },
        .string => {
            const s = try vm.toString(idx);
            return .{ .string = try gpa.dupe(u8, s) };
        },
        .table => {
            var is_object = false;
            var max_index: i64 = 0;
            var count: usize = 0;
            var has_non_integer_key = false;

            if (isObjectMetatable(vm, idx)) is_object = true;

            const KEY = -2;
            vm.pushNil();
            while (vm.next(idx)) {
                defer vm.pop(1);

                if (vm.typeOf(KEY) == .number and vm.isInteger(KEY)) {
                    const k = try vm.toInteger(KEY);
                    if (k >= 1) {
                        if (k > max_index) max_index = k;
                        count += 1;
                    } else has_non_integer_key = true;
                } else has_non_integer_key = true;
            }

            const TOP_OF_STACK = -1;
            _ = vm.getIndexRaw(idx, 1);
            const has_index_1 = vm.typeOf(TOP_OF_STACK) != .nil;
            vm.pop(1);

            is_object = if (has_index_1)
                false
            else if (has_non_integer_key or (count == 0 and isObjectMetatable(vm, idx)))
                true
            else if (count > 0 and @as(usize, @intCast(max_index)) == count)
                false
            else
                false;

            if (!is_object) {
                var arr = std.json.Array.init(gpa);
                errdefer arr.deinit();
                try arr.resize(@intCast(max_index));

                var i: i64 = 1;
                while (i <= max_index) : (i += 1) {
                    _ = vm.getIndexRaw(idx, @intCast(i));
                    defer vm.pop(1);
                    arr.items[@intCast(i - 1)] =
                        if (vm.typeOf(TOP_OF_STACK) == .nil) .null else try jsonFromLua(vm, TOP_OF_STACK);
                }
                return .{ .array = arr };
            } else {
                var obj: std.json.ObjectMap = .empty;
                errdefer obj.deinit(gpa);

                vm.pushNil();
                while (vm.next(idx)) {
                    defer vm.pop(1);

                    const key_str = if (vm.typeOf(KEY) == .string)
                        try vm.toString(KEY)
                    else if (vm.typeOf(KEY) == .number)
                        try gpa.print("{d}", .{try vm.toNumber(KEY)})
                    else
                        return error.UnsupportedLuaKeyType;

                    const owned_key = try gpa.dupe(u8, key_str);
                    const value = try jsonFromLua(vm, TOP_OF_STACK);
                    try obj.put(gpa, owned_key, value);
                }
                return .{ .object = obj };
            }
        },
        else => return error.UnsupportedLuaType,
    }
}
