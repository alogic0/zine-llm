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
        try expectTreeCaptureRangesValid(tree, case.source.len);
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

fn expectTreeCaptureRangesValid(tree: *syntax, source_len: usize) !void {
    const parsed = tree.tree orelse return;
    const cursor = try treez.Query.Cursor.create();
    defer cursor.destroy();
    cursor.execute(tree.query, parsed.getRootNode());

    while (cursor.nextMatch()) |match| {
        for (match.captures()) |capture| {
            const range = capture.node.getRange();
            try std.testing.expect(range.start_byte <= range.end_byte);
            try std.testing.expect(range.end_byte <= source_len);
        }
    }
}
