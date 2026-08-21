const std = @import("std");
const core = @import("native_syntax");

pub fn backendFor(name: []const u8) ?core.Backend {
    if (std.mem.eql(u8, name, "asm") or std.mem.eql(u8, name, "assembly")) return core.languages.assembly.backend;
    if (std.mem.eql(u8, name, "astro")) return core.languages.astro.backend;
    if (std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "sh") or
        std.mem.eql(u8, name, "shell"))
    {
        return core.languages.bash.backend;
    }
    if (std.mem.eql(u8, name, "c") or std.mem.eql(u8, name, "glsl")) return core.languages.c.backend;
    if (std.mem.eql(u8, name, "cmake")) return core.languages.cmake.backend;
    if (std.mem.eql(u8, name, "c-sharp") or std.mem.eql(u8, name, "cs") or std.mem.eql(u8, name, "csharp")) return core.languages.c_sharp.backend;
    if (std.mem.eql(u8, name, "cpp") or std.mem.eql(u8, name, "c++")) return core.languages.cpp.backend;
    if (std.mem.eql(u8, name, "diff") or std.mem.eql(u8, name, "patch")) {
        return core.languages.diff.backend;
    }
    if (std.mem.eql(u8, name, "dockerfile")) return core.languages.dockerfile.backend;
    if (std.mem.eql(u8, name, "go")) return core.languages.go.backend;
    if (std.mem.eql(u8, name, "hcl")) return core.languages.hcl.backend;
    if (std.mem.eql(u8, name, "json")) return core.languages.json.backend;
    if (std.mem.eql(u8, name, "javascript") or std.mem.eql(u8, name, "js")) {
        return core.languages.javascript.backend;
    }
    if (std.mem.eql(u8, name, "java")) return core.languages.java.backend;
    if (std.mem.eql(u8, name, "jsdoc")) return core.languages.jsdoc.backend;
    if (std.mem.eql(u8, name, "kotlin") or std.mem.eql(u8, name, "kt")) return core.languages.kotlin.backend;
    if (std.mem.eql(u8, name, "lua")) return core.languages.lua.backend;
    if (std.mem.eql(u8, name, "make")) return core.languages.make.backend;
    if (std.mem.eql(u8, name, "nasm")) return core.languages.nasm.backend;
    if (std.mem.eql(u8, name, "objc") or std.mem.eql(u8, name, "objective-c")) return core.languages.objc.backend;
    if (std.mem.eql(u8, name, "php")) return core.languages.php.backend;
    if (std.mem.eql(u8, name, "powershell")) return core.languages.powershell.backend;
    if (std.mem.eql(u8, name, "proto") or std.mem.eql(u8, name, "protobuf")) return core.languages.proto.backend;
    if (std.mem.eql(u8, name, "python")) return core.languages.python.backend;
    if (std.mem.eql(u8, name, "regex")) return core.languages.regex.backend;
    if (std.mem.eql(u8, name, "rust")) return core.languages.rust.backend;
    if (std.mem.eql(u8, name, "ruby") or std.mem.eql(u8, name, "rb")) return core.languages.ruby.backend;
    if (std.mem.eql(u8, name, "toml")) return core.languages.toml.backend;
    if (std.mem.eql(u8, name, "swift")) return core.languages.swift.backend;
    if (std.mem.eql(u8, name, "typescript") or std.mem.eql(u8, name, "ts")) {
        return core.languages.typescript.backend;
    }
    if (std.mem.eql(u8, name, "yaml") or std.mem.eql(u8, name, "yml")) {
        return core.languages.yaml.backend;
    }
    if (std.mem.eql(u8, name, "vue")) return core.languages.vue.backend;
    if (std.mem.eql(u8, name, "zig")) return core.languages.zig.backend;
    if (std.mem.eql(u8, name, "ziggy")) return @import("native_syntax_ziggy").backend;
    if (std.mem.eql(u8, name, "ziggy-schema")) return @import("native_syntax_ziggy_schema").backend;
    if (std.mem.eql(u8, name, "scripty")) return @import("native_syntax_scripty").backend;
    if (std.mem.eql(u8, name, "sql")) return core.languages.sql.backend;
    if (std.mem.eql(u8, name, "html")) return @import("native_syntax_html").backend;
    if (std.mem.eql(u8, name, "xml")) return @import("native_syntax_xml").backend;
    if (std.mem.eql(u8, name, "css")) return @import("native_syntax_css").backend;
    if (std.mem.eql(u8, name, "superhtml")) return @import("native_syntax_superhtml").backend;
    if (std.mem.eql(u8, name, "markdown") or
        std.mem.eql(u8, name, "md") or
        std.mem.eql(u8, name, "smd") or
        std.mem.eql(u8, name, "supermd"))
    {
        return @import("native_syntax_markdown").backend;
    }
    if (std.mem.eql(u8, name, "kdl")) return core.languages.kdl.backend;
    if (std.mem.eql(u8, name, "nix")) return core.languages.nix.backend;
    if (std.mem.eql(u8, name, "fish") or std.mem.eql(u8, name, "conf")) return core.languages.fish.backend;
    if (std.mem.eql(u8, name, "nu") or std.mem.eql(u8, name, "nushell")) return core.languages.nu.backend;
    if (std.mem.eql(u8, name, "awk")) return core.languages.awk.backend;
    if (std.mem.eql(u8, name, "ssh-config") or std.mem.eql(u8, name, "sshconfig")) return core.languages.ssh_config.backend;
    if (std.mem.eql(u8, name, "gitcommit") or std.mem.eql(u8, name, "git-commit")) return core.languages.gitcommit.backend;
    if (std.mem.eql(u8, name, "git-rebase") or std.mem.eql(u8, name, "gitrebase")) return core.languages.git_rebase.backend;
    if (std.mem.eql(u8, name, "po") or std.mem.eql(u8, name, "gettext")) return core.languages.po.backend;
    if (std.mem.eql(u8, name, "rst") or std.mem.eql(u8, name, "restructuredtext")) return core.languages.rst.backend;
    if (std.mem.eql(u8, name, "latex") or std.mem.eql(u8, name, "tex")) return core.languages.latex.backend;
    if (std.mem.eql(u8, name, "typst")) return core.languages.typst.backend;
    if (std.mem.eql(u8, name, "org") or std.mem.eql(u8, name, "orgmode")) return core.languages.org.backend;
    if (std.mem.eql(u8, name, "dtd")) return core.languages.dtd.backend;
    if (std.mem.eql(u8, name, "mail") or std.mem.eql(u8, name, "email")) return core.languages.mail.backend;
    if (std.mem.eql(u8, name, "hurl")) return core.languages.hurl.backend;
    if (std.mem.eql(u8, name, "ninja")) return core.languages.ninja.backend;
    if (std.mem.eql(u8, name, "rpmspec") or std.mem.eql(u8, name, "rpm-spec")) return core.languages.rpmspec.backend;
    if (std.mem.eql(u8, name, "rpmbash") or std.mem.eql(u8, name, "rpm-bash")) return core.languages.rpmbash.backend;
    if (std.mem.eql(u8, name, "gdscript")) return core.languages.gdscript.backend;
    if (std.mem.eql(u8, name, "perl")) return core.languages.perl.backend;
    if (std.mem.eql(u8, name, "elixir")) return core.languages.elixir.backend;
    if (std.mem.eql(u8, name, "fsharp") or std.mem.eql(u8, name, "f#")) return core.languages.fsharp.backend;
    if (std.mem.eql(u8, name, "ocaml")) return core.languages.ocaml.backend;
    if (std.mem.eql(u8, name, "haskell")) return core.languages.haskell.backend;
    if (std.mem.eql(u8, name, "gleam")) return core.languages.gleam.backend;
    if (std.mem.eql(u8, name, "commonlisp") or std.mem.eql(u8, name, "lisp")) return core.languages.commonlisp.backend;
    if (std.mem.eql(u8, name, "scheme")) return core.languages.scheme.backend;
    if (std.mem.eql(u8, name, "julia")) return core.languages.julia.backend;
    if (std.mem.eql(u8, name, "elm")) return core.languages.elm.backend;
    if (std.mem.eql(u8, name, "purescript") or std.mem.eql(u8, name, "purs")) return core.languages.purescript.backend;
    if (std.mem.eql(u8, name, "nim")) return core.languages.nim.backend;
    if (std.mem.eql(u8, name, "d") or std.mem.eql(u8, name, "dlang")) return core.languages.d.backend;
    if (std.mem.eql(u8, name, "v") or std.mem.eql(u8, name, "vlang")) return core.languages.v.backend;
    if (std.mem.eql(u8, name, "odin")) return core.languages.odin.backend;
    if (std.mem.eql(u8, name, "c3")) return core.languages.c3.backend;
    if (std.mem.eql(u8, name, "systemverilog") or std.mem.eql(u8, name, "system-verilog") or std.mem.eql(u8, name, "sv")) return core.languages.systemverilog.backend;
    if (std.mem.eql(u8, name, "llvm") or std.mem.eql(u8, name, "llvm-ir") or std.mem.eql(u8, name, "ll")) return core.languages.llvm.backend;
    if (std.mem.eql(u8, name, "openscad") or std.mem.eql(u8, name, "scad")) return core.languages.openscad.backend;
    if (std.mem.eql(u8, name, "nickel")) return core.languages.nickel.backend;
    if (std.mem.eql(u8, name, "hare")) return core.languages.hare.backend;
    if (std.mem.eql(u8, name, "agda")) return core.languages.agda.backend;
    if (std.mem.eql(u8, name, "query") or std.mem.eql(u8, name, "tree-sitter-query") or std.mem.eql(u8, name, "tsquery")) return core.languages.query.backend;
    if (std.mem.eql(u8, name, "vim") or std.mem.eql(u8, name, "vimscript")) return core.languages.vim.backend;
    if (std.mem.eql(u8, name, "uxntal")) return core.languages.uxntal.backend;
    if (std.mem.eql(u8, name, "comment") or std.mem.eql(u8, name, "comment-tags")) return core.languages.comment.backend;
    if (std.mem.eql(u8, name, "nimble")) return core.languages.toml.backend;
    if (std.mem.eql(u8, name, "csproj") or std.mem.eql(u8, name, "props")) return @import("native_syntax_xml").backend;
    if (std.mem.eql(u8, name, "markdown-inline")) return @import("native_syntax_markdown").backend;
    return null;
}

pub fn render(
    allocator: std.mem.Allocator,
    language: []const u8,
    source: []const u8,
    writer: *std.Io.Writer,
) (core.HighlightError || core.html.RenderError)!bool {
    const backend = backendFor(language) orelse return false;

    var sink: core.CaptureSink = .init(allocator, source.len);
    defer sink.deinit();
    try backend.highlight(source, &sink);
    try core.html.render(source, sink.captures(), allocator, writer);
    return true;
}

test "only completed canonical languages use native backends" {
    const native_languages = [_][]const u8{
        "asm",
        "astro",
        "bash",
        "c",
        "cmake",
        "c-sharp",
        "cpp",
        "diff",
        "dockerfile",
        "go",
        "hcl",
        "json",
        "javascript",
        "java",
        "jsdoc",
        "kotlin",
        "lua",
        "make",
        "nasm",
        "objc",
        "php",
        "powershell",
        "proto",
        "regex",
        "ruby",
        "rust",
        "toml",
        "swift",
        "typescript",
        "yaml",
        "vue",
        "zig",
        "ziggy",
        "ziggy-schema",
        "scripty",
        "sql",
        "html",
        "xml",
        "css",
        "superhtml",
        "markdown",
        "python",
        "kdl",
        "nix",
        "fish",
        "nu",
        "awk",
        "ssh-config",
        "gitcommit",
        "git-rebase",
        "po",
        "rst",
        "latex",
        "typst",
        "org",
        "dtd",
        "mail",
        "hurl",
        "ninja",
        "rpmspec",
        "rpmbash",
        "gdscript",
        "perl",
        "elixir",
        "fsharp",
        "ocaml",
        "haskell",
        "gleam",
        "commonlisp",
        "scheme",
        "julia",
        "elm",
        "purescript",
        "nim",
        "d",
        "v",
        "odin",
        "c3",
        "systemverilog",
        "llvm",
        "openscad",
        "nickel",
        "hare",
        "agda",
        "query",
        "vim",
        "uxntal",
        "comment",
    };
    for (native_languages) |language| {
        try std.testing.expect(backendFor(language) != null);
    }

    try std.testing.expectEqual(null, backendFor("shtml"));
}

test "every former Flow file type has a native route" {
    const flow_file_types = [_][]const u8{
        "agda",
        "asm",
        "astro",
        "awk",
        "bash",
        "c",
        "c3",
        "c-sharp",
        "comment",
        "conf",
        "cmake",
        "cpp",
        "csproj",
        "css",
        "d",
        "diff",
        "dockerfile",
        "dtd",
        "elixir",
        "elm",
        "fish",
        "fsharp",
        "gdscript",
        "git-rebase",
        "gitcommit",
        "gleam",
        "glsl",
        "go",
        "hare",
        "haskell",
        "hcl",
        "html",
        "superhtml",
        "hurl",
        "java",
        "javascript",
        "jsdoc",
        "json",
        "julia",
        "kdl",
        "kotlin",
        "latex",
        "commonlisp",
        "llvm",
        "lua",
        "mail",
        "make",
        "markdown",
        "markdown-inline",
        "nasm",
        "nickel",
        "nim",
        "nimble",
        "ninja",
        "nix",
        "nu",
        "objc",
        "ocaml",
        "odin",
        "openscad",
        "org",
        "perl",
        "php",
        "po",
        "powershell",
        "props",
        "proto",
        "purescript",
        "python",
        "regex",
        "rpmbash",
        "rpmspec",
        "rst",
        "ruby",
        "rust",
        "query",
        "scheme",
        "sql",
        "ssh-config",
        "swift",
        "systemverilog",
        "toml",
        "typescript",
        "typst",
        "uxntal",
        "v",
        "vim",
        "vue",
        "xml",
        "yaml",
        "zig",
        "ziggy",
        "ziggy-schema",
    };

    for (flow_file_types) |file_type| {
        try std.testing.expect(backendFor(file_type) != null);
    }
}

test "Zine-owned yml alias shares the native YAML backend" {
    const canonical = backendFor("yaml").?;
    const aliased = backendFor("yml").?;
    try std.testing.expectEqualStrings(canonical.info.canonical_name, aliased.info.canonical_name);
    try std.testing.expectEqual(core.BackendKind.lexical, aliased.info.kind);
}

test "Zine-owned roadmap aliases share their canonical native backends" {
    const aliases = [_]struct { alias: []const u8, canonical: []const u8 }{
        .{ .alias = "cs", .canonical = "c-sharp" },
        .{ .alias = "csharp", .canonical = "c-sharp" },
        .{ .alias = "c++", .canonical = "cpp" },
        .{ .alias = "kt", .canonical = "kotlin" },
        .{ .alias = "rb", .canonical = "ruby" },
        .{ .alias = "assembly", .canonical = "asm" },
        .{ .alias = "objective-c", .canonical = "objc" },
        .{ .alias = "protobuf", .canonical = "proto" },
        .{ .alias = "nushell", .canonical = "nu" },
        .{ .alias = "sshconfig", .canonical = "ssh-config" },
        .{ .alias = "git-commit", .canonical = "gitcommit" },
        .{ .alias = "gitrebase", .canonical = "git-rebase" },
        .{ .alias = "gettext", .canonical = "po" },
        .{ .alias = "restructuredtext", .canonical = "rst" },
        .{ .alias = "tex", .canonical = "latex" },
        .{ .alias = "orgmode", .canonical = "org" },
        .{ .alias = "email", .canonical = "mail" },
        .{ .alias = "rpm-spec", .canonical = "rpmspec" },
        .{ .alias = "rpm-bash", .canonical = "rpmbash" },
        .{ .alias = "f#", .canonical = "fsharp" },
        .{ .alias = "lisp", .canonical = "commonlisp" },
        .{ .alias = "purs", .canonical = "purescript" },
        .{ .alias = "dlang", .canonical = "d" },
        .{ .alias = "vlang", .canonical = "v" },
        .{ .alias = "system-verilog", .canonical = "systemverilog" },
        .{ .alias = "sv", .canonical = "systemverilog" },
        .{ .alias = "llvm-ir", .canonical = "llvm" },
        .{ .alias = "ll", .canonical = "llvm" },
        .{ .alias = "scad", .canonical = "openscad" },
        .{ .alias = "tree-sitter-query", .canonical = "query" },
        .{ .alias = "tsquery", .canonical = "query" },
        .{ .alias = "vimscript", .canonical = "vim" },
        .{ .alias = "comment-tags", .canonical = "comment" },
        .{ .alias = "conf", .canonical = "fish" },
        .{ .alias = "glsl", .canonical = "c" },
        .{ .alias = "nimble", .canonical = "toml" },
        .{ .alias = "csproj", .canonical = "xml" },
        .{ .alias = "props", .canonical = "xml" },
        .{ .alias = "markdown-inline", .canonical = "markdown" },
    };
    for (aliases) |entry| {
        try std.testing.expectEqualStrings(
            backendFor(entry.canonical).?.info.canonical_name,
            backendFor(entry.alias).?.info.canonical_name,
        );
    }
}

test "Zine-owned ts alias shares the native TypeScript backend" {
    const canonical = backendFor("typescript").?;
    const aliased = backendFor("ts").?;
    try std.testing.expectEqualStrings(canonical.info.canonical_name, aliased.info.canonical_name);
    try std.testing.expectEqual(core.BackendKind.lexical, aliased.info.kind);
}

test "Zine-owned js alias shares the native JavaScript backend" {
    const canonical = backendFor("javascript").?;
    const aliased = backendFor("js").?;
    try std.testing.expectEqualStrings(canonical.info.canonical_name, aliased.info.canonical_name);
    try std.testing.expectEqual(core.BackendKind.lexical, aliased.info.kind);
}

test "Zine-owned patch alias shares the native Diff backend" {
    const canonical = backendFor("diff").?;
    const aliased = backendFor("patch").?;
    try std.testing.expectEqualStrings(canonical.info.canonical_name, aliased.info.canonical_name);
    try std.testing.expectEqual(core.BackendKind.lexical, aliased.info.kind);
}

test "native JSON routing covers complete, malformed, and incomplete input" {
    const cases = [_]struct {
        source: []const u8,
        required_class: []const u8,
    }{
        .{
            .source = "{\"name\":\"Zine <&>\",\"enabled\":true,\"value\":1.5e2}",
            .required_class = "syntax-property",
        },
        .{
            .source = "{\"unicode\":\"\\u12<&>",
            .required_class = "syntax-escape",
        },
        .{
            .source = "[tru",
            .required_class = "syntax-boolean",
        },
    };

    for (cases) |case| {
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try std.testing.expect(try render(
            std.testing.allocator,
            "json",
            case.source,
            &output.writer,
        ));
        try std.testing.expect(std.mem.indexOf(u8, output.written(), case.required_class) != null);
        try std.testing.expect(std.mem.indexOf(u8, output.written(), "&lt;&amp;&gt;") != null or
            std.mem.indexOf(u8, case.source, "<&>") == null);
    }
}

test "Zine-owned Bash aliases share the native backend" {
    const canonical = backendFor("bash").?;
    for ([_][]const u8{ "sh", "shell" }) |alias| {
        const aliased = backendFor(alias).?;
        try std.testing.expectEqualStrings(canonical.info.canonical_name, aliased.info.canonical_name);
        try std.testing.expectEqual(core.BackendKind.lexical, aliased.info.kind);
    }
}

test "Zine-owned Markdown aliases share the native backend" {
    const canonical = backendFor("markdown").?;
    for ([_][]const u8{ "md", "smd", "supermd" }) |alias| {
        const aliased = backendFor(alias).?;
        try std.testing.expectEqualStrings(canonical.info.canonical_name, aliased.info.canonical_name);
        try std.testing.expectEqual(core.BackendKind.parser_backed, aliased.info.kind);
    }
}

test "native routing renders completed languages and declines fallback languages" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expect(try render(
        std.testing.allocator,
        "zig",
        "const answer = 42;",
        &output.writer,
    ));
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "syntax-keyword") != null);

    var fallback_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fallback_output.deinit();
    try std.testing.expect(!try render(
        std.testing.allocator,
        "shtml",
        "class Main {}",
        &fallback_output.writer,
    ));
    try std.testing.expectEqual(@as(usize, 0), fallback_output.written().len);
}

test "starter theme maps every stable native scope class" {
    const starter_theme = @import("native_highlight_test_options").starter_theme;
    for (std.enums.values(core.Scope)) |scope| {
        try std.testing.expect(std.mem.indexOf(u8, starter_theme, scope.cssClass()) != null);
    }
}
