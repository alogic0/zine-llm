//! SuperMD semantic analysis over the pure-Zig Markdown AST.
//!
//! Syntax parsing remains independent of SuperMD. This layer owns the
//! directive-typed AST contract and incrementally ports the semantic behavior
//! that used to run directly over nodes from the legacy parser.

const std = @import("std");
const Allocator = std.mem.Allocator;

const supermd = @import("supermd");
const superhtml = @import("superhtml");
const html = superhtml.html;
const scripty = @import("scripty");
const ScriptyVM = scripty.VM(supermd.Value);
const SyntaxAst = @import("Ast.zig");
const Document = @import("Document.zig");
const Parser = @import("Parser.zig");
const Source = @import("Source.zig");

pub const Markdown = SyntaxAst.Contract(supermd.Directive);
pub const Node = Markdown.Node;

pub const Footnote = struct {
    node: Node,
    def_id: []const u8,
    ref_ids: [][]const u8,
};

pub const Error = struct {
    main: SyntaxAst.Range,
    kind: Kind,

    pub const Kind = union(enum) {
        inline_html,
        heading_section_missing_id,
        invalid_ref,
        no_alt_in_links,
        expression_in_image_syntax,
        empty_expression,
        duplicate_id: struct { id: []const u8, original: Node },
        scripty: struct { len: u32, span: Source.Span, err: []const u8 },
        html: html.Ast.Error,
        heading_skip: struct { have: u8, last: ?Node },
    };
};

pub const Options = struct {
    auto_target_blank: bool = false,
};

pub const Destination = struct {
    /// Exact parser value, including optional angle delimiters.
    raw: []const u8,
    /// Value passed to shorthand handling and Scripty.
    value: []const u8,
    /// Range of the original link/image syntax used for diagnostics.
    range: SyntaxAst.Range,
    syntax: Syntax,

    pub const Syntax = enum {
        empty,
        expression,
        self_fragment,
        absolute_page,
        subpage,
        mail,
        url,
        relative_page,
        expression_image,
        site_asset,
        page_asset,
    };
};

/// A parsed Markdown tree together with its SuperMD semantic data.
pub const Ast = struct {
    md: Markdown.Ast,
    options: Options,
    destinations: std.AutoArrayHashMapUnmanaged(SyntaxAst.Index, Destination) = .{},
    evaluated: std.AutoArrayHashMapUnmanaged(SyntaxAst.Index, *supermd.Directive) = .{},
    ids: std.StringArrayHashMapUnmanaged(Node) = .{},
    referenced_ids: std.StringArrayHashMapUnmanaged(Node) = .{},
    sections: std.StringArrayHashMapUnmanaged(Node) = .{},
    footnotes: std.StringArrayHashMapUnmanaged(Footnote) = .{},
    errors: []const Error = &.{},

    pub fn init(gpa: Allocator, source: []const u8, options: Options) !Ast {
        var parser = try Parser.init(gpa);
        defer parser.deinit();

        try parser.feed(source);
        var result: Ast = .{
            .md = blk: {
                var document = try parser.endInput();
                errdefer document.deinit(gpa);
                break :blk try Markdown.Ast.init(gpa, &document);
            },
            .options = options,
        };
        errdefer result.deinit();

        var errors: std.ArrayList(Error) = .empty;
        var analyzer: Analyzer = .{
            .allocator = result.md.allocator(),
            .source = source,
            .options = options,
            .destinations = &result.destinations,
            .evaluated = &result.evaluated,
            .ids = &result.ids,
            .referenced_ids = &result.referenced_ids,
            .sections = &result.sections,
            .footnotes = &result.footnotes,
            .errors = &errors,
        };
        try analyzer.run(result.md.root());
        result.errors = try errors.toOwnedSlice(result.md.allocator());
        return result;
    }

    pub fn deinit(ast: *Ast) void {
        ast.md.deinit();
        ast.* = undefined;
    }

    pub fn root(ast: Ast) Node {
        return ast.md.root();
    }
};

pub fn writeSnapshot(ast: Ast, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("directives:\n");
    var iterator = Markdown.Iter.init(ast.root());
    defer iterator.deinit();
    while (iterator.next()) |event| {
        if (event.dir != .enter) continue;
        const directive = event.node.getDirective() orelse continue;
        const range = event.node.range();
        try writer.print("  {} {s} {}..{} {s}", .{
            @backingInt(event.node.index),
            @tagName(event.node.nodeType()),
            range.start_byte,
            range.end_byte,
            @tagName(std.meta.activeTag(directive.kind)),
        });
        if (directive.id) |id| try writer.print(" id={s}", .{id});
        try writer.writeByte('\n');
    }

    try writer.writeAll("ids:\n");
    for (ast.ids.keys(), ast.ids.values()) |id, node| {
        try writer.print("  {s} -> {} {s}\n", .{ id, @backingInt(node.index), @tagName(node.nodeType()) });
    }
    try writer.writeAll("references:\n");
    for (ast.referenced_ids.keys(), ast.referenced_ids.values()) |id, node| {
        try writer.print("  {s} -> {}\n", .{ id, @backingInt(node.index) });
    }
    try writer.writeAll("sections:\n");
    for (ast.sections.keys(), ast.sections.values()) |id, node| {
        try writer.print("  {s} -> {}\n", .{ id, @backingInt(node.index) });
    }
    try writer.writeAll("footnotes:\n");
    for (ast.footnotes.keys(), ast.footnotes.values()) |label, footnote| {
        try writer.print("  {s}: def={s} refs=", .{ label, footnote.def_id });
        for (footnote.ref_ids, 0..) |ref_id, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll(ref_id);
        }
        try writer.writeByte('\n');
    }
    try writer.writeAll("errors:\n");
    for (ast.errors) |semantic_error| {
        try writer.print("  {s} {}..{}\n", .{
            @tagName(std.meta.activeTag(semantic_error.kind)),
            semantic_error.main.start_byte,
            semantic_error.main.end_byte,
        });
    }
}

const Analyzer = struct {
    allocator: Allocator,
    source: []const u8,
    options: Options,
    destinations: *std.AutoArrayHashMapUnmanaged(SyntaxAst.Index, Destination),
    evaluated: *std.AutoArrayHashMapUnmanaged(SyntaxAst.Index, *supermd.Directive),
    ids: *std.StringArrayHashMapUnmanaged(Node),
    referenced_ids: *std.StringArrayHashMapUnmanaged(Node),
    sections: *std.StringArrayHashMapUnmanaged(Node),
    footnotes: *std.StringArrayHashMapUnmanaged(Footnote),
    errors: *std.ArrayList(Error),
    vm: ScriptyVM = .{},
    sectioned: bool = false,

    fn run(analyzer: *Analyzer, root: Node) !void {
        _ = analyzer.options;

        var iterator = Markdown.Iter.init(root);
        defer iterator.deinit();
        while (iterator.next()) |event| switch (event.dir) {
            .enter => {
                try analyzer.enter(event.node);
                if (event.node.getDirective()) |directive| {
                    // Math validation detaches the queued code child. Resume
                    // after the link instead of following that stale event.
                    if (directive.kind == .mathtex) iterator.reset(event.node, .exit);
                }
            },
            .exit => {},
        };
        try analyzer.buildFootnotes(root);
        try analyzer.validateTopLevel(root);
        try analyzer.validateReferences();
    }

    fn enter(analyzer: *Analyzer, node: Node) !void {
        switch (node.nodeType()) {
            .HTML_BLOCK => try analyzer.addError(node.range(), .inline_html),
            .CODE_BLOCK => try analyzer.validateHtmlBlock(node),
            else => {},
        }
        const is_image = switch (node.nodeType()) {
            .LINK => false,
            .IMAGE => true,
            else => return,
        };
        const stored_destination = node.link() orelse return;
        const destination_and_title = splitDestinationTitle(stored_destination);
        node.setTitle(destination_and_title.title);
        const raw = destination_and_title.destination;
        const value = normalizeDestination(raw);
        const destination: Destination = .{
            .raw = raw,
            .value = value,
            .range = node.range(),
            .syntax = classifyDestination(value, is_image),
        };
        try analyzer.destinations.put(analyzer.allocator, node.index, destination);
        try analyzer.attach(node, destination);
        if (node.getDirective()) |directive| {
            if (try directive.validate(analyzer.allocator, node)) |validation| {
                if (validation == .err) try analyzer.addError(destination.range, .{ .scripty = .{
                    .len = @intCast(destination.value.len),
                    .span = .{ .start = 0, .end = @intCast(destination.value.len) },
                    .err = validation.err,
                } });
            }
            try analyzer.indexDirective(node, directive);
            try analyzer.transformDirective(node, directive);
        }
    }

    fn transformDirective(
        analyzer: *Analyzer,
        node: Node,
        directive: *supermd.Directive,
    ) !void {
        switch (directive.kind) {
            .heading => {
                const parent = node.parent() orelse return;
                _ = try parent.setDirective(analyzer.allocator, directive, false);
            },
            .section => {
                const parent = node.parent() orelse return;
                const id = directive.id orelse return;

                // Keep section semantics on the containing block, then turn
                // the source link into the same self-link the legacy parser produced.
                _ = try parent.setDirective(analyzer.allocator, directive, true);
                directive.id = null;
                directive.attrs = &.{};
                directive.kind = .{ .link = .{
                    .src = .{ .url = "" },
                    .ref = id,
                } };
            },
            .block => {
                const blockquote = semanticTarget(node, directive);
                if (blockquote.nodeType() == .BLOCK_QUOTE) {
                    _ = try blockquote.setDirective(analyzer.allocator, directive, false);
                }
            },
            else => {},
        }
    }

    fn indexDirective(analyzer: *Analyzer, node: Node, directive: *supermd.Directive) !void {
        const target = semanticTarget(node, directive);
        if (directive.kind == .section) {
            analyzer.sectioned = true;
            if (directive.id == null) {
                try analyzer.addError(node.range(), .heading_section_missing_id);
            }
        }
        if (directive.id) |id| {
            const result = try analyzer.ids.getOrPut(analyzer.allocator, id);
            if (result.found_existing) {
                try analyzer.addError(node.range(), .{ .duplicate_id = .{
                    .id = id,
                    .original = result.value_ptr.*,
                } });
            } else result.value_ptr.* = target;
            if (directive.kind == .section) {
                try analyzer.sections.put(analyzer.allocator, id, target);
            }
        }

        if (directive.kind == .link) {
            const link = directive.kind.link;
            if (!link.ref_unsafe and link.ref != null and link.src != null and link.src.? == .self_page) {
                try analyzer.referenced_ids.put(analyzer.allocator, link.ref.?, node);
            }
        }
    }

    fn validateTopLevel(analyzer: *Analyzer, root: Node) !void {
        if (analyzer.sectioned) return;
        var last_level: i32 = 0;
        var last_heading: ?Node = null;
        var node = root.firstChild();
        while (node) |current| : (node = current.nextSibling()) {
            if (current.nodeType() != .HEADING) continue;
            const level = current.headingLevel();
            if (level > last_level + 1) try analyzer.addError(current.range(), .{
                .heading_skip = .{ .have = @intCast(level), .last = last_heading },
            });
            last_level = level;
            last_heading = current;
        }
    }

    fn validateReferences(analyzer: *Analyzer) !void {
        for (analyzer.referenced_ids.keys(), analyzer.referenced_ids.values()) |id, node| {
            if (!analyzer.ids.contains(id)) try analyzer.addError(node.range(), .invalid_ref);
        }
    }

    fn addError(analyzer: *Analyzer, range: SyntaxAst.Range, kind: Error.Kind) !void {
        try analyzer.errors.append(analyzer.allocator, .{ .main = range, .kind = kind });
    }

    fn validateHtmlBlock(analyzer: *Analyzer, node: Node) !void {
        const fence = node.fenceInfo() orelse return;
        if (!std.mem.startsWith(u8, fence, "=html")) return;
        const literal = node.literal() orelse return;
        const html_ast = try html.Ast.init(analyzer.allocator, literal, .html, false);
        defer html_ast.deinit(analyzer.allocator);

        const block_range = node.range();
        const block_source = analyzer.source[block_range.start_byte..block_range.end_byte];
        const content_offset: u32 = if (std.mem.indexOfScalar(u8, block_source, '\n')) |newline|
            block_range.start_byte + @as(u32, @intCast(newline)) + 1
        else
            block_range.start_byte;
        for (html_ast.errors) |html_error| {
            const start = content_offset + html_error.main_location.start;
            const end = content_offset + html_error.main_location.end;
            try analyzer.addError(sourceRange(analyzer.source, start, end), .{ .html = html_error });
        }
    }

    fn buildFootnotes(analyzer: *Analyzer, root: Node) !void {
        var definitions: std.StringArrayHashMapUnmanaged(Node) = .{};
        var counts: std.StringArrayHashMapUnmanaged(usize) = .{};

        var iterator = Markdown.Iter.init(root);
        defer iterator.deinit();
        while (iterator.next()) |event| {
            if (event.dir != .enter) continue;
            switch (event.node.nodeType()) {
                .FOOTNOTE_DEFINITION => try definitions.put(
                    analyzer.allocator,
                    event.node.footnoteLabel().?,
                    event.node,
                ),
                .FOOTNOTE_REFERENCE => {
                    const count = try counts.getOrPutValue(
                        analyzer.allocator,
                        event.node.footnoteLabel().?,
                        0,
                    );
                    count.value_ptr.* += 1;
                },
                else => {},
            }
        }

        iterator = Markdown.Iter.init(root);
        var seen: std.StringArrayHashMapUnmanaged(usize) = .{};
        while (iterator.next()) |event| {
            if (event.dir != .enter or event.node.nodeType() != .FOOTNOTE_REFERENCE) continue;
            const label = event.node.footnoteLabel().?;
            const definition = definitions.get(label) orelse continue;
            const result = try analyzer.footnotes.getOrPut(analyzer.allocator, label);
            if (!result.found_existing) {
                const footnote_number = result.index + 1;
                const def_id = try std.fmt.allocPrint(analyzer.allocator, "fn-{d}", .{footnote_number});
                const ref_ids = try analyzer.allocator.alloc([]const u8, counts.get(label).?);
                for (ref_ids, 0..) |*ref_id, index| {
                    ref_id.* = try std.fmt.allocPrint(
                        analyzer.allocator,
                        "fn-{d}-ref-{d}",
                        .{ footnote_number, index + 1 },
                    );
                }
                result.value_ptr.* = .{
                    .node = definition,
                    .def_id = def_id,
                    .ref_ids = ref_ids,
                };
                try analyzer.ids.put(analyzer.allocator, def_id, definition);
                definition.setFootnoteMetadata(null, @intCast(ref_ids.len), 0);
            }

            const occurrence = try seen.getOrPutValue(analyzer.allocator, label, 0);
            const reference_index = occurrence.value_ptr.*;
            occurrence.value_ptr.* += 1;
            const ref_id = result.value_ptr.ref_ids[reference_index];
            try analyzer.ids.put(analyzer.allocator, ref_id, event.node);
            event.node.setFootnoteMetadata(
                definition.index,
                @intCast(result.value_ptr.ref_ids.len),
                @intCast(reference_index + 1),
            );
        }
    }

    fn attach(analyzer: *Analyzer, node: Node, destination: Destination) !void {
        if (node.nodeType() == .IMAGE and destination.syntax == .expression_image) {
            try analyzer.addError(destination.range, .expression_in_image_syntax);
            return;
        }
        if (destination.syntax == .empty) {
            try analyzer.addError(destination.range, .empty_expression);
            return;
        }
        if (node.nodeType() == .LINK and node.title() != null) {
            try analyzer.addError(destination.range, .no_alt_in_links);
        }
        if (destination.syntax == .expression) {
            const directive = try analyzer.evaluate(node, destination.value) orelse return;
            _ = try node.setDirective(analyzer.allocator, directive, false);
            return;
        }

        var directive: supermd.Directive = switch (destination.syntax) {
            .self_fragment => .{ .kind = .{ .link = .{
                .ref = destination.value[1..],
                .src = .{ .self_page = null },
            } } },
            .absolute_page => absolute: {
                var parts = std.mem.splitScalar(u8, destination.value[1..], '#');
                const path = stripTrailingSlash(parts.first());
                const ref = parts.next();
                break :absolute .{ .kind = .{ .link = .{
                    .ref = ref,
                    .src = .{ .page = .{
                        .ref = path,
                        .kind = .absolute,
                    } },
                } } };
            },
            .subpage => subpage: {
                const path_start: usize = @min(2, destination.value.len);
                var parts = std.mem.tokenizeScalar(u8, destination.value[path_start..], '#');
                const path = stripTrailingSlash(parts.next() orelse "");
                const ref = parts.next();
                break :subpage .{ .kind = .{ .link = .{
                    .ref = ref,
                    .src = .{ .page = .{
                        .ref = path,
                        .kind = .sub,
                    } },
                } } };
            },
            .mail, .url => .{ .kind = .{ .link = .{
                .src = .{ .url = destination.value },
                .new = analyzer.options.auto_target_blank,
            } } },
            .relative_page => .{ .kind = .{ .link = .{ .src = .{ .page = .{
                .ref = destination.value,
                .kind = .sibling,
            } } } } },
            .site_asset => .{ .kind = .{ .image = .{
                .src = .{ .site_asset = .{ .ref = destination.value[1..] } },
                .alt = node.title(),
            } } },
            .page_asset => .{ .kind = .{ .image = .{
                .src = .{ .page_asset = .{ .ref = if (std.mem.startsWith(
                    u8,
                    destination.value,
                    "./",
                )) destination.value[2..] else destination.value } },
                .alt = node.title(),
            } } },
            .empty, .expression_image => return,
            .expression => unreachable,
        };
        if (destination.syntax == .url) {
            _ = std.Uri.parse(destination.value) catch {
                try analyzer.addError(destination.range, .{ .scripty = .{
                    .len = @intCast(destination.value.len),
                    .span = .{ .start = 0, .end = @intCast(destination.value.len) },
                    .err = "invalid URL",
                } });
                return;
            };
        }
        _ = try node.setDirective(analyzer.allocator, &directive, true);
    }

    fn evaluate(analyzer: *Analyzer, node: Node, source: []const u8) !?*supermd.Directive {
        var context: supermd.Content = .{};
        const result = try analyzer.vm.run(analyzer.allocator, &context, source, .{});
        switch (result.value) {
            .directive => |directive| {
                // Scripty returns a pointer into the per-expression Content
                // value. Preserve the evaluated directive in the AST arena.
                const stored = try analyzer.allocator.create(supermd.Directive);
                stored.* = directive.*;
                try analyzer.evaluated.put(analyzer.allocator, node.index, stored);
                return stored;
            },
            .err => |message| {
                try analyzer.addError(node.range(), .{ .scripty = .{
                    .len = @intCast(source.len),
                    .span = .{ .start = result.loc.start, .end = result.loc.end },
                    .err = message,
                } });
                return null;
            },
            else => return null,
        }
    }
};

fn semanticTarget(node: Node, directive: *const supermd.Directive) Node {
    return switch (directive.kind) {
        .heading, .section => node.parent() orelse node,
        .block => block: {
            var current = node.parent() orelse break :block node;
            while (current.nodeType() != .BLOCK_QUOTE) {
                current = current.parent() orelse break :block node;
            }
            break :block current;
        },
        else => node,
    };
}

fn stripTrailingSlash(path: []const u8) []const u8 {
    return if (path.len > 0 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
}

fn sourceRange(source: []const u8, start: u32, end: u32) SyntaxAst.Range {
    const source_len: u32 = @intCast(source.len);
    const bounded_start = @min(start, source_len);
    const bounded_end = @max(bounded_start, @min(end, source_len));
    return .{
        .start = sourcePosition(source, bounded_start),
        .end = sourcePosition(source, bounded_end),
        .start_byte = bounded_start,
        .end_byte = bounded_end,
    };
}

fn splitDestinationTitle(raw: []const u8) struct {
    destination: []const u8,
    title: ?[]const u8,
} {
    var nesting: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;
    for (raw, 0..) |byte, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (byte == '\\') {
            escaped = true;
            continue;
        }
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
            continue;
        }
        switch (byte) {
            '\'', '"' => quote = byte,
            '(' => nesting += 1,
            ')' => nesting -|= 1,
            ' ', '\t', '\n', '\r' => if (nesting == 0) {
                const candidate = std.mem.trim(u8, raw[index..], " \t\n\r");
                if (candidate.len < 2) break;
                const closing: u8 = switch (candidate[0]) {
                    '\'' => '\'',
                    '"' => '"',
                    '(' => ')',
                    else => break,
                };
                if (candidate[candidate.len - 1] != closing) break;
                return .{
                    .destination = raw[0..index],
                    .title = candidate[1 .. candidate.len - 1],
                };
            },
            else => {},
        }
    }
    return .{ .destination = raw, .title = null };
}

fn sourcePosition(source: []const u8, offset_arg: u32) Source.Position {
    const offset = @min(offset_arg, source.len);
    var row: u32 = 1;
    var line_start: usize = 0;
    for (source[0..offset], 0..) |byte, index| {
        if (byte == '\n') {
            row += 1;
            line_start = index + 1;
        }
    }
    return .{ .row = row, .col = @intCast(offset - line_start + 1) };
}

fn normalizeDestination(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '<' and raw[raw.len - 1] == '>') {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

fn classifyDestination(raw: []const u8, is_image: bool) Destination.Syntax {
    if (raw.len == 0) return .empty;
    return if (is_image) switch (raw[0]) {
        '$' => .expression_image,
        '/' => .site_asset,
        else => if (std.mem.indexOf(u8, raw, "://") != null) .url else .page_asset,
    } else switch (raw[0]) {
        '$' => .expression,
        '#' => .self_fragment,
        '/' => .absolute_page,
        '.' => .subpage,
        else => if (std.mem.startsWith(u8, raw, "mailto:"))
            .mail
        else if (std.mem.indexOf(u8, raw, "://") != null)
            .url
        else
            .relative_page,
    };
}

test "semantic Ast.init owns a pure-Zig document" {
    var ast = try Ast.init(std.testing.allocator, "# Hello\n\nworld\n", .{});
    defer ast.deinit();

    const heading = ast.root().firstChild().?;
    try std.testing.expectEqual(SyntaxAst.NodeType.HEADING, heading.nodeType());
    try std.testing.expectEqual(@as(i32, 1), heading.headingLevel());
    try std.testing.expectEqualStrings("Hello", heading.firstChild().?.literal().?);
    try std.testing.expectEqual(SyntaxAst.NodeType.PARAGRAPH, heading.nextSibling().?.nodeType());
}

test "semantic analysis recognizes link and image destination forms" {
    const source =
        \\[$section]($section)
        \\[fragment](#part)
        \\[absolute](/guide#part)
        \\[sub](../guide)
        \\[mail](mailto:a@example.com)
        \\[url](https://example.com)
        \\[relative](guide)
        \\![bad]($image)
        \\![site](/logo.svg)
        \\![page](logo.svg)
    ;
    var ast = try Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    const expected: []const Destination.Syntax = &.{
        .expression,
        .self_fragment,
        .absolute_page,
        .subpage,
        .mail,
        .url,
        .relative_page,
        .expression_image,
        .site_asset,
        .page_asset,
    };
    try std.testing.expectEqual(expected.len, ast.destinations.count());
    for (expected, ast.destinations.values()) |want, found| {
        try std.testing.expectEqual(want, found.syntax);
    }
}

test "angle destinations are normalized without losing diagnostic ranges" {
    const source = "before [section](<$section.id('intro')>) after\n";
    var ast = try Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    const destination = ast.destinations.values()[0];
    try std.testing.expectEqualStrings("<$section.id('intro')>", destination.raw);
    try std.testing.expectEqualStrings("$section.id('intro')", destination.value);
    try std.testing.expectEqual(Destination.Syntax.expression, destination.syntax);
    try std.testing.expect(destination.range.isKnown());
    try std.testing.expectEqualStrings(
        "[section](<$section.id('intro')>)",
        source[destination.range.start_byte..destination.range.end_byte],
    );
}

test "Scripty expressions use the existing SuperMD context" {
    var ast = try Ast.init(
        std.testing.allocator,
        "[intro](<$heading.id('intro').attrs('wide')>)\n",
        .{},
    );
    defer ast.deinit();

    try std.testing.expectEqual(@as(usize, 1), ast.evaluated.count());
    const directive = ast.evaluated.values()[0];
    try std.testing.expectEqualStrings("intro", directive.id.?);
    try std.testing.expectEqualStrings("wide", directive.attrs.?[0]);
    try std.testing.expect(directive.kind == .heading);
    try std.testing.expect(ast.destinations.keys()[0] == ast.root().firstChild().?.firstChild().?.index);
    try std.testing.expect(ast.root().firstChild().?.firstChild().?.getDirective() == directive);
}

test "semantic directives are attached through AST sidecars" {
    var ast = try Ast.init(
        std.testing.allocator,
        "[#](#intro) [page](/guide/) ![logo](./logo.svg)\n",
        .{ .auto_target_blank = true },
    );
    defer ast.deinit();

    const paragraph = ast.root().firstChild().?;
    const fragment = paragraph.firstChild().?;
    const page = fragment.nextSibling().?.nextSibling().?;
    const image = page.nextSibling().?.nextSibling().?;

    try std.testing.expectEqualStrings(
        "intro",
        fragment.getDirective().?.kind.link.ref.?,
    );
    try std.testing.expectEqualStrings(
        "guide",
        page.getDirective().?.kind.link.src.?.page.ref,
    );
    try std.testing.expectEqualStrings(
        "logo.svg",
        image.getDirective().?.kind.image.src.?.page_asset.ref,
    );
}

test "semantic analysis builds IDs, references, sections, and footnotes" {
    const source =
        \\# [Intro]($section.id('intro'))
        \\See [above](#intro) and note[^n] twice[^n].
        \\[^n]: Footnote.
    ;
    var ast = try Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    try std.testing.expect(ast.ids.get("intro").?.nodeType() == .HEADING);
    try std.testing.expect(ast.sections.get("intro").?.nodeType() == .HEADING);
    try std.testing.expect(ast.referenced_ids.contains("intro"));
    try std.testing.expect(ast.ids.contains("fn-1"));
    try std.testing.expect(ast.ids.contains("fn-1-ref-1"));
    try std.testing.expect(ast.ids.contains("fn-1-ref-2"));

    const footnote = ast.footnotes.get("n").?;
    try std.testing.expectEqualStrings("fn-1", footnote.def_id);
    try std.testing.expectEqual(@as(usize, 2), footnote.ref_ids.len);
    try std.testing.expect(footnote.node.nodeType() == .FOOTNOTE_DEFINITION);
}

test "semantic validation errors retain pure parser ranges" {
    const source =
        \\## Skipped
        \\[first]($text.id('same')) [second]($text.id('same'))
        \\[missing](#unknown) ![bad]($image)
        \\<div>
        \\raw
        \\</div>
    ;
    var ast = try Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    var saw_skip = false;
    var saw_duplicate = false;
    var saw_invalid_ref = false;
    var saw_image_expression = false;
    var saw_inline_html = false;
    for (ast.errors) |semantic_error| {
        try std.testing.expect(semantic_error.main.isKnown());
        switch (semantic_error.kind) {
            .heading_skip => saw_skip = true,
            .duplicate_id => saw_duplicate = true,
            .invalid_ref => saw_invalid_ref = true,
            .expression_in_image_syntax => saw_image_expression = true,
            .inline_html => saw_inline_html = true,
            else => {},
        }
    }
    try std.testing.expect(saw_skip);
    try std.testing.expect(saw_duplicate);
    try std.testing.expect(saw_invalid_ref);
    try std.testing.expect(saw_image_expression);
    try std.testing.expect(saw_inline_html);
}

test "semantic transformations preserve sections blocks captions and math" {
    const source =
        \\# [Section]($section.id('section'))
        \\> # [Summary]($block.collapsible(false))
        \\> Body.
        \\
        \\[Caption]($image.asset('photo.jpg'))
        \\
        \\[`x + y`](<$mathtex>)
    ;
    var ast = try Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    const heading = ast.root().firstChild().?;
    try std.testing.expect(heading.getDirective().?.kind == .section);
    const section_link = heading.firstChild().?;
    try std.testing.expect(section_link.getDirective().?.kind == .link);
    try std.testing.expectEqualStrings("section", section_link.getDirective().?.kind.link.ref.?);

    const quote = heading.nextSibling().?;
    try std.testing.expect(quote.getDirective().?.kind == .block);
    try std.testing.expectEqual(false, quote.getDirective().?.kind.block.collapsible.?);

    const caption_paragraph = quote.nextSibling().?;
    const caption = caption_paragraph.firstChild().?;
    try std.testing.expect(caption.getDirective().?.kind == .image);
    try std.testing.expectEqualStrings("Caption", caption.firstChild().?.literal().?);

    const math = caption_paragraph.nextSibling().?.firstChild().?;
    try std.testing.expect(math.getDirective().?.kind == .mathtex);
    try std.testing.expectEqualStrings("x + y", math.getDirective().?.kind.mathtex.formula);
    try std.testing.expect(math.firstChild() == null);
}

test "semantic snapshot is independent of HTML rendering" {
    const gpa = std.testing.allocator;
    const source = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/markdown-semantic/semantic.smd",
        gpa,
        .limited(1024 * 1024),
    );
    defer gpa.free(source);
    const expected = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/markdown-semantic/semantic.snapshot",
        gpa,
        .limited(1024 * 1024),
    );
    defer gpa.free(expected);

    var ast = try Ast.init(gpa, source, .{});
    defer ast.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try writeSnapshot(ast, &output.writer);
    try std.testing.expectEqualStrings(expected, output.written());
}

test "inline HTML policy permits inline HTML but rejects HTML blocks" {
    var inline_ast = try Ast.init(std.testing.allocator, "text <ctx> text\n", .{});
    defer inline_ast.deinit();
    try std.testing.expectEqual(@as(usize, 0), inline_ast.errors.len);
    try std.testing.expect(
        inline_ast.root().firstChild().?.firstChild().?.nextSibling().?.nodeType() == .HTML_INLINE,
    );

    var block_ast = try Ast.init(
        std.testing.allocator,
        "<div>block HTML</div>\n",
        .{},
    );
    defer block_ast.deinit();
    try std.testing.expectEqual(@as(usize, 1), block_ast.errors.len);
    try std.testing.expect(block_ast.errors[0].kind == .inline_html);
    try std.testing.expect(block_ast.errors[0].main.isKnown());
}

test "fenced HTML diagnostics stay within truncated source" {
    const source = "```=html\n<";
    var ast = try Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    try std.testing.expectEqual(@as(usize, 1), ast.errors.len);
    try std.testing.expect(ast.errors[0].kind == .html);
    try std.testing.expect(ast.errors[0].main.isKnown());
    try std.testing.expect(ast.errors[0].main.end_byte <= source.len);
}

test "link titles are separated before Scripty evaluation" {
    const source = "[]($link.page(\"foo\") \"title\")\n";
    var ast = try Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    const link = ast.root().firstChild().?.firstChild().?;
    try std.testing.expectEqualStrings("title", link.title().?);
    try std.testing.expectEqualStrings("foo", link.getDirective().?.kind.link.src.?.page.ref);
    try std.testing.expectEqual(@as(usize, 1), ast.errors.len);
    try std.testing.expect(ast.errors[0].kind == .no_alt_in_links);
    try std.testing.expectEqualStrings(
        source[0 .. source.len - 1],
        source[ast.errors[0].main.start_byte..ast.errors[0].main.end_byte],
    );
}

fn exerciseAllocationFailures(allocator: Allocator, source: []const u8) !void {
    var ast = try Ast.init(allocator, source, .{});
    defer ast.deinit();
}

test "semantic allocation failures clean up owned syntax and sidecars" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{"# Heading\n\nPlain paragraph.\n"},
    );

    const rich_source =
        "# [Section]($section.id('intro').attrs('wide'))\n" ++
        "See [the section](#intro) and a repeated note[^n][^n].\n\n" ++
        "[^n]: Footnote with **formatting**.\n\n" ++
        "```=html\n" ++
        "<div><span>unfinished</div>\n" ++
        "```\n";
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{rich_source},
    );
}
