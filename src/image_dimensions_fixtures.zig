const std = @import("std");

pub const width: u32 = 37;
pub const height: u32 = 23;

pub const png = makePng(width, height);
pub const gif = makeGif(width, height);
pub const jpeg = makeJpeg(width, height);
pub const jpeg_app = makeJpegWithApp(width, height);
pub const jpeg_progressive = makeJpegMarker(width, height, 0xC2);
pub const bmp_info = makeBmpInfo(width, height);
pub const bmp_core = makeBmpCore(width, height);
pub const webp_vp8 = makeWebpVp8();
pub const webp_vp8l = makeWebpVp8l(width, height);
pub const webp_vp8x = makeWebpVp8x(width, height);

fn makePng(w: u32, h: u32) [45]u8 {
    var bytes: [45]u8 = @splat(0);
    bytes[0..8].* = .{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    std.mem.writeInt(u32, bytes[8..12], 13, .big);
    bytes[12..16].* = "IHDR".*;
    std.mem.writeInt(u32, bytes[16..20], w, .big);
    std.mem.writeInt(u32, bytes[20..24], h, .big);
    bytes[24..29].* = .{ 8, 2, 0, 0, 0 };
    std.mem.writeInt(u32, bytes[29..33], std.hash.Crc32.hash(bytes[12..29]), .big);
    bytes[37..41].* = "IDAT".*;
    std.mem.writeInt(u32, bytes[41..45], std.hash.Crc32.hash(bytes[37..41]), .big);
    return bytes;
}

fn makeGif(w: u16, h: u16) [23]u8 {
    var bytes: [23]u8 = @splat(0);
    bytes[0..6].* = "GIF89a".*;
    std.mem.writeInt(u16, bytes[6..8], w, .little);
    std.mem.writeInt(u16, bytes[8..10], h, .little);
    bytes[13] = 0x2C;
    std.mem.writeInt(u16, bytes[18..20], w, .little);
    std.mem.writeInt(u16, bytes[20..22], h, .little);
    return bytes;
}

fn makeJpeg(w: u16, h: u16) [15]u8 {
    return makeJpegMarker(w, h, 0xC0);
}

fn makeJpegMarker(w: u16, h: u16, marker: u8) [15]u8 {
    var bytes: [15]u8 = @splat(0);
    bytes[0..5].* = .{ 0xFF, 0xD8, 0xFF, marker, 0x00 };
    bytes[5] = 11;
    bytes[6] = 8;
    std.mem.writeInt(u16, bytes[7..9], h, .big);
    std.mem.writeInt(u16, bytes[9..11], w, .big);
    bytes[11..15].* = .{ 1, 1, 0x11, 0 };
    return bytes;
}

fn makeJpegWithApp(w: u16, h: u16) [24]u8 {
    var bytes: [24]u8 = @splat(0);
    bytes[0..4].* = .{ 0xFF, 0xD8, 0xFF, 0xE1 };
    std.mem.writeInt(u16, bytes[4..6], 7, .big);
    bytes[6..11].* = "Exif\x00".*;
    bytes[11..24].* = makeJpeg(w, h)[2..15].*;
    return bytes;
}

fn makeBmpInfo(w: i32, h: i32) [54]u8 {
    var bytes: [54]u8 = @splat(0);
    bytes[0..2].* = "BM".*;
    std.mem.writeInt(u32, bytes[2..6], bytes.len, .little);
    std.mem.writeInt(u32, bytes[10..14], bytes.len, .little);
    std.mem.writeInt(u32, bytes[14..18], 40, .little);
    std.mem.writeInt(i32, bytes[18..22], w, .little);
    std.mem.writeInt(i32, bytes[22..26], h, .little);
    std.mem.writeInt(u16, bytes[26..28], 1, .little);
    std.mem.writeInt(u16, bytes[28..30], 24, .little);
    return bytes;
}

fn makeBmpCore(w: u16, h: u16) [26]u8 {
    var bytes: [26]u8 = @splat(0);
    bytes[0..2].* = "BM".*;
    std.mem.writeInt(u32, bytes[2..6], bytes.len, .little);
    std.mem.writeInt(u32, bytes[10..14], bytes.len, .little);
    std.mem.writeInt(u32, bytes[14..18], 12, .little);
    std.mem.writeInt(u16, bytes[18..20], w, .little);
    std.mem.writeInt(u16, bytes[20..22], h, .little);
    std.mem.writeInt(u16, bytes[22..24], 1, .little);
    std.mem.writeInt(u16, bytes[24..26], 24, .little);
    return bytes;
}

fn makeWebpVp8() [42]u8 {
    return [_]u8{
        'R',  'I',  'F',  'F',  0x22, 0x00, 0x00, 0x00, 'W',  'E',  'B',  'P',
        'V',  'P',  '8',  ' ',  0x16, 0x00, 0x00, 0x00, 0x30, 0x01, 0x00, 0x9D,
        0x01, 0x2A, 0x01, 0x00, 0x01, 0x00, 0x01, 0x40, 0x26, 0x25, 0xA4, 0x00,
        0x03, 0x70, 0x00, 0xFE, 0xFF, 0x3D,
    };
}

fn makeWebpVp8l(w: u14, h: u14) [26]u8 {
    var bytes = webpContainer("VP8L", 5);
    bytes[20] = 0x2F;
    const dimension_bits: u32 = @as(u32, w - 1) | (@as(u32, h - 1) << 14);
    std.mem.writeInt(u32, bytes[21..25], dimension_bits, .little);
    return bytes;
}

fn makeWebpVp8x(w: u24, h: u24) [44]u8 {
    var bytes: [44]u8 = @splat(0);
    bytes[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .little);
    bytes[8..12].* = "WEBP".*;
    bytes[12..16].* = "VP8X".*;
    std.mem.writeInt(u32, bytes[16..20], 10, .little);
    writeU24Le(bytes[24..27], w - 1);
    writeU24Le(bytes[27..30], h - 1);
    bytes[30..34].* = "VP8L".*;
    std.mem.writeInt(u32, bytes[34..38], 5, .little);
    bytes[38] = 0x2F;
    const dimension_bits: u32 = @as(u32, w - 1) | (@as(u32, h - 1) << 14);
    std.mem.writeInt(u32, bytes[39..43], dimension_bits, .little);
    return bytes;
}

fn webpContainer(comptime chunk: *const [4]u8, comptime payload_len: u32) [20 + payload_len + (payload_len & 1)]u8 {
    var bytes: [20 + payload_len + (payload_len & 1)]u8 = @splat(0);
    bytes[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .little);
    bytes[8..12].* = "WEBP".*;
    bytes[12..16].* = chunk.*;
    std.mem.writeInt(u32, bytes[16..20], payload_len, .little);
    return bytes;
}

fn writeU24Le(dest: *[3]u8, value: u24) void {
    dest.* = .{
        @truncate(value),
        @truncate(value >> 8),
        @truncate(value >> 16),
    };
}

test "fixtures have their declared container sizes" {
    inline for (.{ webp_vp8, webp_vp8l, webp_vp8x }) |bytes| {
        try std.testing.expectEqual(bytes.len - 8, std.mem.readInt(u32, bytes[4..8], .little));
    }
}
