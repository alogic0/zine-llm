const std = @import("std");

pub const Mode = enum {
    off,
    @"tree-sitter",
    @"native-first",
    @"native-only",

    pub fn usesNative(self: Mode) bool {
        return switch (self) {
            .@"native-first", .@"native-only" => true,
            .off, .@"tree-sitter" => false,
        };
    }

    pub fn usesTreeSitter(self: Mode) bool {
        return switch (self) {
            .@"tree-sitter", .@"native-first" => true,
            .off, .@"native-only" => false,
        };
    }

    pub fn selection(self: Mode, native_available: bool) Selection {
        if (self.usesNative() and native_available) return .native;
        if (self.usesTreeSitter()) return .tree_sitter;
        return .plain;
    }
};

pub const Selection = enum {
    plain,
    native,
    tree_sitter,
};

test "highlight modes select only their configured backends" {
    try std.testing.expectEqual(Selection.plain, Mode.off.selection(false));
    try std.testing.expectEqual(Selection.plain, Mode.off.selection(true));

    try std.testing.expectEqual(Selection.tree_sitter, Mode.@"tree-sitter".selection(false));
    try std.testing.expectEqual(Selection.tree_sitter, Mode.@"tree-sitter".selection(true));

    try std.testing.expectEqual(Selection.tree_sitter, Mode.@"native-first".selection(false));
    try std.testing.expectEqual(Selection.native, Mode.@"native-first".selection(true));

    try std.testing.expectEqual(Selection.plain, Mode.@"native-only".selection(false));
    try std.testing.expectEqual(Selection.native, Mode.@"native-only".selection(true));
}
