const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const markdown = @import("markdown.zig");
const Semantic = @import("markdown/Semantic.zig");
const fixtures = @import("fixtures");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const iterations = if (args.len > 1)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        50;
    if (iterations == 0) return error.InvalidIterations;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_state = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_state.interface;

    try out.print("markdown-benchmark-v1 iterations={}\n", .{iterations});
    for (fixtures.all) |fixture| {
        const syntax_allocations = try allocationProfileSyntax(fixture.source);
        const semantic_allocations = try allocationProfileSemantic(fixture.source);
        const syntax_ns = try timeSyntax(io, std.heap.page_allocator, fixture.source, iterations);
        const semantic_ns = try timeSemantic(io, std.heap.page_allocator, fixture.source, iterations);
        const render_ns = try timeRender(io, std.heap.page_allocator, fixture.source, iterations);
        const divisor: i96 = @intCast(iterations);

        try out.print(
            \\fixture {s} bytes={}
            \\  syntax_parse ns/op={} allocations={} requested_bytes={} peak_bytes={}
            \\  semantic_total ns/op={} allocations={} requested_bytes={} peak_bytes={}
            \\  semantic_overhead ns/op={}
            \\  html_render ns/op={}
            \\
        , .{
            fixture.name,
            fixture.source.len,
            @divTrunc(syntax_ns, divisor),
            syntax_allocations.allocations,
            syntax_allocations.requested,
            syntax_allocations.peak,
            @divTrunc(semantic_ns, divisor),
            semantic_allocations.allocations,
            semantic_allocations.requested,
            semantic_allocations.peak,
            @divTrunc(semantic_ns - syntax_ns, divisor),
            @divTrunc(render_ns, divisor),
        });
    }
    try out.flush();
}

fn timeSyntax(io: Io, gpa: Allocator, source: []const u8, iterations: usize) !i96 {
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        var parser = try markdown.Parser.init(gpa);
        defer parser.deinit();
        try parser.feed(source);
        var document = try parser.endInput();
        std.mem.doNotOptimizeAway(document.nodes.len);
        document.deinit(gpa);
    }
    return Io.Clock.awake.now(io).nanoseconds - start;
}

fn timeSemantic(io: Io, gpa: Allocator, source: []const u8, iterations: usize) !i96 {
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        var ast = try Semantic.Ast.init(gpa, source, .{});
        std.mem.doNotOptimizeAway(ast.ids.count());
        ast.deinit();
    }
    return Io.Clock.awake.now(io).nanoseconds - start;
}

fn timeRender(io: Io, gpa: Allocator, source: []const u8, iterations: usize) !i96 {
    var parser = try markdown.Parser.init(gpa);
    defer parser.deinit();
    try parser.feed(source);
    var document = try parser.endInput();
    defer document.deinit(gpa);

    var buffer: [4096]u8 = undefined;
    const start = Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        var discarding: Io.Writer.Discarding = .init(&buffer);
        try document.render(&discarding.writer);
        std.mem.doNotOptimizeAway(discarding.fullCount());
    }
    return Io.Clock.awake.now(io).nanoseconds - start;
}

const AllocationProfile = struct {
    allocations: usize,
    requested: usize,
    peak: usize,
};

fn allocationProfileSyntax(source: []const u8) !AllocationProfile {
    var tracking: TrackingAllocator = .init(std.heap.page_allocator);
    const gpa = tracking.allocator();
    var parser = try markdown.Parser.init(gpa);
    try parser.feed(source);
    var document = try parser.endInput();
    document.deinit(gpa);
    parser.deinit();
    std.debug.assert(tracking.current == 0);
    return tracking.profile();
}

fn allocationProfileSemantic(source: []const u8) !AllocationProfile {
    var tracking: TrackingAllocator = .init(std.heap.page_allocator);
    var ast = try Semantic.Ast.init(tracking.allocator(), source, .{});
    ast.deinit();
    std.debug.assert(tracking.current == 0);
    return tracking.profile();
}

const TrackingAllocator = struct {
    backing: Allocator,
    allocations: usize = 0,
    requested: usize = 0,
    current: usize = 0,
    peak: usize = 0,

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(backing: Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *TrackingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn profile(self: TrackingAllocator) AllocationProfile {
        return .{
            .allocations = self.allocations,
            .requested = self.requested,
            .peak = self.peak,
        };
    }

    fn recordGrowth(self: *TrackingAllocator, amount: usize) void {
        self.current += amount;
        self.requested += amount;
        self.peak = @max(self.peak, self.current);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocations += 1;
        self.recordGrowth(len);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.recordResize(memory.len, new_len);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.recordResize(memory.len, new_len);
        return result;
    }

    fn recordResize(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.recordGrowth(new_len - old_len);
        } else {
            self.current -= old_len - new_len;
        }
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.current -= memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};
