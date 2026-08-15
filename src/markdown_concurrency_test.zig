const std = @import("std");
const Semantic = @import("markdown/Semantic.zig");
const fixtures = @import("fixtures");

const thread_count = 8;
const iterations = 32;

test "semantic parsing has no shared mutable parser state" {
    var expected: [fixtures.all.len]u64 = undefined;
    for (fixtures.all, &expected) |fixture, *digest_value| {
        digest_value.* = try semanticDigest(std.testing.allocator, fixture.source);
    }

    var failed: std.atomic.Value(bool) = .init(false);
    const context: WorkerContext = .{
        .expected = expected,
        .failed = &failed,
    };
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer for (threads[0..spawned]) |thread| thread.join();

    for (&threads) |*thread| {
        thread.* = try .spawn(.{}, runWorker, .{&context});
        spawned += 1;
    }
    for (threads) |thread| thread.join();

    try std.testing.expect(!failed.load(.acquire));
}

const WorkerContext = struct {
    expected: [fixtures.all.len]u64,
    failed: *std.atomic.Value(bool),
};

fn runWorker(context: *const WorkerContext) void {
    var debug_allocator: std.heap.DebugAllocator(.{ .thread_safe = false }) = .init;
    const gpa = debug_allocator.allocator();

    for (0..iterations) |_| {
        for (fixtures.all, context.expected) |fixture, expected| {
            const actual = semanticDigest(gpa, fixture.source) catch {
                context.failed.store(true, .release);
                _ = debug_allocator.deinit();
                return;
            };
            if (actual != expected) {
                context.failed.store(true, .release);
                _ = debug_allocator.deinit();
                return;
            }
        }
    }

    if (debug_allocator.deinit() != .ok) context.failed.store(true, .release);
}

fn semanticDigest(gpa: std.mem.Allocator, source: []const u8) !u64 {
    var ast = try Semantic.Ast.init(gpa, source, .{});
    defer ast.deinit();

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try Semantic.writeSnapshot(ast, &output.writer);
    return std.hash.Wyhash.hash(0, output.written());
}
