//! MQTT packet framing and parsing. Pure functions over byte slices: no
//! sockets or I/O, so everything here can be tested with plain byte arrays.

const std = @import("std");

/// Works out the total size of the first MQTT packet in `buf`: the fixed
/// header (1 type byte + 1 to 4 length bytes) plus the remaining length that
/// those length bytes encode.
///
/// Returns null if the header hasn't fully arrived yet, so the caller should
/// wait for more bytes. A total can be returned while the packet's body is
/// still arriving; the caller compares it with how many bytes are buffered.
/// Returns error.InvalidLength if the length would need more than 4 bytes.
///
/// Encoding: each length byte holds 7 bits of the value (byte & 0x7F), and
/// its top bit (0x80) says whether another length byte follows. Each length
/// byte counts 128 times more than the one before it.
pub fn packetLength(buf: []const u8) !?usize {
    if (buf.len == 0) return null;

    var multiplier_index: u8 = 0;
    // Place value of each length byte: 1, 128, 128 x 128, 128 x 128 x 128.
    const multiplier_vals: [4]usize = .{ 1, 128, 16_384, 2_097_152 };

    // Header size so far: 1 type byte + 1 length byte. Each extra length byte
    // adds 1 below, and each length byte's value is added on top.
    var total: usize = 2;

    // The length bytes start right after the type byte.
    for (buf[1..]) |byte| {
        // MQTT allows at most 4 length bytes, so the 4th can't say "more".
        if ((byte & 0x80) != 0 and multiplier_index == 3) return error.InvalidLength;

        // Value 0 with no "more" bit: the length ends here.
        if (byte == 0x00) return total;

        // The lower 7 bits are this byte's piece of the value, scaled by its
        // place value.
        const value = (byte & 0x7F) * multiplier_vals[multiplier_index];
        total += value;

        // Top bit set: another length byte follows.
        if ((byte & 0x80) != 0) {
            multiplier_index += 1;
            total += 1;
            continue;
        }

        // Top bit clear: that was the last length byte.
        return total;
    }

    // Ran out of bytes before the last length byte arrived.
    return null;
}

test "packetLength: remaining length fits in one byte" {
    // PINGREQ: type 12, remaining length 0. The whole packet is 2 bytes.
    try std.testing.expectEqual(2, try packetLength(&.{ 0xC0, 0x00 }));

    // CONNECT with client id "abc": remaining length 15, so 1 + 1 + 15 = 17.
    const connect = [_]u8{ 0x10, 0x0F, 0x00, 0x04, 'M', 'Q', 'T', 'T', 0x04, 0x02, 0x00, 0x3C, 0x00, 0x03, 'a', 'b', 'c' };
    try std.testing.expectEqual(17, try packetLength(&connect));

    // 0x7F (0111 1111) is the largest value one length byte can hold: 127.
    // Only the header is here, but the total is already known: 1 + 1 + 127.
    try std.testing.expectEqual(129, try packetLength(&.{ 0x30, 0x7F }));
}

test "packetLength: remaining length uses two bytes" {
    // 0x80 0x01: value 0 with "more" set, then 1 x 128. The smallest value that
    // needs two length bytes: 128. Total: 1 + 2 + 128.
    try std.testing.expectEqual(131, try packetLength(&.{ 0x30, 0x80, 0x01 }));

    // 0xC1 0x02: 65 + 2 x 128 = 321. Total: 1 + 2 + 321.
    try std.testing.expectEqual(324, try packetLength(&.{ 0x30, 0xC1, 0x02 }));

    // 0xFF 0x7F: 127 + 127 x 128 = 16,383, the largest two-byte value.
    // Total: 1 + 2 + 16,383.
    try std.testing.expectEqual(16_386, try packetLength(&.{ 0x30, 0xFF, 0x7F }));

    // 0xC1 has "more" set, but the second length byte hasn't arrived yet, so
    // the header isn't complete: wait for more bytes.
    try std.testing.expectEqual(null, try packetLength(&.{ 0x30, 0xC1 }));
}

test "packetLength: remaining length uses three bytes" {
    // 0x80 0x80 0x01: 0 + 0 x 128 + 1 x 16,384. The smallest value that needs
    // three length bytes: 16,384. Total: 1 + 3 + 16,384.
    try std.testing.expectEqual(16_388, try packetLength(&.{ 0x30, 0x80, 0x80, 0x01 }));

    // 0xFF 0xFF 0x7F: 127 + 127 x 128 + 127 x 16,384 = 2,097,151, the largest
    // three-byte value. Total: 1 + 3 + 2,097,151.
    try std.testing.expectEqual(2_097_155, try packetLength(&.{ 0x30, 0xFF, 0xFF, 0x7F }));

    // The second byte still has "more" set and the third hasn't arrived yet.
    try std.testing.expectEqual(null, try packetLength(&.{ 0x30, 0xFF, 0xFF }));
}

test "packetLength: remaining length uses four bytes" {
    // 0x80 0x80 0x80 0x01: 1 x 2,097,152. The smallest value that needs four
    // length bytes: 2,097,152. Total: 1 + 4 + 2,097,152.
    try std.testing.expectEqual(2_097_157, try packetLength(&.{ 0x30, 0x80, 0x80, 0x80, 0x01 }));

    // 0xFF 0xFF 0xFF 0x7F: 268,435,455, the largest remaining length MQTT
    // allows. Total: 1 + 4 + 268,435,455.
    try std.testing.expectEqual(268_435_460, try packetLength(&.{ 0x30, 0xFF, 0xFF, 0xFF, 0x7F }));

    // The third byte still has "more" set and the fourth hasn't arrived yet.
    try std.testing.expectEqual(null, try packetLength(&.{ 0x30, 0xFF, 0xFF, 0xFF }));
}

test "packetLength: header not here yet" {
    // Nothing buffered at all.
    try std.testing.expectEqual(null, try packetLength(&[_]u8{}));

    // Only the type byte has arrived, no length byte yet.
    try std.testing.expectEqual(null, try packetLength(&.{0x10}));
}

test "packetLength: more than four length bytes" {
    // The 4th length byte still has "more" set, so a 5th follows. MQTT allows
    // at most 4 length bytes, so the packet is broken.
    try std.testing.expectError(error.InvalidLength, packetLength(&.{ 0x30, 0x80, 0x80, 0x80, 0x80, 0x01 }));

    // Same, but the 5th byte hasn't arrived yet. The 4th byte's "more" bit is
    // already enough to know the packet is broken, so don't wait for more.
    try std.testing.expectError(error.InvalidLength, packetLength(&.{ 0x30, 0x80, 0x80, 0x80, 0x80 }));
}
