//! PINGRESP: the server's reply to PINGREQ. It has no body.
const PingResp = @This();

const Writer = @import("../Writer.zig");

pub fn encode(self: PingResp, w: *Writer) !void {
    _ = self;
    try w.writeByte(0xD0);
    try w.writeRemainingLength(0);
}
