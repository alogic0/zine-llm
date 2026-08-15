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

        const kind = std.meta.activeTag(value.err.kind);
        try writer.print("{s}:{}:{}: error: {s}\n", .{
            value.path,
            value.frontmatter_line_count + value.err.main.start.row,
            value.err.main.start.col,
            switch (kind) {
                .inline_html => "markdown inline html syntax is forbidden",
                .heading_section_missing_id => "missing section id",
                .invalid_ref => "unknown ref",
                .no_alt_in_links => "vanilla alt text in scripted link syntax",
                .expression_in_image_syntax => "scripty expression in image syntax",
                .empty_expression => "link syntax without link or scripty expression",
                .duplicate_id => "duplicate id",
                .scripty => "Scripty expression",
                .html => "HTML syntax",
                .heading_skip => "skipped heading level",
            },
        });
        try writer.print("{f}\n", .{linePreview(value.source, value.err.main)});
    }
};

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
