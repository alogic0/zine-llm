const std = @import("std");
const core = @import("native_syntax");

pub fn backendFor(name: []const u8) ?core.Backend {
    if (std.mem.eql(u8, name, "bash") or
        std.mem.eql(u8, name, "sh") or
        std.mem.eql(u8, name, "shell"))
    {
        return core.languages.bash.backend;
    }
    if (std.mem.eql(u8, name, "rust")) return core.languages.rust.backend;
    if (std.mem.eql(u8, name, "zig")) return core.languages.zig.backend;
    if (std.mem.eql(u8, name, "ziggy")) return @import("native_syntax_ziggy").backend;
    if (std.mem.eql(u8, name, "ziggy-schema")) return @import("native_syntax_ziggy_schema").backend;
    if (std.mem.eql(u8, name, "scripty")) return @import("native_syntax_scripty").backend;
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
        "bash",
        "rust",
        "zig",
        "ziggy",
        "ziggy-schema",
        "scripty",
        "html",
        "xml",
        "css",
        "superhtml",
        "markdown",
    };
    for (native_languages) |language| {
        try std.testing.expect(backendFor(language) != null);
    }

    try std.testing.expectEqual(null, backendFor("python"));
    try std.testing.expectEqual(null, backendFor("shtml"));
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
        "python",
        "def main(): pass",
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
