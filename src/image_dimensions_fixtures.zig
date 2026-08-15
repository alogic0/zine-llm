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
pub const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='37' height=\"23\"></svg>";
pub const svg_derived = "<?xml version='1.0'?><!--fixture--><svg:svg xmlns:svg='http://www.w3.org/2000/svg' height='23px' viewBox='0 0 74 46'/>";
pub const avif = makeAvif(&.{.{ .ispe = .{ .width = width, .height = height } }}, &.{1}, false, "av01");
pub const avif_unrelated_ispe = makeAvif(
    &.{
        .{ .ispe = .{ .width = 999, .height = 888 } },
        .{ .ispe = .{ .width = width, .height = height } },
    },
    &.{2},
    false,
    "av01",
);
pub const avif_rotated = makeAvif(
    &.{ .{ .ispe = .{ .width = width, .height = height } }, .{ .irot = 1 } },
    &.{ 1, 2 },
    false,
    "av01",
);
pub const avif_cropped = makeAvif(
    &.{
        .{ .ispe = .{ .width = width, .height = height } },
        .{ .clap = .{ .width = 17, .height = 11 } },
    },
    &.{ 1, 2 },
    false,
    "av01",
);
pub const avif_large_id = makeAvif(&.{.{ .ispe = .{ .width = width, .height = height } }}, &.{1}, true, "av01");
pub const avif_grid = makeAvif(&.{.{ .ispe = .{ .width = width, .height = height } }}, &.{1}, false, "grid");

/// libavif v1.2.0 `tests/data/white_1x1.avif`, licensed under the same
/// BSD-style license as libavif. Its test-data README identifies it as a
/// one-pixel image produced by libavif at default quality.
pub const libavif_white_1x1_base64 =
    "AAAAIGZ0eXBhdmlmAAAAAGF2aWZtaWYxbWlhZk1BMUEAAADybWV0YQAAAAAAAAAo" ++
    "aGRscgAAAAAAAAAAcGljdAAAAAAAAAAAAAAAAGxpYmF2aWYAAAAADnBpdG0AAAAA" ++
    "AAEAAAAeaWxvYwAAAABEAAABAAEAAAABAAABGgAAABcAAAAoaWluZgAAAAAAAQAA" ++
    "ABppbmZlAgAAAAABAABhdjAxQ29sb3IAAAAAamlwcnAAAABLaXBjbwAAABRpc3Bl" ++
    "AAAAAAAAAAEAAAABAAAAEHBpeGkAAAAAAwgICAAAAAxhdjFDgSAAAAAAABNjb2xy" ++
    "bmNseAABAA0ABoAAAAAXaXBtYQAAAAAAAAABAAEEAQKDBAAAAB9tZGF0EgAKBzgA" ++
    "BhAQ0GkyCh/wP///xAAAr3A=";

const FixtureDimensions = struct { width: u32, height: u32 };
const AvifProperty = union(enum) {
    ispe: FixtureDimensions,
    clap: FixtureDimensions,
    irot: u2,
};

fn makeAvif(
    comptime properties: []const AvifProperty,
    comptime associations: []const u8,
    comptime large_id: bool,
    comptime item_type: *const [4]u8,
) [avifFixtureLen(properties, associations.len, large_id)]u8 {
    const total_len = avifFixtureLen(properties, associations.len, large_id);
    var bytes: [total_len]u8 = @splat(0);

    const ftyp_size = 28;
    putBoxHeader(&bytes, 0, ftyp_size, "ftyp");
    bytes[8..12].* = "avif".*;
    bytes[16..20].* = "mif1".*;
    bytes[20..24].* = "avif".*;
    bytes[24..28].* = "miaf".*;

    const pitm_size: usize = if (large_id) 16 else 14;
    const infe_size: usize = if (large_id) 23 else 21;
    const iinf_size = 14 + infe_size;
    const ipco_size = avifIpcoLen(properties);
    const ipma_size = 19 + associations.len + @as(usize, if (large_id) 2 else 0);
    const iprp_size = 8 + ipco_size + ipma_size;
    const meta_size = 12 + pitm_size + iinf_size + iprp_size;
    putBoxHeader(&bytes, ftyp_size, meta_size, "meta");

    var offset: usize = ftyp_size + 12;
    putBoxHeader(&bytes, offset, pitm_size, "pitm");
    bytes[offset + 8] = if (large_id) 1 else 0;
    if (large_id) {
        std.mem.writeInt(u32, bytes[offset + 12 ..][0..4], 0x10001, .big);
    } else {
        std.mem.writeInt(u16, bytes[offset + 12 ..][0..2], 1, .big);
    }
    offset += pitm_size;

    putBoxHeader(&bytes, offset, iinf_size, "iinf");
    std.mem.writeInt(u16, bytes[offset + 12 ..][0..2], 1, .big);
    const infe_offset = offset + 14;
    putBoxHeader(&bytes, infe_offset, infe_size, "infe");
    bytes[infe_offset + 8] = if (large_id) 3 else 2;
    const id_len: usize = if (large_id) 4 else 2;
    if (large_id) {
        std.mem.writeInt(u32, bytes[infe_offset + 12 ..][0..4], 0x10001, .big);
    } else {
        std.mem.writeInt(u16, bytes[infe_offset + 12 ..][0..2], 1, .big);
    }
    bytes[infe_offset + 12 + id_len + 2 ..][0..4].* = item_type.*;
    offset += iinf_size;

    putBoxHeader(&bytes, offset, iprp_size, "iprp");
    const ipco_offset = offset + 8;
    putBoxHeader(&bytes, ipco_offset, ipco_size, "ipco");
    var property_offset = ipco_offset + 8;
    for (properties) |property| {
        property_offset = putAvifProperty(&bytes, property_offset, property);
    }

    const ipma_offset = ipco_offset + ipco_size;
    putBoxHeader(&bytes, ipma_offset, ipma_size, "ipma");
    bytes[ipma_offset + 8] = if (large_id) 1 else 0;
    std.mem.writeInt(u32, bytes[ipma_offset + 12 ..][0..4], 1, .big);
    var association_offset = ipma_offset + 16;
    if (large_id) {
        std.mem.writeInt(u32, bytes[association_offset..][0..4], 0x10001, .big);
        association_offset += 4;
    } else {
        std.mem.writeInt(u16, bytes[association_offset..][0..2], 1, .big);
        association_offset += 2;
    }
    bytes[association_offset] = associations.len;
    association_offset += 1;
    for (associations) |association| {
        bytes[association_offset] = association;
        association_offset += 1;
    }
    return bytes;
}

fn avifFixtureLen(comptime properties: []const AvifProperty, comptime association_count: usize, comptime large_id: bool) usize {
    const pitm_size: usize = if (large_id) 16 else 14;
    const infe_size: usize = if (large_id) 23 else 21;
    const iinf_size = 14 + infe_size;
    const ipma_size = 19 + association_count + @as(usize, if (large_id) 2 else 0);
    return 28 + 12 + pitm_size + iinf_size + 8 + avifIpcoLen(properties) + ipma_size;
}

fn avifIpcoLen(comptime properties: []const AvifProperty) usize {
    var len: usize = 8;
    for (properties) |property| len += switch (property) {
        .ispe => 20,
        .clap => 40,
        .irot => 9,
    };
    return len;
}

fn putAvifProperty(bytes: []u8, offset: usize, property: AvifProperty) usize {
    return switch (property) {
        .ispe => |dimensions| blk: {
            putBoxHeader(bytes, offset, 20, "ispe");
            std.mem.writeInt(u32, bytes[offset + 12 ..][0..4], dimensions.width, .big);
            std.mem.writeInt(u32, bytes[offset + 16 ..][0..4], dimensions.height, .big);
            break :blk offset + 20;
        },
        .clap => |dimensions| blk: {
            putBoxHeader(bytes, offset, 40, "clap");
            std.mem.writeInt(u32, bytes[offset + 8 ..][0..4], dimensions.width, .big);
            std.mem.writeInt(u32, bytes[offset + 12 ..][0..4], 1, .big);
            std.mem.writeInt(u32, bytes[offset + 16 ..][0..4], dimensions.height, .big);
            std.mem.writeInt(u32, bytes[offset + 20 ..][0..4], 1, .big);
            std.mem.writeInt(u32, bytes[offset + 28 ..][0..4], 1, .big);
            std.mem.writeInt(u32, bytes[offset + 36 ..][0..4], 1, .big);
            break :blk offset + 40;
        },
        .irot => |angle| blk: {
            putBoxHeader(bytes, offset, 9, "irot");
            bytes[offset + 8] = angle;
            break :blk offset + 9;
        },
    };
}

fn putBoxHeader(bytes: []u8, offset: usize, size: usize, comptime kind: *const [4]u8) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], size, .big);
    bytes[offset + 4 ..][0..4].* = kind.*;
}

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
