const std = @import("std");

pub const Mode = enum {
    off,
    native,

    pub fn usesNative(self: Mode) bool {
        return switch (self) {
            .native => true,
            .off => false,
        };
    }

    pub fn selection(self: Mode, native_available: bool) Selection {
        if (self.usesNative() and native_available) return .native;
        return .plain;
    }
};

pub const Selection = enum {
    plain,
    native,
};

test "highlight modes select native or plain output" {
    try std.testing.expectEqual(Selection.plain, Mode.off.selection(false));
    try std.testing.expectEqual(Selection.plain, Mode.off.selection(true));

    try std.testing.expectEqual(Selection.plain, Mode.native.selection(false));
    try std.testing.expectEqual(Selection.native, Mode.native.selection(true));
}
