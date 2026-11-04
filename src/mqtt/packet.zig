//! MQTT packet framing and parsing. Pure functions over byte slices: no
//! sockets or I/O, so everything here can be tested with plain byte arrays.

const std = @import("std");

pub const PacketType = enum(u4) {
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
};

/// The fixed header at the start of every MQTT packet: byte 0 (type + flags)
/// followed by 1 to 4 remaining-length bytes.
pub const FixedHeader = struct {
    /// High 4 bits of byte 0.
    packet_type: PacketType,
    /// Low 4 bits of byte 0. Only some packet types use them, PUBLISH most.
    flags: u4,
    /// Size of the fixed header itself: 1 type byte + 1 to 4 length bytes,
    /// so 2 to 5. The packet's body starts at this offset.
    header_len: usize,
    /// Number of bytes after the fixed header: the variable header plus the
    /// payload.
    remaining_len: usize,

    /// Reads the fixed header at the start of `buf`. The packet's body doesn't
    /// need to have arrived yet, only the header.
    ///
    /// Returns null if the header hasn't fully arrived yet.
    /// Returns error.InvalidPacketType for type 0 or 15 (reserved in MQTT
    /// 3.1.1), and error.InvalidLength if the remaining length would need more
    /// than 4 bytes.
    ///
    /// Remaining length encoding: each length byte holds 7 bits of the value
    /// (byte & 0x7F), and its top bit (0x80) says whether another length byte
    /// follows. Each length byte counts 128 times more than the one before it.
    pub fn parse(buf: []const u8) !?FixedHeader {
        if (buf.len == 0) return null;

        // Byte 0, high 4 bits: the type. fromInt returns null for numbers that
        // aren't in the enum (0 and 15).
        const packet_type = std.enums.fromInt(PacketType, buf[0] >> 4) orelse return error.InvalidPacketType;

        var multiplier_index: u8 = 0;
        const multiplier_vals: [4]usize = .{ 1, 128, 16_384, 2_097_152 };

        var total_len: usize = 2;

        // The length bytes start right after the type byte.
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
            // Ran out of bytes before the last length byte arrived.
            return null;
        }

        // 1 type byte + 1 length byte + 1 for each extra length byte.
        const header_len: usize = 2 + multiplier_index;

        return .{
            .packet_type = packet_type,
            // Byte 0, low 4 bits. The mask keeps it at 15 or less, so it fits
            // a u4.
            .flags = @intCast(buf[0] & 0x0F),
            .header_len = header_len,
            .remaining_len = total_len - header_len,
        };
    }

    /// Size of the whole packet: the fixed header plus everything after it.
    pub fn total(self: FixedHeader) usize {
        return self.header_len + self.remaining_len;
    }
};

/// Test helper: parse `buf` and check its header and remaining lengths.
fn expectLengths(buf: []const u8, header_len: usize, remaining_len: usize) !void {
    const header = (try FixedHeader.parse(buf)).?;
    try std.testing.expectEqual(header_len, header.header_len);
    try std.testing.expectEqual(remaining_len, header.remaining_len);
    try std.testing.expectEqual(header_len + remaining_len, header.total());
}

test "FixedHeader.parse: type and flags" {
    // PINGREQ: type 12, no flags.
    const ping = (try FixedHeader.parse(&.{ 0xC0, 0x00 })).?;
    try std.testing.expectEqual(PacketType.pingreq, ping.packet_type);
    try std.testing.expectEqual(0, ping.flags);

    // PUBLISH: type 3, flags 2.
    const publish = (try FixedHeader.parse(&.{ 0x32, 0x00 })).?;
    try std.testing.expectEqual(PacketType.publish, publish.packet_type);
    try std.testing.expectEqual(2, publish.flags);
}

test "FixedHeader.parse: one to four length bytes" {
    // One case per number of length bytes. Only the header has arrived in
    // each, which is all parse needs.
    try expectLengths(&.{ 0xC0, 0x00 }, 2, 0); // 1 length byte
    try expectLengths(&.{ 0x30, 0xC1, 0x02 }, 3, 321); // 2: 65 + 2 x 128
    try expectLengths(&.{ 0x30, 0xFF, 0xFF, 0x7F }, 4, 2_097_151); // 3
    try expectLengths(&.{ 0x30, 0xFF, 0xFF, 0xFF, 0x7F }, 5, 268_435_455); // 4: the maximum
}

test "FixedHeader.parse: incomplete or invalid header" {
    // Nothing buffered, only the type byte, or a length byte that says "more"
    // before the next one has arrived: wait for more bytes.
    try std.testing.expectEqual(null, try FixedHeader.parse(&[_]u8{}));
    try std.testing.expectEqual(null, try FixedHeader.parse(&.{0x10}));
    try std.testing.expectEqual(null, try FixedHeader.parse(&.{ 0x30, 0xC1 }));

    // Types 0 and 15 are reserved in MQTT 3.1.1.
    try std.testing.expectError(error.InvalidPacketType, FixedHeader.parse(&.{ 0x00, 0x00 }));
    try std.testing.expectError(error.InvalidPacketType, FixedHeader.parse(&.{ 0xF0, 0x00 }));

    // The 4th length byte says "more", but MQTT allows at most 4.
    try std.testing.expectError(error.InvalidLength, FixedHeader.parse(&.{ 0x30, 0x80, 0x80, 0x80, 0x80 }));
}
