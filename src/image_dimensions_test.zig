const std = @import("std");
const fixtures = @import("image_dimensions_fixtures.zig");
const image_dimensions = @import("image_dimensions");

const Format = image_dimensions.Format;
const parse = image_dimensions.parse;

test "fixed-layout fixtures" {
    const cases = .{
        .{ .bytes = &fixtures.png, .format = Format.png },
        .{ .bytes = &fixtures.gif, .format = Format.gif },
        .{ .bytes = &fixtures.bmp_info, .format = Format.bmp },
        .{ .bytes = &fixtures.bmp_core, .format = Format.bmp },
        .{ .bytes = &fixtures.jpeg, .format = Format.jpeg },
        .{ .bytes = &fixtures.jpeg_app, .format = Format.jpeg },
        .{ .bytes = &fixtures.jpeg_progressive, .format = Format.jpeg },
    };

    inline for (cases) |case| {
        const result = try parse(case.bytes);
        try std.testing.expectEqual(case.format, result.format);
        try std.testing.expectEqual(fixtures.width, result.dimensions.width);
        try std.testing.expectEqual(fixtures.height, result.dimensions.height);
    }
}

test "fixed-layout required-header truncations" {
    const cases = .{
        .{ .bytes = &fixtures.png, .required = 29 },
        .{ .bytes = &fixtures.gif, .required = 13 },
        .{ .bytes = &fixtures.bmp_info, .required = fixtures.bmp_info.len },
        .{ .bytes = &fixtures.bmp_core, .required = fixtures.bmp_core.len },
        .{ .bytes = &fixtures.jpeg, .required = fixtures.jpeg.len },
        .{ .bytes = &fixtures.jpeg_app, .required = fixtures.jpeg_app.len },
    };

    inline for (cases) |case| {
        for (0..case.required) |prefix_len| {
            try std.testing.expectError(error.Truncated, parse(case.bytes[0..prefix_len]));
        }
        _ = try parse(case.bytes[0..case.required]);
    }
}

test "fixed-layout dimensions and byte order" {
    var png = fixtures.png;
    std.mem.writeInt(u32, png[16..20], 0x01020304, .big);
    std.mem.writeInt(u32, png[20..24], 0x05060708, .big);
    var result = try parse(&png);
    try std.testing.expectEqual(@as(u32, 0x01020304), result.dimensions.width);
    try std.testing.expectEqual(@as(u32, 0x05060708), result.dimensions.height);

    var gif = fixtures.gif;
    std.mem.writeInt(u16, gif[6..8], 0x0102, .little);
    std.mem.writeInt(u16, gif[8..10], 0x0304, .little);
    result = try parse(&gif);
    try std.testing.expectEqual(@as(u32, 0x0102), result.dimensions.width);
    try std.testing.expectEqual(@as(u32, 0x0304), result.dimensions.height);

    var bmp = fixtures.bmp_info;
    std.mem.writeInt(i32, bmp[18..22], 513, .little);
    std.mem.writeInt(i32, bmp[22..26], -257, .little);
    result = try parse(&bmp);
    try std.testing.expectEqual(@as(u32, 513), result.dimensions.width);
    try std.testing.expectEqual(@as(u32, 257), result.dimensions.height);

    std.mem.writeInt(i32, bmp[22..26], std.math.minInt(i32), .little);
    result = try parse(&bmp);
    try std.testing.expectEqual(@as(u32, 1) << 31, result.dimensions.height);
}

test "fixed-layout malformed and unsupported headers" {
    var png = fixtures.png;
    std.mem.writeInt(u32, png[16..20], 0, .big);
    try std.testing.expectError(error.Malformed, parse(&png));
    png = fixtures.png;
    png[25] = 1;
    try std.testing.expectError(error.Malformed, parse(&png));

    var gif = fixtures.gif;
    std.mem.writeInt(u16, gif[8..10], 0, .little);
    try std.testing.expectError(error.Malformed, parse(&gif));

    var bmp = fixtures.bmp_info;
    std.mem.writeInt(u32, bmp[14..18], 16, .little);
    try std.testing.expectError(error.UnsupportedVariant, parse(&bmp));

    try std.testing.expectError(error.UnsupportedFormat, parse("not an image"));
}

test "JPEG marker walking" {
    var with_fill_and_tem: [19]u8 = @splat(0);
    with_fill_and_tem[0..6].* = .{ 0xFF, 0xD8, 0xFF, 0x01, 0xFF, 0xFF };
    with_fill_and_tem[6..19].* = fixtures.jpeg[2..15].*;
    const result = try parse(&with_fill_and_tem);
    try std.testing.expectEqual(Format.jpeg, result.format);
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);

    var bad_length = fixtures.jpeg_app;
    std.mem.writeInt(u16, bad_length[4..6], 1, .big);
    try std.testing.expectError(error.Malformed, parse(&bad_length));

    var zero_height = fixtures.jpeg;
    std.mem.writeInt(u16, zero_height[7..9], 0, .big);
    try std.testing.expectError(error.Malformed, parse(&zero_height));

    try std.testing.expectError(error.Malformed, parse(&.{ 0xFF, 0xD8, 0xFF, 0xD9 }));
    try std.testing.expectError(error.Malformed, parse(&.{ 0xFF, 0xD8, 0xFF, 0xDA, 0, 2 }));
    try std.testing.expectError(error.Truncated, parse(&.{ 0xFF, 0xD8, 0xFF, 0xE1, 0, 20 }));
}

test "WebP container variants" {
    const cases = .{
        .{ .bytes = &fixtures.webp_vp8, .width = @as(u32, 1), .height = @as(u32, 1) },
        .{ .bytes = &fixtures.webp_vp8l, .width = fixtures.width, .height = fixtures.height },
        .{ .bytes = &fixtures.webp_vp8x, .width = fixtures.width, .height = fixtures.height },
    };
    inline for (cases) |case| {
        const result = try parse(case.bytes);
        try std.testing.expectEqual(Format.webp, result.format);
        try std.testing.expectEqual(case.width, result.dimensions.width);
        try std.testing.expectEqual(case.height, result.dimensions.height);

        for (0..case.bytes.len) |prefix_len| {
            try std.testing.expectError(error.Truncated, parse(case.bytes[0..prefix_len]));
        }
    }
}

test "WebP validates RIFF and chunk metadata" {
    var bad_signature = fixtures.webp_vp8;
    bad_signature[23] = 0;
    try std.testing.expectError(error.Malformed, parse(&bad_signature));

    var zero_width = fixtures.webp_vp8;
    zero_width[26] = 0;
    zero_width[27] = 0;
    try std.testing.expectError(error.Malformed, parse(&zero_width));

    var bad_lossless_version = fixtures.webp_vp8l;
    bad_lossless_version[24] |= 0x20;
    try std.testing.expectError(error.UnsupportedVariant, parse(&bad_lossless_version));

    var bad_extended_flags = fixtures.webp_vp8x;
    bad_extended_flags[20] = 1;
    try std.testing.expectError(error.Malformed, parse(&bad_extended_flags));

    var oversized_chunk = fixtures.webp_vp8l;
    std.mem.writeInt(u32, oversized_chunk[16..20], 50, .little);
    try std.testing.expectError(error.Truncated, parse(&oversized_chunk));

    var wrong_form = fixtures.webp_vp8l;
    wrong_form[8..12].* = "WAVE".*;
    try std.testing.expectError(error.UnsupportedFormat, parse(&wrong_form));
}

test "WebP skips unrelated chunks and accounts for odd padding" {
    var bytes: [38]u8 = @splat(0);
    bytes[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, bytes[4..8], bytes.len - 8, .little);
    bytes[8..12].* = "WEBP".*;
    bytes[12..16].* = "JUNK".*;
    std.mem.writeInt(u32, bytes[16..20], 3, .little);
    bytes[20..23].* = .{ 1, 2, 3 };
    bytes[24..38].* = fixtures.webp_vp8l[12..26].*;

    const result = try parse(&bytes);
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);

    std.mem.writeInt(u32, bytes[4..8], bytes.len - 9, .little);
    try std.testing.expectError(error.Truncated, parse(&bytes));
}
