//! Shared HTML emission for Markdown nodes whose semantic invariants are
//! important to production rendering and malformed-input tests.

const std = @import("std");
const Writer = std.Io.Writer;
const Semantic = @import("Semantic.zig");
const Ast = Semantic.Ast;
const Node = Semantic.Node;
const HtmlSafe = @import("superhtml").HtmlSafe;

pub fn footnoteReference(ast: Ast, node: Node, w: *Writer) Writer.Error!void {
    const label = node.literal() orelse "";
    const def_idx = ast.footnotes.getIndex(label) orelse
        return unresolvedFootnote(label, w);
    const footnote = ast.footnotes.values()[def_idx];
    const reference_number = node.footnoteRefIx();
    if (reference_number <= 0) return unresolvedFootnote(label, w);
    const reference_index: usize = @intCast(reference_number - 1);
    if (reference_index >= footnote.ref_ids.len) {
        return unresolvedFootnote(label, w);
    }

    try w.print("<sup class=\"footnote-ref\"><a href=\"#{s}\" id=\"{s}\">{d}</a></sup>", .{
        footnote.def_id,
        footnote.ref_ids[reference_index],
        def_idx + 1,
    });
}

fn unresolvedFootnote(label: []const u8, w: *Writer) Writer.Error!void {
    try w.writeAll("[^");
    try w.print("{f}", .{HtmlSafe{ .bytes = label }});
    try w.writeByte(']');
}

/// Renders a URL-backed semantic link and returns whether the node was
/// handled. Page and asset links return false because they need site context.
pub fn urlLink(node: Node, enter: bool, w: *Writer) Writer.Error!bool {
    const directive = node.getDirective() orelse return false;
    if (directive.kind != .link) return false;
    const link = directive.kind.link;
    const src = link.src orelse return false;
    const url = switch (src) {
        .url => |value| value,
        else => return false,
    };

    if (!enter) {
        try w.writeAll("</a>");
        return true;
    }

    try w.writeAll("<a");
    if (directive.id) |id| try w.print(" id=\"{s}\"", .{id});
    if (directive.attrs) |attrs| {
        try w.writeAll(" class=\"");
        for (attrs) |attr| try w.print("{s} ", .{attr});
        try w.writeAll("\"");
    }
    if (directive.title) |title| try w.print(" title=\"{s}\"", .{title});
    try w.print(" href=\"{s}", .{url});
    if (link.ref) |ref| try w.print("#{s}", .{ref});
    try w.writeByte('"');
    if (link.new orelse false) try w.writeAll(" target=\"_blank\"");
    try w.writeByte('>');
    return true;
}

test "unresolved footnote fallback escapes the literal label" {
    var ast = try Semantic.Ast.init(
        std.testing.allocator,
        "Text[^unsafe&label].\n\n[^unsafe&label]: Body.\n",
        .{},
    );
    defer ast.deinit();

    var reference: ?Node = null;
    var iterator = Semantic.Markdown.Iter.init(ast.root());
    defer iterator.deinit();
    while (iterator.next()) |event| {
        if (event.dir == .enter and event.node.nodeType() == .FOOTNOTE_REFERENCE) {
            reference = event.node;
            break;
        }
    }
    try std.testing.expect(ast.footnotes.orderedRemove("unsafe&label"));

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try footnoteReference(ast, reference.?, &output.writer);
    try std.testing.expectEqualStrings("[^unsafe&amp;label]", output.written());
}
