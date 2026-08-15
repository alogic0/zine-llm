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

    if (bytes.len > 4) {
        switch (signature(bytes[4..], "ftyp")) {
            .match => return .{ .format = .avif, .dimensions = try parseAvif(bytes) },
            .prefix => return error.Truncated,
            .different => {},
        }
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

const Box = struct {
    kind: u32,
    start: usize,
    payload_start: usize,
    end: usize,
};

const FullBox = struct {
    version: u8,
    flags: u24,
    content_start: usize,
};

fn parseAvif(bytes: []const u8) ProbeError!Dimensions {
    var offset: usize = 0;
    var saw_ftyp = false;
    var saw_avif_brand = false;
    var saw_sequence_brand = false;
    var meta: ?Box = null;
    while (offset < bytes.len) {
        const box = try nextBox(bytes, &offset, bytes.len);
        switch (box.kind) {
            fourcc("ftyp") => {
                if (saw_ftyp) return error.Malformed;
                saw_ftyp = true;
                const brands = try parseAvifBrands(bytes, box);
                saw_avif_brand = brands.avif;
                saw_sequence_brand = brands.avis;
            },
            fourcc("meta") => {
                if (meta != null) return error.Malformed;
                meta = box;
            },
            fourcc("moov") => saw_sequence_brand = true,
            else => {},
        }
    }
    if (!saw_avif_brand) return error.UnsupportedFormat;
    if (saw_sequence_brand) return error.UnsupportedVariant;
    return parseAvifMeta(bytes, meta orelse return error.Malformed);
}

const AvifBrands = struct { avif: bool = false, avis: bool = false };

fn parseAvifBrands(bytes: []const u8, box: Box) ProbeError!AvifBrands {
    if (box.end - box.payload_start < 8 or ((box.end - box.payload_start - 8) & 3) != 0) {
        return error.Malformed;
    }
    var brands: AvifBrands = .{};
    var offset = box.payload_start;
    checkAvifBrand(readU32Be(bytes, offset), &brands);
    offset += 8;
    while (offset < box.end) : (offset += 4) checkAvifBrand(readU32Be(bytes, offset), &brands);
    return brands;
}

fn checkAvifBrand(brand: u32, brands: *AvifBrands) void {
    if (brand == fourcc("avif") or brand == fourcc("avio")) brands.avif = true;
    if (brand == fourcc("avis")) brands.avis = true;
}

fn parseAvifMeta(bytes: []const u8, meta: Box) ProbeError!Dimensions {
    const full = try parseFullBox(bytes, meta);
    if (full.version != 0 or full.flags != 0) return error.UnsupportedVariant;

    var primary_item_id: ?u32 = null;
    var iinf: ?Box = null;
    var iprp: ?Box = null;
    var offset = full.content_start;
    while (offset < meta.end) {
        const child = try nextBox(bytes, &offset, meta.end);
        switch (child.kind) {
            fourcc("pitm") => {
                if (primary_item_id != null) return error.Malformed;
                primary_item_id = try parsePrimaryItem(bytes, child);
            },
            fourcc("iinf") => {
                if (iinf != null) return error.Malformed;
                iinf = child;
            },
            fourcc("iprp") => {
                if (iprp != null) return error.Malformed;
                iprp = child;
            },
            else => {},
        }
    }

    const item_id = primary_item_id orelse return error.Malformed;
    const item_type = try findAvifItemType(bytes, iinf orelse return error.Malformed, item_id);
    if (item_type != fourcc("av01")) return error.UnsupportedVariant;
    return parseAvifProperties(bytes, iprp orelse return error.Malformed, item_id);
}

fn parsePrimaryItem(bytes: []const u8, box: Box) ProbeError!u32 {
    const full = try parseFullBox(bytes, box);
    if (full.flags != 0) return error.Malformed;
    return switch (full.version) {
        0 => blk: {
            if (box.end - full.content_start != 2) return error.Malformed;
            break :blk readU16Be(bytes, full.content_start);
        },
        1 => blk: {
            if (box.end - full.content_start != 4) return error.Malformed;
            break :blk readU32Be(bytes, full.content_start);
        },
        else => error.UnsupportedVariant,
    };
}

fn findAvifItemType(bytes: []const u8, iinf: Box, target_id: u32) ProbeError!u32 {
    const full = try parseFullBox(bytes, iinf);
    if (full.flags != 0 or full.version > 1) return error.UnsupportedVariant;
    const count_len: usize = if (full.version == 0) 2 else 4;
    if (iinf.end - full.content_start < count_len) return error.Truncated;
    const declared_count: u32 = if (count_len == 2)
        readU16Be(bytes, full.content_start)
    else
        readU32Be(bytes, full.content_start);

    var actual_count: u32 = 0;
    var found_type: ?u32 = null;
    var offset = full.content_start + count_len;
    while (offset < iinf.end) {
        const child = try nextBox(bytes, &offset, iinf.end);
        if (child.kind != fourcc("infe")) continue;
        actual_count += 1;
        const infe = try parseFullBox(bytes, child);
        if (infe.flags != 0) return error.Malformed;
        const id_len: usize = switch (infe.version) {
            2 => 2,
            3 => 4,
            else => return error.UnsupportedVariant,
        };
        if (child.end - infe.content_start < id_len + 7) return error.Truncated;
        const item_id: u32 = if (id_len == 2)
            readU16Be(bytes, infe.content_start)
        else
            readU32Be(bytes, infe.content_start);
        const item_type = readU32Be(bytes, infe.content_start + id_len + 2);
        if (item_id == target_id) {
            if (found_type != null) return error.Malformed;
            found_type = item_type;
        }
    }
    if (actual_count != declared_count) return error.Malformed;
    return found_type orelse error.Malformed;
}

fn parseAvifProperties(bytes: []const u8, iprp: Box, target_id: u32) ProbeError!Dimensions {
    var ipco: ?Box = null;
    var ipma: ?Box = null;
    var offset = iprp.payload_start;
    while (offset < iprp.end) {
        const child = try nextBox(bytes, &offset, iprp.end);
        switch (child.kind) {
            fourcc("ipco") => {
                if (ipco != null) return error.Malformed;
                ipco = child;
            },
            fourcc("ipma") => {
                if (ipma != null) return error.Malformed;
                ipma = child;
            },
            else => {},
        }
    }
    return parseAvifAssociations(
        bytes,
        ipco orelse return error.Malformed,
        ipma orelse return error.Malformed,
        target_id,
    );
}

const AvifPropertyState = struct {
    spatial: ?Dimensions = null,
    dimensions: ?Dimensions = null,
    saw_clean_aperture: bool = false,
    saw_transform: bool = false,
};

fn parseAvifAssociations(bytes: []const u8, ipco: Box, ipma: Box, target_id: u32) ProbeError!Dimensions {
    const full = try parseFullBox(bytes, ipma);
    if (full.version > 1 or (full.flags & ~@as(u24, 1)) != 0) return error.UnsupportedVariant;
    const large_associations = (full.flags & 1) != 0;
    const item_id_len: usize = if (full.version == 0) 2 else 4;
    const association_len: usize = if (large_associations) 2 else 1;
    if (ipma.end - full.content_start < 4) return error.Truncated;
    const entry_count = readU32Be(bytes, full.content_start);
    var offset = full.content_start + 4;
    var found_target = false;
    var state: AvifPropertyState = .{};
    for (0..entry_count) |_| {
        const item_and_count_end = std.math.add(usize, offset, item_id_len + 1) catch return error.DimensionOverflow;
        if (item_and_count_end > ipma.end) return error.Truncated;
        const item_id: u32 = if (item_id_len == 2)
            readU16Be(bytes, offset)
        else
            readU32Be(bytes, offset);
        offset += item_id_len;
        const association_count = bytes[offset];
        offset += 1;
        if (item_id == target_id) {
            if (found_target) return error.Malformed;
            found_target = true;
        }

        for (0..association_count) |_| {
            const association_end = std.math.add(usize, offset, association_len) catch return error.DimensionOverflow;
            if (association_end > ipma.end) return error.Truncated;
            const association: u16 = if (association_len == 1)
                bytes[offset]
            else
                readU16Be(bytes, offset);
            offset = association_end;
            if (item_id != target_id) continue;

            const essential_mask: u16 = if (association_len == 1) 0x80 else 0x8000;
            const property_index = association & ~essential_mask;
            if (property_index == 0) continue;
            const property = try findAvifProperty(bytes, ipco, property_index);
            try applyAvifProperty(bytes, property, (association & essential_mask) != 0, &state);
        }
    }
    if (offset != ipma.end or !found_target) return error.Malformed;

    _ = state.spatial orelse return error.Malformed;
    return state.dimensions orelse error.Malformed;
}

fn findAvifProperty(bytes: []const u8, ipco: Box, target_index: u16) ProbeError!Box {
    var index: u16 = 1;
    var offset = ipco.payload_start;
    while (offset < ipco.end) : (index += 1) {
        const property = try nextBox(bytes, &offset, ipco.end);
        if (index == target_index) return property;
        if (index == std.math.maxInt(u16)) return error.DimensionOverflow;
    }
    return error.Malformed;
}

fn applyAvifProperty(bytes: []const u8, property: Box, essential: bool, state: *AvifPropertyState) ProbeError!void {
    switch (property.kind) {
        fourcc("ispe") => {
            if (state.spatial != null) return error.Malformed;
            const full = try parseFullBox(bytes, property);
            if (full.version != 0 or full.flags != 0 or property.end - full.content_start != 8) {
                return error.Malformed;
            }
            const width = readU32Be(bytes, full.content_start);
            const height = readU32Be(bytes, full.content_start + 4);
            if (width == 0 or height == 0) return error.Malformed;
            state.spatial = .{ .width = width, .height = height };
            state.dimensions = state.spatial;
        },
        fourcc("clap") => {
            const spatial = state.spatial orelse return error.UnsupportedVariant;
            if (state.saw_clean_aperture or state.saw_transform or property.end - property.payload_start != 32) {
                return error.Malformed;
            }
            state.saw_clean_aperture = true;
            const width_n = readU32Be(bytes, property.payload_start);
            const width_d = readU32Be(bytes, property.payload_start + 4);
            const height_n = readU32Be(bytes, property.payload_start + 8);
            const height_d = readU32Be(bytes, property.payload_start + 12);
            const horizontal_d = readU32Be(bytes, property.payload_start + 20);
            const vertical_d = readU32Be(bytes, property.payload_start + 28);
            if (width_d == 0 or height_d == 0 or horizontal_d == 0 or vertical_d == 0 or
                width_n == 0 or height_n == 0 or width_n % width_d != 0 or height_n % height_d != 0)
            {
                return error.UnsupportedVariant;
            }
            const clean_aperture: Dimensions = .{
                .width = width_n / width_d,
                .height = height_n / height_d,
            };
            if (clean_aperture.width > spatial.width or clean_aperture.height > spatial.height) {
                return error.Malformed;
            }
            state.dimensions = clean_aperture;
        },
        fourcc("irot") => {
            if (property.end - property.payload_start != 1 or (bytes[property.payload_start] & 0xFC) != 0) {
                return error.Malformed;
            }
            state.saw_transform = true;
            if ((bytes[property.payload_start] & 1) != 0) {
                if (state.dimensions) |*dimensions| {
                    std.mem.swap(u32, &dimensions.width, &dimensions.height);
                } else {
                    return error.UnsupportedVariant;
                }
            }
        },
        fourcc("imir") => {
            if (property.end - property.payload_start != 1 or (bytes[property.payload_start] & 0xFE) != 0) {
                return error.Malformed;
            }
            state.saw_transform = true;
        },
        fourcc("pasp") => {
            if (property.end - property.payload_start != 8) return error.Malformed;
            const horizontal_spacing = readU32Be(bytes, property.payload_start);
            const vertical_spacing = readU32Be(bytes, property.payload_start + 4);
            if (horizontal_spacing == 0 or vertical_spacing == 0) return error.Malformed;
            if (horizontal_spacing != vertical_spacing) return error.UnsupportedVariant;
        },
        fourcc("pixi"),
        fourcc("av1C"),
        fourcc("colr"),
        fourcc("a1op"),
        fourcc("lsel"),
        fourcc("a1lx"),
        => {},
        else => if (essential) return error.UnsupportedVariant,
    }
}

fn parseFullBox(bytes: []const u8, box: Box) ProbeError!FullBox {
    if (box.end - box.payload_start < 4) return error.Truncated;
    return .{
        .version = bytes[box.payload_start],
        .flags = readU24Be(bytes, box.payload_start + 1),
        .content_start = box.payload_start + 4,
    };
}

fn nextBox(bytes: []const u8, offset: *usize, limit: usize) ProbeError!Box {
    const start = offset.*;
    if (start > limit or limit > bytes.len or limit - start < 8) return error.Truncated;
    const size32 = readU32Be(bytes, start);
    const kind = readU32Be(bytes, start + 4);
    var header_len: usize = 8;
    const box_len: usize = switch (size32) {
        0 => limit - start,
        1 => blk: {
            if (limit - start < 16) return error.Truncated;
            header_len = 16;
            break :blk std.math.cast(usize, readU64Be(bytes, start + 8)) orelse return error.DimensionOverflow;
        },
        else => size32,
    };
    if (box_len < header_len) return error.Malformed;
    const end = std.math.add(usize, start, box_len) catch return error.DimensionOverflow;
    if (end > limit) return error.Truncated;
    offset.* = end;
    return .{
        .kind = kind,
        .start = start,
        .payload_start = start + header_len,
        .end = end,
    };
}

fn fourcc(comptime value: *const [4]u8) u32 {
    return std.mem.readInt(u32, value, .big);
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

fn readU24Be(bytes: []const u8, offset: usize) u24 {
    return (@as(u24, bytes[offset]) << 16) |
        (@as(u24, bytes[offset + 1]) << 8) |
        @as(u24, bytes[offset + 2]);
}

fn readI32Le(bytes: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, bytes[offset..][0..4], .little);
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

fn readU64Be(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .big);
}
