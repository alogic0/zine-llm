const MacosWatcher = @This();

const std = @import("std");
const Io = std.Io;
const fatal = @import("../../../fatal.zig");
const Debouncer = @import("../../serve.zig").Debouncer;
const fsevents = @import("FSEvents.zig");

const log = std.log.scoped(.watcher);

io: Io,
gpa: std.mem.Allocator,
debouncer: *Debouncer,
dir_paths: []const [:0]const u8,

pub fn init(
    io: Io,
    gpa: std.mem.Allocator,
    debouncer: *Debouncer,
    dir_paths: []const [:0]const u8,
) MacosWatcher {
    return .{
        .io = io,
        .gpa = gpa,
        .debouncer = debouncer,
        .dir_paths = dir_paths,
    };
}

pub fn start(watcher: *MacosWatcher) !void {
    const t = try std.Thread.spawn(.{}, MacosWatcher.listen, .{watcher});
    t.detach();
}

pub fn listen(watcher: *MacosWatcher) void {
    var api = fsevents.Api.init() catch |err| fatal.msg(
        "error: unable to load macOS FSEvents: {s}",
        .{@errorName(err)},
    );
    defer api.deinit();
    const c = api.symbols;

    const macos_paths = watcher.gpa.alloc(
        ?fsevents.CFStringRef,
        watcher.dir_paths.len,
    ) catch fatal.oom();
    defer watcher.gpa.free(macos_paths);
    @memset(macos_paths, null);
    defer for (macos_paths) |path| if (path) |value| c.CFRelease(value);

    for (watcher.dir_paths, macos_paths) |str, *ref| {
        ref.* = c.CFStringCreateWithCString(
            null,
            str.ptr,
            .utf8,
        ) orelse fatal.msg("error: unable to create macOS watch path", .{});
    }

    const paths_to_watch = c.CFArrayCreate(
        null,
        @ptrCast(macos_paths.ptr),
        @intCast(macos_paths.len),
        null,
    ) orelse fatal.msg("error: unable to create macOS watch path array", .{});
    defer c.CFRelease(paths_to_watch);

    var stream_context: fsevents.FSEventStreamContext = std.mem.zeroes(
        fsevents.FSEventStreamContext,
    );
    stream_context.info = watcher;
    const stream = c.FSEventStreamCreate(
        null,
        &macosCallback,
        &stream_context,
        paths_to_watch,
        fsevents.event_id_since_now,
        0.05,
        fsevents.create_flag_file_events,
    ) orelse fatal.msg("error: unable to create macOS FSEvent stream", .{});
    defer c.FSEventStreamRelease(stream);

    c.FSEventStreamScheduleWithRunLoop(
        stream,
        c.CFRunLoopGetCurrent(),
        c.kCFRunLoopDefaultMode.*,
    );

    if (c.FSEventStreamStart(stream) == 0) {
        fatal.msg("error: macos watcher FSEventStreamStart failed", .{});
    }

    c.CFRunLoopRun();

    c.FSEventStreamStop(stream);
    c.FSEventStreamInvalidate(stream);
}

pub fn macosCallback(
    streamRef: fsevents.ConstFSEventStreamRef,
    clientCallBackInfo: ?*anyopaque,
    numEvents: usize,
    eventPaths: *anyopaque,
    eventFlags: [*]const fsevents.FSEventStreamEventFlags,
    eventIds: [*]const fsevents.FSEventStreamEventId,
) callconv(.c) void {
    _ = eventIds;
    _ = eventFlags;
    _ = streamRef;
    const callback_info = clientCallBackInfo orelse return;
    const watcher: *MacosWatcher = @ptrCast(@alignCast(callback_info));

    const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(eventPaths));
    for (paths[0..numEvents]) |p| {
        const path = std.mem.span(p);
        log.debug("Changed: {s}\n", .{path});

        // const basename = std.fs.path.basename(path);
        // var base_path = path[0 .. path.len - basename.len];
        // if (std.mem.endsWith(u8, base_path, "/"))
        //     base_path = base_path[0 .. base_path.len - 1];
        watcher.debouncer.newEvent();
    }
}
