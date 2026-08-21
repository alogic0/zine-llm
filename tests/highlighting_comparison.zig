const std = @import("std");
const native = @import("native_syntax");
const syntax = @import("syntax");
const treez = @import("treez");

const Case = struct {
    source: []const u8,
    native_scopes: []const native.Scope,
    tree_captures: []const []const u8,
};

test "native JSON recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "{\"name\":\"Zine <&>\",\"escaped\":\"line\\n\",\"enabled\":true,\"missing\":null,\"value\":1.5e2}",
            .native_scopes = &.{
                .property, .string, .escape, .boolean, .constant, .number, .punctuation,
            },
            .tree_captures = &.{
                "string.special.key", "string", "escape", "constant.builtin", "number",
            },
        },
        .{
            .source = "{\"unicode\":\"\\u12<&>\n",
            .native_scopes = &.{ .property, .string, .escape, .punctuation },
            .tree_captures = &.{ "string", "escape" },
        },
        .{
            .source = "[tru\n",
            .native_scopes = &.{ .boolean, .punctuation },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();

    for (cases) |case| {
        var sink: native.CaptureSink = .init(std.testing.allocator, case.source.len);
        defer sink.deinit();
        try native.languages.json.backend.highlight(case.source, &sink);
        for (case.native_scopes) |scope| {
            try std.testing.expect(hasNativeScope(sink.captures(), scope));
        }

        const tree = try syntax.create_file_type_static(
            std.testing.allocator,
            "json",
            query_cache,
        );
        defer tree.destroy();
        try tree.refresh_full(case.source);
        _ = try expectTreeCaptureRangesValid(tree, case.source.len);
        for (case.tree_captures) |capture_name| {
            if (!try hasTreeCapture(tree, capture_name)) {
                std.debug.print(
                    "missing Tree-sitter capture {s} for JSON source {s}\n",
                    .{ capture_name, case.source },
                );
                return error.TestExpectedTreeCapture;
            }
        }

        if (std.mem.startsWith(u8, case.source, "[tru")) {
            try std.testing.expect(!try hasTreeCapture(tree, "constant.builtin"));
        }
        if (std.mem.indexOf(u8, case.source, "\\u12") != null) {
            try std.testing.expect(!try hasTreeCapture(tree, "string.special.key"));
        }
    }
}

test "native Diff recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
            .native_scopes = &.{ .keyword, .label, .special, .operator },
            .tree_captures = &.{},
        },
        .{
            .source = "@@ -1 +1\n+unterminated <&>",
            .native_scopes = &.{ .special, .operator },
            .tree_captures = &.{},
        },
        .{
            .source = "+++",
            .native_scopes = &.{.operator},
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("diff", case.source, case.native_scopes);
        const tree = try createTree("diff", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native TOML recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "title = \"Zine <&>\"\nenabled = true\n[package.meta]\nvalue = 1.5e2\n",
            .native_scopes = &.{ .property, .namespace, .string, .boolean, .number, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "[package\nvalue = \"unterminated\\u12<&>\n",
            .native_scopes = &.{ .namespace, .property, .string, .escape },
            .tree_captures = &.{},
        },
        .{
            .source = "enabled = tru\n",
            .native_scopes = &.{ .property, .operator },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("toml", case.source, case.native_scopes);
        const tree = try createTree("toml", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native Dockerfile recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "# syntax=docker/dockerfile:1\nFROM alpine:${VERSION} AS build\nCOPY --chown=1000 . .\nRUN echo \"<&>\" && true\n",
            .native_scopes = &.{ .special, .keyword, .variable, .attribute, .number, .string, .operator },
            .tree_captures = &.{},
        },
        .{
            .source = "FROM alpine AS\nRUN echo \"unterminated ${NAME} <&>\n",
            .native_scopes = &.{ .keyword, .string, .variable },
            .tree_captures = &.{},
        },
        .{
            .source = "RUN echo ${NAME\n",
            .native_scopes = &.{ .keyword, .variable },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("dockerfile", case.source, case.native_scopes);
        const tree = try createTree("dockerfile", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

fn expectNativeScopes(
    language: []const u8,
    source: []const u8,
    expected: []const native.Scope,
) !void {
    const backend = if (std.mem.eql(u8, language, "diff"))
        native.languages.diff.backend
    else if (std.mem.eql(u8, language, "toml"))
        native.languages.toml.backend
    else if (std.mem.eql(u8, language, "dockerfile"))
        native.languages.dockerfile.backend
    else
        return error.UnknownNativeComparisonLanguage;
    var sink: native.CaptureSink = .init(std.testing.allocator, source.len);
    defer sink.deinit();
    try backend.highlight(source, &sink);
    for (expected) |scope| try std.testing.expect(hasNativeScope(sink.captures(), scope));
}

fn createTree(
    language: []const u8,
    source: []const u8,
    query_cache: *syntax.QueryCache,
) !*syntax {
    const tree = try syntax.create_file_type_static(std.testing.allocator, language, query_cache);
    errdefer tree.destroy();
    try tree.refresh_full(source);
    return tree;
}

fn hasNativeScope(captures: []const native.Capture, expected: native.Scope) bool {
    for (captures) |capture| {
        if (capture.scope == expected) return true;
    }
    return false;
}

fn hasTreeCapture(tree: *syntax, expected: []const u8) !bool {
    const parsed = tree.tree orelse return false;
    const cursor = try treez.Query.Cursor.create();
    defer cursor.destroy();
    cursor.execute(tree.query, parsed.getRootNode());

    while (cursor.nextMatch()) |match| {
        for (match.captures()) |capture| {
            if (std.mem.eql(u8, tree.query.getCaptureNameForId(capture.id), expected)) return true;
        }
    }
    return false;
}

fn expectTreeCaptureRangesValid(tree: *syntax, source_len: usize) !usize {
    const parsed = tree.tree orelse return 0;
    const cursor = try treez.Query.Cursor.create();
    defer cursor.destroy();
    cursor.execute(tree.query, parsed.getRootNode());

    var count: usize = 0;
    while (cursor.nextMatch()) |match| {
        for (match.captures()) |capture| {
            count += 1;
            const range = capture.node.getRange();
            try std.testing.expect(range.start_byte <= range.end_byte);
            try std.testing.expect(range.end_byte <= source_len);
        }
    }
    return count;
}
