const std = @import("std");
const markdown = @import("markdown.zig");
const Semantic = @import("markdown/Semantic.zig");
const RenderSafety = @import("markdown/RenderSafety.zig");

test "generated Markdown inputs parse and render without violating ranges" {
    const alphabet = "abcdefghijklmnopqrstuvwxyz \t\n[]()<>*_~`!|:#^\\\x00\xff";
    var state: u64 = 0x7a69_6e65_6d64_7631;
    var source_buffer: [512]u8 = undefined;

    for (0..512) |_| {
        const len: usize = @intCast(nextRandom(&state) % (source_buffer.len + 1));
        for (source_buffer[0..len]) |*byte| {
            byte.* = alphabet[@intCast(nextRandom(&state) % alphabet.len)];
        }
        try exerciseSyntax(source_buffer[0..len]);
    }
}

test "structured malformed Markdown remains safe through semantic analysis" {
    const cases = [_][]const u8{
        "***nested **delimiters *without balanced endings\n",
        "[link](unterminated and [nested](target(foo(bar)))\n",
        "![image]($image.asset('unterminated.png')\n",
        "| table | with | cells |\n| :--- | :-: | ---: |\n| escaped \\| pipe | `|` |\n",
        "text[^missing] and repeated[^note][^note]\n\n[^note]: body\n    continuation\n",
        "angle <https://example.com/path> and plain https://example.com/plain.\n",
        "[]($link.page('/').ref('missing')) and []($section.id('open'))\n",
        "```=html\n<div><span>unfinished\n```\n",
    };

    for (cases) |source| {
        try exerciseSemantic(source);
        try exerciseProductionSafety(source);
        for (0..source.len + 1) |end| try exerciseSemantic(source[0..end]);
    }
}

test "undefined footnotes and autolinks reach production HTML emission" {
    var undefined_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer undefined_output.deinit();
    try renderProductionSafety("Text[^missing].\n", &undefined_output.writer);
    try std.testing.expectEqualStrings("Text[^missing].", undefined_output.written());
    try std.testing.expect(std.mem.indexOf(u8, undefined_output.written(), "footnote-ref") == null);

    var autolink_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer autolink_output.deinit();
    try renderProductionSafety(
        "Angle <https://example.com/path>.\n",
        &autolink_output.writer,
    );
    try std.testing.expectEqualStrings(
        "Angle <a href=\"https://example.com/path\">https://example.com/path</a>.",
        autolink_output.written(),
    );
}

test "generated Markdown survives the SuperMD semantic pass" {
    const alphabet = "abc xyz\n[]()'\"$._-/!|*~`<>^\\";
    var state: u64 = 0x7068_6173_6538_7072;
    var source_buffer: [192]u8 = undefined;

    for (0..256) |_| {
        const len: usize = @intCast(nextRandom(&state) % (source_buffer.len + 1));
        for (source_buffer[0..len]) |*byte| {
            byte.* = alphabet[@intCast(nextRandom(&state) % alphabet.len)];
        }
        try exerciseSemantic(source_buffer[0..len]);
    }
}

fn exerciseSyntax(source: []const u8) !void {
    const gpa = std.testing.allocator;
    var parser = try markdown.Parser.init(gpa);
    defer parser.deinit();
    try parser.feed(source);
    var document = try parser.endInput();
    defer document.deinit(gpa);

    for (document.spans) |span| {
        try std.testing.expect(span.start <= span.end);
        try std.testing.expect(span.end <= source.len);
    }

    var render_buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&render_buffer);
    try document.render(&discarding.writer);
}

fn exerciseSemantic(source: []const u8) !void {
    var ast = try Semantic.Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    var iterator = Semantic.Markdown.Iter.init(ast.root());
    defer iterator.deinit();
    while (iterator.next()) |event| {
        const range = event.node.range();
        if (!range.isKnown()) continue;
        try std.testing.expect(range.start_byte <= range.end_byte);
        try std.testing.expect(range.end_byte <= source.len);
    }

    for (ast.errors) |semantic_error| {
        if (!semantic_error.main.isKnown()) continue;
        try std.testing.expect(semantic_error.main.start_byte <= semantic_error.main.end_byte);
        try std.testing.expect(semantic_error.main.end_byte <= source.len);
    }
}

fn exerciseProductionSafety(source: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&buffer);
    try renderProductionSafety(source, &discarding.writer);
}

fn renderProductionSafety(source: []const u8, writer: *std.Io.Writer) !void {
    var ast = try Semantic.Ast.init(std.testing.allocator, source, .{});
    defer ast.deinit();

    var iterator = Semantic.Markdown.Iter.init(ast.root());
    defer iterator.deinit();
    while (iterator.next()) |event| switch (event.node.nodeType()) {
        .TEXT => if (event.dir == .enter) {
            try writer.writeAll(event.node.literal() orelse "");
        },
        .FOOTNOTE_REFERENCE => if (event.dir == .enter) {
            try RenderSafety.footnoteReference(ast, event.node, writer);
        },
        .LINK => _ = try RenderSafety.urlLink(event.node, event.dir == .enter, writer),
        else => {},
    };
}

fn nextRandom(state: *u64) u64 {
    var value = state.*;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    state.* = value;
    return value;
}
