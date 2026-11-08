//! Sets up the listening socket and runs the event loop.

const std = @import("std");
const Broker = @import("Broker.zig");
const Server = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var broker: Broker = .init(io, alloc);

    var server: Server = try .init(alloc, &broker, .{ 127, 0, 0, 1 }, 42069);
    defer server.deinit();

    try server.serve();
}

// Tests only run for files reachable from here.
test {
    _ = @import("mqtt.zig");
}
