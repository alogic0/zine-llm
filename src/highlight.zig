const std = @import("std");
const log = std.log.scoped(.highlight);
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const options = @import("options");
const tracy = @import("tracy");
const HtmlSafe = @import("superhtml").HtmlSafe;
const highlight_mode = options.highlight_mode;
const native = if (highlight_mode.usesNative())
    @import("highlight/native.zig")
else
    struct {};

pub fn run(
    io: Io,
    arena: Allocator,
    lang_name: []const u8,
    code: []const u8,
    w: *Writer,
) error{ OutOfMemory, WriteFailed, NoLanguage, Unknown }!void {
    const zone = tracy.traceNamed(@src(), "highlightCode");
    defer zone.end();
    tracy.messageCopy(lang_name);
    _ = io;

    if (comptime highlight_mode.usesNative()) {
        const handled_natively = native.render(arena, lang_name, code, w) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.WriteFailed,
            else => return error.Unknown,
        };
        if (handled_natively) return;
    }

    try w.print("{f}", .{HtmlSafe{ .bytes = code }});
}

pub fn runConsole(w: *Writer, source: []const u8) Writer.Error!void {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const prompt_end: ?usize = end: {
            if (line.len == 0) break :end null;
            switch (line[0]) {
                else => break :end null,
                '$', '#' => break :end 1,
                '[' => {},
            }
            const i = std.mem.findScalar(u8, line, ']') orelse break :end null;
            if (i == line.len - 1) break :end null;
            break :end switch (line[i + 1]) {
                '$', '#' => i + 2,
                else => null,
            };
        };
        if (prompt_end) |index| {
            try w.print("<span class=\"prompt\">{f}</span> <span class=\"command\">{f}</span>", .{
                @as(HtmlSafe, .{ .bytes = line[0..index] }),
                @as(HtmlSafe, .{ .bytes = std.mem.trim(u8, line[index..], &std.ascii.whitespace) }),
            });
        } else {
            try w.print("{f}", .{@as(HtmlSafe, .{ .bytes = line })});
        }
        if (it.index != null) try w.writeByte('\n');
    }
}

test "native mode renders unsupported languages as escaped plain text" {
    if (highlight_mode != .native) return error.SkipZigTest;

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try run(
        std.testing.io,
        std.testing.allocator,
        "shtml",
        "<tag>&",
        &out.writer,
    );

    try std.testing.expectEqualStrings("&lt;tag&gt;&amp;", out.written());
}

test "native mode routes completed native backends" {
    if (highlight_mode != .native) return error.SkipZigTest;

    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try run(
        std.testing.io,
        std.testing.allocator,
        "zig",
        "const answer = 42;",
        &out.writer,
    );

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "syntax-keyword") != null);
}
