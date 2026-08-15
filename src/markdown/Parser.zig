//! A Markdown parser producing `Document`s.
//!
//! The parser operates at two levels: at the outer level, the parser accepts
//! the content of an input document line by line and begins building the _block
//! structure_ of the document. This creates a stack of currently open blocks.
//!
//! When the parser detects the end of a block, it closes the block, popping it
//! from the open block stack and completing any additional parsing of the
//! block's content. For blocks which contain parseable inline content, this
//! invokes the inner level of the parser, handling the _inline structure_ of
//! the block.
//!
//! Inline parsing scans through the collected inline content of a block. When
//! it encounters a character that could indicate the beginning of an inline, it
//! either handles the inline right away (if possible) or adds it to a pending
//! inlines stack. When an inline is completed, it is added to a list of
//! completed inlines, which (along with any surrounding text nodes) will become
//! the children of the parent inline or the block whose inline content is being
//! parsed.

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const isWhitespace = std.ascii.isWhitespace;
const Allocator = mem.Allocator;
const expectEqual = std.testing.expectEqual;
const Document = @import("Document.zig");
const Node = Document.Node;
const ExtraIndex = Document.ExtraIndex;
const ExtraData = Document.ExtraData;
const StringIndex = Document.StringIndex;
const ArrayList = std.ArrayList;
const Source = @import("Source.zig");

nodes: Node.List = .{},
extra: ArrayList(u32) = .empty,
scratch_extra: ArrayList(u32) = .empty,
string_bytes: ArrayList(u8) = .empty,
scratch_string: ArrayList(u8) = .empty,
scratch_source_spans: ArrayList(Source.Span) = .empty,
pending_blocks: ArrayList(Block) = .empty,
spans: ArrayList(Source.Span) = .empty,
line_starts: ArrayList(u32) = .empty,
references: ArrayList(Reference) = .empty,
source_len: u32 = 0,
current_line: []const u8 = "",
current_line_start: u32 = 0,
current_line_end: u32 = 0,
current_line_ending_len: u2 = 0,
allocator: Allocator,

const Parser = @This();

const Reference = struct {
    label: StringIndex,
    target: StringIndex,
};

/// An arbitrary limit on the maximum number of columns in a table so that
/// table-related metadata maintained by the parser does not require dynamic
/// memory allocation.
const max_table_columns = 128;

/// A block element which is still receiving children.
const Block = struct {
    tag: Tag,
    data: Data,
    extra_start: usize,
    string_start: usize,
    source_span: Source.Span,

    const Tag = enum {
        /// Data is `list`.
        list,
        /// Data is `list_item`.
        list_item,
        /// Data is `table`.
        table,
        /// Data is `none`.
        table_row,
        /// Data is `heading`.
        heading,
        /// Data is `code_block`.
        code_block,
        /// Data is `none`.
        blockquote,
        /// Data is `none`.
        paragraph,
        /// Data is `none`.
        thematic_break,
        /// Data is `none`.
        html_block,
        /// Data is `footnote_definition`.
        footnote_definition,
    };

    const Data = union {
        none: void,
        list: struct {
            marker: ListMarker,
            /// Between 0 and 999,999,999, inclusive.
            start: u30,
            tight: bool,
            last_line_blank: bool = false,
        },
        list_item: struct {
            continuation_indent: usize,
            task: Node.TaskStatus = .none,
        },
        table: struct {
            column_alignments_buffer: [max_table_columns]Node.TableCellAlignment,
            column_alignments_len: usize,
        },
        heading: struct {
            /// Between 1 and 6, inclusive.
            level: u3,
        },
        code_block: struct {
            tag: StringIndex,
            fence_char: u8,
            fence_len: usize,
            indent: usize,
        },
        footnote_definition: struct {
            label: StringIndex,
            continuation_indent: usize,
        },

        const ListMarker = enum {
            @"-",
            @"*",
            @"+",
            number_dot,
            number_paren,
        };
    };

    const ContentType = enum {
        blocks,
        inlines,
        raw_inlines,
        nothing,
    };

    fn canAccept(b: Block) ContentType {
        return switch (b.tag) {
            .list,
            .list_item,
            .table,
            .blockquote,
            .footnote_definition,
            => .blocks,

            .heading,
            .paragraph,
            => .inlines,

            .code_block,
            .html_block,
            => .raw_inlines,

            .table_row,
            .thematic_break,
            => .nothing,
        };
    }

    /// Attempts to continue `b` using the contents of `line`. If successful,
    /// returns the remaining portion of `line` to be considered part of `b`
    /// (e.g. for a blockquote, this would be everything except the leading
    /// `>`). If unsuccessful, returns null.
    fn match(b: Block, line: []const u8) ?[]const u8 {
        const unindented = mem.trimStart(u8, line, " \t");
        const indent = line.len - unindented.len;
        return switch (b.tag) {
            .list => line,
            .list_item => if (indent >= b.data.list_item.continuation_indent)
                line[b.data.list_item.continuation_indent..]
            else if (unindented.len == 0)
                // Blank lines should not close list items, since there may be
                // more indented contents to follow after the blank line.
                ""
            else
                null,
            .table => if (unindented.len > 0) line else null,
            .table_row => null,
            .heading => null,
            .code_block => code_block: {
                const trimmed = mem.trimEnd(u8, unindented, " \t");
                const closer_len = mem.findNonePos(u8, trimmed, 0, &.{b.data.code_block.fence_char}) orelse trimmed.len;
                if (closer_len < b.data.code_block.fence_len or closer_len != trimmed.len) {
                    const effective_indent = @min(indent, b.data.code_block.indent);
                    break :code_block line[effective_indent..];
                } else {
                    break :code_block null;
                }
            },
            .html_block => if (unindented.len > 0) line else null,
            .footnote_definition => if (indent >= b.data.footnote_definition.continuation_indent)
                line[b.data.footnote_definition.continuation_indent..]
            else if (unindented.len == 0)
                ""
            else
                null,
            .blockquote => if (mem.startsWith(u8, unindented, ">"))
                unindented[1..]
            else
                null,
            .paragraph => if (unindented.len > 0) line else null,
            .thematic_break => null,
        };
    }
};

pub fn init(allocator: Allocator) Allocator.Error!Parser {
    var p: Parser = .{ .allocator = allocator };
    errdefer p.deinit();
    try p.nodes.append(allocator, .{
        .tag = .root,
        .data = undefined,
    });
    try p.spans.append(allocator, .{ .start = 0, .end = 0 });
    try p.string_bytes.append(allocator, 0);
    return p;
}

pub fn deinit(p: *Parser) void {
    p.nodes.deinit(p.allocator);
    p.extra.deinit(p.allocator);
    p.scratch_extra.deinit(p.allocator);
    p.string_bytes.deinit(p.allocator);
    p.scratch_string.deinit(p.allocator);
    p.scratch_source_spans.deinit(p.allocator);
    p.pending_blocks.deinit(p.allocator);
    p.spans.deinit(p.allocator);
    p.line_starts.deinit(p.allocator);
    p.references.deinit(p.allocator);
    p.* = undefined;
}

/// Accepts a single line of content at its absolute source byte offset. `line`
/// excludes its line ending; `line_ending_len` is 0, 1 (LF), or 2 (CRLF).
pub fn feedLine(p: *Parser, line: []const u8, line_start: u32, line_ending_len: u2) Allocator.Error!void {
    assert(line_ending_len <= 2);
    assert(p.line_starts.items.len == 0 or line_start >= p.line_starts.items[p.line_starts.items.len - 1]);
    try p.line_starts.append(p.allocator, line_start);
    p.current_line = line;
    p.current_line_start = line_start;
    p.current_line_ending_len = line_ending_len;
    p.current_line_end = line_start + @as(u32, @intCast(line.len)) + line_ending_len;
    p.source_len = @max(p.source_len, p.current_line_end);

    if (try p.consumeReferenceDefinition(line)) return;
    if (try p.promoteParagraphToSetext(line)) return;
    if (try p.promoteParagraphToTable(line)) return;

    var rest_line = line;
    const first_unmatched = for (p.pending_blocks.items, 0..) |b, i| {
        if (b.match(rest_line)) |rest| {
            rest_line = rest;
        } else {
            break i;
        }
    } else p.pending_blocks.items.len;

    for (p.pending_blocks.items[0..first_unmatched]) |*block| {
        block.source_span.end = p.currentContentEnd();
    }

    const in_code_block = p.pending_blocks.items.len > 0 and
        p.pending_blocks.last().?.tag == .code_block;
    const in_html_block = p.pending_blocks.items.len > 0 and
        p.pending_blocks.last().?.tag == .html_block;
    const code_block_end = in_code_block and
        first_unmatched + 1 == p.pending_blocks.items.len;
    if (code_block_end) {
        p.pending_blocks.items[p.pending_blocks.items.len - 1].source_span.end = p.currentContentEnd();
    }
    // New blocks cannot be started if we are actively inside a code block or
    // are just closing one (to avoid interpreting the closing ``` as a new code
    // block start).
    var maybe_block_start = if ((!in_code_block or first_unmatched + 2 <= p.pending_blocks.items.len) and !in_html_block)
        try p.startBlock(rest_line)
    else
        null;

    // This is a lazy continuation line if there are no new blocks to open and
    // the last open block is a paragraph.
    if (maybe_block_start == null and
        !isBlank(rest_line) and
        p.pending_blocks.items.len > 0 and
        p.pending_blocks.last().?.tag == .paragraph)
    {
        for (p.pending_blocks.items) |*block| block.source_span.end = p.currentContentEnd();
        try p.addScratchStringLine(mem.trimStart(u8, rest_line, " \t"));
        return;
    }

    // If a new block needs to be started, any paragraph needs to be closed,
    // even though this isn't detected as part of the closing condition for
    // paragraphs.
    if (maybe_block_start != null and
        p.pending_blocks.items.len > 0 and
        p.pending_blocks.last().?.tag == .paragraph)
    {
        try p.closeLastBlock();
    }

    while (p.pending_blocks.items.len > first_unmatched) {
        try p.closeLastBlock();
    }

    while (maybe_block_start) |block_start| : (maybe_block_start = try p.startBlock(rest_line)) {
        try p.appendBlockStart(block_start);
        // There may be more blocks to start within the same line.
        rest_line = block_start.rest;
        // Headings and raw HTML blocks do not contain nested blocks.
        if (block_start.tag == .heading or block_start.tag == .html_block) break;
        // An opening code fence does not contain any additional block or inline
        // content to process.
        if (block_start.tag == .code_block) return;
    }

    // Do not append the end of a code block (```) as textual content.
    if (code_block_end) return;

    const can_accept = if (p.pending_blocks.last()) |last_pending_block|
        last_pending_block.canAccept()
    else
        .blocks;
    var rest_line_trimmed = mem.trimStart(u8, rest_line, " \t");
    switch (can_accept) {
        .blocks => {
            // If we're inside a list item and the rest of the line is blank, it
            // means that any subsequent child of the list item (or subsequent
            // item in the list) will cause the containing list to be considered
            // loose. However, we can't immediately declare that the list is
            // loose, since we might just be looking at a blank line after the
            // end of the last item in the list. The final determination will be
            // made when appending the next child of the list or list item.
            const maybe_containing_list_index = if (p.pending_blocks.items.len > 0 and p.pending_blocks.last().?.tag == .list_item)
                p.pending_blocks.items.len - 2
            else
                null;

            if (rest_line_trimmed.len > 0) {
                if (p.pending_blocks.items.len > 0 and
                    p.pending_blocks.last().?.tag == .list_item and
                    p.scratch_extra.items.len == p.pending_blocks.last().?.extra_start)
                {
                    if (taskListMarker(rest_line_trimmed)) |task| {
                        p.pending_blocks.items[p.pending_blocks.items.len - 1].data.list_item.task = task.status;
                        rest_line_trimmed = task.rest;
                    }
                }
                try p.appendBlockStart(.{
                    .tag = .paragraph,
                    .data = .{ .none = {} },
                    .rest = undefined,
                    .source_start = p.sourceOffset(rest_line_trimmed),
                });
                try p.addScratchStringLine(rest_line_trimmed);
            }

            if (maybe_containing_list_index) |containing_list_index| {
                p.pending_blocks.items[containing_list_index].data.list.last_line_blank = rest_line_trimmed.len == 0;
            }
        },
        .inlines => try p.addScratchStringLine(rest_line_trimmed),
        .raw_inlines => try p.addScratchStringLine(rest_line),
        .nothing => {},
    }
}

/// Feeds a complete source buffer while preserving LF/CRLF byte widths.
pub fn feed(p: *Parser, source: []const u8) Allocator.Error!void {
    try p.scanReferenceDefinitions(source);
    var line_start: usize = 0;
    var pos: usize = 0;
    while (pos < source.len) : (pos += 1) {
        if (source[pos] != '\n') continue;
        const has_cr = pos > line_start and source[pos - 1] == '\r';
        const content_end = pos - @intFromBool(has_cr);
        try p.feedLine(
            source[line_start..content_end],
            @intCast(line_start),
            if (has_cr) 2 else 1,
        );
        line_start = pos + 1;
    }
    try p.feedLine(source[line_start..], @intCast(line_start), 0);
}

/// Completes processing of the input and returns the parsed document.
pub fn endInput(p: *Parser) Allocator.Error!Document {
    while (p.pending_blocks.items.len > 0) {
        try p.closeLastBlock();
    }
    // There should be no inline content pending after closing the last open
    // block.
    assert(p.scratch_string.items.len == 0);

    const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items));
    p.nodes.items(.data)[0] = .{ .container = .{ .children = children } };
    const root_end = if (p.scratch_extra.items.len > 0)
        p.spans.items[p.scratch_extra.items[p.scratch_extra.items.len - 1]].end
    else
        0;
    p.spans.items[0] = .{ .start = 0, .end = root_end };
    p.scratch_string.items.len = 0;
    p.scratch_extra.items.len = 0;

    try p.extra.shrinkToLen(p.allocator);
    try p.string_bytes.shrinkToLen(p.allocator);
    try p.spans.shrinkToLen(p.allocator);
    try p.line_starts.shrinkToLen(p.allocator);

    return .{
        .nodes = p.nodes.toOwnedSlice(),
        .extra = p.extra.toOwnedSliceAssert(),
        .string_bytes = p.string_bytes.toOwnedSliceAssert(),
        .spans = p.spans.toOwnedSliceAssert(),
        .line_starts = p.line_starts.toOwnedSliceAssert(),
        .source_len = p.source_len,
    };
}

/// Data describing the start of a new block element.
const BlockStart = struct {
    tag: Tag,
    data: Data,
    rest: []const u8,
    source_start: u32,

    const Tag = enum {
        /// Data is `list_item`.
        list_item,
        /// Data is `table_row`.
        table_row,
        /// Data is `heading`.
        heading,
        /// Data is `code_block`.
        code_block,
        /// Data is `none`.
        blockquote,
        /// Data is `none`.
        paragraph,
        /// Data is `none`.
        thematic_break,
        /// Data is `none`.
        html_block,
        /// Data is `footnote_definition`.
        footnote_definition,
    };

    const Data = union {
        none: void,
        list_item: struct {
            marker: Block.Data.ListMarker,
            number: u30,
            continuation_indent: usize,
        },
        table_row: struct {
            cells_buffer: [max_table_columns][]const u8,
            cells_len: usize,
        },
        heading: struct {
            /// Between 1 and 6, inclusive.
            level: u3,
        },
        code_block: struct {
            tag: StringIndex,
            fence_char: u8,
            fence_len: usize,
            indent: usize,
        },
        footnote_definition: struct {
            label: StringIndex,
            continuation_indent: usize,
        },
    };
};

fn appendBlockStart(p: *Parser, block_start: BlockStart) !void {
    if (p.pending_blocks.last()) |last_pending_block| {
        // Close the last block if it is a list and the new block is not a list item
        // or not of the same marker type.
        const should_close_list = last_pending_block.tag == .list and
            (block_start.tag != .list_item or
                block_start.data.list_item.marker != last_pending_block.data.list.marker);
        // The last block should also be closed if the new block is not a table
        // row, which is the only allowed child of a table.
        const should_close_table = last_pending_block.tag == .table and
            block_start.tag != .table_row;
        if (should_close_list or should_close_table) {
            try p.closeLastBlock();
        }
    }

    if (p.pending_blocks.last()) |last_pending_block| {
        // If the last block is a list or list item, check for tightness based
        // on the last line.
        const maybe_containing_list = switch (last_pending_block.tag) {
            .list => &p.pending_blocks.items[p.pending_blocks.items.len - 1],
            .list_item => &p.pending_blocks.items[p.pending_blocks.items.len - 2],
            else => null,
        };
        if (maybe_containing_list) |containing_list| {
            if (containing_list.data.list.last_line_blank) {
                containing_list.data.list.tight = false;
            }
        }
    }

    // Start a new list if the new block is a list item and there is no
    // containing list yet.
    if (block_start.tag == .list_item and
        (p.pending_blocks.items.len == 0 or p.pending_blocks.last().?.tag != .list))
    {
        try p.pending_blocks.append(p.allocator, .{
            .tag = .list,
            .data = .{ .list = .{
                .marker = block_start.data.list_item.marker,
                .start = block_start.data.list_item.number,
                .tight = true,
            } },
            .string_start = p.scratch_string.items.len,
            .extra_start = p.scratch_extra.items.len,
            .source_span = .{ .start = block_start.source_start, .end = p.currentContentEnd() },
        });
    }

    if (block_start.tag == .table_row) {
        // Likewise, table rows start a table implicitly.
        if (p.pending_blocks.items.len == 0 or p.pending_blocks.last().?.tag != .table) {
            try p.pending_blocks.append(p.allocator, .{
                .tag = .table,
                .data = .{ .table = .{
                    .column_alignments_buffer = undefined,
                    .column_alignments_len = 0,
                } },
                .string_start = p.scratch_string.items.len,
                .extra_start = p.scratch_extra.items.len,
                .source_span = .{ .start = block_start.source_start, .end = p.currentContentEnd() },
            });
        }

        const current_row = p.scratch_extra.items.len - p.pending_blocks.last().?.extra_start;
        if (current_row <= 1) {
            var buffer: [max_table_columns]Node.TableCellAlignment = undefined;
            const table_row = &block_start.data.table_row;
            if (parseTableHeaderDelimiter(table_row.cells_buffer[0..table_row.cells_len], &buffer)) |alignments| {
                const table = &p.pending_blocks.items[p.pending_blocks.items.len - 1].data.table;
                @memcpy(table.column_alignments_buffer[0..alignments.len], alignments);
                table.column_alignments_len = alignments.len;
                if (current_row == 1) {
                    // We need to go back and mark the header row and its column
                    // alignments.
                    const datas = p.nodes.items(.data);
                    const header_data = datas[p.scratch_extra.last().?];
                    for (p.extraChildren(header_data.container.children), 0..) |header_cell, i| {
                        const alignment = if (i < alignments.len) alignments[i] else .unset;
                        const cell_data = &datas[@backingInt(header_cell)].table_cell;
                        cell_data.info.alignment = alignment;
                        cell_data.info.header = true;
                    }
                }
                return;
            }
        }
    }

    const tag: Block.Tag, const data: Block.Data = switch (block_start.tag) {
        .list_item => .{ .list_item, .{ .list_item = .{
            .continuation_indent = block_start.data.list_item.continuation_indent,
            .task = .none,
        } } },
        .table_row => .{ .table_row, .{ .none = {} } },
        .heading => .{ .heading, .{ .heading = .{
            .level = block_start.data.heading.level,
        } } },
        .code_block => .{ .code_block, .{ .code_block = .{
            .tag = block_start.data.code_block.tag,
            .fence_char = block_start.data.code_block.fence_char,
            .fence_len = block_start.data.code_block.fence_len,
            .indent = block_start.data.code_block.indent,
        } } },
        .blockquote => .{ .blockquote, .{ .none = {} } },
        .paragraph => .{ .paragraph, .{ .none = {} } },
        .thematic_break => .{ .thematic_break, .{ .none = {} } },
        .html_block => .{ .html_block, .{ .none = {} } },
        .footnote_definition => .{ .footnote_definition, .{ .footnote_definition = .{
            .label = block_start.data.footnote_definition.label,
            .continuation_indent = block_start.data.footnote_definition.continuation_indent,
        } } },
    };

    try p.pending_blocks.append(p.allocator, .{
        .tag = tag,
        .data = data,
        .string_start = p.scratch_string.items.len,
        .extra_start = p.scratch_extra.items.len,
        .source_span = .{ .start = block_start.source_start, .end = p.currentContentEnd() },
    });

    if (tag == .table_row) {
        // Table rows are unique, since we already have all the children
        // available in the BlockStart. We can immediately parse and append
        // these children now.
        const containing_table = p.pending_blocks.items[p.pending_blocks.items.len - 2];
        const table = &containing_table.data.table;
        const column_alignments = table.column_alignments_buffer[0..table.column_alignments_len];
        const table_row = &block_start.data.table_row;
        for (table_row.cells_buffer[0..table_row.cells_len], 0..) |cell_content, i| {
            const cell_start = p.sourceOffset(cell_content);
            const cell_children = try p.parseInlinesAt(cell_content, cell_start);
            const alignment = if (i < column_alignments.len) column_alignments[i] else .unset;
            const cell = try p.addNode(.{
                .tag = .table_cell,
                .data = .{ .table_cell = .{
                    .info = .{
                        .alignment = alignment,
                        .header = false,
                    },
                    .children = cell_children,
                } },
            }, .{ .start = cell_start, .end = cell_start + @as(u32, @intCast(cell_content.len)) });
            try p.addScratchExtraNode(cell);
        }
    }
}

fn startBlock(p: *Parser, line: []const u8) !?BlockStart {
    const unindented = mem.trimStart(u8, line, " \t");
    const source_start = p.sourceOffset(unindented);
    const indent = line.len - unindented.len;
    if (isThematicBreak(line)) {
        // Thematic breaks take precedence over list items.
        return .{
            .tag = .thematic_break,
            .data = .{ .none = {} },
            .rest = "",
            .source_start = source_start,
        };
    } else if (startListItem(unindented)) |list_item| {
        return .{
            .tag = .list_item,
            .data = .{ .list_item = .{
                .marker = list_item.marker,
                .number = list_item.number,
                .continuation_indent = indent + list_item.marker_len,
            } },
            .rest = list_item.rest,
            .source_start = source_start,
        };
    } else if (hasOpenTable(p) and
        startTableRow(unindented) != null)
    {
        const table_row = startTableRow(unindented).?;
        return .{
            .tag = .table_row,
            .data = .{ .table_row = .{
                .cells_buffer = table_row.cells_buffer,
                .cells_len = table_row.cells_len,
            } },
            .rest = "",
            .source_start = source_start,
        };
    } else if (startHeading(unindented)) |heading| {
        return .{
            .tag = .heading,
            .data = .{ .heading = .{
                .level = heading.level,
            } },
            .rest = heading.rest,
            .source_start = source_start,
        };
    } else if (try p.startCodeBlock(unindented)) |code_block| {
        return .{
            .tag = .code_block,
            .data = .{ .code_block = .{
                .tag = code_block.tag,
                .fence_char = code_block.fence_char,
                .fence_len = code_block.fence_len,
                .indent = indent,
            } },
            .rest = "",
            .source_start = source_start,
        };
    } else if (isHtmlBlockStart(unindented)) {
        return .{
            .tag = .html_block,
            .data = .{ .none = {} },
            .rest = unindented,
            .source_start = source_start,
        };
    } else if (try p.startFootnoteDefinition(unindented, indent)) |footnote| {
        return .{
            .tag = .footnote_definition,
            .data = .{ .footnote_definition = .{
                .label = footnote.label,
                .continuation_indent = footnote.continuation_indent,
            } },
            .rest = footnote.rest,
            .source_start = source_start,
        };
    } else if (startBlockquote(unindented)) |rest| {
        return .{
            .tag = .blockquote,
            .data = .{ .none = {} },
            .rest = rest,
            .source_start = source_start,
        };
    } else {
        return null;
    }
}

const FootnoteDefinitionStart = struct {
    label: StringIndex,
    continuation_indent: usize,
    rest: []const u8,
};

fn startFootnoteDefinition(p: *Parser, line: []const u8, indent: usize) !?FootnoteDefinitionStart {
    if (!mem.startsWith(u8, line, "[^")) return null;
    const close = mem.findScalar(u8, line[2..], ']') orelse return null;
    const close_pos = close + 2;
    if (close_pos == 2 or close_pos + 1 >= line.len or line[close_pos + 1] != ':') return null;
    var rest_pos = close_pos + 2;
    if (rest_pos < line.len and (line[rest_pos] == ' ' or line[rest_pos] == '\t')) rest_pos += 1;
    return .{
        .label = try p.addString(line[2..close_pos]),
        .continuation_indent = indent + 4,
        .rest = line[rest_pos..],
    };
}

fn hasOpenTable(p: *Parser) bool {
    if (p.pending_blocks.items.len == 0) return false;
    if (p.pending_blocks.last().?.tag == .table) return true;
    return p.pending_blocks.items.len >= 2 and
        p.pending_blocks.items[p.pending_blocks.items.len - 2].tag == .table;
}

const ListItemStart = struct {
    marker: Block.Data.ListMarker,
    number: u30,
    marker_len: usize,
    rest: []const u8,
};

fn startListItem(unindented_line: []const u8) ?ListItemStart {
    if (mem.startsWith(u8, unindented_line, "- ")) {
        return .{
            .marker = .@"-",
            .number = undefined,
            .marker_len = 2,
            .rest = unindented_line[2..],
        };
    } else if (mem.startsWith(u8, unindented_line, "* ")) {
        return .{
            .marker = .@"*",
            .number = undefined,
            .marker_len = 2,
            .rest = unindented_line[2..],
        };
    } else if (mem.startsWith(u8, unindented_line, "+ ")) {
        return .{
            .marker = .@"+",
            .number = undefined,
            .marker_len = 2,
            .rest = unindented_line[2..],
        };
    }

    const number_end = mem.findNone(u8, unindented_line, "0123456789") orelse return null;
    const after_number = unindented_line[number_end..];
    const marker: Block.Data.ListMarker = if (mem.startsWith(u8, after_number, ". "))
        .number_dot
    else if (mem.startsWith(u8, after_number, ") "))
        .number_paren
    else
        return null;
    const number = std.fmt.parseInt(u30, unindented_line[0..number_end], 10) catch return null;
    if (number > 999_999_999) return null;
    return .{
        .marker = marker,
        .number = number,
        .marker_len = number_end + 2,
        .rest = after_number[2..],
    };
}

const TableRowStart = struct {
    cells_buffer: [max_table_columns][]const u8,
    cells_len: usize,
};

const ReferenceDefinition = struct {
    label: []const u8,
    target: []const u8,
};

fn parseReferenceDefinition(line_arg: []const u8) ?ReferenceDefinition {
    const line = mem.trimStart(u8, line_arg, " \t");
    if (line.len < 5 or line[0] != '[' or line[1] == '^') return null;
    const close = mem.findScalar(u8, line[1..], ']') orelse return null;
    const close_pos = close + 1;
    if (close_pos == 1 or close_pos + 1 >= line.len or line[close_pos + 1] != ':') return null;
    var rest = mem.trimStart(u8, line[close_pos + 2 ..], " \t");
    if (rest.len == 0) return null;
    const target = if (rest[0] == '<') target: {
        const end = mem.findScalar(u8, rest[1..], '>') orelse return null;
        break :target rest[1 .. end + 1];
    } else target: {
        const end = mem.findAny(u8, rest, " \t") orelse rest.len;
        break :target rest[0..end];
    };
    return .{ .label = line[1..close_pos], .target = target };
}

fn registerReference(p: *Parser, definition: ReferenceDefinition) !void {
    if (p.lookupReference(definition.label) != null) return;
    try p.references.append(p.allocator, .{
        .label = try p.addString(definition.label),
        .target = try p.addString(definition.target),
    });
}

fn lookupReference(p: *Parser, label: []const u8) ?Reference {
    for (p.references.items) |reference| {
        if (std.ascii.eqlIgnoreCase(p.string(reference.label), label)) return reference;
    }
    return null;
}

fn string(p: Parser, index: StringIndex) []const u8 {
    const start: usize = @backingInt(index);
    const end = mem.findScalarPos(u8, p.string_bytes.items, start, 0).?;
    return p.string_bytes.items[start..end];
}

fn scanReferenceDefinitions(p: *Parser, source: []const u8) !void {
    var lines = mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trimEnd(u8, raw_line, "\r");
        if (parseReferenceDefinition(line)) |definition| try p.registerReference(definition);
    }
}

fn consumeReferenceDefinition(p: *Parser, line: []const u8) !bool {
    const definition = parseReferenceDefinition(line) orelse return false;
    while (p.pending_blocks.items.len > 0) try p.closeLastBlock();
    try p.registerReference(definition);
    return true;
}

fn promoteParagraphToSetext(p: *Parser, delimiter_line: []const u8) !bool {
    if (p.pending_blocks.items.len == 0 or p.pending_blocks.last().?.tag != .paragraph) return false;
    const delimiter = mem.trim(u8, delimiter_line, " \t");
    if (delimiter.len == 0) return false;
    const level: u3 = switch (delimiter[0]) {
        '=' => 1,
        '-' => 2,
        else => return false,
    };
    for (delimiter) |c| if (c != delimiter[0]) return false;

    const paragraph = p.pending_blocks.last().?;
    const content_with_newline = p.scratch_string.items[paragraph.string_start..];
    if (content_with_newline.len == 0 or content_with_newline[content_with_newline.len - 1] != '\n') return false;
    const content = content_with_newline[0 .. content_with_newline.len - 1];
    if (mem.findScalar(u8, content, '\n') != null) return false;

    _ = p.pending_blocks.pop();
    const children = try p.parseInlines(
        content,
        p.scratch_source_spans.items[paragraph.string_start..][0..content.len],
    );
    const heading = try p.addNode(.{
        .tag = .heading,
        .data = .{ .heading = .{ .level = level, .children = children } },
    }, .{ .start = paragraph.source_span.start, .end = p.currentContentEnd() });
    p.scratch_string.items.len = paragraph.string_start;
    p.scratch_source_spans.items.len = paragraph.string_start;
    p.scratch_extra.items.len = paragraph.extra_start;
    try p.addScratchExtraNode(heading);
    return true;
}

fn promoteParagraphToTable(p: *Parser, delimiter_line: []const u8) !bool {
    if (p.pending_blocks.items.len == 0 or p.pending_blocks.last().?.tag != .paragraph) return false;
    const paragraph = p.pending_blocks.last().?;
    const header_with_newline = p.scratch_string.items[paragraph.string_start..];
    if (header_with_newline.len == 0 or header_with_newline[header_with_newline.len - 1] != '\n') return false;
    const header = header_with_newline[0 .. header_with_newline.len - 1];
    if (mem.findScalar(u8, header, '\n') != null) return false;

    const header_row = startTableRow(header) orelse return false;
    const delimiter_row = startTableRow(mem.trimStart(u8, delimiter_line, " \t")) orelse return false;
    var alignment_buffer: [max_table_columns]Node.TableCellAlignment = undefined;
    const alignments = parseTableHeaderDelimiter(
        delimiter_row.cells_buffer[0..delimiter_row.cells_len],
        &alignment_buffer,
    ) orelse return false;
    if (alignments.len != header_row.cells_len) return false;

    _ = p.pending_blocks.pop();
    try p.pending_blocks.append(p.allocator, .{
        .tag = .table,
        .data = .{ .table = .{
            .column_alignments_buffer = undefined,
            .column_alignments_len = alignments.len,
        } },
        .string_start = paragraph.string_start,
        .extra_start = paragraph.extra_start,
        .source_span = .{
            .start = paragraph.source_span.start,
            .end = p.currentContentEnd(),
        },
    });
    @memcpy(
        p.pending_blocks.items[p.pending_blocks.items.len - 1].data.table.column_alignments_buffer[0..alignments.len],
        alignments,
    );

    var cell_nodes_buffer: [max_table_columns]Node.Index = undefined;
    var cell_nodes: ArrayList(Node.Index) = .initBuffer(&cell_nodes_buffer);
    const header_maps = p.scratch_source_spans.items[paragraph.string_start..][0..header.len];
    for (header_row.cells_buffer[0..header_row.cells_len], 0..) |cell_content, i| {
        const offset = @intFromPtr(cell_content.ptr) - @intFromPtr(header.ptr);
        const cell_maps = header_maps[offset..][0..cell_content.len];
        const children = try p.parseInlines(cell_content, cell_maps);
        const cell = try p.addNode(.{
            .tag = .table_cell,
            .data = .{ .table_cell = .{
                .info = .{ .alignment = alignments[i], .header = true },
                .children = children,
            } },
        }, mappedSpan(cell_maps, paragraph.source_span.start));
        cell_nodes.appendAssumeCapacity(cell);
    }
    const row = try p.addNode(.{
        .tag = .table_row,
        .data = .{ .container = .{
            .children = try p.addExtraChildren(cell_nodes.items),
        } },
    }, paragraph.source_span);

    p.scratch_string.items.len = paragraph.string_start;
    p.scratch_source_spans.items.len = paragraph.string_start;
    p.scratch_extra.items.len = paragraph.extra_start;
    try p.addScratchExtraNode(row);
    return true;
}

fn mappedSpan(maps: []const Source.Span, fallback: u32) Source.Span {
    if (maps.len == 0) return .{ .start = fallback, .end = fallback };
    return .{ .start = maps[0].start, .end = maps[maps.len - 1].end };
}

fn startTableRow(unindented_line: []const u8) ?TableRowStart {
    const line = mem.trim(u8, unindented_line, " \t");
    if (line.len == 0) return null;

    const has_leading_pipe = line[0] == '|';
    const has_trailing_pipe = line[line.len - 1] == '|' and
        (line.len < 2 or line[line.len - 2] != '\\');
    const content_start: usize = @intFromBool(has_leading_pipe);
    const content_end = line.len - @intFromBool(has_trailing_pipe);
    if (content_start > content_end) return null;

    var cells_buffer: [max_table_columns][]const u8 = undefined;
    var cells: ArrayList([]const u8) = .initBuffer(&cells_buffer);
    const table_row_content = line[content_start..content_end];
    var cell_start: usize = 0;
    var i: usize = 0;
    var saw_separator = has_leading_pipe or has_trailing_pipe;
    while (i < table_row_content.len) : (i += 1) {
        switch (table_row_content[i]) {
            '\\' => i += 1,
            '|' => {
                saw_separator = true;
                cells.appendBounded(table_row_content[cell_start..i]) catch return null;
                cell_start = i + 1;
            },
            '`' => {
                // Ignoring pipes in code spans allows table cells to contain
                // code using ||, for example.
                const open_start = i;
                i = mem.findNonePos(u8, table_row_content, i, "`") orelse return null;
                const open_len = i - open_start;
                while (mem.findScalarPos(u8, table_row_content, i, '`')) |close_start| {
                    i = mem.findNonePos(u8, table_row_content, close_start, "`") orelse return null;
                    const close_len = i - close_start;
                    if (close_len == open_len) break;
                } else return null;
            },
            else => {},
        }
    }
    if (!saw_separator) return null;
    cells.appendBounded(table_row_content[cell_start..]) catch return null;

    return .{ .cells_buffer = cells_buffer, .cells_len = cells.items.len };
}

fn parseTableHeaderDelimiter(
    row_cells: []const []const u8,
    buffer: []Node.TableCellAlignment,
) ?[]Node.TableCellAlignment {
    var alignments: ArrayList(Node.TableCellAlignment) = .initBuffer(buffer);
    for (row_cells) |content| {
        const alignment = parseTableHeaderDelimiterCell(content) orelse return null;
        alignments.appendAssumeCapacity(alignment);
    }
    return alignments.items;
}

fn parseTableHeaderDelimiterCell(content: []const u8) ?Node.TableCellAlignment {
    var state: enum {
        before_rule,
        after_left_anchor,
        in_rule,
        after_right_anchor,
        after_rule,
    } = .before_rule;
    var left_anchor = false;
    var right_anchor = false;
    for (content) |c| {
        switch (state) {
            .before_rule => switch (c) {
                ' ' => {},
                ':' => {
                    left_anchor = true;
                    state = .after_left_anchor;
                },
                '-' => state = .in_rule,
                else => return null,
            },
            .after_left_anchor => switch (c) {
                '-' => state = .in_rule,
                else => return null,
            },
            .in_rule => switch (c) {
                '-' => {},
                ':' => {
                    right_anchor = true;
                    state = .after_right_anchor;
                },
                ' ' => state = .after_rule,
                else => return null,
            },
            .after_right_anchor => switch (c) {
                ' ' => state = .after_rule,
                else => return null,
            },
            .after_rule => switch (c) {
                ' ' => {},
                else => return null,
            },
        }
    }

    switch (state) {
        .before_rule,
        .after_left_anchor,
        => return null,

        .in_rule,
        .after_right_anchor,
        .after_rule,
        => {},
    }

    return if (left_anchor and right_anchor)
        .center
    else if (left_anchor)
        .left
    else if (right_anchor)
        .right
    else
        .unset;
}

test parseTableHeaderDelimiterCell {
    try expectEqual(null, parseTableHeaderDelimiterCell(""));
    try expectEqual(null, parseTableHeaderDelimiterCell("   "));
    try expectEqual(.unset, parseTableHeaderDelimiterCell("-"));
    try expectEqual(.unset, parseTableHeaderDelimiterCell(" - "));
    try expectEqual(.unset, parseTableHeaderDelimiterCell("----"));
    try expectEqual(.unset, parseTableHeaderDelimiterCell(" ---- "));
    try expectEqual(null, parseTableHeaderDelimiterCell(":"));
    try expectEqual(null, parseTableHeaderDelimiterCell("::"));
    try expectEqual(.left, parseTableHeaderDelimiterCell(":-"));
    try expectEqual(.left, parseTableHeaderDelimiterCell(" :----"));
    try expectEqual(.center, parseTableHeaderDelimiterCell(":-:"));
    try expectEqual(.center, parseTableHeaderDelimiterCell(":----:"));
    try expectEqual(.center, parseTableHeaderDelimiterCell("   :----:   "));
    try expectEqual(.right, parseTableHeaderDelimiterCell("-:"));
    try expectEqual(.right, parseTableHeaderDelimiterCell("----:"));
    try expectEqual(.right, parseTableHeaderDelimiterCell("  ----:  "));
}

const HeadingStart = struct {
    level: u3,
    rest: []const u8,
};

fn startHeading(unindented_line: []const u8) ?HeadingStart {
    var level: u3 = 0;
    return for (unindented_line, 0..) |c, i| {
        switch (c) {
            '#' => {
                if (level == 6) break null;
                level += 1;
            },
            ' ' => {
                // We must have seen at least one # by this point, since
                // unindented_line has no leading spaces.
                assert(level > 0);
                break .{
                    .level = level,
                    .rest = unindented_line[i + 1 ..],
                };
            },
            else => break null,
        }
    } else null;
}

const CodeBlockStart = struct {
    tag: StringIndex,
    fence_char: u8,
    fence_len: usize,
};

fn startCodeBlock(p: *Parser, unindented_line: []const u8) !?CodeBlockStart {
    if (unindented_line.len == 0 or
        (unindented_line[0] != '`' and unindented_line[0] != '~')) return null;
    const fence_char = unindented_line[0];
    var fence_len: usize = 0;
    const tag_bytes = for (unindented_line, 0..) |c, i| {
        if (c == fence_char)
            fence_len += 1
        else
            break unindented_line[i..];
    } else "";
    // Code block tags may not contain backticks, since that would create
    // potential confusion with inline code spans.
    if (fence_len < 3 or
        (fence_char == '`' and mem.findScalar(u8, tag_bytes, '`') != null)) return null;
    return .{
        .tag = try p.addString(mem.trim(u8, tag_bytes, " ")),
        .fence_char = fence_char,
        .fence_len = fence_len,
    };
}

fn startBlockquote(unindented_line: []const u8) ?[]const u8 {
    return if (mem.startsWith(u8, unindented_line, ">"))
        unindented_line[1..]
    else
        null;
}

fn isThematicBreak(line: []const u8) bool {
    var char: ?u8 = null;
    var count: usize = 0;
    for (line) |c| {
        switch (c) {
            ' ' => {},
            '-', '_', '*' => {
                if (char != null and c != char.?) return false;
                char = c;
                count += 1;
            },
            else => return false,
        }
    }
    return count >= 3;
}

fn isHtmlBlockStart(line: []const u8) bool {
    if (line.len < 2 or line[0] != '<') return false;
    if (mem.startsWith(u8, line, "<!--") or
        mem.startsWith(u8, line, "<?") or
        mem.startsWith(u8, line, "<![CDATA[") or
        (line.len > 2 and line[1] == '!' and std.ascii.isUpper(line[2]))) return true;

    var pos: usize = 1;
    if (line[pos] == '/') pos += 1;
    const name_start = pos;
    while (pos < line.len and (std.ascii.isAlphanumeric(line[pos]) or line[pos] == '-')) : (pos += 1) {}
    if (pos == name_start) return false;
    if (!isBlockHtmlTag(line[name_start..pos])) return false;
    return pos == line.len or isWhitespace(line[pos]) or line[pos] == '>' or line[pos] == '/';
}

fn isBlockHtmlTag(name: []const u8) bool {
    const tags = [_][]const u8{
        "address", "article",  "aside",    "base",     "basefont", "blockquote", "body",
        "caption", "center",   "col",      "colgroup", "dd",       "details",    "dialog",
        "dir",     "div",      "dl",       "dt",       "fieldset", "figcaption", "figure",
        "footer",  "form",     "frame",    "frameset", "h1",       "h2",         "h3",
        "h4",      "h5",       "h6",       "head",     "header",   "hr",         "html",
        "iframe",  "legend",   "li",       "link",     "main",     "menu",       "menuitem",
        "nav",     "noframes", "ol",       "optgroup", "option",   "p",          "param",
        "search",  "section",  "summary",  "table",    "tbody",    "td",         "tfoot",
        "th",      "thead",    "title",    "tr",       "track",    "ul",         "script",
        "pre",     "style",    "textarea",
    };
    for (tags) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

fn closeLastBlock(p: *Parser) !void {
    const b = p.pending_blocks.pop().?;
    const node = switch (b.tag) {
        .list => list: {
            assert(b.string_start == p.scratch_string.items.len);

            // Although tightness is parsed as a property of the list, it is
            // stored at the list item level to make it possible to render each
            // node without any context from its parents.
            const list_items = p.scratch_extra.items[b.extra_start..];
            const node_datas = p.nodes.items(.data);
            if (!b.data.list.tight) {
                for (list_items) |list_item| {
                    node_datas[list_item].list_item.tight = false;
                }
            }

            const children = try p.addExtraChildren(@ptrCast(list_items));
            break :list try p.addNode(.{
                .tag = .list,
                .data = .{ .list = .{
                    .start = switch (b.data.list.marker) {
                        .number_dot, .number_paren => @fromBackingInt(@intCast(b.data.list.start)),
                        .@"-", .@"*", .@"+" => .unordered,
                    },
                    .children = children,
                } },
            }, b.source_span);
        },
        .list_item => list_item: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :list_item try p.addNode(.{
                .tag = .list_item,
                .data = .{ .list_item = .{
                    .tight = true,
                    .task = b.data.list_item.task,
                    .children = children,
                } },
            }, b.source_span);
        },
        .table => table: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :table try p.addNode(.{
                .tag = .table,
                .data = .{ .container = .{
                    .children = children,
                } },
            }, b.source_span);
        },
        .table_row => table_row: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :table_row try p.addNode(.{
                .tag = .table_row,
                .data = .{ .container = .{
                    .children = children,
                } },
            }, b.source_span);
        },
        .heading => heading: {
            const children = try p.parseInlines(
                p.scratch_string.items[b.string_start..],
                p.scratch_source_spans.items[b.string_start..],
            );
            break :heading try p.addNode(.{
                .tag = .heading,
                .data = .{ .heading = .{
                    .level = b.data.heading.level,
                    .children = children,
                } },
            }, b.source_span);
        },
        .code_block => code_block: {
            const content = try p.addString(p.scratch_string.items[b.string_start..]);
            break :code_block try p.addNode(.{
                .tag = .code_block,
                .data = .{ .code_block = .{
                    .tag = b.data.code_block.tag,
                    .content = content,
                } },
            }, b.source_span);
        },
        .blockquote => blockquote: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :blockquote try p.addNode(.{
                .tag = .blockquote,
                .data = .{ .container = .{
                    .children = children,
                } },
            }, b.source_span);
        },
        .paragraph => paragraph: {
            const children = try p.parseInlines(
                p.scratch_string.items[b.string_start..],
                p.scratch_source_spans.items[b.string_start..],
            );
            break :paragraph try p.addNode(.{
                .tag = .paragraph,
                .data = .{ .container = .{
                    .children = children,
                } },
            }, b.source_span);
        },
        .thematic_break => try p.addNode(.{
            .tag = .thematic_break,
            .data = .{ .none = {} },
        }, b.source_span),
        .html_block => html_block: {
            const content = mem.trimEnd(u8, p.scratch_string.items[b.string_start..], "\n");
            break :html_block try p.addNode(.{
                .tag = .html_block,
                .data = .{ .text = .{ .content = try p.addString(content) } },
            }, b.source_span);
        },
        .footnote_definition => footnote_definition: {
            assert(b.string_start == p.scratch_string.items.len);
            const children = try p.addExtraChildren(@ptrCast(p.scratch_extra.items[b.extra_start..]));
            break :footnote_definition try p.addNode(.{
                .tag = .footnote_definition,
                .data = .{ .footnote_definition = .{
                    .label = b.data.footnote_definition.label,
                    .children = children,
                } },
            }, b.source_span);
        },
    };
    p.scratch_string.items.len = b.string_start;
    p.scratch_source_spans.items.len = b.string_start;
    p.scratch_extra.items.len = b.extra_start;
    try p.addScratchExtraNode(node);
}

const InlineParser = struct {
    parent: *Parser,
    content: []const u8,
    source_spans: []const Source.Span,
    pos: usize = 0,
    pending_inlines: ArrayList(PendingInline) = .empty,
    completed_inlines: ArrayList(CompletedInline) = .empty,

    const PendingInline = struct {
        tag: Tag,
        data: Data,
        start: usize,

        const Tag = enum {
            /// Data is `emphasis`.
            emphasis,
            /// Data is `none`.
            link,
            /// Data is `none`.
            image,
            /// Data is `none`.
            strikethrough,
        };

        const Data = union {
            none: void,
            emphasis: struct {
                underscore: bool,
                run_len: usize,
            },
        };
    };

    const CompletedInline = struct {
        node: Node.Index,
        start: usize,
        len: usize,
    };

    fn deinit(ip: *InlineParser) void {
        ip.pending_inlines.deinit(ip.parent.allocator);
        ip.completed_inlines.deinit(ip.parent.allocator);
    }

    fn sourceSpan(ip: InlineParser, start: usize, end: usize) Source.Span {
        assert(start <= end and end <= ip.source_spans.len);
        if (start < end) return .{
            .start = ip.source_spans[start].start,
            .end = ip.source_spans[end - 1].end,
        };
        const offset = if (start < ip.source_spans.len)
            ip.source_spans[start].start
        else if (ip.source_spans.len > 0)
            ip.source_spans[ip.source_spans.len - 1].end
        else
            0;
        return .{ .start = offset, .end = offset };
    }

    /// Parses all of `ip.content`, returning the children of the node
    /// containing the inline content.
    fn parse(ip: *InlineParser) Allocator.Error!ExtraIndex {
        while (ip.pos < ip.content.len) : (ip.pos += 1) {
            switch (ip.content[ip.pos]) {
                '\\' => ip.pos += 1,
                '[' => if (!try ip.parseFootnoteReference()) {
                    try ip.pending_inlines.append(ip.parent.allocator, .{
                        .tag = .link,
                        .data = .{ .none = {} },
                        .start = ip.pos,
                    });
                },
                '!' => if (ip.pos + 1 < ip.content.len and ip.content[ip.pos + 1] == '[') {
                    try ip.pending_inlines.append(ip.parent.allocator, .{
                        .tag = .image,
                        .data = .{ .none = {} },
                        .start = ip.pos,
                    });
                    ip.pos += 1;
                },
                ']' => try ip.parseLink(),
                '<' => if (!try ip.parseHtml()) try ip.parseAutolink(),
                '*', '_' => try ip.parseEmphasis(),
                '~' => try ip.parseStrikethrough(),
                '`' => try ip.parseCodeSpan(),
                'h' => if (ip.pos == 0 or isPreTextAutolink(ip.content[ip.pos - 1])) {
                    try ip.parseTextAutolink();
                },
                else => {},
            }
        }

        const children = try ip.encodeChildren(0, ip.content.len);
        // There may be pending inlines after parsing (e.g. unclosed emphasis
        // runs), but there must not be any completed inlines, since those
        // should all be part of `children`.
        assert(ip.completed_inlines.items.len == 0);
        return children;
    }

    /// Parses a link, starting at the `]` at the end of the link text. `ip.pos`
    /// is left at the closing `)` of the link target or at the closing `]` if
    /// there is none.
    fn parseLink(ip: *InlineParser) !void {
        var i = ip.pending_inlines.items.len;
        while (i > 0) {
            i -= 1;
            if (ip.pending_inlines.items[i].tag == .link or
                ip.pending_inlines.items[i].tag == .image) break;
        } else return;
        const opener = ip.pending_inlines.items[i];
        ip.pending_inlines.shrinkRetainingCapacity(i);
        const text_start = switch (opener.tag) {
            .link => opener.start + 1,
            .image => opener.start + 2,
            else => unreachable,
        };

        const text_end = ip.pos;
        var target: StringIndex = undefined;
        var link_end: usize = undefined;
        if (ip.pos + 1 < ip.content.len and ip.content[ip.pos + 1] == '(') {
            const target_start = text_end + 2;
            var target_end = target_start;
            var nesting_level: usize = 1;
            while (target_end < ip.content.len) : (target_end += 1) {
                switch (ip.content[target_end]) {
                    '\\' => target_end += 1,
                    '(' => nesting_level += 1,
                    ')' => {
                        if (nesting_level == 1) break;
                        nesting_level -= 1;
                    },
                    else => {},
                }
            } else return;
            target = try ip.encodeLinkTarget(target_start, target_end);
            link_end = target_end + 1;
        } else {
            var label = ip.content[text_start..text_end];
            var end = text_end + 1;
            if (text_end + 1 < ip.content.len and ip.content[text_end + 1] == '[') {
                const label_end = mem.findScalarPos(u8, ip.content, text_end + 2, ']') orelse return;
                const explicit_label = ip.content[text_end + 2 .. label_end];
                if (explicit_label.len > 0) label = explicit_label;
                end = label_end + 1;
            }
            const resolved = ip.parent.lookupReference(label) orelse return;
            target = resolved.target;
            link_end = end;
        }
        ip.pos = link_end - 1;

        const children = try ip.encodeChildren(text_start, text_end);

        const link = try ip.parent.addNode(.{
            .tag = switch (opener.tag) {
                .link => .link,
                .image => .image,
                else => unreachable,
            },
            .data = .{ .link = .{
                .target = target,
                .children = children,
            } },
        }, ip.sourceSpan(opener.start, link_end));
        try ip.completed_inlines.append(ip.parent.allocator, .{
            .node = link,
            .start = opener.start,
            .len = link_end - opener.start,
        });
    }

    fn parseFootnoteReference(ip: *InlineParser) !bool {
        const start = ip.pos;
        if (start + 3 >= ip.content.len or ip.content[start + 1] != '^') return false;
        const close = mem.findScalarPos(u8, ip.content, start + 2, ']') orelse return false;
        if (close == start + 2) return false;
        const label = ip.content[start + 2 .. close];
        if (mem.findAny(u8, label, " \t\n") != null) return false;

        const node = try ip.parent.addNode(.{
            .tag = .footnote_reference,
            .data = .{ .text = .{ .content = try ip.parent.addString(label) } },
        }, ip.sourceSpan(start, close + 1));
        try ip.completed_inlines.append(ip.parent.allocator, .{
            .node = node,
            .start = start,
            .len = close + 1 - start,
        });
        ip.pos = close;
        return true;
    }

    /// Parses a raw inline HTML tag, comment, declaration, or processing
    /// instruction. Returns whether a node was emitted.
    fn parseHtml(ip: *InlineParser) !bool {
        const start = ip.pos;
        if (start + 1 >= ip.content.len) return false;

        var pos = start + 1;
        const special = ip.content[pos] == '!' or ip.content[pos] == '?';
        if (!special) {
            if (ip.content[pos] == '/') pos += 1;
            if (pos >= ip.content.len or !std.ascii.isAlphabetic(ip.content[pos])) return false;
            pos += 1;
            while (pos < ip.content.len and
                (std.ascii.isAlphanumeric(ip.content[pos]) or ip.content[pos] == '-')) : (pos += 1)
            {}
            if (pos >= ip.content.len or
                !(isWhitespace(ip.content[pos]) or ip.content[pos] == '/' or ip.content[pos] == '>')) return false;
        }

        var quote: ?u8 = null;
        while (pos < ip.content.len) : (pos += 1) {
            const c = ip.content[pos];
            if (quote) |q| {
                if (c == q) quote = null;
                continue;
            }
            if (c == '\'' or c == '"') {
                quote = c;
            } else if (c == '>') {
                const end = pos + 1;
                const node = try ip.parent.addNode(.{
                    .tag = .html_inline,
                    .data = .{ .text = .{
                        .content = try ip.parent.addString(ip.content[start..end]),
                    } },
                }, ip.sourceSpan(start, end));
                try ip.completed_inlines.append(ip.parent.allocator, .{
                    .node = node,
                    .start = start,
                    .len = end - start,
                });
                ip.pos = pos;
                return true;
            } else if (c == '\n') {
                return false;
            }
        }
        return false;
    }

    fn encodeLinkTarget(ip: *InlineParser, start: usize, end: usize) !StringIndex {
        // For efficiency, we can encode directly into string_bytes rather than
        // creating a temporary string and then encoding it, since this process
        // is entirely linear.
        const string_top = ip.parent.string_bytes.items.len;
        errdefer ip.parent.string_bytes.shrinkRetainingCapacity(string_top);

        var text_iter: TextIterator = .{ .content = ip.content[start..end], .smart = false };
        while (text_iter.next()) |content| {
            switch (content) {
                .char => |c| try ip.parent.string_bytes.append(ip.parent.allocator, c),
                .text => |s| try ip.parent.string_bytes.appendSlice(ip.parent.allocator, s),
                .line_break => try ip.parent.string_bytes.appendSlice(ip.parent.allocator, "\\\n"),
                .soft_break => try ip.parent.string_bytes.append(ip.parent.allocator, '\n'),
            }
        }
        try ip.parent.string_bytes.append(ip.parent.allocator, 0);
        return @fromBackingInt(@intCast(string_top));
    }

    /// Parses an autolink, starting at the opening `<`. `ip.pos` is left at the
    /// closing `>`, or remains unchanged at the opening `<` if there is none.
    fn parseAutolink(ip: *InlineParser) !void {
        const start = ip.pos;
        ip.pos += 1;
        var state: enum {
            start,
            scheme,
            target,
        } = .start;
        while (ip.pos < ip.content.len) : (ip.pos += 1) {
            switch (state) {
                .start => switch (ip.content[ip.pos]) {
                    'A'...'Z', 'a'...'z' => state = .scheme,
                    else => break,
                },
                .scheme => switch (ip.content[ip.pos]) {
                    'A'...'Z', 'a'...'z', '0'...'9', '+', '.', '-' => {},
                    ':' => state = .target,
                    else => break,
                },
                .target => switch (ip.content[ip.pos]) {
                    '<', ' ', '\t', '\n' => break, // Not allowed in autolinks
                    '>' => {
                        // Backslash escapes are not recognized in autolink targets.
                        const target = try ip.parent.addString(ip.content[start + 1 .. ip.pos]);
                        const node = try ip.parent.addNode(.{
                            .tag = .autolink,
                            .data = .{ .text = .{
                                .content = target,
                            } },
                        }, ip.sourceSpan(start, ip.pos + 1));
                        try ip.completed_inlines.append(ip.parent.allocator, .{
                            .node = node,
                            .start = start,
                            .len = ip.pos - start + 1,
                        });
                        return;
                    },
                    else => {},
                },
            }
        }
        ip.pos = start;
    }

    /// Parses a plain text autolink (not delimited by `<>`), starting at the
    /// first character in the link (an `h`). `ip.pos` is left at the last
    /// character of the link, or remains unchanged if there is no valid link.
    fn parseTextAutolink(ip: *InlineParser) !void {
        const start = ip.pos;
        var state: union(enum) {
            /// Inside `http`. Contains the rest of the text to be matched.
            http: []const u8,
            after_http,
            after_https,
            /// Inside `://`. Contains the rest of the text to be matched.
            authority: []const u8,
            /// Inside link content.
            content: struct {
                start: usize,
                paren_nesting: usize,
            },
        } = .{ .http = "http" };

        while (ip.pos < ip.content.len) : (ip.pos += 1) {
            switch (state) {
                .http => |rest| {
                    if (ip.content[ip.pos] != rest[0]) break;
                    if (rest.len > 1) {
                        state = .{ .http = rest[1..] };
                    } else {
                        state = .after_http;
                    }
                },
                .after_http => switch (ip.content[ip.pos]) {
                    's' => state = .after_https,
                    ':' => state = .{ .authority = "//" },
                    else => break,
                },
                .after_https => switch (ip.content[ip.pos]) {
                    ':' => state = .{ .authority = "//" },
                    else => break,
                },
                .authority => |rest| {
                    if (ip.content[ip.pos] != rest[0]) break;
                    if (rest.len > 1) {
                        state = .{ .authority = rest[1..] };
                    } else {
                        state = .{ .content = .{
                            .start = ip.pos + 1,
                            .paren_nesting = 0,
                        } };
                    }
                },
                .content => |*content| switch (ip.content[ip.pos]) {
                    ' ', '\t', '\n' => break,
                    '(' => content.paren_nesting += 1,
                    ')' => if (content.paren_nesting == 0) {
                        break;
                    } else {
                        content.paren_nesting -= 1;
                    },
                    else => {},
                },
            }
        }

        switch (state) {
            .http, .after_http, .after_https, .authority => {
                ip.pos = start;
            },
            .content => |content| {
                while (ip.pos > content.start and isPostTextAutolink(ip.content[ip.pos - 1])) {
                    ip.pos -= 1;
                }
                if (ip.pos == content.start) {
                    ip.pos = start;
                    return;
                }

                const target = try ip.parent.addString(ip.content[start..ip.pos]);
                const node = try ip.parent.addNode(.{
                    .tag = .autolink,
                    .data = .{ .text = .{
                        .content = target,
                    } },
                }, ip.sourceSpan(start, ip.pos));
                try ip.completed_inlines.append(ip.parent.allocator, .{
                    .node = node,
                    .start = start,
                    .len = ip.pos - start,
                });
                ip.pos -= 1;
            },
        }
    }

    /// Returns whether `c` may appear before a text autolink is recognized.
    fn isPreTextAutolink(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\n', '*', '_', '(' => true,
            else => false,
        };
    }

    /// Returns whether `c` is punctuation that may appear after a text autolink
    /// and not be considered part of it.
    fn isPostTextAutolink(c: u8) bool {
        return switch (c) {
            '?', '!', '.', ',', ':', '*', '_' => true,
            else => false,
        };
    }

    /// Parses emphasis, starting at the beginning of a run of `*` or `_`
    /// characters. `ip.pos` is left at the last character in the run after
    /// parsing.
    fn parseEmphasis(ip: *InlineParser) !void {
        const char = ip.content[ip.pos];
        var start = ip.pos;
        while (ip.pos + 1 < ip.content.len and ip.content[ip.pos + 1] == char) {
            ip.pos += 1;
        }
        var len = ip.pos - start + 1;
        const underscore = char == '_';
        const space_before = start == 0 or isWhitespace(ip.content[start - 1]);
        const space_after = start + len == ip.content.len or isWhitespace(ip.content[start + len]);
        const punct_before = start == 0 or isPunctuation(ip.content[start - 1]);
        const punct_after = start + len == ip.content.len or isPunctuation(ip.content[start + len]);
        // The rules for when emphasis may be closed or opened are stricter for
        // underscores to avoid inappropriately interpreting snake_case words as
        // containing emphasis markers.
        const can_open = if (underscore)
            !space_after and (space_before or punct_before)
        else
            !space_after;
        const can_close = if (underscore)
            !space_before and (space_after or punct_after)
        else
            !space_before;

        if (can_close and ip.pending_inlines.items.len > 0) {
            var i = ip.pending_inlines.items.len;
            while (i > 0 and len > 0) {
                i -= 1;
                const opener = &ip.pending_inlines.items[i];
                if (opener.tag != .emphasis or
                    opener.data.emphasis.underscore != underscore) continue;

                const close_len = @min(opener.data.emphasis.run_len, len);
                const opener_end = opener.start + opener.data.emphasis.run_len;

                const emphasis = try ip.encodeEmphasis(opener_end, start, close_len);
                const emphasis_start = opener_end - close_len;
                const emphasis_len = start - emphasis_start + close_len;
                try ip.completed_inlines.append(ip.parent.allocator, .{
                    .node = emphasis,
                    .start = emphasis_start,
                    .len = emphasis_len,
                });

                // There may still be other openers further down in the
                // stack to close, or part of this run might serve as an
                // opener itself.
                start += close_len;
                len -= close_len;

                // Remove any pending inlines above this on the stack, since
                // closing this emphasis will prevent them from being closed.
                // Additionally, if this opener is completely consumed by
                // being closed, it can be removed.
                opener.data.emphasis.run_len -= close_len;
                if (opener.data.emphasis.run_len == 0) {
                    ip.pending_inlines.shrinkRetainingCapacity(i);
                } else {
                    ip.pending_inlines.shrinkRetainingCapacity(i + 1);
                }
            }
        }

        if (can_open and len > 0) {
            try ip.pending_inlines.append(ip.parent.allocator, .{
                .tag = .emphasis,
                .data = .{ .emphasis = .{
                    .underscore = underscore,
                    .run_len = len,
                } },
                .start = start,
            });
        }
    }

    fn parseStrikethrough(ip: *InlineParser) !void {
        if (ip.pos + 1 >= ip.content.len or ip.content[ip.pos + 1] != '~') return;

        var i = ip.pending_inlines.items.len;
        while (i > 0) {
            i -= 1;
            if (ip.pending_inlines.items[i].tag == .strikethrough) break;
        } else {
            try ip.pending_inlines.append(ip.parent.allocator, .{
                .tag = .strikethrough,
                .data = .{ .none = {} },
                .start = ip.pos,
            });
            ip.pos += 1;
            return;
        }

        const opener = ip.pending_inlines.items[i];
        ip.pending_inlines.shrinkRetainingCapacity(i);
        const end = ip.pos + 2;
        const children = try ip.encodeChildren(opener.start + 2, ip.pos);
        const node = try ip.parent.addNode(.{
            .tag = .strikethrough,
            .data = .{ .container = .{ .children = children } },
        }, ip.sourceSpan(opener.start, end));
        try ip.completed_inlines.append(ip.parent.allocator, .{
            .node = node,
            .start = opener.start,
            .len = end - opener.start,
        });
        ip.pos += 1;
    }

    /// Encodes emphasis specified by a run of `run_len` emphasis characters,
    /// with `start..end` being the range of content contained within the
    /// emphasis.
    fn encodeEmphasis(ip: *InlineParser, start: usize, end: usize, run_len: usize) !Node.Index {
        const children = try ip.encodeChildren(start, end);
        const source_span = ip.sourceSpan(start - run_len, end + run_len);
        var inner = switch (run_len % 3) {
            1 => try ip.parent.addNode(.{
                .tag = .emphasis,
                .data = .{ .container = .{
                    .children = children,
                } },
            }, source_span),
            2 => try ip.parent.addNode(.{
                .tag = .strong,
                .data = .{ .container = .{
                    .children = children,
                } },
            }, source_span),
            0 => strong_emphasis: {
                const strong = try ip.parent.addNode(.{
                    .tag = .strong,
                    .data = .{ .container = .{
                        .children = children,
                    } },
                }, source_span);
                break :strong_emphasis try ip.parent.addNode(.{
                    .tag = .emphasis,
                    .data = .{ .container = .{
                        .children = try ip.parent.addExtraChildren(&.{strong}),
                    } },
                }, source_span);
            },
            else => unreachable,
        };

        var run_left = run_len;
        while (run_left > 3) : (run_left -= 3) {
            const strong = try ip.parent.addNode(.{
                .tag = .strong,
                .data = .{ .container = .{
                    .children = try ip.parent.addExtraChildren(&.{inner}),
                } },
            }, source_span);
            inner = try ip.parent.addNode(.{
                .tag = .emphasis,
                .data = .{ .container = .{
                    .children = try ip.parent.addExtraChildren(&.{strong}),
                } },
            }, source_span);
        }

        return inner;
    }

    /// Parses a code span, starting at the beginning of the opening backtick
    /// run. `ip.pos` is left at the last character in the closing run after
    /// parsing.
    fn parseCodeSpan(ip: *InlineParser) !void {
        const opener_start = ip.pos;
        ip.pos = mem.findNonePos(u8, ip.content, ip.pos, "`") orelse ip.content.len;
        const opener_len = ip.pos - opener_start;

        const start = ip.pos;
        const end = while (mem.findScalarPos(u8, ip.content, ip.pos, '`')) |closer_start| {
            ip.pos = mem.findNonePos(u8, ip.content, closer_start, "`") orelse ip.content.len;
            const closer_len = ip.pos - closer_start;

            if (closer_len == opener_len) break closer_start;
        } else unterminated: {
            ip.pos = ip.content.len;
            break :unterminated ip.content.len;
        };

        var content = if (start < ip.content.len)
            ip.content[start..end]
        else
            "";
        // This single space removal rule allows code spans to be written which
        // start or end with backticks.
        if (mem.startsWith(u8, content, " `")) content = content[1..];
        if (mem.endsWith(u8, content, "` ")) content = content[0 .. content.len - 1];

        const text = try ip.parent.addNode(.{
            .tag = .code_span,
            .data = .{ .text = .{
                .content = try ip.parent.addString(content),
            } },
        }, ip.sourceSpan(opener_start, ip.pos));
        try ip.completed_inlines.append(ip.parent.allocator, .{
            .node = text,
            .start = opener_start,
            .len = ip.pos - opener_start,
        });
        // Ensure ip.pos is pointing at the last character of the
        // closer, not after it.
        ip.pos -= 1;
    }

    /// Encodes children parsed in the content range `start..end`. The children
    /// will be text nodes and any completed inlines within the range.
    fn encodeChildren(ip: *InlineParser, start: usize, end: usize) !ExtraIndex {
        const scratch_extra_top = ip.parent.scratch_extra.items.len;
        defer ip.parent.scratch_extra.shrinkRetainingCapacity(scratch_extra_top);

        var child_index = ip.completed_inlines.items.len;
        while (child_index > 0 and ip.completed_inlines.items[child_index - 1].start >= start) {
            child_index -= 1;
        }
        const start_child_index = child_index;

        var pos = start;
        while (child_index < ip.completed_inlines.items.len) : (child_index += 1) {
            const child_inline = ip.completed_inlines.items[child_index];
            // Completed inlines must be strictly nested within the encodable
            // content.
            assert(child_inline.start >= pos and child_inline.start + child_inline.len <= end);

            if (child_inline.start > pos) {
                try ip.encodeTextNode(pos, child_inline.start);
            }
            try ip.parent.addScratchExtraNode(child_inline.node);

            pos = child_inline.start + child_inline.len;
        }
        ip.completed_inlines.shrinkRetainingCapacity(start_child_index);

        if (pos < end) {
            try ip.encodeTextNode(pos, end);
        }

        const children = ip.parent.scratch_extra.items[scratch_extra_top..];
        return try ip.parent.addExtraChildren(@ptrCast(children));
    }

    /// Encodes textual content `ip.content[start..end]` to `scratch_extra`. The
    /// encoded content may include both `text` and `line_break` nodes.
    fn encodeTextNode(ip: *InlineParser, start: usize, end: usize) !void {
        // For efficiency, we can encode directly into string_bytes rather than
        // creating a temporary string and then encoding it, since this process
        // is entirely linear.
        const string_top = ip.parent.string_bytes.items.len;
        errdefer ip.parent.string_bytes.shrinkRetainingCapacity(string_top);

        var string_start = string_top;
        var text_iter: TextIterator = .{ .content = ip.content[start..end] };
        var text_source_start = start;
        while (text_iter.next()) |content| {
            const raw_end = start + text_iter.pos;
            switch (content) {
                .char => |c| try ip.parent.string_bytes.append(ip.parent.allocator, c),
                .text => |s| try ip.parent.string_bytes.appendSlice(ip.parent.allocator, s),
                .line_break => {
                    const raw_start = raw_end - 2;
                    if (ip.parent.string_bytes.items.len > string_start) {
                        try ip.parent.string_bytes.append(ip.parent.allocator, 0);
                        try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                            .tag = .text,
                            .data = .{ .text = .{
                                .content = @fromBackingInt(@intCast(string_start)),
                            } },
                        }, ip.sourceSpan(text_source_start, raw_start)));
                        string_start = ip.parent.string_bytes.items.len;
                    }
                    try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                        .tag = .line_break,
                        .data = .{ .none = {} },
                    }, ip.sourceSpan(raw_start, raw_end)));
                    text_source_start = raw_end;
                },
                .soft_break => {
                    const raw_start = raw_end - 1;
                    if (ip.parent.string_bytes.items.len > string_start) {
                        try ip.parent.string_bytes.append(ip.parent.allocator, 0);
                        try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                            .tag = .text,
                            .data = .{ .text = .{
                                .content = @fromBackingInt(@intCast(string_start)),
                            } },
                        }, ip.sourceSpan(text_source_start, raw_start)));
                        string_start = ip.parent.string_bytes.items.len;
                    }
                    try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                        .tag = .soft_break,
                        .data = .{ .none = {} },
                    }, ip.sourceSpan(raw_start, raw_end)));
                    text_source_start = raw_end;
                },
            }
        }
        if (ip.parent.string_bytes.items.len > string_start) {
            try ip.parent.string_bytes.append(ip.parent.allocator, 0);
            try ip.parent.addScratchExtraNode(try ip.parent.addNode(.{
                .tag = .text,
                .data = .{ .text = .{
                    .content = @fromBackingInt(@intCast(string_start)),
                } },
            }, ip.sourceSpan(text_source_start, end)));
        }
    }

    /// An iterator over parts of textual content, handling unescaping of
    /// escaped characters and line breaks.
    const TextIterator = struct {
        content: []const u8,
        pos: usize = 0,
        smart: bool = true,

        const Content = union(enum) {
            char: u8,
            text: []const u8,
            line_break,
            soft_break,
        };

        const replacement = "\u{FFFD}";
        const ellipsis = "\u{2026}";
        const en_dash = "\u{2013}";
        const em_dash = "\u{2014}";
        const left_single_quote = "\u{2018}";
        const right_single_quote = "\u{2019}";
        const left_double_quote = "\u{201C}";
        const right_double_quote = "\u{201D}";

        fn next(iter: *TextIterator) ?Content {
            if (iter.pos >= iter.content.len) return null;
            if (iter.content[iter.pos] == '\n') {
                iter.pos += 1;
                return .soft_break;
            }
            if (iter.smart) {
                const rest = iter.content[iter.pos..];
                if (mem.startsWith(u8, rest, "...")) {
                    iter.pos += 3;
                    return .{ .text = ellipsis };
                }
                if (mem.startsWith(u8, rest, "---")) {
                    iter.pos += 3;
                    return .{ .text = em_dash };
                }
                if (mem.startsWith(u8, rest, "--")) {
                    iter.pos += 2;
                    return .{ .text = en_dash };
                }
                if (iter.content[iter.pos] == '\'' or iter.content[iter.pos] == '"') {
                    const quote = iter.content[iter.pos];
                    const opens = iter.pos == 0 or isWhitespace(iter.content[iter.pos - 1]) or
                        isOpeningPunctuation(iter.content[iter.pos - 1]);
                    iter.pos += 1;
                    return .{ .text = if (quote == '\'')
                        (if (opens) left_single_quote else right_single_quote)
                    else
                        (if (opens) left_double_quote else right_double_quote) };
                }
            }
            if (iter.content[iter.pos] == '\\') {
                iter.pos += 1;
                if (iter.pos == iter.content.len) {
                    return .{ .char = '\\' };
                } else if (iter.content[iter.pos] == '\n') {
                    iter.pos += 1;
                    return .line_break;
                } else if (isPunctuation(iter.content[iter.pos])) {
                    const c = iter.content[iter.pos];
                    iter.pos += 1;
                    return .{ .char = c };
                } else {
                    return .{ .char = '\\' };
                }
            }
            return iter.nextCodepoint();
        }

        fn nextCodepoint(iter: *TextIterator) ?Content {
            switch (iter.content[iter.pos]) {
                0 => {
                    iter.pos += 1;
                    return .{ .text = replacement };
                },
                1...127 => |c| {
                    iter.pos += 1;
                    return .{ .char = c };
                },
                else => |b| {
                    const cp_len = std.unicode.utf8ByteSequenceLength(b) catch {
                        iter.pos += 1;
                        return .{ .text = replacement };
                    };
                    const is_valid = iter.pos + cp_len <= iter.content.len and
                        std.unicode.utf8ValidateSlice(iter.content[iter.pos..][0..cp_len]);
                    const cp_encoded = if (is_valid)
                        iter.content[iter.pos..][0..cp_len]
                    else
                        replacement;
                    iter.pos += cp_len;
                    return .{ .text = cp_encoded };
                },
            }
        }
    };
};

fn isOpeningPunctuation(c: u8) bool {
    return switch (c) {
        '(', '[', '{', '<' => true,
        else => false,
    };
}

fn parseInlines(p: *Parser, content: []const u8, source_spans: []const Source.Span) !ExtraIndex {
    assert(content.len == source_spans.len);
    const trimmed = mem.trim(u8, content, " \t\n");
    const trim_start = @intFromPtr(trimmed.ptr) - @intFromPtr(content.ptr);
    var ip: InlineParser = .{
        .parent = p,
        .content = trimmed,
        .source_spans = source_spans[trim_start..][0..trimmed.len],
    };
    defer ip.deinit();
    return try ip.parse();
}

fn parseInlinesAt(p: *Parser, content: []const u8, source_start: u32) !ExtraIndex {
    var source_spans: ArrayList(Source.Span) = .empty;
    defer source_spans.deinit(p.allocator);
    try source_spans.ensureTotalCapacity(p.allocator, content.len);
    for (0..content.len) |i| {
        const start = source_start + @as(u32, @intCast(i));
        source_spans.appendAssumeCapacity(.{ .start = start, .end = start + 1 });
    }
    return p.parseInlines(content, source_spans.items);
}

pub fn extraData(p: Parser, comptime T: type, index: ExtraIndex) ExtraData(T) {
    const info = @typeInfo(T).@"struct";
    var i: usize = @backingInt(index);
    var result: T = undefined;
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        @field(result, field_name) = switch (field_type) {
            u32 => p.extra.items[i],
            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{ .data = result, .end = i };
}

pub fn extraChildren(p: Parser, index: ExtraIndex) []const Node.Index {
    const children = p.extraData(Node.Children, index);
    return @ptrCast(p.extra.items[children.end..][0..children.data.len]);
}

fn addNode(p: *Parser, node: Node, source_span: Source.Span) !Node.Index {
    const index: Node.Index = @fromBackingInt(@intCast(@as(u32, @intCast(p.nodes.len))));
    try p.nodes.append(p.allocator, node);
    errdefer _ = p.nodes.pop();
    try p.spans.append(p.allocator, source_span);
    return index;
}

fn addString(p: *Parser, s: []const u8) !StringIndex {
    if (s.len == 0) return .empty;

    const index: StringIndex = @fromBackingInt(@intCast(@as(u32, @intCast(p.string_bytes.items.len))));
    try p.string_bytes.ensureUnusedCapacity(p.allocator, s.len + 1);
    p.string_bytes.appendSliceAssumeCapacity(s);
    p.string_bytes.appendAssumeCapacity(0);
    return index;
}

fn addExtraChildren(p: *Parser, nodes: []const Node.Index) !ExtraIndex {
    const index: ExtraIndex = @fromBackingInt(@intCast(@as(u32, @intCast(p.extra.items.len))));
    try p.extra.ensureUnusedCapacity(p.allocator, nodes.len + 1);
    p.extra.appendAssumeCapacity(@intCast(nodes.len));
    p.extra.appendSliceAssumeCapacity(@ptrCast(nodes));
    return index;
}

fn addScratchExtraNode(p: *Parser, node: Node.Index) !void {
    try p.scratch_extra.append(p.allocator, @backingInt(node));
}

fn addScratchStringLine(p: *Parser, line: []const u8) !void {
    try p.scratch_string.ensureUnusedCapacity(p.allocator, line.len + 1);
    try p.scratch_source_spans.ensureUnusedCapacity(p.allocator, line.len + 1);
    p.scratch_string.appendSliceAssumeCapacity(line);
    const source_start = p.sourceOffset(line);
    for (0..line.len) |i| {
        const start = source_start + @as(u32, @intCast(i));
        p.scratch_source_spans.appendAssumeCapacity(.{ .start = start, .end = start + 1 });
    }
    p.scratch_string.appendAssumeCapacity('\n');
    const ending_start = p.current_line_end - p.current_line_ending_len;
    p.scratch_source_spans.appendAssumeCapacity(.{
        .start = ending_start,
        .end = p.current_line_end,
    });
}

fn sourceOffset(p: Parser, slice: []const u8) u32 {
    const slice_ptr = @intFromPtr(slice.ptr);
    const line_ptr = @intFromPtr(p.current_line.ptr);
    if (slice.len == 0 and (slice_ptr < line_ptr or slice_ptr > line_ptr + p.current_line.len)) {
        return p.current_line_end - p.current_line_ending_len;
    }
    const byte_offset = slice_ptr - line_ptr;
    assert(byte_offset <= p.current_line.len);
    return p.current_line_start + @as(u32, @intCast(byte_offset));
}

fn currentContentEnd(p: Parser) u32 {
    return p.current_line_end - p.current_line_ending_len;
}

fn isBlank(line: []const u8) bool {
    return mem.findNone(u8, line, " \t") == null;
}

const TaskListMarker = struct {
    status: Node.TaskStatus,
    rest: []const u8,
};

fn taskListMarker(line: []const u8) ?TaskListMarker {
    if (line.len < 4 or line[0] != '[' or line[2] != ']' or
        (line[3] != ' ' and line[3] != '\t')) return null;
    const status: Node.TaskStatus = switch (line[1]) {
        ' ' => .unchecked,
        'x', 'X' => .checked,
        else => return null,
    };
    return .{ .status = status, .rest = mem.trimStart(u8, line[4..], " \t") };
}

fn isPunctuation(c: u8) bool {
    return switch (c) {
        '!',
        '"',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        '-',
        '.',
        '/',
        ':',
        ';',
        '<',
        '=',
        '>',
        '?',
        '@',
        '[',
        '\\',
        ']',
        '^',
        '_',
        '`',
        '{',
        '|',
        '}',
        '~',
        => true,
        else => false,
    };
}
