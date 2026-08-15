//! SuperMD semantic analysis over the pure-Zig Markdown AST.
//!
//! Syntax parsing remains independent of SuperMD. This layer owns the
//! directive-typed AST contract and incrementally ports the semantic behavior
//! that used to run directly over cmark nodes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const supermd = @import("supermd");
const SyntaxAst = @import("Ast.zig");
const Document = @import("Document.zig");
const Parser = @import("Parser.zig");

pub const Markdown = SyntaxAst.Contract(supermd.Directive);
pub const Node = Markdown.Node;

pub const Options = struct {
    auto_target_blank: bool = false,
};

/// A parsed Markdown tree together with its SuperMD semantic data.
pub const Ast = struct {
    md: Markdown.Ast,
    options: Options,

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

        var analyzer: Analyzer = .{ .options = options };
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
    options: Options,

    fn run(analyzer: *Analyzer, root: Node) !void {
        _ = analyzer.options;

        var iterator = Markdown.Iter.init(root);
        defer iterator.deinit();
        while (iterator.next()) |event| switch (event.dir) {
            .enter => try analyzer.enter(event.node),
            .exit => {},
        };
    }

    fn enter(_: *Analyzer, _: Node) !void {}
};

test "semantic Ast.init owns a pure-Zig document" {
    var ast = try Ast.init(std.testing.allocator, "# Hello\n\nworld\n", .{});
    defer ast.deinit();

    const heading = ast.root().firstChild().?;
    try std.testing.expectEqual(SyntaxAst.NodeType.HEADING, heading.nodeType());
    try std.testing.expectEqual(@as(i32, 1), heading.headingLevel());
    try std.testing.expectEqualStrings("Hello", heading.firstChild().?.literal().?);
    try std.testing.expectEqual(SyntaxAst.NodeType.PARAGRAPH, heading.nextSibling().?.nodeType());
}
