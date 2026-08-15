//! Temporary compile-time boundary between the cmark and pure-Zig Markdown
//! implementations. Phase 7 removes this module after the Zig backend becomes
//! authoritative.

const std = @import("std");
const Allocator = std.mem.Allocator;
const options = @import("options");
const supermd = @import("supermd");
const Semantic = @import("Semantic.zig");

pub const selected = options.markdown_parser;
pub const is_zig = selected == .zig;

pub const Ast = if (is_zig) Semantic.Ast else supermd.Ast;
pub const Node = if (is_zig) Semantic.Node else supermd.Node;
pub const Iter = if (is_zig) Semantic.Markdown.Iter else supermd.Ast.Iter;
pub const Error = if (is_zig) Semantic.Error else supermd.Ast.Error;
pub const Directive = supermd.Directive;
pub const ParserContext = supermd.Ast.CmarkParser;
pub const ExtensionKind = enum { strikethrough, table, table_row, table_cell };

pub const ParseOptions = struct {
    auto_target_blank: bool = false,
};

pub fn parse(
    gpa: Allocator,
    source: []const u8,
    cmark: ParserContext,
    parse_options: ParseOptions,
) !Ast {
    return if (is_zig)
        Semantic.Ast.init(gpa, source, .{
            .auto_target_blank = parse_options.auto_target_blank,
        })
    else
        supermd.Ast.init(gpa, source, cmark, .{
            .auto_target_blank = parse_options.auto_target_blank,
        });
}

pub fn deinit(ast: *Ast, gpa: Allocator) void {
    if (is_zig) ast.deinit() else ast.*.deinit(gpa);
}

pub fn root(ast: *const Ast) Node {
    return if (is_zig) ast.root() else ast.md.root;
}

pub fn eql(a: Node, b: Node) bool {
    return a.eql(b);
}

pub fn extensionKind(node: Node) ?ExtensionKind {
    if (is_zig) return switch (node.nodeType()) {
        .STRIKETHROUGH => .strikethrough,
        .TABLE => .table,
        .TABLE_ROW => .table_row,
        .TABLE_CELL => .table_cell,
        else => null,
    };

    const raw = @backingInt(node.nodeType());
    if (raw == supermd.c.CMARK_NODE_STRIKETHROUGH) return .strikethrough;
    if (raw == supermd.c.CMARK_NODE_TABLE) return .table;
    if (raw == supermd.c.CMARK_NODE_TABLE_ROW) return .table_row;
    if (raw == supermd.c.CMARK_NODE_TABLE_CELL) return .table_cell;
    return null;
}

pub fn linePreview(source: []const u8, range: @TypeOf(@as(Node, undefined).range())) supermd.Ast.LinePreview {
    return if (is_zig)
        supermd.Ast.linePreview(source, .{
            .start = .{ .row = range.start.row, .col = range.start.col },
            .end = .{ .row = range.end.row, .col = range.end.col },
        })
    else
        supermd.Ast.linePreview(source, range);
}

pub fn errorFmt(
    err: Error,
    frontmatter_line_count: u32,
    source: []const u8,
    path: []const u8,
) ErrorFmt {
    return .{
        .err = err,
        .source = source,
        .path = path,
        .frontmatter_line_count = frontmatter_line_count,
    };
}

pub const ErrorFmt = struct {
    err: Error,
    source: []const u8,
    path: []const u8,
    frontmatter_line_count: u32,

    pub fn format(value: ErrorFmt, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!is_zig) {
            try writer.print("{f}", .{value.err.fmt(
                value.frontmatter_line_count,
                value.source,
                value.path,
            )});
            return;
        }

        try writer.print("{s}:{}:{}: ", .{
            value.path,
            value.frontmatter_line_count + value.err.main.start.row,
            value.err.main.start.col,
        });
        var preview = linePreview(value.source, value.err.main);
        preview.carets += 1;
        switch (value.err.kind) {
            .inline_html => try writer.print(
                \\error: markdown inline html syntax is forbidden
                \\{f}
                \\| -- note: superhtml supports `=html` code blocks as an alternative
                \\
            , .{preview}),
            .heading_section_missing_id => try writer.print(
                \\error: missing section id
                \\{f}
                \\| -- note: all heading sections must have an id
                \\
            , .{preview}),
            .invalid_ref => try writer.print(
                \\error: unknown ref
                \\{f}
                \\
            , .{preview}),
            .no_alt_in_links => try writer.print(
                \\error: vanilla alt text in scripted link syntax
                \\{f}
                \\| -- note: use `.alt()` to provide alt text
                \\
            , .{preview}),
            .expression_in_image_syntax => try writer.print(
                \\error: scripty expression in image syntax
                \\{f}
                \\| -- note: scripty expressions go in link syntax, remove the '!'
                \\
            , .{preview}),
            .empty_expression => try writer.print(
                \\error: link syntax without link or scripty expression
                \\{f}
                \\
            , .{preview}),
            .duplicate_id => |duplicate| {
                const original_range = duplicate.original.range();
                var original_preview = linePreview(value.source, original_range);
                original_preview.carets += 1;
                try writer.print(
                    \\error: duplicate id '{s}'
                    \\{f}
                    \\| -- note: first definition was on line {} col {}:
                    \\{f}
                    \\
                , .{
                    duplicate.id,
                    preview,
                    value.frontmatter_line_count + original_range.start.row,
                    original_range.start.col,
                    original_preview,
                });
            },
            .scripty => |script_error| {
                const precise_range = scriptyRange(
                    value.source,
                    value.err.main,
                    script_error.span,
                );
                try writer.print(
                    \\[scripty] error: {s}
                    \\{f}
                    \\
                , .{ script_error.err, linePreview(value.source, precise_range) });
            },
            .html => |html_error| try writer.print(
                \\[html] error: {f}
                \\{f}
                \\
            , .{
                html_error.tag.fmt("test"),
                linePreview(value.source, value.err.main),
            }),
            .heading_skip => |gap| {
                try writer.print(
                    \\error: skipped heading level
                    \\{f}
                    \\
                , .{preview});
                if (gap.last) |last| {
                    const previous_range = last.range();
                    var previous_preview = linePreview(value.source, previous_range);
                    previous_preview.carets += 1;
                    try writer.print(
                        \\| -- note: previous heading (level {}):
                        \\{f}
                        \\
                    , .{ last.headingLevel(), previous_preview });
                } else try writer.writeAll(
                    \\| -- note: supermd documents start at heading level 1 ('#')
                    \\| -- note: if your intent is to start the content at '<h2>', you
                    \\|          can change how headings render in html by setting the
                    \\|          corresponding option in your zine config file
                    \\
                );
            },
        }
    }
};

fn scriptyRange(
    source: []const u8,
    main: @TypeOf(@as(Semantic.Error, undefined).main),
    relative: anytype,
) @TypeOf(main) {
    if (!main.isKnown()) return main;
    const bytes = source[main.start_byte..main.end_byte];
    const relative_destination = std.mem.indexOf(u8, bytes, "](") orelse return main;
    const base: u32 = main.start_byte + @as(u32, @intCast(relative_destination)) + 2;
    return rangeFromOffsets(source, base + relative.start, base + relative.end);
}

fn rangeFromOffsets(
    source: []const u8,
    start: u32,
    end: u32,
) @TypeOf(@as(Semantic.Error, undefined).main) {
    return .{
        .start = position(source, start),
        .end = position(source, end),
        .start_byte = start,
        .end_byte = end,
    };
}

fn position(
    source: []const u8,
    offset_arg: u32,
) @TypeOf(@as(Semantic.Error, undefined).main.start) {
    const offset = @min(offset_arg, source.len);
    var row: u32 = 1;
    var line_start: usize = 0;
    for (source[0..offset], 0..) |byte, index| if (byte == '\n') {
        row += 1;
        line_start = index + 1;
    };
    return .{ .row = row, .col = @intCast(offset - line_start + 1) };
}

test "selected Markdown backend has the compatibility boundary" {
    if (is_zig) {
        try std.testing.expect(Ast == Semantic.Ast);
        try std.testing.expect(Node == Semantic.Node);
    } else {
        try std.testing.expect(Ast == supermd.Ast);
        try std.testing.expect(Node == supermd.Node);
    }
}

test "selected backend parses and owns its AST" {
    if (!is_zig) supermd.c.cmark_gfm_core_extensions_ensure_registered();
    const parser: ParserContext = if (is_zig) undefined else .default();
    defer if (!is_zig) supermd.c.cmark_parser_free(parser.parser);

    var ast = try parse(std.testing.allocator, "# Heading\n", parser, .{});
    defer deinit(&ast, std.testing.allocator);
    try std.testing.expect(root(&ast).firstChild().?.nodeType() == .HEADING);
}
