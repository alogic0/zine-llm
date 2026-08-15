const std = @import("std");

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

pub const Format = enum {
    bmp,
    gif,
    jpeg,
    png,
    webp,
    svg,
    avif,
};

pub const Result = struct {
    format: Format,
    dimensions: Dimensions,
};

pub const ProbeError = error{
    UnsupportedFormat,
    UnsupportedVariant,
    Truncated,
    Malformed,
    DimensionOverflow,
};

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub fn parse(bytes: []const u8) ProbeError!Result {
    switch (signature(bytes, &png_signature)) {
        .match => return .{ .format = .png, .dimensions = try parsePng(bytes) },
        .prefix => return error.Truncated,
        .different => {},
    }

    switch (signature(bytes, "GIF87a")) {
        .match => return .{ .format = .gif, .dimensions = try parseGif(bytes) },
        .prefix => return error.Truncated,
        .different => {},
    }
    switch (signature(bytes, "GIF89a")) {
        .match => return .{ .format = .gif, .dimensions = try parseGif(bytes) },
        .prefix => return error.Truncated,
        .different => {},
    }

    switch (signature(bytes, "BM")) {
        .match => return .{ .format = .bmp, .dimensions = try parseBmp(bytes) },
        .prefix => return error.Truncated,
        .different => {},
    }

    switch (signature(bytes, &.{ 0xFF, 0xD8 })) {
        .match => return .{ .format = .jpeg, .dimensions = try parseJpeg(bytes) },
        .prefix => return error.Truncated,
        .different => {},
    }

    return error.UnsupportedFormat;
}

const SignatureMatch = enum { match, prefix, different };

fn signature(bytes: []const u8, expected: []const u8) SignatureMatch {
    const compared_len = @min(bytes.len, expected.len);
    if (!std.mem.eql(u8, bytes[0..compared_len], expected[0..compared_len])) {
        return .different;
    }
    return if (bytes.len < expected.len) .prefix else .match;
}

fn parsePng(bytes: []const u8) ProbeError!Dimensions {
    try requireLen(bytes, 29);
    if (readU32Be(bytes, 8) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) {
        return error.Malformed;
    }

    const width = readU32Be(bytes, 16);
    const height = readU32Be(bytes, 20);
    if (width == 0 or height == 0) return error.Malformed;

    const bit_depth = bytes[24];
    const color_type = bytes[25];
    if (!validPngBitDepth(color_type, bit_depth)) return error.Malformed;
    if (bytes[26] != 0 or bytes[27] != 0 or bytes[28] > 1) return error.Malformed;

    return .{ .width = width, .height = height };
}

fn validPngBitDepth(color_type: u8, bit_depth: u8) bool {
    return switch (color_type) {
        0 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        2, 4, 6 => bit_depth == 8 or bit_depth == 16,
        3 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        else => false,
    };
}

fn parseGif(bytes: []const u8) ProbeError!Dimensions {
    try requireLen(bytes, 13);
    const width = readU16Le(bytes, 6);
    const height = readU16Le(bytes, 8);
    if (width == 0 or height == 0) return error.Malformed;

    return .{ .width = width, .height = height };
}

fn parseBmp(bytes: []const u8) ProbeError!Dimensions {
    try requireLen(bytes, 18);
    const declared_file_size = readU32Le(bytes, 2);
    const pixel_offset = readU32Le(bytes, 10);
    const dib_size = readU32Le(bytes, 14);

    const dimensions: Dimensions = switch (dib_size) {
        12 => blk: {
            try requireLen(bytes, 26);
            if (readU16Le(bytes, 22) != 1) return error.Malformed;
            try validateBmpBitDepth(readU16Le(bytes, 24));
            break :blk .{
                .width = readU16Le(bytes, 18),
                .height = readU16Le(bytes, 20),
            };
        },
        40, 52, 56, 64, 108, 124 => blk: {
            const header_end = std.math.add(usize, 14, dib_size) catch return error.DimensionOverflow;
            try requireLen(bytes, header_end);
            if (readU16Le(bytes, 26) != 1) return error.Malformed;
            try validateBmpBitDepth(readU16Le(bytes, 28));

            const signed_width = readI32Le(bytes, 18);
            const signed_height = readI32Le(bytes, 22);
            if (signed_width <= 0 or signed_height == 0) return error.Malformed;
            const absolute_height: u32 = @abs(signed_height);
            break :blk .{
                .width = @intCast(signed_width),
                .height = absolute_height,
            };
        },
        else => return error.UnsupportedVariant,
    };

    if (dimensions.width == 0 or dimensions.height == 0) return error.Malformed;
    const header_end = std.math.add(u32, 14, dib_size) catch return error.DimensionOverflow;
    if (pixel_offset < header_end) return error.Malformed;
    if (declared_file_size != 0 and declared_file_size < pixel_offset) return error.Malformed;

    return dimensions;
}

fn parseJpeg(bytes: []const u8) ProbeError!Dimensions {
    var offset: usize = 2;
    while (true) {
        try requireLen(bytes, std.math.add(usize, offset, 2) catch return error.DimensionOverflow);
        if (bytes[offset] != 0xFF) return error.Malformed;

        while (offset < bytes.len and bytes[offset] == 0xFF) : (offset += 1) {}
        if (offset == bytes.len) return error.Truncated;

        const marker = bytes[offset];
        offset += 1;
        switch (marker) {
            0x00 => return error.Malformed,
            0x01, 0xD0...0xD7 => continue,
            0xD8 => return error.Malformed,
            0xD9, 0xDA => return error.Malformed,
            else => {},
        }

        try requireLen(bytes, std.math.add(usize, offset, 2) catch return error.DimensionOverflow);
        const segment_len = readU16Be(bytes, offset);
        if (segment_len < 2) return error.Malformed;
        const segment_end = std.math.add(usize, offset, segment_len) catch return error.DimensionOverflow;
        try requireLen(bytes, segment_end);

        if (isJpegSof(marker)) {
            if (segment_len < 8) return error.Malformed;
            const precision = bytes[offset + 2];
            const height = readU16Be(bytes, offset + 3);
            const width = readU16Be(bytes, offset + 5);
            const component_count = bytes[offset + 7];
            if (precision == 0 or width == 0 or height == 0 or component_count == 0) {
                return error.Malformed;
            }
            const component_bytes = std.math.mul(u16, component_count, 3) catch return error.DimensionOverflow;
            const expected_len = std.math.add(u16, 8, component_bytes) catch return error.DimensionOverflow;
            if (segment_len != expected_len) return error.Malformed;
            return .{ .width = width, .height = height };
        }

        offset = segment_end;
    }
}

fn isJpegSof(marker: u8) bool {
    return switch (marker) {
        0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF => true,
        else => false,
    };
}

fn validateBmpBitDepth(bit_depth: u16) ProbeError!void {
    switch (bit_depth) {
        1, 4, 8, 16, 24, 32 => {},
        else => return error.UnsupportedVariant,
    }
}

fn requireLen(bytes: []const u8, required: usize) ProbeError!void {
    if (bytes.len < required) return error.Truncated;
}

fn readU16Le(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU16Be(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readU32Le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readI32Le(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
