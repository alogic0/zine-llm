const std = @import("std");
const fixtures = @import("image_dimensions_fixtures.zig");
const image_dimensions = @import("image_dimensions.zig");
const image_dimensions_file = @import("image_dimensions_file.zig");

const Case = struct {
    name: []const u8,
    bytes: []const u8,
    format: image_dimensions.Format,
    width: u32 = fixtures.width,
    height: u32 = fixtures.height,
};

test "filesystem probe handles every supported fixture" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cases = [_]Case{
        .{ .name = "image.png", .bytes = &fixtures.png, .format = .png },
        .{ .name = "image.gif", .bytes = &fixtures.gif, .format = .gif },
        .{ .name = "image.jpg", .bytes = &fixtures.jpeg_app, .format = .jpeg },
        .{ .name = "info.bmp", .bytes = &fixtures.bmp_info, .format = .bmp },
        .{ .name = "core.bmp", .bytes = &fixtures.bmp_core, .format = .bmp },
        .{ .name = "lossy.webp", .bytes = &fixtures.webp_vp8, .format = .webp, .width = 1, .height = 1 },
        .{ .name = "lossless.webp", .bytes = &fixtures.webp_vp8l, .format = .webp },
        .{ .name = "extended.webp", .bytes = &fixtures.webp_vp8x, .format = .webp },
        .{ .name = "image.svg", .bytes = fixtures.svg, .format = .svg },
        .{ .name = "image.avif", .bytes = &fixtures.avif, .format = .avif },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = case.name, .data = case.bytes });
        const result = try image_dimensions_file.probeFile(io, tmp.dir, case.name);
        try std.testing.expectEqual(case.format, result.format);
        try std.testing.expectEqual(case.width, result.dimensions.width);
        try std.testing.expectEqual(case.height, result.dimensions.height);
    }
}

test "filesystem probe skips large unrelated ranges" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var jpeg: [3017]u8 = @splat(0xA5);
    jpeg[0..4].* = .{ 0xFF, 0xD8, 0xFF, 0xE1 };
    std.mem.writeInt(u16, jpeg[4..6], 3000, .big);
    jpeg[3004..].* = fixtures.jpeg[2..].*;
    try tmp.dir.writeFile(io, .{ .sub_path = "metadata.jpg", .data = &jpeg });
    var result = try image_dimensions_file.probeFile(io, tmp.dir, "metadata.jpg");
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);

    var webp: [4036]u8 = @splat(0x5A);
    webp[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, webp[4..8], webp.len - 8, .little);
    webp[8..12].* = "WEBP".*;
    webp[12..16].* = "JUNK".*;
    std.mem.writeInt(u32, webp[16..20], 4001, .little);
    webp[4022..].* = fixtures.webp_vp8l[12..].*;
    try tmp.dir.writeFile(io, .{ .sub_path = "chunks.webp", .data = &webp });
    result = try image_dimensions_file.probeFile(io, tmp.dir, "chunks.webp");
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);

    const metadata_len = fixtures.avif.len - 28;
    var avif: [28 + 4104 + metadata_len]u8 = @splat(0x33);
    avif[0..28].* = fixtures.avif[0..28].*;
    std.mem.writeInt(u32, avif[28..32], 4104, .big);
    avif[32..36].* = "mdat".*;
    avif[28 + 4104 ..].* = fixtures.avif[28..].*;
    try tmp.dir.writeFile(io, .{ .sub_path = "spaced.avif", .data = &avif });
    result = try image_dimensions_file.probeFile(io, tmp.dir, "spaced.avif");
    try std.testing.expectEqual(fixtures.width, result.dimensions.width);
    try std.testing.expectEqual(fixtures.height, result.dimensions.height);
}

test "filesystem and parser failures remain distinct and non-allocating" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.FileNotFound,
        image_dimensions_file.probeFile(io, tmp.dir, "missing.png"),
    );

    try tmp.dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
    try std.testing.expectError(
        error.Truncated,
        image_dimensions_file.probeFile(io, tmp.dir, "empty"),
    );

    try tmp.dir.writeFile(io, .{ .sub_path = "short.png", .data = fixtures.png[0..12] });
    try std.testing.expectError(
        error.Truncated,
        image_dimensions_file.probeFile(io, tmp.dir, "short.png"),
    );

    var webp = fixtures.webp_vp8l;
    std.mem.writeInt(u32, webp[16..20], std.math.maxInt(u32), .little);
    try tmp.dir.writeFile(io, .{ .sub_path = "oversized.webp", .data = &webp });
    try std.testing.expectError(
        error.Truncated,
        image_dimensions_file.probeFile(io, tmp.dir, "oversized.webp"),
    );

    var avif = fixtures.avif;
    std.mem.writeInt(u32, avif[28..32], std.math.maxInt(u32), .big);
    try tmp.dir.writeFile(io, .{ .sub_path = "oversized.avif", .data = &avif });
    try std.testing.expectError(
        error.Truncated,
        image_dimensions_file.probeFile(io, tmp.dir, "oversized.avif"),
    );
}
