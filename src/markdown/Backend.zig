//! Zine-facing SuperMD parser and diagnostic helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const supermd = @import("supermd");
const Semantic = @import("Semantic.zig");

pub const Ast = Semantic.Ast;
pub const Node = Semantic.Node;
pub const Iter = Semantic.Markdown.Iter;
pub const Error = Semantic.Error;
pub const Directive = supermd.Directive;
pub const ExtensionKind = enum { strikethrough, table, table_row, table_cell };

pub const ParseOptions = struct {
    auto_target_blank: bool = false,
};

pub fn parse(
    gpa: Allocator,
    source: []const u8,
    parse_options: ParseOptions,
) !Ast {
    return Semantic.Ast.init(gpa, source, .{
        .auto_target_blank = parse_options.auto_target_blank,
    });
}

pub fn deinit(ast: *Ast, _: Allocator) void {
    ast.deinit();
}

pub fn root(ast: *const Ast) Node {
    return ast.root();
}

pub fn eql(a: Node, b: Node) bool {
    return a.eql(b);
}

pub fn extensionKind(node: Node) ?ExtensionKind {
    return switch (node.nodeType()) {
        .STRIKETHROUGH => .strikethrough,
        .TABLE => .table,
        .TABLE_ROW => .table_row,
        .TABLE_CELL => .table_cell,
        else => null,
    };
}

pub const LinePreview = struct {
    code: []const u8,
    spaces: u32,
    carets: u32,

    pub fn format(preview: LinePreview, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("|    {s}\n", .{preview.code});
        try writer.writeAll("|    ");
        try writer.splatByteAll(' ', preview.spaces);
        try writer.splatByteAll('^', preview.carets);
    }
};

pub fn linePreview(source: []const u8, range: @TypeOf(@as(Node, undefined).range())) LinePreview {
    const line = blk: {
        var iterator = std.mem.splitScalar(u8, source, '\n');
        for (1..range.start.row) |_| _ = iterator.next();
        break :blk iterator.next().?;
    };

    const line_trim_left = std.mem.trimStart(u8, line, &std.ascii.whitespace);
    const start_trim_left = line.len - line_trim_left.len;
    const line_trim = std.mem.trimEnd(u8, line_trim_left, &std.ascii.whitespace);
    const caret_len = if (range.start.row == range.end.row)
        range.end.col - range.start.col
    else
        line_trim.len - start_trim_left;
    const caret_spaces_len = range.start.col - 1 - start_trim_left;

    return .{
        .code = line_trim,
        .spaces = @intCast(caret_spaces_len),
        .carets = @intCast(if (caret_len == 0) 1 else caret_len),
    };
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

test "parser facade parses and owns its AST" {
    var ast = try parse(std.testing.allocator, "# Heading\n", .{});
    defer deinit(&ast, std.testing.allocator);
    try std.testing.expect(root(&ast).firstChild().?.nodeType() == .HEADING);
}
