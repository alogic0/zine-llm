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
