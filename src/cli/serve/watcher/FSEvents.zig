//! Minimal Zig bindings for the CoreFoundation and FSEvents APIs used by Zine.
//!
//! CoreServices is loaded dynamically so cross-compiling Zine does not require
//! Apple headers, translated C declarations, or a framework SDK bundle.

const std = @import("std");
const builtin = @import("builtin");

pub const Api = struct {
    core_services: std.DynLib,
    symbols: Symbols,

    pub fn init() (std.DynLib.Error || error{MissingCoreServicesSymbol})!Api {
        var core_services = try std.DynLib.open(
            "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        );
        errdefer core_services.close();

        var symbols: Symbols = undefined;
        const symbols_info = @typeInfo(Symbols).@"struct";
        inline for (symbols_info.field_names, symbols_info.field_types) |field_name, field_type| {
            @field(symbols, field_name) = core_services.lookup(
                field_type,
                field_name,
            ) orelse return error.MissingCoreServicesSymbol;
        }

        return .{
            .core_services = core_services,
            .symbols = symbols,
        };
    }

    pub fn deinit(api: *Api) void {
        api.core_services.close();
    }
};

pub const CFAllocatorRef = ?*const opaque {};
pub const CFArrayRef = *const opaque {};
pub const CFStringRef = *const opaque {};
pub const CFRunLoopRef = *opaque {};
pub const CFTimeInterval = f64;
pub const CFIndex = c_long;
pub const CFStringEncoding = enum(u32) {
    utf8 = 0x08000100,
};

const CFAllocatorRetainCallBack = *const fn (
    info: ?*const anyopaque,
) callconv(.c) *const anyopaque;
const CFAllocatorReleaseCallBack = *const fn (
    info: ?*const anyopaque,
) callconv(.c) void;
const CFAllocatorCopyDescriptionCallBack = *const fn (
    info: ?*const anyopaque,
) callconv(.c) CFStringRef;

pub const FSEventStreamRef = *opaque {};
pub const ConstFSEventStreamRef = *const @typeInfo(FSEventStreamRef).pointer.child;
pub const FSEventStreamEventId = u64;
pub const FSEventStreamEventFlags = u32;
pub const FSEventStreamCreateFlags = u32;

pub const event_id_since_now = std.math.maxInt(FSEventStreamEventId);
pub const create_flag_file_events: FSEventStreamCreateFlags = 0x00000010;

pub const FSEventStreamCallback = *const fn (
    stream: ConstFSEventStreamRef,
    client_callback_info: ?*anyopaque,
    num_events: usize,
    event_paths: *anyopaque,
    event_flags: [*]const FSEventStreamEventFlags,
    event_ids: [*]const FSEventStreamEventId,
) callconv(.c) void;

pub const FSEventStreamContext = extern struct {
    version: CFIndex,
    info: ?*anyopaque,
    retain: ?CFAllocatorRetainCallBack,
    release: ?CFAllocatorReleaseCallBack,
    copy_description: ?CFAllocatorCopyDescriptionCallBack,
};

pub const Symbols = struct {
    CFStringCreateWithCString: *const fn (
        allocator: CFAllocatorRef,
        c_string: [*:0]const u8,
        encoding: CFStringEncoding,
    ) callconv(.c) ?CFStringRef,
    CFArrayCreate: *const fn (
        allocator: CFAllocatorRef,
        values: [*]const usize,
        num_values: CFIndex,
        callbacks: ?*const opaque {},
    ) callconv(.c) ?CFArrayRef,
    CFRelease: *const fn (value: *const anyopaque) callconv(.c) void,
    CFRunLoopGetCurrent: *const fn () callconv(.c) CFRunLoopRef,
    CFRunLoopRun: *const fn () callconv(.c) void,
    kCFRunLoopDefaultMode: *const CFStringRef,
    FSEventStreamCreate: *const fn (
        allocator: CFAllocatorRef,
        callback: FSEventStreamCallback,
        context: ?*const FSEventStreamContext,
        paths_to_watch: CFArrayRef,
        since_when: FSEventStreamEventId,
        latency: CFTimeInterval,
        flags: FSEventStreamCreateFlags,
    ) callconv(.c) ?FSEventStreamRef,
    FSEventStreamScheduleWithRunLoop: *const fn (
        stream: FSEventStreamRef,
        run_loop: CFRunLoopRef,
        run_loop_mode: CFStringRef,
    ) callconv(.c) void,
    FSEventStreamStart: *const fn (stream: FSEventStreamRef) callconv(.c) u8,
    FSEventStreamStop: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    FSEventStreamInvalidate: *const fn (stream: FSEventStreamRef) callconv(.c) void,
    FSEventStreamRelease: *const fn (stream: FSEventStreamRef) callconv(.c) void,
};

test "FSEventStreamContext matches the 64-bit macOS ABI" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 40), @sizeOf(FSEventStreamContext));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(FSEventStreamContext));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(FSEventStreamContext, "version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(FSEventStreamContext, "info"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(FSEventStreamContext, "retain"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(FSEventStreamContext, "release"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(FSEventStreamContext, "copy_description"));
}

test "CoreServices exports every required symbol" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    var api = try Api.init();
    defer api.deinit();
}
