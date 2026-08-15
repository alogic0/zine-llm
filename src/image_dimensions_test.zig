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

test "SVG intrinsic dimensions" {
    const direct = try parse(fixtures.svg);
    try std.testing.expectEqual(Format.svg, direct.format);
    try std.testing.expectEqual(fixtures.width, direct.dimensions.width);
    try std.testing.expectEqual(fixtures.height, direct.dimensions.height);

    const derived = try parse(fixtures.svg_derived);
    try std.testing.expectEqual(fixtures.width, derived.dimensions.width);
    try std.testing.expectEqual(fixtures.height, derived.dimensions.height);

    const absolute_units = try parse("<svg width='1in' height='2.54cm'/>");
    try std.testing.expectEqual(@as(u32, 96), absolute_units.dimensions.width);
    try std.testing.expectEqual(@as(u32, 96), absolute_units.dimensions.height);

    const rounded = try parse("<svg width='.1px' height='1.6pt'/>");
    try std.testing.expectEqual(@as(u32, 1), rounded.dimensions.width);
    try std.testing.expectEqual(@as(u32, 2), rounded.dimensions.height);
}

test "SVG prolog and root scanning" {
    const with_doctype =
        "\xEF\xBB\xBF<?xml version='1.0'?><!DOCTYPE svg [<!ENTITY ignored '37'>]>" ++
        "<!-- before root --><svg height='23' width='37'></svg>";
    const result = try parse(with_doctype);
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);

    try std.testing.expectError(error.UnsupportedFormat, parse("<html width='37' height='23'>"));
    try std.testing.expectError(error.Truncated, parse("<?xml version='1.0'?> <!--"));
    try std.testing.expectError(error.Malformed, parse("<!CDATA[x]]><svg width='1' height='1'>"));
}

test "SVG unresolved and malformed sizing" {
    try std.testing.expectError(error.UnsupportedVariant, parse("<svg viewBox='0 0 37 23'/>"));
    try std.testing.expectError(error.UnsupportedVariant, parse("<svg width='100%' height='23'/>"));
    try std.testing.expectError(error.UnsupportedVariant, parse("<svg width='2em' height='23'/>"));
    try std.testing.expectError(error.UnsupportedVariant, parse("<svg width='37'/>"));
    try std.testing.expectError(error.Malformed, parse("<svg width='0' height='23'/>"));
    try std.testing.expectError(error.Malformed, parse("<svg width='37' viewBox='0 0 0 1'/>"));
    try std.testing.expectError(error.Truncated, parse("<svg width='37' height='23"));
    try std.testing.expectError(error.DimensionOverflow, parse("<svg width='4294967296' height='1'/>"));
}

test "SVG scanning is bounded" {
    var bytes: [64 * 1024 + 32]u8 = @splat(' ');
    bytes[0..4].* = "<!--".*;
    try std.testing.expectError(error.UnsupportedVariant, parse(&bytes));
}

test "static AVIF primary item dimensions" {
    const cases = .{
        .{ .bytes = &fixtures.avif, .width = fixtures.width, .height = fixtures.height },
        .{ .bytes = &fixtures.avif_unrelated_ispe, .width = fixtures.width, .height = fixtures.height },
        .{ .bytes = &fixtures.avif_large_id, .width = fixtures.width, .height = fixtures.height },
        .{ .bytes = &fixtures.avif_rotated, .width = fixtures.height, .height = fixtures.width },
        .{ .bytes = &fixtures.avif_cropped, .width = @as(u32, 17), .height = @as(u32, 11) },
    };
    inline for (cases) |case| {
        const result = try parse(case.bytes);
        try std.testing.expectEqual(Format.avif, result.format);
        try std.testing.expectEqual(case.width, result.dimensions.width);
        try std.testing.expectEqual(case.height, result.dimensions.height);
    }
}

test "upstream libavif fixture" {
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(fixtures.libavif_white_1x1_base64);
    try std.testing.expectEqual(@as(usize, 305), decoded_len);
    var bytes: [305]u8 = undefined;
    try std.base64.standard.Decoder.decode(&bytes, fixtures.libavif_white_1x1_base64);
    const result = try parse(&bytes);
    try std.testing.expectEqual(@as(u32, 1), result.dimensions.width);
    try std.testing.expectEqual(@as(u32, 1), result.dimensions.height);
}

test "AVIF rejects unsupported and malformed metadata" {
    try std.testing.expectError(error.UnsupportedVariant, parse(&fixtures.avif_grid));

    var sequence = fixtures.avif;
    sequence[20..24].* = "avis".*;
    try std.testing.expectError(error.UnsupportedVariant, parse(&sequence));

    var unrelated_primary = fixtures.avif_unrelated_ispe;
    unrelated_primary[unrelated_primary.len - 1] = 1;
    const wrong_dimensions = try parse(&unrelated_primary);
    try std.testing.expectEqual(@as(u32, 999), wrong_dimensions.dimensions.width);
    try std.testing.expectEqual(@as(u32, 888), wrong_dimensions.dimensions.height);

    var oversized_meta = fixtures.avif;
    std.mem.writeInt(u32, oversized_meta[28..32], oversized_meta.len, .big);
    try std.testing.expectError(error.Truncated, parse(&oversized_meta));

    var bad_ispe = fixtures.avif;
    const ispe = std.mem.indexOf(u8, &bad_ispe, "ispe").?;
    std.mem.writeInt(u32, bad_ispe[ispe + 8 ..][0..4], 0, .big);
    try std.testing.expectError(error.Malformed, parse(&bad_ispe));

    var unknown_essential = fixtures.avif;
    const property_type = std.mem.indexOf(u8, &unknown_essential, "ispe").?;
    unknown_essential[property_type..][0..4].* = "zzzz".*;
    unknown_essential[unknown_essential.len - 1] |= 0x80;
    try std.testing.expectError(error.UnsupportedVariant, parse(&unknown_essential));
}

test "AVIF property containers may be reordered" {
    const ipco_type = std.mem.indexOf(u8, &fixtures.avif, "ipco").?;
    const ipco_start = ipco_type - 4;
    const ipco_len = std.mem.readInt(u32, fixtures.avif[ipco_start..][0..4], .big);
    const ipma_type = std.mem.indexOfPos(u8, &fixtures.avif, ipco_start + ipco_len, "ipma").?;
    const ipma_start = ipma_type - 4;
    const ipma_len = std.mem.readInt(u32, fixtures.avif[ipma_start..][0..4], .big);

    var reordered = fixtures.avif;
    @memcpy(reordered[ipco_start..][0..ipma_len], fixtures.avif[ipma_start..][0..ipma_len]);
    @memcpy(reordered[ipco_start + ipma_len ..][0..ipco_len], fixtures.avif[ipco_start..][0..ipco_len]);
    const result = try parse(&reordered);
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);
}

test "AVIF box walking is bounded" {
    for (8..fixtures.avif.len) |prefix_len| {
        const expected_error = if (prefix_len == 28) error.Malformed else error.Truncated;
        try std.testing.expectError(expected_error, parse(fixtures.avif[0..prefix_len]));
    }

    var extended: [8 + fixtures.avif.len]u8 = @splat(0);
    extended[0..4].* = fixtures.avif[0..4].*;
    extended[4..8].* = "ftyp".*;
    extended[0..4].* = .{ 0, 0, 0, 1 };
    std.mem.writeInt(u64, extended[8..16], 16 + 20, .big);
    extended[16..36].* = fixtures.avif[8..28].*;
    extended[36..].* = fixtures.avif[28..].*;
    const result = try parse(&extended);
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);
}
