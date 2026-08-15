const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const supermd = @import("supermd");
const Ast = supermd.Ast;
const Node = supermd.Node;
const Directive = supermd.Directive;
const c = supermd.c;

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_state = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_state.interface;

    var paths: std.ArrayList([]const u8) = .empty;
    try collectFixtures(io, arena, &paths);
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    c.cmark_gfm_core_extensions_ensure_registered();
    const cmark_parser = Ast.CmarkParser.default();
    defer c.cmark_parser_free(cmark_parser.parser);

    try out.writeAll(
        "markdown-oracle-v1\n" ++
            "parser cmark-gfm\n" ++
            "options default,safe,smart,footnotes\n" ++
            "extensions table,strikethrough,tasklist,autolink\n\n",
    );

    for (paths.items, 0..) |path, source_index| {
        if (source_index != 0) try out.writeByte('\n');

        const full_src = try Io.Dir.cwd().readFileAlloc(
            io,
            path,
            arena,
            .limited(supermd.max_size),
        );
        const markdown_start = if (std.mem.endsWith(u8, path, ".smd"))
            findMarkdownStart(full_src)
        else
            0;
        const markdown = full_src[markdown_start..];
        const frontmatter_lines: u32 = @intCast(std.mem.countScalar(
            u8,
            full_src[0..markdown_start],
            '\n',
        ));

        const ast = try Ast.init(arena, markdown, cmark_parser, .{});
        defer ast.deinit(arena);

        try writeSource(out, path, markdown_start, markdown);
        try writeEvents(out, ast);
        try writeIds(out, ast);
        try writeFootnotes(out, ast);
        try writeErrors(out, ast, markdown, frontmatter_lines, path);
        try writeHtml(out, ast);
        try out.writeAll("end-source\n");
    }

    try out.flush();
}

fn collectFixtures(
    io: Io,
    arena: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
) !void {
    var tests_dir = try Io.Dir.cwd().openDir(io, "tests", .{ .iterate = true });
    defer tests_dir.close(io);

    var walker = try tests_dir.walk(arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const is_supermd = std.mem.endsWith(u8, entry.path, ".smd");
        const is_focused_markdown =
            std.mem.startsWith(u8, entry.path, "markdown-oracle/fixtures/") and
            std.mem.endsWith(u8, entry.path, ".md");
        if (!is_supermd and !is_focused_markdown) continue;

        try paths.append(arena, try std.fmt.allocPrint(arena, "tests/{s}", .{entry.path}));
    }
}

fn lessThanPath(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn findMarkdownStart(src: []const u8) usize {
    const first_end = std.mem.indexOfScalar(u8, src, '\n') orelse return 0;
    if (!std.mem.eql(u8, std.mem.trim(u8, src[0..first_end], " \t\r"), "---")) {
        return 0;
    }

    var line_start = first_end + 1;
    while (line_start < src.len) {
        const relative_end = std.mem.indexOfScalar(u8, src[line_start..], '\n');
        const line_end = if (relative_end) |offset| line_start + offset else src.len;
        const line = std.mem.trim(u8, src[line_start..line_end], " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            return if (line_end < src.len) line_end + 1 else line_end;
        }
        line_start = if (line_end < src.len) line_end + 1 else line_end;
    }
    return 0;
}

fn writeSource(out: *Writer, path: []const u8, markdown_start: usize, markdown: []const u8) !void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(markdown, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    try out.writeAll("source ");
    try writeJson(out, path);
    try out.print(" markdown_start={d} markdown_len={d} sha256={s}\n", .{
        markdown_start,
        markdown.len,
        &digest_hex,
    });
}

fn writeEvents(out: *Writer, ast: Ast) !void {
    var iterator = Ast.Iter.init(ast.md.root);
    defer iterator.deinit();

    while (iterator.next()) |event| {
        try writeEvent(out, event.dir, nodeDepth(event.node), event.node);
    }
}

fn nodeDepth(node: Node) usize {
    var depth: usize = 0;
    var current = node.n;
    while (c.cmark_node_parent(current)) |parent| {
        depth += 1;
        current = parent;
    }
    return depth;
}

fn writeEvent(out: *Writer, dir: Ast.Iter.Event.Dir, depth: usize, node: Node) !void {
    const node_type_ptr = c.cmark_node_get_type_string(node.n);
    const node_type = if (node_type_ptr == null) "<unknown>" else std.mem.span(node_type_ptr);
    const range = node.range();

    try out.print("event {s} depth={d} tag=", .{ @tagName(dir), depth });
    try writeJson(out, node_type);
    try out.print(" range={d}:{d}-{d}:{d}", .{
        range.start.row,
        range.start.col,
        range.end.row,
        range.end.col,
    });

    if (node.literal()) |literal| {
        try out.writeAll(" literal=");
        try writeJson(out, literal);
    }
    if (node.link()) |destination| {
        try out.writeAll(" destination=");
        try writeJson(out, destination);
    }
    if (node.title()) |title| {
        try out.writeAll(" title=");
        try writeJson(out, title);
    }
    if (node.fenceInfo()) |fence_info| {
        try out.writeAll(" fence_info=");
        try writeJson(out, fence_info);
    }

    switch (node.nodeType()) {
        .HEADING => try out.print(" level={d}", .{node.headingLevel()}),
        .LIST => try out.print(" list={s} tight={}", .{
            @tagName(node.listType()),
            node.listIsTight(),
        }),
        else => {},
    }

    if (std.mem.eql(u8, node_type, "table")) {
        try out.writeAll(" alignments=[");
        for (node.getTableAlignments(), 0..) |alignment, index| {
            if (index != 0) try out.writeByte(',');
            try out.print("{d}", .{alignment});
        }
        try out.writeByte(']');
    } else if (std.mem.eql(u8, node_type, "table_row")) {
        try out.print(" header={}", .{node.isTableHeader()});
    } else if (node.nodeType() == .FOOTNOTE_DEFINITION) {
        try out.print(" reference_count={d}", .{node.footnoteDefCount()});
    } else if (node.nodeType() == .FOOTNOTE_REFERENCE) {
        try out.print(" reference_index={d}", .{node.footnoteRefIx()});
    }

    if (node.getDirective()) |directive| try writeDirective(out, directive);
    try out.writeByte('\n');
}

fn writeDirective(out: *Writer, directive: *const Directive) !void {
    try out.writeAll(" directive=");
    try writeJson(out, @tagName(directive.kind));

    if (directive.id) |id| {
        try out.writeAll(" directive_id=");
        try writeJson(out, id);
    }
    if (directive.title) |title| {
        try out.writeAll(" directive_title=");
        try writeJson(out, title);
    }
    if (directive.attrs) |attrs| {
        try out.writeAll(" attrs=[");
        for (attrs, 0..) |attr, index| {
            if (index != 0) try out.writeByte(',');
            try writeJson(out, attr);
        }
        try out.writeByte(']');
    }
    if (directive.data.fields.count() != 0) {
        try out.writeAll(" data_keys=[");
        for (directive.data.fields.keys(), 0..) |key, index| {
            if (index != 0) try out.writeByte(',');
            try writeJson(out, key);
        }
        try out.writeByte(']');
    }

    switch (directive.kind) {
        .section => |section| try writeOptionalBool(out, "end", section.end),
        .block => |block| try writeOptionalBool(out, "collapsible", block.collapsible),
        .heading, .text => {},
        .mathtex => |mathtex| {
            try out.writeAll(" formula=");
            try writeJson(out, mathtex.formula);
        },
        .image => |image| {
            if (image.src) |src| try writeSrc(out, src);
            try writeOptionalString(out, "alt", image.alt);
            try writeOptionalBool(out, "linked", image.linked);
            if (image.size) |size| try out.print(" size={d}x{d}", .{ size.w, size.h });
        },
        .video => |video| {
            if (video.src) |src| try writeSrc(out, src);
            try writeOptionalBool(out, "loop", video.loop);
            try writeOptionalBool(out, "muted", video.muted);
            try writeOptionalBool(out, "autoplay", video.autoplay);
            try writeOptionalBool(out, "controls", video.controls);
            try writeOptionalBool(out, "pip", video.pip);
        },
        .audio => |audio| {
            if (audio.src) |src| try writeSrc(out, src);
            try writeOptionalBool(out, "loop", audio.loop);
            try writeOptionalBool(out, "muted", audio.muted);
            try writeOptionalBool(out, "autoplay", audio.autoplay);
            try writeOptionalBool(out, "hide_controls", audio.hide_controls);
        },
        .link => |link| {
            if (link.src) |src| try writeSrc(out, src);
            try writeOptionalString(out, "alternative", link.alternative);
            try writeOptionalString(out, "ref", link.ref);
            if (link.ref_unsafe) try out.writeAll(" ref_unsafe=true");
            try writeOptionalBool(out, "new", link.new);
        },
        .code => |code| {
            if (code.src) |src| try writeSrc(out, src);
            try writeOptionalString(out, "language", code.language);
            if (code.lines) |lines| try out.print(" lines={d}-{d}", .{ lines.start, lines.end });
        },
    }
}

fn writeSrc(out: *Writer, src: supermd.context.Src) !void {
    try out.writeAll(" src_kind=");
    try writeJson(out, @tagName(src));
    switch (src) {
        .url => |url| try writeKeyString(out, "src", url),
        .self_page => |alternative| try writeOptionalString(out, "src", alternative),
        .page => |page| {
            try writeKeyString(out, "src", page.ref);
            try out.writeAll(" page_kind=");
            try writeJson(out, @tagName(page.kind));
            try writeOptionalString(out, "locale", page.locale);
        },
        .page_asset => |asset| try writeKeyString(out, "src", asset.ref),
        .site_asset => |asset| try writeKeyString(out, "src", asset.ref),
        .build_asset => |asset| try writeKeyString(out, "src", asset.ref),
    }
}

fn writeIds(out: *Writer, ast: Ast) !void {
    for (ast.ids.keys(), ast.ids.values()) |id, node| {
        const range = node.range();
        const node_type_ptr = c.cmark_node_get_type_string(node.n);
        const node_type = if (node_type_ptr == null) "<unknown>" else std.mem.span(node_type_ptr);
        try out.writeAll("id name=");
        try writeJson(out, id);
        try out.writeAll(" tag=");
        try writeJson(out, node_type);
        try out.print(" range={d}:{d}-{d}:{d}\n", .{
            range.start.row,
            range.start.col,
            range.end.row,
            range.end.col,
        });
    }
}

fn writeFootnotes(out: *Writer, ast: Ast) !void {
    for (ast.footnotes.keys(), ast.footnotes.values()) |name, footnote| {
        try out.writeAll("footnote name=");
        try writeJson(out, name);
        try out.writeAll(" definition_id=");
        try writeJson(out, footnote.def_id);
        try out.writeAll(" reference_ids=[");
        for (footnote.ref_ids, 0..) |reference_id, index| {
            if (index != 0) try out.writeByte(',');
            try writeJson(out, reference_id);
        }
        try out.writeAll("]\n");
    }
}

fn writeErrors(
    out: *Writer,
    ast: Ast,
    markdown: []const u8,
    frontmatter_lines: u32,
    path: []const u8,
) !void {
    for (ast.errors) |err| {
        try out.writeAll("error kind=");
        try writeJson(out, @tagName(err.kind));
        try out.print(" range={d}:{d}-{d}:{d}", .{
            err.main.start.row,
            err.main.start.col,
            err.main.end.row,
            err.main.end.col,
        });
        switch (err.kind) {
            .duplicate_id => |duplicate| try writeKeyString(out, "id", duplicate.id),
            .scripty => |scripty| try writeKeyString(out, "message", scripty.err),
            .heading_skip => |skip| try out.print(" have={d}", .{skip.have}),
            else => {},
        }
        try out.writeByte('\n');
        try out.writeAll("diagnostic-begin\n");
        try out.print("{f}\n", .{err.fmt(frontmatter_lines, markdown, path)});
        try out.writeAll("diagnostic-end\n");
    }
}

fn writeHtml(out: *Writer, ast: Ast) !void {
    const rendered_ptr = c.cmark_render_html(ast.md.root.n, c.CMARK_OPT_DEFAULT, ast.md.extensions);
    if (rendered_ptr == null) return error.OutOfMemory;
    defer c.cmark_get_default_mem_allocator().*.free.?(@ptrCast(rendered_ptr));

    try out.writeAll("html=");
    try writeJson(out, std.mem.span(rendered_ptr));
    try out.writeByte('\n');
}

fn writeOptionalBool(out: *Writer, key: []const u8, value: ?bool) !void {
    if (value) |present| try out.print(" {s}={}", .{ key, present });
}

fn writeOptionalString(out: *Writer, key: []const u8, value: ?[]const u8) !void {
    if (value) |present| try writeKeyString(out, key, present);
}

fn writeKeyString(out: *Writer, key: []const u8, value: []const u8) !void {
    try out.print(" {s}=", .{key});
    try writeJson(out, value);
}

fn writeJson(out: *Writer, value: []const u8) !void {
    try out.print("{f}", .{std.json.fmt(value, .{})});
}
