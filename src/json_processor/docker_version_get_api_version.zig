const std = @import("std");
const Init = @import("init").Init;

pub const Impl = struct {
    pub fn init(ptr: *anyopaque, processor_init: *const Init) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, processor_init };
    }

    pub fn deinit(ptr: *anyopaque, processor_init: *const Init) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, processor_init };
    }

    pub fn process(ptr: *anyopaque, inputs: *const std.json.Array, processor_init: *const Init) std.json.Value {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = .{ self, processor_init };
        return inputs.items[0].object.get("ApiVersion").?;
    }
};
