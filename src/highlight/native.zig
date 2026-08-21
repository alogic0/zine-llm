const std = @import("std");
const core = @import("native_syntax");

pub fn backendFor(name: []const u8) ?core.Backend {
    if (std.mem.eql(u8, name, "zig")) return core.languages.zig.backend;
    if (std.mem.eql(u8, name, "ziggy")) return @import("native_syntax_ziggy").backend;
    if (std.mem.eql(u8, name, "ziggy-schema")) return @import("native_syntax_ziggy_schema").backend;
    if (std.mem.eql(u8, name, "scripty")) return @import("native_syntax_scripty").backend;
    if (std.mem.eql(u8, name, "html")) return @import("native_syntax_html").backend;
    if (std.mem.eql(u8, name, "xml")) return @import("native_syntax_xml").backend;
    if (std.mem.eql(u8, name, "css")) return @import("native_syntax_css").backend;
    if (std.mem.eql(u8, name, "superhtml")) return @import("native_syntax_superhtml").backend;
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
        "zig",
        "ziggy",
        "ziggy-schema",
        "scripty",
        "html",
        "xml",
        "css",
        "superhtml",
    };
    for (native_languages) |language| {
        try std.testing.expect(backendFor(language) != null);
    }

    try std.testing.expectEqual(null, backendFor("rust"));
    try std.testing.expectEqual(null, backendFor("bash"));
    try std.testing.expectEqual(null, backendFor("shtml"));
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
        "rust",
        "fn main() {}",
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
