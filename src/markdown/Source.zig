//! Source locations shared by the Markdown parser, compact document, and AST.

const std = @import("std");

/// A half-open byte range in the original Markdown source.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn merge(a: Span, b: Span) Span {
        return .{ .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }
};

/// A one-based source position. Columns count bytes, matching CommonMark's
/// source-position convention and keeping conversion independent of UTF-8
/// decoding.
pub const Position = struct {
    row: u32 = 0,
    col: u32 = 0,
};

pub const Range = struct {
    start: Position = .{},
    end: Position = .{},
    start_byte: u32 = unknown_offset,
    end_byte: u32 = unknown_offset,

    pub const unknown_offset = std.math.maxInt(u32);
    pub const unknown: Range = .{};

    pub fn isKnown(range: Range) bool {
        return range.start_byte != unknown_offset and range.end_byte != unknown_offset;
    }
};

/// Start byte of every source line. The parser owns this array; this view does
/// not allocate and uses binary search for offset conversion.
pub const LineIndex = struct {
    starts: []const u32,
    source_len: u32,

    pub fn position(index: LineIndex, offset_arg: u32) Position {
        const offset = @min(offset_arg, index.source_len);
        if (index.starts.len == 0) return .{ .row = 1, .col = offset + 1 };

        var low: usize = 0;
        var high: usize = index.starts.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (index.starts[mid] <= offset)
                low = mid + 1
            else
                high = mid;
        }
        const line = if (low == 0) 0 else low - 1;
        return .{
            .row = @intCast(line + 1),
            .col = offset - index.starts[line] + 1,
        };
    }

    pub fn range(index: LineIndex, span: Span) Range {
        return .{
            .start = index.position(span.start),
            .end = index.position(if (span.end > span.start) span.end - 1 else span.end),
            .start_byte = span.start,
            .end_byte = span.end,
        };
    }
};

test "line index handles UTF-8 byte columns and CRLF boundaries" {
    const index: LineIndex = .{
        .starts = &.{ 0, 5, 9 },
        .source_len = 9,
    };
    try std.testing.expectEqualDeep(Position{ .row = 1, .col = 3 }, index.position(2));
    try std.testing.expectEqualDeep(Position{ .row = 2, .col = 1 }, index.position(5));
    try std.testing.expectEqualDeep(Position{ .row = 3, .col = 1 }, index.position(9));
}
