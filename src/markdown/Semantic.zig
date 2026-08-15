//! SuperMD semantic analysis over the pure-Zig Markdown AST.
//!
//! Syntax parsing remains independent of SuperMD. This layer owns the
//! directive-typed AST contract and incrementally ports the semantic behavior
//! that used to run directly over cmark nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const supermd = @import("supermd");
const scripty = @import("scripty");
const ScriptyVM = scripty.VM(supermd.Value);
const SyntaxAst = @import("Ast.zig");
const Document = @import("Document.zig");
const Parser = @import("Parser.zig");

pub const Markdown = SyntaxAst.Contract(supermd.Directive);
pub const Node = Markdown.Node;

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

    pub fn init(gpa: Allocator, source: []const u8, options: Options) !Ast {
        var parser = try Parser.init(gpa);
        defer parser.deinit();

        try parser.feed(source);
        var document = try parser.endInput();
        errdefer document.deinit(gpa);

        var result: Ast = .{
            .md = try Markdown.Ast.init(gpa, &document),
            .options = options,
        };
        errdefer result.deinit();

        var analyzer: Analyzer = .{
            .allocator = result.md.allocator(),
            .options = options,
            .destinations = &result.destinations,
            .evaluated = &result.evaluated,
        };
        try analyzer.run(result.md.root());
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

const Analyzer = struct {
    allocator: Allocator,
    options: Options,
    destinations: *std.AutoArrayHashMapUnmanaged(SyntaxAst.Index, Destination),
    evaluated: *std.AutoArrayHashMapUnmanaged(SyntaxAst.Index, *supermd.Directive),
    vm: ScriptyVM = .{},

    fn run(analyzer: *Analyzer, root: Node) !void {
        _ = analyzer.options;

        var iterator = Markdown.Iter.init(root);
        defer iterator.deinit();
        while (iterator.next()) |event| switch (event.dir) {
            .enter => try analyzer.enter(event.node),
            .exit => {},
        };
    }

    fn enter(analyzer: *Analyzer, node: Node) !void {
        const is_image = switch (node.nodeType()) {
            .LINK => false,
            .IMAGE => true,
            else => return,
        };
        const raw = node.link() orelse return;
        const value = normalizeDestination(raw);
        const destination: Destination = .{
            .raw = raw,
            .value = value,
            .range = node.range(),
            .syntax = classifyDestination(value, is_image),
        };
        try analyzer.destinations.put(analyzer.allocator, node.index, destination);
        try analyzer.attach(node, destination);
    }

    fn attach(analyzer: *Analyzer, node: Node, destination: Destination) !void {
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
            else => return null,
        }
    }
};

fn stripTrailingSlash(path: []const u8) []const u8 {
    return if (path.len > 0 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
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
