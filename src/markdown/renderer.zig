const std = @import("std");
const Document = @import("Document.zig");
const Node = Document.Node;
const assert = std.debug.assert;
const Writer = std.Io.Writer;

/// A Markdown document renderer.
///
/// Each concrete `Renderer` type has a `renderDefault` function, with the
/// intention that custom `renderFn` implementations can call `renderDefault`
/// for node types for which they require no special rendering.
pub fn Renderer(comptime Context: type) type {
    return struct {
        renderFn: *const fn (
            r: Self,
            doc: Document,
            node: Node.Index,
            writer: *Writer,
        ) Writer.Error!void = renderDefault,
        context: Context,

        const Self = @This();

        pub fn render(r: Self, doc: Document, writer: *Writer) Writer.Error!void {
            try r.renderFn(r, doc, .root, writer);
        }

        pub fn renderDefault(
            r: Self,
            doc: Document,
            node: Node.Index,
            writer: *Writer,
        ) Writer.Error!void {
            const data = doc.nodes.items(.data)[@backingInt(node)];
            switch (doc.nodes.items(.tag)[@backingInt(node)]) {
                .root => {
                    for (doc.extraChildren(data.container.children)) |child| {
                        if (doc.nodes.items(.tag)[@backingInt(child)] == .footnote_definition) continue;
                        try r.renderFn(r, doc, child, writer);
                    }
                    var wrote_section = false;
                    for (doc.extraChildren(data.container.children)) |child| {
                        if (doc.nodes.items(.tag)[@backingInt(child)] != .footnote_definition) continue;
                        if (!wrote_section) {
                            try writer.writeAll("<section class=\"footnotes\" data-footnotes>\n<ol>\n");
                            wrote_section = true;
                        }
                        try r.renderFn(r, doc, child, writer);
                    }
                    if (wrote_section) try writer.writeAll("</ol>\n</section>\n");
                },
                .list => {
                    if (data.list.start.asNumber()) |start| {
                        if (start == 1) {
                            try writer.writeAll("<ol>\n");
                        } else {
                            try writer.print("<ol start=\"{d}\">\n", .{start});
                        }
                    } else {
                        try writer.writeAll("<ul>\n");
                    }
                    for (doc.extraChildren(data.list.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    if (data.list.start.asNumber() != null) {
                        try writer.writeAll("</ol>\n");
                    } else {
                        try writer.writeAll("</ul>\n");
                    }
                },
                .list_item => {
                    try writer.writeAll("<li>");
                    switch (data.list_item.task) {
                        .none => {},
                        .unchecked => try writer.writeAll("<input type=\"checkbox\" disabled=\"\" /> "),
                        .checked => try writer.writeAll("<input type=\"checkbox\" checked=\"\" disabled=\"\" /> "),
                    }
                    for (doc.extraChildren(data.list_item.children)) |child| {
                        if (data.list_item.tight and doc.nodes.items(.tag)[@backingInt(child)] == .paragraph) {
                            const para_data = doc.nodes.items(.data)[@backingInt(child)];
                            for (doc.extraChildren(para_data.container.children)) |para_child| {
                                try r.renderFn(r, doc, para_child, writer);
                            }
                        } else {
                            try r.renderFn(r, doc, child, writer);
                        }
                    }
                    try writer.writeAll("</li>\n");
                },
                .table => {
                    try writer.writeAll("<table>\n");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</table>\n");
                },
                .table_row => {
                    try writer.writeAll("<tr>\n");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</tr>\n");
                },
                .table_cell => {
                    if (data.table_cell.info.header) {
                        try writer.writeAll("<th");
                    } else {
                        try writer.writeAll("<td");
                    }
                    switch (data.table_cell.info.alignment) {
                        .unset => try writer.writeAll(">"),
                        else => |a| try writer.print(" style=\"text-align: {s}\">", .{@tagName(a)}),
                    }

                    for (doc.extraChildren(data.table_cell.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }

                    if (data.table_cell.info.header) {
                        try writer.writeAll("</th>\n");
                    } else {
                        try writer.writeAll("</td>\n");
                    }
                },
                .heading => {
                    try writer.print("<h{d}>", .{data.heading.level});
                    for (doc.extraChildren(data.heading.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.print("</h{d}>\n", .{data.heading.level});
                },
                .code_block => {
                    const content = doc.string(data.code_block.content);
                    try writer.print("<pre><code>{f}</code></pre>\n", .{fmtHtml(content)});
                },
                .blockquote => {
                    try writer.writeAll("<blockquote>\n");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</blockquote>\n");
                },
                .paragraph => {
                    try writer.writeAll("<p>");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</p>\n");
                },
                .thematic_break => {
                    try writer.writeAll("<hr />\n");
                },
                .html_block => {
                    try writer.writeAll(doc.string(data.text.content));
                    try writer.writeByte('\n');
                },
                .footnote_definition => {
                    const label = doc.string(data.footnote_definition.label);
                    try writer.print("<li id=\"fn-{f}\">\n", .{fmtHtml(label)});
                    for (doc.extraChildren(data.footnote_definition.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</li>\n");
                },
                .link => {
                    const target = doc.string(data.link.target);
                    try writer.print("<a href=\"{f}\">", .{fmtHtml(target)});
                    for (doc.extraChildren(data.link.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</a>");
                },
                .autolink => {
                    const target = doc.string(data.text.content);
                    try writer.print("<a href=\"{0f}\">{0f}</a>", .{fmtHtml(target)});
                },
                .image => {
                    const target = doc.string(data.link.target);
                    try writer.print("<img src=\"{f}\" alt=\"", .{fmtHtml(target)});
                    for (doc.extraChildren(data.link.children)) |child| {
                        try renderInlineNodeText(doc, child, writer);
                    }
                    try writer.writeAll("\" />");
                },
                .strong => {
                    try writer.writeAll("<strong>");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</strong>");
                },
                .emphasis => {
                    try writer.writeAll("<em>");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</em>");
                },
                .strikethrough => {
                    try writer.writeAll("<del>");
                    for (doc.extraChildren(data.container.children)) |child| {
                        try r.renderFn(r, doc, child, writer);
                    }
                    try writer.writeAll("</del>");
                },
                .code_span => {
                    const content = doc.string(data.text.content);
                    try writer.print("<code>{f}</code>", .{fmtHtml(content)});
                },
                .text => {
                    const content = doc.string(data.text.content);
                    try writer.print("{f}", .{fmtHtml(content)});
                },
                .line_break => {
                    try writer.writeAll("<br />\n");
                },
                .soft_break => try writer.writeByte('\n'),
                .html_inline => try writer.writeAll(doc.string(data.text.content)),
                .footnote_reference => {
                    const label = doc.string(data.text.content);
                    try writer.print(
                        "<sup class=\"footnote-ref\"><a href=\"#fn-{0f}\" id=\"fnref-{0f}\" data-footnote-ref>{1d}</a></sup>",
                        .{ fmtHtml(label), footnoteOrdinal(doc, label) },
                    );
                },
            }
        }
    };
}

/// Renders an inline node as plain text. Asserts that the node is an inline and
/// has no non-inline children.
pub fn renderInlineNodeText(
    doc: Document,
    node: Node.Index,
    writer: *Writer,
) Writer.Error!void {
    const data = doc.nodes.items(.data)[@backingInt(node)];
    switch (doc.nodes.items(.tag)[@backingInt(node)]) {
        .root,
        .list,
        .list_item,
        .table,
        .table_row,
        .table_cell,
        .heading,
        .code_block,
        .blockquote,
        .paragraph,
        .thematic_break,
        .html_block,
        .footnote_definition,
        => unreachable, // Blocks

        .link, .image => {
            for (doc.extraChildren(data.link.children)) |child| {
                try renderInlineNodeText(doc, child, writer);
            }
        },
        .strong => {
            for (doc.extraChildren(data.container.children)) |child| {
                try renderInlineNodeText(doc, child, writer);
            }
        },
        .emphasis, .strikethrough => {
            for (doc.extraChildren(data.container.children)) |child| {
                try renderInlineNodeText(doc, child, writer);
            }
        },
        .autolink, .code_span, .text, .html_inline, .footnote_reference => {
            const content = doc.string(data.text.content);
            try writer.print("{f}", .{fmtHtml(content)});
        },
        .line_break, .soft_break => {
            try writer.writeAll("\n");
        },
    }
}

fn footnoteOrdinal(doc: Document, label: []const u8) usize {
    var ordinal: usize = 0;
    const tags = doc.nodes.items(.tag);
    const datas = doc.nodes.items(.data);
    for (tags, 0..) |tag, i| {
        if (tag != .footnote_definition) continue;
        ordinal += 1;
        if (std.ascii.eqlIgnoreCase(doc.string(datas[i].footnote_definition.label), label)) return ordinal;
    }
    return 0;
}

pub fn fmtHtml(bytes: []const u8) std.fmt.Alt([]const u8, formatHtml) {
    return .{ .data = bytes };
}

fn formatHtml(bytes: []const u8, w: *Writer) Writer.Error!void {
    for (bytes) |b| switch (b) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(b),
    };
}
