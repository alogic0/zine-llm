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

test "native Python recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "@decorator\nclass Entry:\n    def render(self, value: int = 1_000) -> str:\n        return f\"{value} <&>\\n\"\n",
            .native_scopes = &.{ .attribute, .keyword, .type, .function, .variable, .builtin, .number, .string, .escape, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "def broken(x:\n    return \"unterminated\\n<&>\n",
            .native_scopes = &.{ .keyword, .function, .variable, .string, .escape },
            .tree_captures = &.{},
        },
        .{
            .source = "text = \"\"\"unfinished\n<&>\n",
            .native_scopes = &.{ .variable, .string, .operator },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("python", case.source, case.native_scopes);
        const tree = try createTree("python", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native SQL recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "SELECT u.\"name\", count(*) FROM users u WHERE enabled = true AND id > :minimum LIMIT 10;\n",
            .native_scopes = &.{ .keyword, .property, .variable, .function, .boolean, .parameter, .number, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "SELECT /* open\n name FROM t WHERE value = 'unterminated <&>\n",
            .native_scopes = &.{ .keyword, .comment },
            .tree_captures = &.{},
        },
        .{
            .source = "SELECT $body$unfinished\n<&>\n",
            .native_scopes = &.{ .keyword, .string },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("sql", case.source, case.native_scopes);
        const tree = try createTree("sql", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native C recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "#include <stdint.h>\n/** docs */\nstatic int render(const char *text) { return text != NULL ? 0xffu : 0; }\n",
            .native_scopes = &.{ .macro, .comment, .documentation, .keyword, .builtin, .type, .function, .variable, .constant, .number, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "#define OPEN(x) \\\n  ((x) + 1\nint main( { return \"unterminated\\n<&>\n",
            .native_scopes = &.{ .macro, .builtin, .function, .keyword, .string, .escape },
            .tree_captures = &.{},
        },
        .{
            .source = "/* unfinished\nint hidden(void);\n",
            .native_scopes = &.{.comment},
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("c", case.source, case.native_scopes);
        const tree = try createTree("c", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native JavaScript recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "/** docs */\nexport class Entry { #value = 1_000; async render(ok = true) { return `${this.#value} <&>\\n`; } }\n",
            .native_scopes = &.{ .comment, .documentation, .keyword, .type, .property, .function, .variable, .string, .escape, .boolean, .number, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "function broken(value { return `unfinished ${value}\\n<&>\n",
            .native_scopes = &.{ .keyword, .function, .variable, .string, .escape, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "/* unfinished\nconst hidden = true;\n",
            .native_scopes = &.{.comment},
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("javascript", case.source, case.native_scopes);
        const tree = try createTree("javascript", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native TypeScript recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "/** docs */\nexport interface Entry<T extends object> { readonly value: T; enabled?: boolean; }\ntype Result<T> = Promise<T | null>;\n",
            .native_scopes = &.{ .comment, .documentation, .keyword, .type, .builtin, .variable, .constant, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "interface Broken<T extends { value: string\nconst text = `unfinished ${value}\\n<&>\n",
            .native_scopes = &.{ .keyword, .type, .builtin, .variable, .string, .escape, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "type = string\n",
            .native_scopes = &.{ .keyword, .builtin, .type, .operator },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("typescript", case.source, case.native_scopes);
        const tree = try createTree("typescript", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native YAML recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "%YAML 1.2\n---\ndefaults: &defaults\n  enabled: true\nservice:\n  value: *defaults\n  text: |\n    line <&>\n",
            .native_scopes = &.{ .special, .property, .label, .variable, .boolean, .operator, .string },
            .tree_captures = &.{},
        },
        .{
            .source = "root:\n  value: \"unterminated\\u12<&>\nnext: true\n",
            .native_scopes = &.{ .property, .string, .escape, .boolean, .operator },
            .tree_captures = &.{},
        },
        .{
            .source = "text: |\n  unfinished <&>\nnext: false\n",
            .native_scopes = &.{ .property, .operator, .string, .boolean },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("yaml", case.source, case.native_scopes);
        const tree = try createTree("yaml", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native HCL recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{
            .source = "variable \"image\" {\n  type = string\n}\nlocals {\n  enabled = true\n  source = var.image\n  name = format(\"service-${var.image}<&>\")\n}\n",
            .native_scopes = &.{ .keyword, .string, .property, .type, .boolean, .function, .embedded, .variable, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "root {\n  value = \"unterminated\\u12<&>\n  next = true\n}\n",
            .native_scopes = &.{ .variable, .property, .string, .escape, .boolean, .operator, .punctuation },
            .tree_captures = &.{},
        },
        .{
            .source = "text = <<-EOF\n  unfinished <&>\n",
            .native_scopes = &.{ .property, .operator, .label, .string },
            .tree_captures = &.{},
        },
    };

    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes("hcl", case.source, case.native_scopes);
        const tree = try createTree("hcl", case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0) try std.testing.expect(capture_count > 0);
    }
}

test "native Make recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{ .source = "include config.mk\nCC := cc\nall: build\n\t$(CC) -o app main.c <&>\n", .native_scopes = &.{ .keyword, .property, .label, .variable, .operator, .embedded }, .tree_captures = &.{} },
        .{ .source = "VALUE = \"unterminated\\q<&>\nnext: dep\n", .native_scopes = &.{ .property, .string, .escape, .label, .operator }, .tree_captures = &.{} },
        .{ .source = "target: dep\n\t@echo $(VALUE) <&>\n", .native_scopes = &.{ .label, .operator, .embedded, .variable }, .tree_captures = &.{} },
    };
    try compareLanguage("make", cases[0..]);
}

test "native CMake recovery remains compared with Tree-sitter" {
    const cases = [_]Case{
        .{ .source = "cmake_minimum_required(VERSION 3.28)\nset(NAME \"demo<&>\")\nif(ON)\nendif()\n", .native_scopes = &.{ .function, .number, .string, .keyword, .boolean, .punctuation }, .tree_captures = &.{} },
        .{ .source = "set(NAME \"unterminated\\q<&>\nif(ON)\n", .native_scopes = &.{ .function, .string, .escape, .keyword, .boolean }, .tree_captures = &.{} },
        .{ .source = "function(build name)\n message(STATUS \"<&>\")\n", .native_scopes = &.{ .keyword, .function, .string }, .tree_captures = &.{} },
    };
    try compareLanguage("cmake", cases[0..]);
}

test "native roadmap languages 25 through 42 remain compared with Tree-sitter" {
    const specs = [_]struct { language: []const u8, complete: []const u8, malformed: []const u8, incomplete: []const u8, complete_scopes: []const native.Scope, malformed_scopes: []const native.Scope, incomplete_scopes: []const native.Scope }{
        .{ .language = "java", .complete = "public class Demo { int n = 42; String s = \"x<&>\"; boolean ok = true; }", .malformed = "class X { String s = \"bad\\u12<&>\n", .incomplete = "/** incomplete <&>", .complete_scopes = &.{ .keyword, .type, .number, .string, .boolean }, .malformed_scopes = &.{ .keyword, .string, .escape }, .incomplete_scopes = &.{ .comment, .documentation } },
        .{ .language = "c-sharp", .complete = "public class Demo { int N = 42; string S = \"x<&>\"; bool Ok = true; }", .malformed = "class X { string s = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .type, .number, .string, .boolean }, .malformed_scopes = &.{ .keyword, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "cpp", .complete = "#include <string>\nclass Demo { public: int n = 42; bool ok = true; };", .malformed = "const char* s = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .macro, .keyword, .type, .number, .boolean }, .malformed_scopes = &.{ .keyword, .type, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "go", .complete = "package main\nfunc run() string { n := 42; return \"x<&>\" }", .malformed = "var s = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .type, .number, .string, .function }, .malformed_scopes = &.{ .keyword, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "powershell", .complete = "function Test-X { param([string]$Name) $ok = $true; Write-Output($Name) }", .malformed = "$x = \"bad\\u12<&>\n", .incomplete = "<# incomplete <&>", .complete_scopes = &.{ .keyword, .type, .variable, .boolean, .function }, .malformed_scopes = &.{ .variable, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "php", .complete = "<?php function run(string $x): bool { return true; }", .malformed = "$x = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .type, .variable, .boolean, .function }, .malformed_scopes = &.{ .variable, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "lua", .complete = "local n = 42\nfunction run() return \"x<&>\" end", .malformed = "local s = \"bad\\u12<&>\n", .incomplete = "--[[ incomplete <&>", .complete_scopes = &.{ .keyword, .number, .function, .string }, .malformed_scopes = &.{ .keyword, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "kotlin", .complete = "class Demo { val n: Int = 42; fun run(): String = \"x<&>\" }", .malformed = "val s = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .type, .number, .string }, .malformed_scopes = &.{ .keyword, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "ruby", .complete = "class Demo\n def run()\n  puts(\"x<&>\")\n end\nend", .malformed = "s = \"bad\\u12<&>\n", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .function, .string }, .malformed_scopes = &.{ .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "swift", .complete = "struct Demo { let n: Int = 42; func run() -> String { \"x<&>\" } }", .malformed = "let s = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .type, .number, .string }, .malformed_scopes = &.{ .keyword, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "asm", .complete = "start:\n mov rax, 42\n ret", .malformed = "msg: .ascii \"bad\\u12<&>\n", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .label, .keyword, .type, .number }, .malformed_scopes = &.{ .label, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "nasm", .complete = "section .text\nstart:\n mov rax, 42\n ret", .malformed = "msg: db \"bad\\u12<&>\n", .incomplete = "; incomplete <&>", .complete_scopes = &.{ .keyword, .label, .type, .number }, .malformed_scopes = &.{ .label, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "objc", .complete = "#import <Foundation/Foundation.h>\n@interface Demo\n@end\nint run() { return 42; }", .malformed = "NSString *s = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .macro, .attribute, .type, .function, .keyword, .number }, .malformed_scopes = &.{ .variable, .string, .escape }, .incomplete_scopes = &.{.comment} },
        .{ .language = "vue", .complete = "<template><div class=\"x\">{{ value }}<&></div></template>", .malformed = "<template><div title=\"open<&>\n", .incomplete = "<!-- incomplete <&>", .complete_scopes = &.{ .tag, .attribute, .string, .embedded }, .malformed_scopes = &.{ .tag, .attribute, .string }, .incomplete_scopes = &.{.comment} },
        .{ .language = "astro", .complete = "---\nconst x = 1;\n---\n<main class=\"x\"><&></main>", .malformed = "---\nconst x = '<&>'\n<div>", .incomplete = "<!-- incomplete <&>", .complete_scopes = &.{ .special, .embedded, .tag, .attribute, .string }, .malformed_scopes = &.{ .special, .embedded }, .incomplete_scopes = &.{.comment} },
        .{ .language = "jsdoc", .complete = "/** @param {string} value `code` <&> */", .malformed = "/** @param {string value <&>", .incomplete = "/** @returns {bool}", .complete_scopes = &.{ .comment, .documentation, .attribute, .type, .markup_code }, .malformed_scopes = &.{ .comment, .attribute, .type }, .incomplete_scopes = &.{ .comment, .attribute, .type } },
        .{ .language = "regex", .complete = "^(?<name>[A-Za-z_]\\w+)$", .malformed = "^(unterminated[<&>\\d+", .incomplete = "foo(bar|baz", .complete_scopes = &.{ .special, .punctuation, .string, .escape, .operator }, .malformed_scopes = &.{ .special, .punctuation, .string }, .incomplete_scopes = &.{ .punctuation, .operator } },
        .{ .language = "proto", .complete = "syntax = \"proto3\"; message Entry { string name = 1; bool ok = 2; }", .malformed = "string name = \"bad\\u12<&>\n", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string, .type, .property, .number }, .malformed_scopes = &.{ .type, .property, .string, .escape }, .incomplete_scopes = &.{.comment} },
    };
    for (specs) |spec| {
        const cases = [_]Case{
            .{ .source = spec.complete, .native_scopes = spec.complete_scopes, .tree_captures = &.{} },
            .{ .source = spec.malformed, .native_scopes = spec.malformed_scopes, .tree_captures = &.{} },
            .{ .source = spec.incomplete, .native_scopes = spec.incomplete_scopes, .tree_captures = &.{} },
        };
        try compareLanguage(spec.language, cases[0..]);
    }
}

test "native roadmap languages 43 through 74 remain compared with Tree-sitter" {
    const specs = [_]struct {
        language: []const u8,
        complete: []const u8,
        incomplete: []const u8,
        complete_scopes: []const native.Scope,
        malformed_scopes: []const native.Scope = &.{ .string, .escape, .operator },
    }{
        .{ .language = "kdl", .complete = "node key=\"x\\n<&>\" count=42 enabled=true // comment", .incomplete = "// incomplete <&>", .complete_scopes = &.{ .variable, .string } },
        .{ .language = "nix", .complete = "let value = \"x\\n<&>\"; count = 42; enabled = true; # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "fish", .complete = "function run; set value \"x\\n<&>\"; end # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "nu", .complete = "def run [] { let value = \"x\\n<&>\" } # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "awk", .complete = "BEGIN { value = \"x\\n<&>\"; print(value) } # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "ssh-config", .complete = "Host demo\n HostName \"x\\n<&>\" # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "gitcommit", .complete = "feat: render \"x\\n<&>\" 42 true\n# comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .variable, .string } },
        .{ .language = "git-rebase", .complete = "pick 42 feat \"x\\n<&>\"\n# comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "po", .complete = "msgid \"x\\n<&>\"\nmsgstr \"value\"\n# comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "rst", .complete = "note \"x\\n<&>\" 42 true\n.. comment", .incomplete = ".. incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "latex", .complete = "section { \"x\\n<&>\" 42 true } % comment", .incomplete = "% incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "typst", .complete = "let value = \"x\\n<&>\"; // comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "org", .complete = "TODO \"x\\n<&>\" 42 true\n# comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "dtd", .complete = "ELEMENT note (PCDATA) \"x\\n<&>\" <!-- comment", .incomplete = "<!-- incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "mail", .complete = "Subject: \"x\\n<&>\" 42 true\n> comment", .incomplete = "> incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "hurl", .complete = "GET \"x\\n<&>\"\nstatus = 42 # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "ninja", .complete = "rule run\n command = \"x\\n<&>\" # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "rpmspec", .complete = "Name = \"x\\n<&>\"\nVersion = 42 # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "rpmbash", .complete = "if true; then\n value=\"x\\n<&>\"\n echo %{name}\nfi # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string }, .malformed_scopes = &.{ .string, .escape } },
        .{ .language = "gdscript", .complete = "func run(): var value = \"x\\n<&>\" # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "perl", .complete = "sub run { my $value = \"x\\n<&>\"; } # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "elixir", .complete = "def run do value = \"x\\n<&>\" end # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "fsharp", .complete = "let run () = let value = \"x\\n<&>\" in value // comment", .incomplete = "// incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "ocaml", .complete = "let run () = let value = \"x\\n<&>\" in value (* comment *)", .incomplete = "(* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "haskell", .complete = "run = let value = \"x\\n<&>\" in value -- comment", .incomplete = "-- incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "gleam", .complete = "pub fn run() { let value = \"x\\n<&>\" } // comment", .incomplete = "// incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "commonlisp", .complete = "(defun run () (let ((value \"x\\n<&>\")) value)) ; comment", .incomplete = "; incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "scheme", .complete = "(define (run) (let ((value \"x\\n<&>\")) value)) ; comment", .incomplete = "; incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "julia", .complete = "function run() value = \"x\\n<&>\"; end # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "elm", .complete = "run = let value = \"x\\n<&>\" in value -- comment", .incomplete = "-- incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "purescript", .complete = "run = let value = \"x\\n<&>\" in value -- comment", .incomplete = "-- incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "nim", .complete = "proc run() = let value = \"x\\n<&>\" # comment", .incomplete = "# incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
    };
    for (specs) |spec| {
        const cases = [_]Case{
            .{ .source = spec.complete, .native_scopes = spec.complete_scopes, .tree_captures = &.{} },
            .{ .source = "value = \"bad\\q<&>\nnext = true | false\n", .native_scopes = spec.malformed_scopes, .tree_captures = &.{} },
            .{ .source = spec.incomplete, .native_scopes = &.{.comment}, .tree_captures = &.{} },
        };
        try compareLanguage(spec.language, cases[0..]);
    }
}

test "native roadmap languages 75 through 88 remain compared with Tree-sitter" {
    const specs = [_]struct {
        language: []const u8,
        complete: []const u8,
        malformed: []const u8 = "value = \"bad\\q<&>\nnext = true | false\n",
        incomplete: []const u8,
        complete_scopes: []const native.Scope,
        malformed_scopes: []const native.Scope = &.{ .string, .escape, .operator },
        incomplete_scopes: []const native.Scope = &.{.comment},
    }{
        .{ .language = "d", .complete = "module demo; struct Item { string value = \"x\\n<&>\"; bool enabled = true; } // comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "v", .complete = "module main\nstruct Item { value string }\nvalue := \"x\\n<&>\" // comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "odin", .complete = "package main\nItem :: struct { value: string }\nvalue := \"x\\n<&>\" // comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "c3", .complete = "module demo; struct Item { string value; } string value = \"x\\n<&>\"; // comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "systemverilog", .complete = "module demo; string value = \"x\\n<&>\"; logic enabled = true; // comment\nendmodule", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "llvm", .complete = "@text = private constant [3 x i8] c\"x\\0A<&>\"\ndefine i32 @main() { ret i32 42 } ; comment", .incomplete = "; incomplete <&>", .complete_scopes = &.{ .keyword, .type, .string } },
        .{ .language = "openscad", .complete = "module demo() { value = \"x\\n<&>\"; enabled = true; } // comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "nickel", .complete = "let item = { value = \"x\\n<&>\", enabled = true } in item # comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "hare", .complete = "export fn main() void = { let value: str = \"x\\n<&>\"; }; // comment", .incomplete = "/* incomplete <&>", .complete_scopes = &.{ .keyword, .string } },
        .{ .language = "agda", .complete = "module Demo where\ndata Item : Set where\n  item : Item\ntext = \"x\\n<&>\" -- comment", .incomplete = "{- incomplete <&>", .complete_scopes = &.{ .keyword, .type, .string } },
        .{ .language = "query", .complete = "(function_definition name: (identifier) @function (#match? @function \"^x\\n<&>\")) ; comment", .incomplete = "; incomplete <&>", .complete_scopes = &.{ .keyword, .attribute, .string } },
        .{ .language = "vim", .complete = "function Demo()\n  let value = 'x\\n<&>'\n  let enabled = v:true\nendfunction\n\" comment", .malformed = "let value = 'bad\\q<&>\nlet enabled = v:true\n", .incomplete = "\" incomplete <&>", .complete_scopes = &.{ .keyword, .string }, .malformed_scopes = &.{ .string, .escape, .operator, .boolean } },
        .{ .language = "uxntal", .complete = "|0100 @main #2a #01 ADD \"x\\n\nBRK ( comment )", .incomplete = "( incomplete <&>", .complete_scopes = &.{ .keyword, .string }, .malformed_scopes = &.{ .string, .escape, .operator } },
        .{ .language = "comment", .complete = "TODO(alice): fix #42 at https://example.test", .malformed = "FIXME(unclosed <&>", .incomplete = "WIP(user", .complete_scopes = &.{ .special, .constant, .number, .string, .markup_link }, .malformed_scopes = &.{ .special, .constant, .punctuation }, .incomplete_scopes = &.{ .special, .constant, .punctuation } },
    };
    for (specs) |spec| {
        const cases = [_]Case{
            .{ .source = spec.complete, .native_scopes = spec.complete_scopes, .tree_captures = &.{} },
            .{ .source = spec.malformed, .native_scopes = spec.malformed_scopes, .tree_captures = &.{} },
            .{ .source = spec.incomplete, .native_scopes = spec.incomplete_scopes, .tree_captures = &.{} },
        };
        try compareLanguage(spec.language, cases[0..]);
    }
}

fn compareLanguage(language: []const u8, cases: []const Case) !void {
    var query_cache = try syntax.QueryCache.create(std.testing.io, std.testing.allocator, .{});
    defer query_cache.deinit();
    for (cases, 0..) |case, index| {
        try expectNativeScopes(language, case.source, case.native_scopes);
        const tree = try createTree(language, case.source, query_cache);
        defer tree.destroy();
        const capture_count = try expectTreeCaptureRangesValid(tree, case.source.len);
        if (index == 0 and capture_count == 0) {
            std.debug.print("Tree-sitter produced no captures for {s}\n", .{language});
            return error.TestUnexpectedResult;
        }
    }
}

fn expectNativeScopes(
    language: []const u8,
    source: []const u8,
    expected: []const native.Scope,
) !void {
    const backend = if (std.mem.eql(u8, language, "diff"))
        native.languages.diff.backend
    else if (std.mem.eql(u8, language, "c"))
        native.languages.c.backend
    else if (std.mem.eql(u8, language, "javascript"))
        native.languages.javascript.backend
    else if (std.mem.eql(u8, language, "typescript"))
        native.languages.typescript.backend
    else if (std.mem.eql(u8, language, "yaml"))
        native.languages.yaml.backend
    else if (std.mem.eql(u8, language, "hcl"))
        native.languages.hcl.backend
    else if (std.mem.eql(u8, language, "make"))
        native.languages.make.backend
    else if (std.mem.eql(u8, language, "cmake"))
        native.languages.cmake.backend
    else if (std.mem.eql(u8, language, "d")) native.languages.d.backend else if (std.mem.eql(u8, language, "v")) native.languages.v.backend else if (std.mem.eql(u8, language, "odin")) native.languages.odin.backend else if (std.mem.eql(u8, language, "c3")) native.languages.c3.backend else if (std.mem.eql(u8, language, "systemverilog")) native.languages.systemverilog.backend else if (std.mem.eql(u8, language, "llvm")) native.languages.llvm.backend else if (std.mem.eql(u8, language, "openscad")) native.languages.openscad.backend else if (std.mem.eql(u8, language, "nickel")) native.languages.nickel.backend else if (std.mem.eql(u8, language, "hare")) native.languages.hare.backend else if (std.mem.eql(u8, language, "agda")) native.languages.agda.backend else if (std.mem.eql(u8, language, "query")) native.languages.query.backend else if (std.mem.eql(u8, language, "vim")) native.languages.vim.backend else if (std.mem.eql(u8, language, "uxntal")) native.languages.uxntal.backend else if (std.mem.eql(u8, language, "comment")) native.languages.comment.backend else if (std.mem.eql(u8, language, "kdl")) native.languages.kdl.backend else if (std.mem.eql(u8, language, "nix")) native.languages.nix.backend else if (std.mem.eql(u8, language, "fish")) native.languages.fish.backend else if (std.mem.eql(u8, language, "nu")) native.languages.nu.backend else if (std.mem.eql(u8, language, "awk")) native.languages.awk.backend else if (std.mem.eql(u8, language, "ssh-config")) native.languages.ssh_config.backend else if (std.mem.eql(u8, language, "gitcommit")) native.languages.gitcommit.backend else if (std.mem.eql(u8, language, "git-rebase")) native.languages.git_rebase.backend else if (std.mem.eql(u8, language, "po")) native.languages.po.backend else if (std.mem.eql(u8, language, "rst")) native.languages.rst.backend else if (std.mem.eql(u8, language, "latex")) native.languages.latex.backend else if (std.mem.eql(u8, language, "typst")) native.languages.typst.backend else if (std.mem.eql(u8, language, "org")) native.languages.org.backend else if (std.mem.eql(u8, language, "dtd")) native.languages.dtd.backend else if (std.mem.eql(u8, language, "mail")) native.languages.mail.backend else if (std.mem.eql(u8, language, "hurl")) native.languages.hurl.backend else if (std.mem.eql(u8, language, "ninja")) native.languages.ninja.backend else if (std.mem.eql(u8, language, "rpmspec")) native.languages.rpmspec.backend else if (std.mem.eql(u8, language, "rpmbash")) native.languages.rpmbash.backend else if (std.mem.eql(u8, language, "gdscript")) native.languages.gdscript.backend else if (std.mem.eql(u8, language, "perl")) native.languages.perl.backend else if (std.mem.eql(u8, language, "elixir")) native.languages.elixir.backend else if (std.mem.eql(u8, language, "fsharp")) native.languages.fsharp.backend else if (std.mem.eql(u8, language, "ocaml")) native.languages.ocaml.backend else if (std.mem.eql(u8, language, "haskell")) native.languages.haskell.backend else if (std.mem.eql(u8, language, "gleam")) native.languages.gleam.backend else if (std.mem.eql(u8, language, "commonlisp")) native.languages.commonlisp.backend else if (std.mem.eql(u8, language, "scheme")) native.languages.scheme.backend else if (std.mem.eql(u8, language, "julia")) native.languages.julia.backend else if (std.mem.eql(u8, language, "elm")) native.languages.elm.backend else if (std.mem.eql(u8, language, "purescript")) native.languages.purescript.backend else if (std.mem.eql(u8, language, "nim")) native.languages.nim.backend else if (std.mem.eql(u8, language, "java")) native.languages.java.backend else if (std.mem.eql(u8, language, "c-sharp")) native.languages.c_sharp.backend else if (std.mem.eql(u8, language, "cpp")) native.languages.cpp.backend else if (std.mem.eql(u8, language, "go")) native.languages.go.backend else if (std.mem.eql(u8, language, "powershell")) native.languages.powershell.backend else if (std.mem.eql(u8, language, "php")) native.languages.php.backend else if (std.mem.eql(u8, language, "lua")) native.languages.lua.backend else if (std.mem.eql(u8, language, "kotlin")) native.languages.kotlin.backend else if (std.mem.eql(u8, language, "ruby")) native.languages.ruby.backend else if (std.mem.eql(u8, language, "swift")) native.languages.swift.backend else if (std.mem.eql(u8, language, "asm")) native.languages.assembly.backend else if (std.mem.eql(u8, language, "nasm")) native.languages.nasm.backend else if (std.mem.eql(u8, language, "objc")) native.languages.objc.backend else if (std.mem.eql(u8, language, "vue")) native.languages.vue.backend else if (std.mem.eql(u8, language, "astro")) native.languages.astro.backend else if (std.mem.eql(u8, language, "jsdoc")) native.languages.jsdoc.backend else if (std.mem.eql(u8, language, "regex")) native.languages.regex.backend else if (std.mem.eql(u8, language, "proto")) native.languages.proto.backend else if (std.mem.eql(u8, language, "toml"))
        native.languages.toml.backend
    else if (std.mem.eql(u8, language, "dockerfile"))
        native.languages.dockerfile.backend
    else if (std.mem.eql(u8, language, "python"))
        native.languages.python.backend
    else if (std.mem.eql(u8, language, "sql"))
        native.languages.sql.backend
    else
        return error.UnknownNativeComparisonLanguage;
    var sink: native.CaptureSink = .init(std.testing.allocator, source.len);
    defer sink.deinit();
    try backend.highlight(source, &sink);
    for (expected) |scope| {
        if (!hasNativeScope(sink.captures(), scope)) {
            std.debug.print("Native highlighter produced no {s} scope for {s}\n", .{ @tagName(scope), language });
            return error.TestUnexpectedResult;
        }
    }
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
