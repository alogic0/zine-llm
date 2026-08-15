const std = @import("std");
const fixtures = @import("image_dimensions_fixtures.zig");
const image_dimensions = @import("image_dimensions");
const legacy = @import("legacy_wuffs");

const Case = struct {
    name: []const u8,
    bytes: []const u8,
    width: i64 = fixtures.width,
    height: i64 = fixtures.height,
    first_complete_prefix: ?usize,
};

const cases = [_]Case{
    .{ .name = "png", .bytes = &fixtures.png, .first_complete_prefix = 41 },
    .{ .name = "gif", .bytes = &fixtures.gif, .first_complete_prefix = 22 },
    .{ .name = "jpeg SOF0", .bytes = &fixtures.jpeg, .first_complete_prefix = fixtures.jpeg.len },
    .{ .name = "BMP INFOHEADER", .bytes = &fixtures.bmp_info, .first_complete_prefix = fixtures.bmp_info.len },
    .{ .name = "BMP COREHEADER", .bytes = &fixtures.bmp_core, .first_complete_prefix = fixtures.bmp_core.len },
    .{ .name = "WebP VP8", .bytes = &fixtures.webp_vp8, .width = 1, .height = 1, .first_complete_prefix = null },
    .{ .name = "WebP VP8L", .bytes = &fixtures.webp_vp8l, .first_complete_prefix = 25 },
    .{ .name = "WebP VP8X", .bytes = &fixtures.webp_vp8x, .first_complete_prefix = null },
};

test "Wuffs dimension oracle" {
    for (cases) |case| {
        if (case.first_complete_prefix == null) {
            try std.testing.expectError(
                error.WuffsError,
                legacy.parseImageSize(std.testing.allocator, case.bytes),
            );
            continue;
        }
        const actual = legacy.parseImageSize(std.testing.allocator, case.bytes) catch |err| {
            std.debug.print("fixture {s} failed: {}\n", .{ case.name, err });
            return err;
        };
        try std.testing.expectEqual(case.width, actual.w);
        try std.testing.expectEqual(case.height, actual.h);
    }
}

test "Wuffs truncation boundaries" {
    for (cases) |case| {
        const first_complete_prefix = case.first_complete_prefix orelse continue;
        for (0..first_complete_prefix) |prefix_len| {
            if (legacy.parseImageSize(std.testing.allocator, case.bytes[0..prefix_len])) |size| {
                std.debug.print(
                    "fixture {s} unexpectedly completed at prefix {d} with {any}\n",
                    .{ case.name, prefix_len, size },
                );
                return error.UnexpectedSuccessfulPrefix;
            } else |_| {}
        }

        const actual = try legacy.parseImageSize(
            std.testing.allocator,
            case.bytes[0..first_complete_prefix],
        );
        try std.testing.expectEqual(case.width, actual.w);
        try std.testing.expectEqual(case.height, actual.h);
    }
}

test "Wuffs rejects unknown and malformed input" {
    try std.testing.expectError(
        error.UnsupportedImageFormat,
        legacy.parseImageSize(std.testing.allocator, "not an image"),
    );

    var malformed_png = fixtures.png;
    malformed_png[12] = 'X';
    try std.testing.expectError(
        error.WuffsError,
        legacy.parseImageSize(std.testing.allocator, &malformed_png),
    );
}

test "fixed-layout Zig results match Wuffs" {
    const retained_cases = .{
        &fixtures.png,
        &fixtures.gif,
        &fixtures.bmp_info,
        &fixtures.bmp_core,
    };
    inline for (retained_cases) |bytes| {
        const old = try legacy.parseImageSize(std.testing.allocator, bytes);
        const new = try image_dimensions.parse(bytes);
        try std.testing.expectEqual(old.w, new.dimensions.width);
        try std.testing.expectEqual(old.h, new.dimensions.height);
    }
}
