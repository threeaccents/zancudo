//! Sets up the listening socket and runs the event loop.

const std = @import("std");
const sys = @import("sys.zig");
const Conn = @import("Conn.zig");
const Broker = @import("Broker.zig");
const Server = @import("Server.zig");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var server: Server = try .init(io, alloc, .{ 127, 0, 0, 1 }, 42069);
    defer server.deinit();

    try server.listen();
}

// Tests only run for files reachable from here.
test {
    _ = @import("mqtt.zig");
}
