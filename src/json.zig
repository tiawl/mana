const std = @import("std");

pub fn freeValue(gpa: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .number_string, .string => |s| gpa.free(s),
        .array => |*a| {
            for (a.items) |*item| freeValue(gpa, item);
            a.deinit();
        },
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |*entry| {
                gpa.free(entry.key_ptr.*);
                freeValue(gpa, entry.value_ptr);
            }
            o.deinit(gpa);
        },
        else => {},
    }
}

pub fn dupeValue(gpa: std.mem.Allocator, value: *const std.json.Value) !std.json.Value {
    return switch (value.*) {
        .null => .{ .null = {} },
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try gpa.dupe(u8, s) },
        .string => |s| .{ .string = try gpa.dupe(u8, s) },
        .array => |a| blk: {
            var new_arr = std.json.Array.init(gpa);
            for (a.items) |*item| try new_arr.append(try dupeValue(gpa, item));
            break :blk .{ .array = new_arr };
        },
        .object => |o| blk: {
            var new_obj: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |*entry| try new_obj.put(gpa, try gpa.dupe(u8, entry.key_ptr.*), try dupeValue(gpa, entry.value_ptr));
            break :blk .{ .object = new_obj };
        },
    };
}
