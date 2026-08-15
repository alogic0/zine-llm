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

    switch (signature(bytes, "RIFF")) {
        .match => {
            try requireLen(bytes, 12);
            if (!std.mem.eql(u8, bytes[8..12], "WEBP")) return error.UnsupportedFormat;
            return .{ .format = .webp, .dimensions = try parseWebp(bytes) };
        },
        .prefix => return error.Truncated,
        .different => {},
    }

    return .{ .format = .svg, .dimensions = try parseSvg(bytes) };
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

fn parseWebp(bytes: []const u8) ProbeError!Dimensions {
    const riff_size = readU32Le(bytes, 4);
    const riff_end = std.math.add(usize, 8, riff_size) catch return error.DimensionOverflow;
    if (riff_end < 12) return error.Malformed;
    try requireLen(bytes, riff_end);

    var offset: usize = 12;
    while (offset < riff_end) {
        const chunk_header_end = std.math.add(usize, offset, 8) catch return error.DimensionOverflow;
        if (chunk_header_end > riff_end) return error.Truncated;

        const chunk_type = bytes[offset..][0..4];
        const chunk_len = readU32Le(bytes, offset + 4);
        const payload_offset = chunk_header_end;
        const payload_end = std.math.add(usize, payload_offset, chunk_len) catch return error.DimensionOverflow;
        if (payload_end > riff_end) return error.Truncated;
        const padded_len = std.math.add(usize, chunk_len, chunk_len & 1) catch return error.DimensionOverflow;
        const padded_end = std.math.add(usize, payload_offset, padded_len) catch return error.DimensionOverflow;
        if (padded_end > riff_end) return error.Truncated;

        if (std.mem.eql(u8, chunk_type, "VP8 ")) {
            return parseWebpVp8(bytes[payload_offset..payload_end]);
        }
        if (std.mem.eql(u8, chunk_type, "VP8L")) {
            return parseWebpVp8l(bytes[payload_offset..payload_end]);
        }
        if (std.mem.eql(u8, chunk_type, "VP8X")) {
            return parseWebpVp8x(bytes[payload_offset..payload_end]);
        }

        offset = padded_end;
    }

    return error.UnsupportedVariant;
}

fn parseWebpVp8(payload: []const u8) ProbeError!Dimensions {
    try requireLen(payload, 10);
    if ((payload[0] & 1) != 0 or !std.mem.eql(u8, payload[3..6], &.{ 0x9D, 0x01, 0x2A })) {
        return error.Malformed;
    }
    const width = readU16Le(payload, 6) & 0x3FFF;
    const height = readU16Le(payload, 8) & 0x3FFF;
    if (width == 0 or height == 0) return error.Malformed;
    return .{ .width = width, .height = height };
}

fn parseWebpVp8l(payload: []const u8) ProbeError!Dimensions {
    try requireLen(payload, 5);
    if (payload[0] != 0x2F) return error.Malformed;
    const dimension_bits = readU32Le(payload, 1);
    if ((dimension_bits >> 29) != 0) return error.UnsupportedVariant;
    return .{
        .width = (dimension_bits & 0x3FFF) + 1,
        .height = ((dimension_bits >> 14) & 0x3FFF) + 1,
    };
}

fn parseWebpVp8x(payload: []const u8) ProbeError!Dimensions {
    if (payload.len != 10) return if (payload.len < 10) error.Truncated else error.Malformed;
    if ((payload[0] & 0xC1) != 0 or payload[1] != 0 or payload[2] != 0 or payload[3] != 0) {
        return error.Malformed;
    }
    return .{
        .width = @as(u32, readU24Le(payload, 4)) + 1,
        .height = @as(u32, readU24Le(payload, 7)) + 1,
    };
}

const max_svg_prefix = 64 * 1024;

fn parseSvg(bytes: []const u8) ProbeError!Dimensions {
    const bounded = bytes.len > max_svg_prefix;
    const prefix = bytes[0..@min(bytes.len, max_svg_prefix)];
    return parseSvgPrefix(prefix) catch |err| switch (err) {
        error.Truncated => if (bounded) error.UnsupportedVariant else error.Truncated,
        else => err,
    };
}

fn parseSvgPrefix(bytes: []const u8) ProbeError!Dimensions {
    var offset: usize = 0;
    if (std.mem.startsWith(u8, bytes, &.{ 0xEF, 0xBB, 0xBF })) offset = 3;

    while (true) {
        skipXmlSpace(bytes, &offset);
        if (offset == bytes.len) return error.UnsupportedFormat;
        if (bytes[offset] != '<') return error.UnsupportedFormat;

        if (startsAt(bytes, offset, "<!--")) {
            offset = try skipUntil(bytes, offset + 4, "-->");
            continue;
        }
        if (startsAt(bytes, offset, "<?")) {
            offset = try skipUntil(bytes, offset + 2, "?>");
            continue;
        }
        if (startsAt(bytes, offset, "<!DOCTYPE")) {
            offset = try skipDoctype(bytes, offset + "<!DOCTYPE".len);
            continue;
        }
        if (startsAt(bytes, offset, "<!")) return error.Malformed;
        break;
    }

    offset += 1;
    const element_name = try parseXmlName(bytes, &offset);
    const local_name = if (std.mem.lastIndexOfScalar(u8, element_name, ':')) |colon|
        element_name[colon + 1 ..]
    else
        element_name;
    if (!std.mem.eql(u8, local_name, "svg")) return error.UnsupportedFormat;

    var width_value: ?[]const u8 = null;
    var height_value: ?[]const u8 = null;
    var view_box_value: ?[]const u8 = null;
    while (true) {
        skipXmlSpace(bytes, &offset);
        if (offset == bytes.len) return error.Truncated;
        if (bytes[offset] == '>') break;
        if (bytes[offset] == '/') {
            offset += 1;
            if (offset == bytes.len) return error.Truncated;
            if (bytes[offset] != '>') return error.Malformed;
            break;
        }

        const attribute_name = try parseXmlName(bytes, &offset);
        skipXmlSpace(bytes, &offset);
        if (offset == bytes.len) return error.Truncated;
        if (bytes[offset] != '=') return error.Malformed;
        offset += 1;
        skipXmlSpace(bytes, &offset);
        if (offset == bytes.len) return error.Truncated;
        const quote = bytes[offset];
        if (quote != '\'' and quote != '"') return error.Malformed;
        offset += 1;
        const value_start = offset;
        while (offset < bytes.len and bytes[offset] != quote) : (offset += 1) {}
        if (offset == bytes.len) return error.Truncated;
        const value = bytes[value_start..offset];
        offset += 1;

        if (std.mem.eql(u8, attribute_name, "width")) width_value = value;
        if (std.mem.eql(u8, attribute_name, "height")) height_value = value;
        if (std.mem.eql(u8, attribute_name, "viewBox")) view_box_value = value;
    }

    const width_px = if (width_value) |value| try parseSvgLength(value) else null;
    const height_px = if (height_value) |value| try parseSvgLength(value) else null;
    if (width_px == null and height_px == null) return error.UnsupportedVariant;

    var resolved_width = width_px;
    var resolved_height = height_px;
    if (resolved_width == null or resolved_height == null) {
        const view_box = try parseViewBox(view_box_value orelse return error.UnsupportedVariant);
        if (resolved_width) |width| {
            resolved_height = width * view_box.height / view_box.width;
        } else if (resolved_height) |height| {
            resolved_width = height * view_box.width / view_box.height;
        }
    }

    return .{
        .width = try cssPixelsToDimension(resolved_width.?),
        .height = try cssPixelsToDimension(resolved_height.?),
    };
}

fn parseSvgLength(raw: []const u8) ProbeError!?f64 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return error.Malformed;
    const number_end = scanNumber(value, 0) catch return error.Malformed;
    const number = std.fmt.parseFloat(f64, value[0..number_end]) catch return error.Malformed;
    if (!std.math.isFinite(number) or number <= 0) return error.Malformed;
    const unit = value[number_end..];
    const multiplier: f64 = if (unit.len == 0 or std.mem.eql(u8, unit, "px"))
        1
    else if (std.mem.eql(u8, unit, "in"))
        96
    else if (std.mem.eql(u8, unit, "cm"))
        4800.0 / 127.0
    else if (std.mem.eql(u8, unit, "mm"))
        480.0 / 127.0
    else if (std.mem.eql(u8, unit, "q"))
        120.0 / 127.0
    else if (std.mem.eql(u8, unit, "pt"))
        4.0 / 3.0
    else if (std.mem.eql(u8, unit, "pc"))
        16
    else
        return error.UnsupportedVariant;
    return number * multiplier;
}

const ViewBox = struct { width: f64, height: f64 };

fn parseViewBox(raw: []const u8) ProbeError!ViewBox {
    var offset: usize = 0;
    var values: [4]f64 = undefined;
    for (&values) |*value| {
        skipSvgNumberSeparators(raw, &offset);
        const end = scanNumber(raw, offset) catch return error.Malformed;
        value.* = std.fmt.parseFloat(f64, raw[offset..end]) catch return error.Malformed;
        if (!std.math.isFinite(value.*)) return error.Malformed;
        offset = end;
    }
    skipSvgNumberSeparators(raw, &offset);
    if (offset != raw.len or values[2] <= 0 or values[3] <= 0) return error.Malformed;
    return .{ .width = values[2], .height = values[3] };
}

fn scanNumber(bytes: []const u8, start: usize) ProbeError!usize {
    var offset = start;
    if (offset < bytes.len and (bytes[offset] == '+' or bytes[offset] == '-')) offset += 1;

    const integer_start = offset;
    while (offset < bytes.len and std.ascii.isDigit(bytes[offset])) : (offset += 1) {}
    var has_digits = offset > integer_start;
    if (offset < bytes.len and bytes[offset] == '.') {
        offset += 1;
        const fraction_start = offset;
        while (offset < bytes.len and std.ascii.isDigit(bytes[offset])) : (offset += 1) {}
        has_digits = has_digits or offset > fraction_start;
    }
    if (!has_digits) return error.Malformed;

    if (offset < bytes.len and (bytes[offset] == 'e' or bytes[offset] == 'E')) {
        var exponent_offset = offset + 1;
        if (exponent_offset < bytes.len and (bytes[exponent_offset] == '+' or bytes[exponent_offset] == '-')) {
            exponent_offset += 1;
        }
        if (exponent_offset < bytes.len and std.ascii.isDigit(bytes[exponent_offset])) {
            offset = exponent_offset + 1;
            while (offset < bytes.len and std.ascii.isDigit(bytes[offset])) : (offset += 1) {}
        }
    }
    return offset;
}

fn cssPixelsToDimension(value: f64) ProbeError!u32 {
    if (!std.math.isFinite(value) or value <= 0) return error.Malformed;
    // HTML width/height attributes are integral. Use the nearest CSS pixel and
    // preserve every positive sub-pixel intrinsic length as one pixel.
    const rounded = @round(value);
    if (rounded > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return error.DimensionOverflow;
    return if (rounded < 1) 1 else @intFromFloat(rounded);
}

fn skipXmlSpace(bytes: []const u8, offset: *usize) void {
    while (offset.* < bytes.len and isXmlSpace(bytes[offset.*])) : (offset.* += 1) {}
}

fn skipSvgNumberSeparators(bytes: []const u8, offset: *usize) void {
    while (offset.* < bytes.len and (isXmlSpace(bytes[offset.*]) or bytes[offset.*] == ',')) : (offset.* += 1) {}
}

fn isXmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn parseXmlName(bytes: []const u8, offset: *usize) ProbeError![]const u8 {
    if (offset.* == bytes.len) return error.Truncated;
    const start = offset.*;
    if (!isXmlNameStart(bytes[offset.*])) return error.Malformed;
    offset.* += 1;
    while (offset.* < bytes.len and isXmlNameContinue(bytes[offset.*])) : (offset.* += 1) {}
    return bytes[start..offset.*];
}

fn isXmlNameStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_' or byte == ':';
}

fn isXmlNameContinue(byte: u8) bool {
    return isXmlNameStart(byte) or std.ascii.isDigit(byte) or byte == '-' or byte == '.';
}

fn startsAt(bytes: []const u8, offset: usize, expected: []const u8) bool {
    return offset <= bytes.len and expected.len <= bytes.len - offset and
        std.mem.eql(u8, bytes[offset..][0..expected.len], expected);
}

fn skipUntil(bytes: []const u8, start: usize, terminator: []const u8) ProbeError!usize {
    const relative = std.mem.indexOf(u8, bytes[start..], terminator) orelse return error.Truncated;
    return std.math.add(usize, start + relative, terminator.len) catch return error.DimensionOverflow;
}

fn skipDoctype(bytes: []const u8, start: usize) ProbeError!usize {
    var offset = start;
    var subset_depth: usize = 0;
    var quote: ?u8 = null;
    while (offset < bytes.len) : (offset += 1) {
        const byte = bytes[offset];
        if (quote) |active_quote| {
            if (byte == active_quote) quote = null;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (byte == '[') {
            subset_depth += 1;
        } else if (byte == ']') {
            if (subset_depth == 0) return error.Malformed;
            subset_depth -= 1;
        } else if (byte == '>' and subset_depth == 0) {
            return offset + 1;
        }
    }
    return error.Truncated;
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

fn readU24Le(bytes: []const u8, offset: usize) u24 {
    return @as(u24, bytes[offset]) |
        (@as(u24, bytes[offset + 1]) << 8) |
        (@as(u24, bytes[offset + 2]) << 16);
}

fn readI32Le(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}
