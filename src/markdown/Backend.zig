//! Temporary compile-time boundary between the cmark and pure-Zig Markdown
//! implementations. Phase 7 removes this module after the Zig backend becomes
//! authoritative.

const std = @import("std");
const options = @import("options");
const supermd = @import("supermd");
const Semantic = @import("Semantic.zig");

pub const selected = options.markdown_parser;
pub const is_zig = selected == .zig;

pub const Ast = if (is_zig) Semantic.Ast else supermd.Ast;
pub const Node = if (is_zig) Semantic.Node else supermd.Node;
pub const Iter = if (is_zig) Semantic.Markdown.Iter else supermd.Ast.Iter;
pub const Error = if (is_zig) Semantic.Error else supermd.Ast.Error;
pub const Directive = supermd.Directive;

pub fn root(ast: *const Ast) Node {
    return if (is_zig) ast.root() else ast.md.root;
}

pub fn eql(a: Node, b: Node) bool {
    return a.eql(b);
}

test "selected Markdown backend has the compatibility boundary" {
    if (is_zig) {
        try std.testing.expect(Ast == Semantic.Ast);
        try std.testing.expect(Node == Semantic.Node);
    } else {
        try std.testing.expect(Ast == supermd.Ast);
        try std.testing.expect(Node == supermd.Node);
    }
}
