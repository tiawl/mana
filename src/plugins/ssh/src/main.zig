const std = @import("std");
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    _ = init;

    const ssh_client: [:0]const u8 = "ssh";
    const port_option: [:0]const u8 = "-p";
    const port: [:0]const u8 = "2222";
    const dest: [:0]const u8 = "sshuser@127.0.0.1";
    const args: []const [*c]const u8 = &.{
        ssh_client.ptr, port_option, port, dest,
    };
    _ = c.main(args.len, args.ptr);
}
