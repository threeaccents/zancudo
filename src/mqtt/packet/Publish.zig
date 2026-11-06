const Publish = @This();

const std = @import("std");
const Reader = @import("../Reader.zig");
const QoS = @import("../packet.zig").QoS;

packet_id: u16,

pub fn decode(flags: u4, body: []const u8) !Publish {}
