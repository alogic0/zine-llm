const std = @import("std");
const fixtures = @import("image_dimensions_fixtures.zig");
const image_dimensions = @import("image_dimensions");

fn expectSafe(bytes: []const u8) !void {
    if (image_dimensions.parse(bytes)) |result| {
        try std.testing.expect(result.dimensions.width > 0);
        try std.testing.expect(result.dimensions.height > 0);
    } else |err| switch (err) {
        error.UnsupportedFormat,
        error.UnsupportedVariant,
        error.Truncated,
        error.Malformed,
        error.DimensionOverflow,
        => {},
    }
}

fn exercisePrefixesAndMutations(original: []const u8) !void {
    try std.testing.expect(original.len <= 512);
    for (0..original.len + 1) |prefix_len| try expectSafe(original[0..prefix_len]);

    var mutated: [512]u8 = undefined;
    @memcpy(mutated[0..original.len], original);
    for (0..original.len) |index| {
        inline for (.{ @as(u8, 0x01), @as(u8, 0x80), @as(u8, 0xFF) }) |mask| {
            mutated[index] = original[index] ^ mask;
            try expectSafe(mutated[0..original.len]);
        }
        mutated[index] = original[index];
    }
}

test "all fixture prefixes and byte mutations are safe" {
    try exercisePrefixesAndMutations(&fixtures.png);
    try exercisePrefixesAndMutations(&fixtures.gif);
    try exercisePrefixesAndMutations(&fixtures.jpeg);
    try exercisePrefixesAndMutations(&fixtures.jpeg_app);
    try exercisePrefixesAndMutations(&fixtures.jpeg_progressive);
    try exercisePrefixesAndMutations(&fixtures.bmp_info);
    try exercisePrefixesAndMutations(&fixtures.bmp_core);
    try exercisePrefixesAndMutations(&fixtures.webp_vp8);
    try exercisePrefixesAndMutations(&fixtures.webp_vp8l);
    try exercisePrefixesAndMutations(&fixtures.webp_vp8x);
    try exercisePrefixesAndMutations(fixtures.svg);
    try exercisePrefixesAndMutations(fixtures.svg_derived);
    try exercisePrefixesAndMutations(&fixtures.avif);
    try exercisePrefixesAndMutations(&fixtures.avif_unrelated_ispe);
    try exercisePrefixesAndMutations(&fixtures.avif_rotated);
    try exercisePrefixesAndMutations(&fixtures.avif_cropped);
    try exercisePrefixesAndMutations(&fixtures.avif_large_id);
}

test "deterministic arbitrary inputs are safe" {
    var bytes: [512]u8 = undefined;
    var state: u64 = 0x6A09E667F3BCC909;
    for (0..bytes.len + 1) |len| {
        if (len > 0) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            bytes[len - 1] = @truncate(state);
        }
        try expectSafe(bytes[0..len]);
    }
}

test "declared length fields never escape their buffers" {
    var webp = fixtures.webp_vp8l;
    inline for (.{ @as(u32, 0), 1, 11, std.math.maxInt(u32) }) |declared_size| {
        std.mem.writeInt(u32, webp[4..8], declared_size, .little);
        try expectSafe(&webp);
        std.mem.writeInt(u32, webp[16..20], declared_size, .little);
        try expectSafe(&webp);
    }

    var avif = fixtures.avif;
    inline for (.{ @as(u32, 0), 1, 7, std.math.maxInt(u32) }) |box_size| {
        std.mem.writeInt(u32, avif[28..32], box_size, .big);
        try expectSafe(&avif);
    }

    var jpeg = fixtures.jpeg_app;
    inline for (.{ @as(u16, 0), 1, 2, std.math.maxInt(u16) }) |segment_size| {
        std.mem.writeInt(u16, jpeg[4..6], segment_size, .big);
        try expectSafe(&jpeg);
    }
}
