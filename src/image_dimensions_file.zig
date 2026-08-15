const std = @import("std");
const image_dimensions = @import("image_dimensions.zig");

const Io = std.Io;
const File = Io.File;

pub const max_metadata_bytes = 64 * 1024;

/// Opens one local file and probes only the bounded metadata ranges needed to
/// determine its intrinsic dimensions. File-system errors remain distinct from
/// `image_dimensions.ProbeError` in the inferred error set.
pub fn probeFile(io: Io, base_dir: Io.Dir, path: []const u8) !image_dimensions.Result {
    const file = try base_dir.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    return probeOpenFile(io, file, stat.size);
}

pub fn probeOpenFile(io: Io, file: File, file_size: u64) !image_dimensions.Result {
    var signature: [12]u8 = undefined;
    const signature_len: usize = @intCast(@min(file_size, signature.len));
    try readExact(io, file, file_size, 0, signature[0..signature_len]);
    const bytes = signature[0..signature_len];

    if (startsWith(bytes, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A })) {
        return probePrefix(io, file, file_size, 29);
    }
    if (startsWith(bytes, "GIF87a") or startsWith(bytes, "GIF89a")) {
        return probePrefix(io, file, file_size, 13);
    }
    if (startsWith(bytes, "BM")) return probeBmp(io, file, file_size);
    if (startsWith(bytes, &.{ 0xFF, 0xD8 })) {
        return .{ .format = .jpeg, .dimensions = try probeJpeg(io, file, file_size) };
    }
    if (startsWith(bytes, "RIFF")) {
        if (bytes.len < 12) return error.Truncated;
        if (!std.mem.eql(u8, bytes[8..12], "WEBP")) return error.UnsupportedFormat;
        return .{ .format = .webp, .dimensions = try probeWebp(io, file, file_size, bytes) };
    }
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[4..8], "ftyp")) {
        return .{ .format = .avif, .dimensions = try probeAvif(io, file, file_size) };
    }
    return probeSvg(io, file, file_size);
}

fn startsWith(bytes: []const u8, expected: []const u8) bool {
    return bytes.len >= expected.len and std.mem.eql(u8, bytes[0..expected.len], expected);
}

fn probePrefix(io: Io, file: File, file_size: u64, required: usize) !image_dimensions.Result {
    var buffer: [138]u8 = undefined;
    try readExact(io, file, file_size, 0, buffer[0..required]);
    return image_dimensions.parse(buffer[0..required]);
}

fn probeBmp(io: Io, file: File, file_size: u64) !image_dimensions.Result {
    var buffer: [138]u8 = undefined;
    try readExact(io, file, file_size, 0, buffer[0..18]);
    const dib_size = std.mem.readInt(u32, buffer[14..18], .little);
    const required_u32 = std.math.add(u32, 14, dib_size) catch return error.DimensionOverflow;
    const required = std.math.cast(usize, required_u32) orelse return error.DimensionOverflow;
    if (required > buffer.len) return error.UnsupportedVariant;
    try readExact(io, file, file_size, 18, buffer[18..required]);
    return image_dimensions.parse(buffer[0..required]);
}

fn probeJpeg(io: Io, file: File, file_size: u64) !image_dimensions.Dimensions {
    var offset: u64 = 2;
    var marker_bytes: [2]u8 = undefined;
    while (true) {
        try readExact(io, file, file_size, offset, marker_bytes[0..2]);
        if (marker_bytes[0] != 0xFF) return error.Malformed;

        while (true) {
            offset = std.math.add(u64, offset, 1) catch return error.DimensionOverflow;
            try readExact(io, file, file_size, offset, marker_bytes[0..1]);
            if (marker_bytes[0] != 0xFF) break;
        }

        const marker = marker_bytes[0];
        offset = std.math.add(u64, offset, 1) catch return error.DimensionOverflow;
        switch (marker) {
            0x00 => return error.Malformed,
            0x01, 0xD0...0xD7 => continue,
            0xD8 => return error.Malformed,
            0xD9, 0xDA => return error.Malformed,
            else => {},
        }

        var segment_prefix: [8]u8 = undefined;
        try readExact(io, file, file_size, offset, segment_prefix[0..2]);
        const segment_len = std.mem.readInt(u16, segment_prefix[0..2], .big);
        if (segment_len < 2) return error.Malformed;
        const segment_end = std.math.add(u64, offset, segment_len) catch return error.DimensionOverflow;
        if (segment_end > file_size) return error.Truncated;

        if (isJpegSof(marker)) {
            try readExact(io, file, file_size, offset + 2, segment_prefix[2..8]);
            return image_dimensions.parseJpegSofSegment(marker, segment_len, &segment_prefix);
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

fn probeWebp(io: Io, file: File, file_size: u64, signature: []const u8) !image_dimensions.Dimensions {
    const riff_size = std.mem.readInt(u32, signature[4..8], .little);
    const riff_end = std.math.add(u64, 8, riff_size) catch return error.DimensionOverflow;
    if (riff_end < 12) return error.Malformed;
    if (riff_end > file_size) return error.Truncated;

    var offset: u64 = 12;
    var chunk_header: [8]u8 = undefined;
    var payload_prefix: [10]u8 = undefined;
    while (offset < riff_end) {
        const header_end = std.math.add(u64, offset, chunk_header.len) catch return error.DimensionOverflow;
        if (header_end > riff_end) return error.Truncated;
        try readExact(io, file, file_size, offset, &chunk_header);

        const chunk_len = std.mem.readInt(u32, chunk_header[4..8], .little);
        const payload_end = std.math.add(u64, header_end, chunk_len) catch return error.DimensionOverflow;
        if (payload_end > riff_end) return error.Truncated;
        const padded_end = std.math.add(u64, payload_end, chunk_len & 1) catch return error.DimensionOverflow;
        if (padded_end > riff_end) return error.Truncated;

        const kind: *const [4]u8 = chunk_header[0..4];
        const required: ?usize = if (std.mem.eql(u8, kind, "VP8 "))
            10
        else if (std.mem.eql(u8, kind, "VP8L"))
            5
        else if (std.mem.eql(u8, kind, "VP8X"))
            10
        else
            null;
        if (required) |required_len| {
            if (std.mem.eql(u8, kind, "VP8X") and chunk_len != 10) {
                return if (chunk_len < 10) error.Truncated else error.Malformed;
            }
            if (chunk_len < required_len) return error.Truncated;
            try readExact(io, file, file_size, header_end, payload_prefix[0..required_len]);
            return image_dimensions.parseWebpChunk(kind, payload_prefix[0..required_len]);
        }
        offset = padded_end;
    }
    return error.UnsupportedVariant;
}

fn probeSvg(io: Io, file: File, file_size: u64) !image_dimensions.Result {
    var buffer: [max_metadata_bytes]u8 = undefined;
    const read_len: usize = @intCast(@min(file_size, buffer.len));
    try readExact(io, file, file_size, 0, buffer[0..read_len]);
    return image_dimensions.parse(buffer[0..read_len]) catch |err| switch (err) {
        error.Truncated => if (file_size > buffer.len) error.UnsupportedVariant else error.Truncated,
        else => err,
    };
}

fn probeAvif(io: Io, file: File, file_size: u64) !image_dimensions.Dimensions {
    var metadata: [max_metadata_bytes]u8 = undefined;
    var metadata_len: usize = 0;
    var offset: u64 = 0;
    while (offset < file_size) {
        var header: [16]u8 = undefined;
        try readExact(io, file, file_size, offset, header[0..8]);
        const size32 = std.mem.readInt(u32, header[0..4], .big);
        const kind = std.mem.readInt(u32, header[4..8], .big);
        var header_len: u64 = 8;
        const box_len: u64 = switch (size32) {
            0 => file_size - offset,
            1 => blk: {
                try readExact(io, file, file_size, offset + 8, header[8..16]);
                header_len = 16;
                break :blk std.mem.readInt(u64, header[8..16], .big);
            },
            else => size32,
        };
        if (box_len < header_len) return error.Malformed;
        const box_end = std.math.add(u64, offset, box_len) catch return error.DimensionOverflow;
        if (box_end > file_size) return error.Truncated;

        if (kind == fourcc("moov")) return error.UnsupportedVariant;
        if (kind == fourcc("ftyp") or kind == fourcc("meta")) {
            const copy_len = std.math.cast(usize, box_len) orelse return error.DimensionOverflow;
            const copy_end = std.math.add(usize, metadata_len, copy_len) catch return error.DimensionOverflow;
            if (copy_end > metadata.len) return error.UnsupportedVariant;
            try readExact(io, file, file_size, offset, metadata[metadata_len..copy_end]);
            metadata_len = copy_end;
        }
        offset = box_end;
    }
    const result = try image_dimensions.parse(metadata[0..metadata_len]);
    if (result.format != .avif) return error.UnsupportedFormat;
    return result.dimensions;
}

fn fourcc(comptime value: *const [4]u8) u32 {
    return std.mem.readInt(u32, value, .big);
}

fn readExact(io: Io, file: File, file_size: u64, offset: u64, buffer: []u8) !void {
    const end = std.math.add(u64, offset, buffer.len) catch return error.DimensionOverflow;
    if (end > file_size) return error.Truncated;
    const read = try file.readPositionalAll(io, buffer, offset);
    if (read != buffer.len) return error.Truncated;
}
