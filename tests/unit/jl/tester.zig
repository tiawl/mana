const std = @import("std");
const zlua = @import("zlua");
const jl = @import("jl");

fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

    return switch (a) {
        .null => true,
        .bool => |av| av == b.bool,
        .integer => |av| av == b.integer,
        .float => |av| av == b.float,
        .number_string => |av| std.mem.eql(u8, av, b.number_string),
        .string => |av| std.mem.eql(u8, av, b.string),
        .array => |av| {
            const bv = b.array;
            if (av.items.len != bv.items.len) return false;
            for (av.items, bv.items) |ai, bi| {
                if (!jsonEql(ai, bi)) return false;
            }
            return true;
        },
        .object => |av| {
            const bv = b.object;
            if (av.count() != bv.count()) return false;
            var it = av.iterator();
            while (it.next()) |entry| {
                const other = bv.get(entry.key_ptr.*) orelse return false;
                if (!jsonEql(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
    };
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const vm = try zlua.Lua.init(arena);
    defer vm.deinit();
    vm.openLibs();
    jl.setJsonGlobals(vm);
    var it = init.minimal.args.iterate();
    std.debug.assert(it.skip());
    const expected_json_str = try std.Io.Dir.cwd().readFileAlloc(init.io, it.next().?, arena, .unlimited);
    const expected = try std.json.parseFromSliceLeaky(std.json.Value, arena, expected_json_str, .{});
    try vm.doFile(it.next().?);

    _ = vm.getGlobal("eql");
    _ = vm.getGlobal("expected");

    try jl.luaFromJson(vm, &expected);

    vm.protectedCall(.{ .args = 2, .results = 1 }) catch |err| {
        const msg = if (vm.getTop() > 0) vm.toString(-1) catch "Unknown error" else "Unknown error";
        std.debug.print("Lua error: \"{s}\"\n", .{msg});
        return err;
    };

    std.debug.assert(vm.typeOf(-1) == .boolean);
    std.testing.expect(vm.toBoolean(-1)) catch std.process.exit(1);
    vm.pop(1);

    try jl.luaFromJson(vm, &expected);

    const result = try jl.jsonFromLua(vm, -1);
    std.testing.expect(jsonEql(expected, result)) catch {
        std.Io.File.stdout().writeStreamingAll(init.io, std.json.Stringify.valueAlloc(arena, result, .{ .whitespace = .indent_2 }) catch unreachable) catch unreachable;
        std.process.exit(2);
    };
    std.process.exit(3);
}
