const PubAck = @This();

const std = @import("std");
const Writer = @import("../Writer.zig");

pub fn encode(self: *PubAck, w: *Writer) !void {
    _ = self;
    try w.writeByte(0x40);
    try w.writeRemainingLength(0);
}
