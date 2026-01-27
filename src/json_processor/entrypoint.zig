const Impl = @import("impl").Impl;
const JSONProcessor = @import("interface").JSONProcessor;

const Entrypoint = extern struct {
    init: *const fn () callconv(.c) void,
    deinit: *const fn () callconv(.c) void,
    process: *const fn ([*:0]const u8) callconv(.c) [*:0]const u8,
    free: *const fn ([*:0]const u8) callconv(.c) void,
};

var impl_instance: Impl = undefined;
var json_processor: JSONProcessor = .implement(Impl, &impl_instance);

fn init() callconv(.c) void {
    json_processor.init();
}

fn deinit() callconv(.c) void {
    json_processor.deinit();
}

fn process(inputs_str: [*:0]const u8) callconv(.c) [*:0]const u8 {
    return json_processor.process(inputs_str);
}

fn free(output_str: [*:0]const u8) callconv(.c) void {
    json_processor.free(output_str);
}

export fn getEntrypoint() callconv(.c) Entrypoint {
    return .{
        .init = init,
        .deinit = deinit,
        .process = process,
        .free = free,
    };
}

pub const EntrypointGetter = @TypeOf(&getEntrypoint);
