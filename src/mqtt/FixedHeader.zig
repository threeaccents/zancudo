//! The fixed header at the start of every MQTT packet: byte 0 (type + flags)
//! followed by 1 to 4 remaining-length bytes.
const FixedHeader = @This();

const std = @import("std");
const PacketType = @import("packet.zig").PacketType;

packet_type: PacketType,
flags: u4,

/// 2 to 5 bytes. The body starts at this offset.
header_len: usize,

/// Bytes after the fixed header.
remaining_len: usize,

/// Returns null if the header hasn't fully arrived yet. The body doesn't need
/// to have arrived.
///
/// Each remaining-length byte holds 7 bits of the value, and its top bit says
/// another byte follows. Each byte counts 128 times more than the one before.
pub fn parse(buf: []const u8) !?FixedHeader {
    if (buf.len == 0) return null;

    // Types 0 and 15 aren't in the enum, so fromInt returns null for them.
    const packet_type = std.enums.fromInt(PacketType, buf[0] >> 4) orelse return error.InvalidPacketType;

    var multiplier_index: u8 = 0;
    const multiplier_vals: [4]usize = .{ 1, 128, 16_384, 2_097_152 };

    var total_len: usize = 2;

    for (buf[1..]) |byte| {
        // MQTT allows at most 4 length bytes, so the 4th can't say "more".
        if ((byte & 0x80) != 0 and multiplier_index == 3) return error.InvalidLength;

        if (byte == 0x00) break;

        const value = (byte & 0x7F) * multiplier_vals[multiplier_index];
        total_len += value;

        if ((byte & 0x80) != 0) {
            multiplier_index += 1;
            total_len += 1;
            continue;
        }

        break;
    } else {
        return null;
    }

    const header_len: usize = 2 + multiplier_index;

    return .{
        .packet_type = packet_type,
        .flags = @intCast(buf[0] & 0x0F),
        .header_len = header_len,
        .remaining_len = total_len - header_len,
    };
}

pub fn packetLen(self: FixedHeader) usize {
    return self.header_len + self.remaining_len;
}

fn expectLengths(buf: []const u8, header_len: usize, remaining_len: usize) !void {
    const testing = std.testing;

    const header = (try parse(buf)).?;
    try testing.expectEqual(header_len, header.header_len);
    try testing.expectEqual(remaining_len, header.remaining_len);
    try testing.expectEqual(header_len + remaining_len, header.packetLen());
}

test "FixedHeader: parse type and flags" {
    const testing = std.testing;

    // PINGREQ: type 12, no flags.
    const ping = (try parse(&.{ 0xC0, 0x00 })).?;
    try testing.expectEqual(PacketType.pingreq, ping.packet_type);
    try testing.expectEqual(0, ping.flags);

    // PUBLISH: type 3, flags 2.
    const publish = (try parse(&.{ 0x32, 0x00 })).?;
    try testing.expectEqual(PacketType.publish, publish.packet_type);
    try testing.expectEqual(2, publish.flags);
}

test "FixedHeader: parse one to four length bytes" {
    try expectLengths(&.{ 0xC0, 0x00 }, 2, 0); // 1 length byte
    try expectLengths(&.{ 0x30, 0xC1, 0x02 }, 3, 321); // 2: 65 + 2 x 128
    try expectLengths(&.{ 0x30, 0xFF, 0xFF, 0x7F }, 4, 2_097_151); // 3
    try expectLengths(&.{ 0x30, 0xFF, 0xFF, 0xFF, 0x7F }, 5, 268_435_455); // 4: the maximum
}

test "FixedHeader: parse incomplete or invalid header" {
    const testing = std.testing;

    // Header not complete yet.
    try testing.expectEqual(null, try parse(&[_]u8{}));
    try testing.expectEqual(null, try parse(&.{0x10}));
    try testing.expectEqual(null, try parse(&.{ 0x30, 0xC1 }));

    // Types 0 and 15 are reserved in MQTT 3.1.1.
    try testing.expectError(error.InvalidPacketType, parse(&.{ 0x00, 0x00 }));
    try testing.expectError(error.InvalidPacketType, parse(&.{ 0xF0, 0x00 }));

    // The 4th length byte says "more", but MQTT allows at most 4.
    try testing.expectError(error.InvalidLength, parse(&.{ 0x30, 0x80, 0x80, 0x80, 0x80 }));
}
