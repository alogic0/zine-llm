//! Stable, Zine-facing handles over the compact Markdown `Document`.
//!
//! The parser owns compact syntax data. This facade adds stable node handles,
//! relations, ranges, and semantic sidecars without embedding SuperMD types in
//! the Markdown layer. Instantiate `Contract` with the semantic directive type
//! used by the caller.

const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown_parser = @import("markdown_parser");
const Document = markdown_parser.Document;
const Parser = markdown_parser.Parser;
const Source = markdown_parser.Source;

pub const Index = Document.Node.Index;

pub const Position = Source.Position;
pub const Range = Source.Range;

pub const Relation = struct {
    parent: ?Index = null,
    first_child: ?Index = null,
    last_child: ?Index = null,
    previous_sibling: ?Index = null,
    next_sibling: ?Index = null,
};

/// Names mirror the current SuperMD facade so downstream migration can remain
/// mechanical. Extension-only tags are included before their parser support is
/// added in later phases.
pub const NodeType = enum {
    NONE,
    DOCUMENT,
    BLOCK_QUOTE,
    LIST,
    ITEM,
    CODE_BLOCK,
    HTML_BLOCK,
    CUSTOM_BLOCK,
    PARAGRAPH,
    HEADING,
    THEMATIC_BREAK,
    FOOTNOTE_DEFINITION,
    TEXT,
    SOFTBREAK,
    LINEBREAK,
    CODE,
    HTML_INLINE,
    CUSTOM_INLINE,
    EMPH,
    STRONG,
    LINK,
    IMAGE,
    FOOTNOTE_REFERENCE,
    STRIKETHROUGH,
    TABLE,
    TABLE_ROW,
    TABLE_CELL,
};

pub fn Contract(comptime Directive: type) type {
    return struct {
        pub const Metadata = struct {
            range: Range = .unknown,
            directive: ?*Directive = null,
            title: ?[]const u8 = null,
            table_alignments: []const u8 = &.{},
            parent_footnote_definition: ?Index = null,
            footnote_definition_count: i32 = 0,
            footnote_reference_index: i32 = 0,
        };

        pub const Store = struct {
            document: Document,
            relations: []Relation,
            metadata: []Metadata,
            gpa: Allocator,
            arena: *std.heap.ArenaAllocator,

            pub fn allocator(store: *Store) Allocator {
                return store.arena.allocator();
            }

            fn syntaxTag(store: *const Store, index: Index) Document.Node.Tag {
                return store.document.nodes.items(.tag)[indexInt(index)];
            }

            fn syntaxData(store: *const Store, index: Index) Document.Node.Data {
                return store.document.nodes.items(.data)[indexInt(index)];
            }

            fn syntaxChildren(store: *const Store, index: Index) []const Index {
                const data = store.syntaxData(index);
                return switch (store.syntaxTag(index)) {
                    .root,
                    .table,
                    .table_row,
                    .blockquote,
                    .paragraph,
                    .strong,
                    .emphasis,
                    .strikethrough,
                    => store.document.extraChildren(data.container.children),
                    .list => store.document.extraChildren(data.list.children),
                    .list_item => store.document.extraChildren(data.list_item.children),
                    .table_cell => store.document.extraChildren(data.table_cell.children),
                    .heading => store.document.extraChildren(data.heading.children),
                    .link, .image => store.document.extraChildren(data.link.children),
                    .footnote_definition => store.document.extraChildren(data.footnote_definition.children),
                    .code_block,
                    .thematic_break,
                    .html_block,
                    .code_span,
                    .text,
                    .line_break,
                    .soft_break,
                    .html_inline,
                    .footnote_reference,
                    => &.{},
                };
            }

            fn buildRelations(store: *Store) void {
                for (store.relations) |*relation| relation.* = .{};

                for (0..store.relations.len) |parent_int| {
                    const parent: Index = @fromBackingInt(@intCast(parent_int));
                    const children = store.syntaxChildren(parent);
                    if (children.len == 0) continue;

                    store.relations[parent_int].first_child = children[0];
                    store.relations[parent_int].last_child = children[children.len - 1];
                    for (children, 0..) |child, child_offset| {
                        const child_int = indexInt(child);
                        std.debug.assert(store.relations[child_int].parent == null);
                        const child_relation = &store.relations[child_int];
                        child_relation.parent = parent;
                        child_relation.previous_sibling = if (child_offset == 0)
                            null
                        else
                            children[child_offset - 1];
                        child_relation.next_sibling = if (child_offset + 1 == children.len)
                            null
                        else
                            children[child_offset + 1];
                    }
                }
            }

            fn buildTableMetadata(store: *Store) !void {
                const arena_allocator = store.allocator();
                for (0..store.relations.len) |node_int| {
                    const table: Index = @fromBackingInt(@intCast(node_int));
                    if (store.syntaxTag(table) != .table) continue;

                    const row = store.relations[node_int].first_child orelse continue;
                    var cell = store.relations[indexInt(row)].first_child;
                    var column_count: usize = 0;
                    while (cell) |current| : (cell = store.relations[indexInt(current)].next_sibling) {
                        column_count += 1;
                    }

                    const alignments = try arena_allocator.alloc(u8, column_count);
                    cell = store.relations[indexInt(row)].first_child;
                    var column: usize = 0;
                    while (cell) |current| : (cell = store.relations[indexInt(current)].next_sibling) {
                        const data = store.syntaxData(current);
                        alignments[column] = switch (data.table_cell.info.alignment) {
                            .unset => 0,
                            .left => 'l',
                            .center => 'c',
                            .right => 'r',
                        };
                        column += 1;
                    }
                    store.metadata[node_int].table_alignments = alignments;
                }
            }

            fn node(store: *Store, index: Index) Node {
                return .{ .store = store, .index = index };
            }
        };

        pub const Ast = struct {
            store: *Store,

            /// Takes ownership of `document` on success. The document must have
            /// been allocated with `gpa`, which is retained for destruction.
            pub fn init(gpa: Allocator, document: *Document) !Ast {
                const arena = try gpa.create(std.heap.ArenaAllocator);
                errdefer gpa.destroy(arena);
                arena.* = .init(gpa);
                errdefer arena.deinit();

                const arena_allocator = arena.allocator();
                const store = try arena_allocator.create(Store);
                const relations = try arena_allocator.alloc(Relation, document.nodes.len);
                const metadata = try arena_allocator.alloc(Metadata, document.nodes.len);
                for (metadata, 0..) |*entry, node_int| entry.* = .{
                    .range = document.range(@fromBackingInt(@intCast(node_int))),
                };

                store.* = .{
                    .document = document.*,
                    .relations = relations,
                    .metadata = metadata,
                    .gpa = gpa,
                    .arena = arena,
                };
                store.buildRelations();
                try store.buildTableMetadata();

                document.* = undefined;
                return .{ .store = store };
            }

            pub fn deinit(ast: *Ast) void {
                const store = ast.store;
                const gpa = store.gpa;
                const arena = store.arena;
                store.document.deinit(gpa);
                arena.deinit();
                gpa.destroy(arena);
                ast.* = undefined;
            }

            pub fn allocator(ast: Ast) Allocator {
                return ast.store.allocator();
            }

            pub fn root(ast: Ast) Node {
                return ast.store.node(.root);
            }

            pub fn node(ast: Ast, index: Index) Node {
                std.debug.assert(indexInt(index) < ast.store.relations.len);
                return ast.store.node(index);
            }
        };

        pub const Node = struct {
            store: *Store,
            index: Index,

            pub const ListType = enum { ul, ol };

            pub fn eql(node: Node, other: Node) bool {
                return node.store == other.store and node.index == other.index;
            }

            pub fn range(node: Node) Range {
                return node.store.metadata[indexInt(node.index)].range;
            }

            pub fn setRange(node: Node, new_range: Range) void {
                node.store.metadata[indexInt(node.index)].range = new_range;
            }

            pub fn nodeType(node: Node) NodeType {
                return switch (node.store.syntaxTag(node.index)) {
                    .root => .DOCUMENT,
                    .list => .LIST,
                    .list_item => .ITEM,
                    .table => .TABLE,
                    .table_row => .TABLE_ROW,
                    .table_cell => .TABLE_CELL,
                    .heading => .HEADING,
                    .code_block => .CODE_BLOCK,
                    .blockquote => .BLOCK_QUOTE,
                    .paragraph => .PARAGRAPH,
                    .thematic_break => .THEMATIC_BREAK,
                    .html_block => .HTML_BLOCK,
                    .footnote_definition => .FOOTNOTE_DEFINITION,
                    .link => .LINK,
                    .image => .IMAGE,
                    .strong => .STRONG,
                    .emphasis => .EMPH,
                    .strikethrough => .STRIKETHROUGH,
                    .code_span => .CODE,
                    .text => .TEXT,
                    .line_break => .LINEBREAK,
                    .soft_break => .SOFTBREAK,
                    .html_inline => .HTML_INLINE,
                    .footnote_reference => .FOOTNOTE_REFERENCE,
                };
            }

            pub fn literal(node: Node) ?[]const u8 {
                const data = node.store.syntaxData(node.index);
                return switch (node.store.syntaxTag(node.index)) {
                    .code_span, .text, .html_inline, .html_block, .footnote_reference => node.store.document.string(data.text.content),
                    .code_block => node.store.document.string(data.code_block.content),
                    else => null,
                };
            }

            pub fn link(node: Node) ?[]const u8 {
                const data = node.store.syntaxData(node.index);
                return switch (node.store.syntaxTag(node.index)) {
                    .link, .image => node.store.document.string(data.link.target),
                    else => null,
                };
            }

            pub fn footnoteLabel(node: Node) ?[]const u8 {
                const data = node.store.syntaxData(node.index);
                return switch (node.store.syntaxTag(node.index)) {
                    .footnote_definition => node.store.document.string(data.footnote_definition.label),
                    .footnote_reference => node.store.document.string(data.text.content),
                    else => null,
                };
            }

            pub fn title(node: Node) ?[]const u8 {
                return node.store.metadata[indexInt(node.index)].title;
            }

            pub fn setTitle(node: Node, value: ?[]const u8) void {
                node.store.metadata[indexInt(node.index)].title = value;
            }

            pub fn fenceInfo(node: Node) ?[]const u8 {
                if (node.store.syntaxTag(node.index) != .code_block) return null;
                const data = node.store.syntaxData(node.index);
                const value = node.store.document.string(data.code_block.tag);
                return if (value.len == 0) null else value;
            }

            pub fn headingLevel(node: Node) i32 {
                std.debug.assert(node.nodeType() == .HEADING);
                return node.store.syntaxData(node.index).heading.level;
            }

            pub fn listType(node: Node) ListType {
                std.debug.assert(node.nodeType() == .LIST);
                return if (node.store.syntaxData(node.index).list.start == .unordered) .ul else .ol;
            }

            pub fn listStart(node: Node) ?u30 {
                std.debug.assert(node.nodeType() == .LIST);
                return node.store.syntaxData(node.index).list.start.asNumber();
            }

            pub fn listIsTight(node: Node) bool {
                std.debug.assert(node.nodeType() == .LIST);
                const item = node.rawFirstChild() orelse return true;
                return node.store.syntaxData(item.index).list_item.tight;
            }

            pub fn tasklistItemChecked(node: Node) ?bool {
                if (node.nodeType() != .ITEM) return null;
                return switch (node.store.syntaxData(node.index).list_item.task) {
                    .none => null,
                    .unchecked => false,
                    .checked => true,
                };
            }

            fn rawParent(node: Node) ?Node {
                const parent_index = node.store.relations[indexInt(node.index)].parent orelse return null;
                return node.store.node(parent_index);
            }

            pub fn parent(node: Node) ?Node {
                const result = node.rawParent() orelse return null;
                return if (result.nodeType() == .DOCUMENT) null else result;
            }

            fn rawFirstChild(node: Node) ?Node {
                const child = node.store.relations[indexInt(node.index)].first_child orelse return null;
                return node.store.node(child);
            }

            pub fn firstChild(node: Node) ?Node {
                return node.rawFirstChild();
            }

            pub fn nextSibling(node: Node) ?Node {
                const sibling = node.store.relations[indexInt(node.index)].next_sibling orelse return null;
                return node.store.node(sibling);
            }

            pub fn prevSibling(node: Node) ?Node {
                const sibling = node.store.relations[indexInt(node.index)].previous_sibling orelse return null;
                return node.store.node(sibling);
            }

            pub fn next(node: Node, stop: Node) ?Node {
                std.debug.assert(node.store == stop.store);
                return node.firstChild() orelse node.nextSibling() orelse node.nextUncle(stop);
            }

            pub fn nextUncle(node: Node, stop: Node) ?Node {
                std.debug.assert(node.store == stop.store);
                var current = node;
                while (current.parent()) |parent_node| {
                    if (parent_node.eql(stop)) return null;
                    if (parent_node.nextSibling()) |sibling| return sibling;
                    current = parent_node;
                }
                return null;
            }

            pub fn setDirective(
                node: Node,
                allocator: Allocator,
                directive: *Directive,
                copy: bool,
            ) !*Directive {
                const stored = if (copy) copied: {
                    const result = try allocator.create(Directive);
                    result.* = directive.*;
                    break :copied result;
                } else directive;
                node.store.metadata[indexInt(node.index)].directive = stored;
                return stored;
            }

            pub fn getDirective(node: Node) ?*Directive {
                return node.store.metadata[indexInt(node.index)].directive;
            }

            /// Detaches this node while retaining its descendants.
            pub fn unlink(node: Node) void {
                const node_int = indexInt(node.index);
                const relation = &node.store.relations[node_int];
                const parent_index = relation.parent orelse return;
                const previous = relation.previous_sibling;
                const next_node = relation.next_sibling;

                if (previous) |previous_index| {
                    node.store.relations[indexInt(previous_index)].next_sibling = next_node;
                } else {
                    node.store.relations[indexInt(parent_index)].first_child = next_node;
                }
                if (next_node) |next_index| {
                    node.store.relations[indexInt(next_index)].previous_sibling = previous;
                } else {
                    node.store.relations[indexInt(parent_index)].last_child = previous;
                }

                relation.parent = null;
                relation.previous_sibling = null;
                relation.next_sibling = null;
            }

            /// Prepends an existing node. This mutates only relation sidecars;
            /// the compact syntax document remains unchanged.
            pub fn prependChild(parent_node: Node, new_child: Node) !void {
                if (parent_node.store != new_child.store) return error.ForeignStore;
                if (parent_node.eql(new_child) or new_child.isAncestorOf(parent_node)) {
                    return error.Cycle;
                }
                if (!parent_node.canHaveChildren()) return error.InvalidParent;

                new_child.unlink();
                const parent_relation = &parent_node.store.relations[indexInt(parent_node.index)];
                const old_first = parent_relation.first_child;
                const child_relation = &new_child.store.relations[indexInt(new_child.index)];
                child_relation.parent = parent_node.index;
                child_relation.previous_sibling = null;
                child_relation.next_sibling = old_first;
                if (old_first) |first| {
                    parent_node.store.relations[indexInt(first)].previous_sibling = new_child.index;
                } else {
                    parent_relation.last_child = new_child.index;
                }
                parent_relation.first_child = new_child.index;
            }

            /// Replaces this node with its only child. The replaced node is
            /// detached and left valid as a handle with no children.
            pub fn replaceWithChild(node: Node) !void {
                const parent_node = node.rawParent() orelse return error.MissingParent;
                const child = node.rawFirstChild() orelse return error.ExpectedSingleChild;
                if (child.nextSibling() != null) return error.ExpectedSingleChild;

                const relation = node.store.relations[indexInt(node.index)];
                node.store.relations[indexInt(node.index)] = .{};

                const child_relation = &node.store.relations[indexInt(child.index)];
                child_relation.parent = parent_node.index;
                child_relation.previous_sibling = relation.previous_sibling;
                child_relation.next_sibling = relation.next_sibling;

                if (relation.previous_sibling) |previous| {
                    node.store.relations[indexInt(previous)].next_sibling = child.index;
                } else {
                    node.store.relations[indexInt(parent_node.index)].first_child = child.index;
                }
                if (relation.next_sibling) |next_node| {
                    node.store.relations[indexInt(next_node)].previous_sibling = child.index;
                } else {
                    node.store.relations[indexInt(parent_node.index)].last_child = child.index;
                }
            }

            fn isAncestorOf(node: Node, other: Node) bool {
                var current = other.rawParent();
                while (current) |candidate| : (current = candidate.rawParent()) {
                    if (node.eql(candidate)) return true;
                }
                return false;
            }

            pub fn renderPlaintext(node: Node) error{OutOfMemory}![]const u8 {
                var output: std.Io.Writer.Allocating = .init(node.store.allocator());
                errdefer output.deinit();

                var iterator = Iter.init(node);
                while (iterator.next()) |event| {
                    if (event.dir != .enter) continue;
                    const current = event.node;
                    switch (current.store.syntaxTag(current.index)) {
                        .code_span, .text, .code_block, .html_inline, .html_block, .footnote_reference => {
                            output.writer.writeAll(current.literal().?) catch return error.OutOfMemory;
                        },
                        .line_break, .soft_break => output.writer.writeByte('\n') catch return error.OutOfMemory,
                        else => {},
                    }
                }
                return output.toOwnedSlice();
            }

            pub fn parentFootnoteDef(node: Node) ?Node {
                const parent_index = node.store.metadata[indexInt(node.index)].parent_footnote_definition orelse return null;
                return node.store.node(parent_index);
            }

            pub fn footnoteDefCount(node: Node) i32 {
                return node.store.metadata[indexInt(node.index)].footnote_definition_count;
            }

            pub fn footnoteRefIx(node: Node) i32 {
                return node.store.metadata[indexInt(node.index)].footnote_reference_index;
            }

            pub fn setFootnoteMetadata(
                node: Node,
                parent_definition: ?Index,
                definition_count: i32,
                reference_index: i32,
            ) void {
                const metadata = &node.store.metadata[indexInt(node.index)];
                metadata.parent_footnote_definition = parent_definition;
                metadata.footnote_definition_count = definition_count;
                metadata.footnote_reference_index = reference_index;
            }

            pub fn isTableHeader(node: Node) bool {
                std.debug.assert(node.nodeType() == .TABLE_ROW);
                const cell = node.rawFirstChild() orelse return false;
                return node.store.syntaxData(cell.index).table_cell.info.header;
            }

            pub fn getTableAlignments(node: Node) []const u8 {
                std.debug.assert(node.nodeType() == .TABLE);
                return node.store.metadata[indexInt(node.index)].table_alignments;
            }

            fn canHaveChildren(node: Node) bool {
                return switch (node.store.syntaxTag(node.index)) {
                    .root,
                    .list,
                    .list_item,
                    .table,
                    .table_row,
                    .table_cell,
                    .heading,
                    .blockquote,
                    .paragraph,
                    .link,
                    .image,
                    .strong,
                    .emphasis,
                    .strikethrough,
                    .footnote_definition,
                    => true,
                    .code_block,
                    .thematic_break,
                    .html_block,
                    .code_span,
                    .text,
                    .line_break,
                    .soft_break,
                    .html_inline,
                    .footnote_reference,
                    => false,
                };
            }
        };

        pub const Iter = struct {
            root: Node,
            next_event: ?Event,

            pub const Event = struct {
                dir: Dir,
                node: Node,

                pub const Dir = enum { enter, exit };
            };

            pub fn init(root: Node) Iter {
                return .{
                    .root = root,
                    .next_event = .{ .dir = .enter, .node = root },
                };
            }

            pub fn deinit(_: *Iter) void {}

            pub fn next(iterator: *Iter) ?Event {
                const event = iterator.next_event orelse return null;
                iterator.next_event = iterator.after(event);
                return event;
            }

            /// Positions the iterator immediately after `current`'s specified
            /// event, matching the legacy iterator reset semantics.
            pub fn reset(iterator: *Iter, current: Node, dir: Event.Dir) void {
                std.debug.assert(iterator.root.store == current.store);
                iterator.next_event = iterator.after(.{ .dir = dir, .node = current });
            }

            pub fn exit(iterator: *Iter, current: Node) void {
                iterator.reset(current, .exit);
            }

            fn after(iterator: Iter, event: Event) ?Event {
                return switch (event.dir) {
                    .enter => if (event.node.rawFirstChild()) |child|
                        .{ .dir = .enter, .node = child }
                    else if (event.node.canHaveChildren())
                        .{ .dir = .exit, .node = event.node }
                    else
                        iterator.afterExit(event.node),
                    .exit => iterator.afterExit(event.node),
                };
            }

            fn afterExit(iterator: Iter, node: Node) ?Event {
                if (node.eql(iterator.root)) return null;
                if (node.nextSibling()) |sibling| {
                    return .{ .dir = .enter, .node = sibling };
                }
                const parent_node = node.rawParent() orelse return null;
                return .{ .dir = .exit, .node = parent_node };
            }
        };
    };
}

fn indexInt(index: Index) usize {
    return @backingInt(index);
}

const TestDirective = struct {
    name: []const u8,
};
const TestContract = Contract(TestDirective);

fn parseTestAst(input: []const u8) !TestContract.Ast {
    var parser = try Parser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed(input);
    var document = try parser.endInput();
    errdefer document.deinit(std.testing.allocator);
    return TestContract.Ast.init(std.testing.allocator, &document);
}

fn findType(root: TestContract.Node, node_type: NodeType) ?TestContract.Node {
    var current: ?TestContract.Node = root;
    while (current) |node| : (current = node.next(root)) {
        if (node.nodeType() == node_type) return node;
    }
    return null;
}

fn expectRange(
    node: TestContract.Node,
    start_byte: u32,
    end_byte: u32,
    start_row: u32,
    start_col: u32,
    end_row: u32,
    end_col: u32,
) !void {
    try std.testing.expectEqualDeep(Range{
        .start = .{ .row = start_row, .col = start_col },
        .end = .{ .row = end_row, .col = end_col },
        .start_byte = start_byte,
        .end_byte = end_byte,
    }, node.range());
}

test "source ranges match the existing SuperMD diagnostic oracle" {
    var ast = try parseTestAst("Your **SuperMD** content goes here.\n");
    defer ast.deinit();

    const root = ast.root();
    const paragraph = root.firstChild().?;
    const first_text = paragraph.firstChild().?;
    const strong = first_text.nextSibling().?;
    const strong_text = strong.firstChild().?;
    const last_text = strong.nextSibling().?;

    try expectRange(root, 0, 35, 1, 1, 1, 35);
    try expectRange(paragraph, 0, 35, 1, 1, 1, 35);
    try expectRange(first_text, 0, 5, 1, 1, 1, 5);
    try expectRange(strong, 5, 16, 1, 6, 1, 16);
    try expectRange(strong_text, 7, 14, 1, 8, 1, 14);
    try expectRange(last_text, 16, 35, 1, 17, 1, 35);
}

test "source ranges preserve UTF-8 byte columns, CRLF, and escapes" {
    var ast = try parseTestAst("# h\xC3\xA9 \\*x\r\n");
    defer ast.deinit();

    const heading = ast.root().firstChild().?;
    const text_node = heading.firstChild().?;
    try expectRange(heading, 0, 9, 1, 1, 1, 9);
    try expectRange(text_node, 2, 9, 1, 3, 1, 9);
    try std.testing.expectEqualStrings("h\xC3\xA9 *x", try heading.renderPlaintext());
}

test "source ranges cross CRLF in multiline links" {
    var ast = try parseTestAst("[one\r\n two](url)\r\n");
    defer ast.deinit();

    const paragraph = ast.root().firstChild().?;
    const link = paragraph.firstChild().?;
    const first_text = link.firstChild().?;
    const soft_break = first_text.nextSibling().?;
    const last_text = soft_break.nextSibling().?;
    try expectRange(paragraph, 0, 16, 1, 1, 2, 10);
    try expectRange(link, 0, 16, 1, 1, 2, 10);
    try expectRange(first_text, 1, 4, 1, 2, 1, 4);
    try std.testing.expectEqual(NodeType.SOFTBREAK, soft_break.nodeType());
    try expectRange(soft_break, 4, 6, 1, 5, 1, 6);
    try expectRange(last_text, 7, 10, 2, 2, 2, 4);
}

test "autolinks expose compatible link children and exact ranges" {
    const angle_target = "https://example.com";
    const plain_target = "https://example.org/path";
    const source = "<" ++ angle_target ++ "> " ++ plain_target ++ ".\n";
    var ast = try parseTestAst(source);
    defer ast.deinit();

    const paragraph = ast.root().firstChild().?;
    const angle_link = paragraph.firstChild().?;
    const angle_text = angle_link.firstChild().?;
    try std.testing.expectEqual(NodeType.LINK, angle_link.nodeType());
    try std.testing.expectEqual(NodeType.TEXT, angle_text.nodeType());
    try std.testing.expectEqualStrings(angle_target, angle_link.link().?);
    try std.testing.expectEqualStrings(angle_target, angle_text.literal().?);
    try std.testing.expect(angle_text.nextSibling() == null);
    try expectRange(angle_link, 0, angle_target.len + 2, 1, 1, 1, angle_target.len + 2);
    try expectRange(angle_text, 1, angle_target.len + 1, 1, 2, 1, angle_target.len + 1);

    const separator = angle_link.nextSibling().?;
    const plain_link = separator.nextSibling().?;
    const plain_text = plain_link.firstChild().?;
    const plain_start = angle_target.len + 3;
    try std.testing.expectEqualStrings(" ", separator.literal().?);
    try std.testing.expectEqualStrings(plain_target, plain_link.link().?);
    try std.testing.expectEqualStrings(plain_target, plain_text.literal().?);
    try expectRange(
        plain_link,
        plain_start,
        plain_start + plain_target.len,
        1,
        plain_start + 1,
        1,
        plain_start + plain_target.len,
    );
    try std.testing.expectEqualStrings(".", plain_link.nextSibling().?.literal().?);
}

test "raw HTML nodes retain literal content and ranges" {
    var ast = try parseTestAst("<div>\nblock\n</div>\n\nbefore <i>x</i> after\n");
    defer ast.deinit();

    const html_block = ast.root().firstChild().?;
    try std.testing.expectEqual(NodeType.HTML_BLOCK, html_block.nodeType());
    try std.testing.expectEqualStrings("<div>\nblock\n</div>", html_block.literal().?);
    try expectRange(html_block, 0, 18, 1, 1, 3, 6);

    const html_inline = findType(ast.root(), .HTML_INLINE).?;
    try std.testing.expectEqualStrings("<i>", html_inline.literal().?);
    try expectRange(html_inline, 27, 30, 5, 8, 5, 10);
}

test "strikethrough nodes retain children and source ranges" {
    var ast = try parseTestAst("before ~~gone *now*~~ after\n");
    defer ast.deinit();

    const strike = findType(ast.root(), .STRIKETHROUGH).?;
    try expectRange(strike, 7, 21, 1, 8, 1, 21);
    try std.testing.expectEqualStrings("gone now", try strike.renderPlaintext());
    try std.testing.expectEqual(NodeType.EMPH, strike.firstChild().?.nextSibling().?.nodeType());
}

test "GFM tables without outer pipes retain structure and ranges" {
    var ast = try parseTestAst("name | value\n:--- | ---:\none | two\n");
    defer ast.deinit();

    const table = findType(ast.root(), .TABLE).?;
    try expectRange(table, 0, 34, 1, 1, 3, 9);
    try std.testing.expectEqualSlices(u8, &.{ 'l', 'r' }, table.getTableAlignments());
    const header = table.firstChild().?;
    try std.testing.expect(header.isTableHeader());
    try std.testing.expectEqual(NodeType.TABLE_CELL, header.firstChild().?.nodeType());
}

test "task list state is exposed on item nodes" {
    var ast = try parseTestAst("- [ ] open\n- [x] done\n- ordinary\n");
    defer ast.deinit();

    const list = findType(ast.root(), .LIST).?;
    const unchecked = list.firstChild().?;
    const checked = unchecked.nextSibling().?;
    const ordinary = checked.nextSibling().?;
    try std.testing.expectEqual(@as(?bool, false), unchecked.tasklistItemChecked());
    try std.testing.expectEqual(@as(?bool, true), checked.tasklistItemChecked());
    try std.testing.expectEqual(@as(?bool, null), ordinary.tasklistItemChecked());
    try expectRange(checked, 11, 21, 2, 1, 2, 10);
}

test "footnote definitions and references expose labels and ranges" {
    var ast = try parseTestAst("Text[^note].\n\n[^note]: Footnote body.\n");
    defer ast.deinit();

    const reference = findType(ast.root(), .FOOTNOTE_REFERENCE).?;
    const definition = findType(ast.root(), .FOOTNOTE_DEFINITION).?;
    try std.testing.expectEqualStrings("note", reference.footnoteLabel().?);
    try std.testing.expectEqualStrings("note", definition.footnoteLabel().?);
    try expectRange(reference, 4, 11, 1, 5, 1, 11);
    try std.testing.expectEqualStrings("Footnote body.", try definition.renderPlaintext());
}

test "undefined footnote references become literal text with their original range" {
    var ast = try parseTestAst("Before[^missing] after.\n");
    defer ast.deinit();

    try std.testing.expect(findType(ast.root(), .FOOTNOTE_REFERENCE) == null);
    const paragraph = findType(ast.root(), .PARAGRAPH).?;
    const literal = paragraph.firstChild().?.nextSibling().?;
    try std.testing.expectEqual(NodeType.TEXT, literal.nodeType());
    try std.testing.expectEqualStrings("[^missing]", literal.literal().?);
    try expectRange(literal, 6, 16, 1, 7, 1, 16);
}

test "forward footnote references use the definition's canonical label" {
    var ast = try parseTestAst("Before[^Note].\n\n[^note]: Body.\n");
    defer ast.deinit();

    const reference = findType(ast.root(), .FOOTNOTE_REFERENCE).?;
    const definition = findType(ast.root(), .FOOTNOTE_DEFINITION).?;
    try std.testing.expectEqualStrings("note", reference.footnoteLabel().?);
    try std.testing.expectEqualStrings("note", definition.footnoteLabel().?);
    try expectRange(reference, 6, 13, 1, 7, 1, 13);
}

test "streamed forward footnote references resolve at end of input" {
    var parser = try Parser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feedLine("Before[^Note].", 0, 1);
    try parser.feedLine("", 15, 1);
    try parser.feedLine("[^note]: Body.", 16, 0);

    var document = try parser.endInput();
    errdefer document.deinit(std.testing.allocator);
    var ast = try TestContract.Ast.init(std.testing.allocator, &document);
    defer ast.deinit();

    const reference = findType(ast.root(), .FOOTNOTE_REFERENCE).?;
    try std.testing.expectEqualStrings("note", reference.footnoteLabel().?);
    try expectRange(reference, 6, 13, 1, 7, 1, 13);
}

test "tilde fenced code retains info and full fence range" {
    var ast = try parseTestAst("~~~zig\ncode\n~~~~\n");
    defer ast.deinit();

    const code = findType(ast.root(), .CODE_BLOCK).?;
    try std.testing.expectEqualStrings("zig", code.fenceInfo().?);
    try std.testing.expectEqualStrings("code\n", code.literal().?);
    try expectRange(code, 0, 16, 1, 1, 3, 4);
}

test "forward reference links resolve before inline parsing" {
    var ast = try parseTestAst("[first][id]\n\n[id]: /target\n");
    defer ast.deinit();

    const link = findType(ast.root(), .LINK).?;
    try std.testing.expectEqualStrings("/target", link.link().?);
    try expectRange(link, 0, 11, 1, 1, 1, 11);
}

test "Setext headings include underline source range" {
    var ast = try parseTestAst("Heading\n=======\n");
    defer ast.deinit();

    const heading = findType(ast.root(), .HEADING).?;
    try std.testing.expectEqual(@as(i32, 1), heading.headingLevel());
    try std.testing.expectEqualStrings("Heading", try heading.renderPlaintext());
    try expectRange(heading, 0, 15, 1, 1, 2, 7);
}

test "smart punctuation retains original source range" {
    var ast = try parseTestAst("\"Hi\" -- it's...\n");
    defer ast.deinit();

    const paragraph = ast.root().firstChild().?;
    try std.testing.expectEqualStrings("“Hi” – it’s…", try paragraph.renderPlaintext());
    try expectRange(paragraph.firstChild().?, 0, 15, 1, 1, 1, 15);
}

test "source ranges cover nested blocks and fenced code" {
    const source = "> - item\r\n>   continued\r\n\r\n```zig\r\nconst \xCF\x80 = 1;\r\n```\r\n";
    var ast = try parseTestAst(source);
    defer ast.deinit();

    const root = ast.root();
    const blockquote = root.firstChild().?;
    const list = blockquote.firstChild().?;
    const item = list.firstChild().?;
    const paragraph = item.firstChild().?;
    const code = blockquote.nextSibling().?;

    try expectRange(blockquote, 0, 23, 1, 1, 2, 13);
    try expectRange(list, 2, 23, 1, 3, 2, 13);
    try expectRange(item, 2, 23, 1, 3, 2, 13);
    try expectRange(paragraph, 4, 23, 1, 5, 2, 13);
    try expectRange(code, 27, 53, 4, 1, 6, 3);

    var current: ?TestContract.Node = root;
    while (current) |node| : (current = node.next(root)) {
        try std.testing.expect(node.range().isKnown());
    }
}

test "stable handles preserve navigation and metadata when Ast moves" {
    var ast = try parseTestAst(
        \\# Hello *world*
        \\
        \\[site](https://example.com)
        \\
        \\- one
        \\- two
        \\
        \\| left | center | right |
        \\| :--- | :----: | ----: |
        \\| one | two | three |
        \\
    );

    const root = ast.root();
    var moved = ast;
    ast = undefined;
    defer moved.deinit();

    const heading = root.firstChild().?;
    try std.testing.expectEqual(NodeType.HEADING, heading.nodeType());
    try std.testing.expectEqual(@as(i32, 1), heading.headingLevel());
    try std.testing.expectEqualStrings("Hello world", try heading.renderPlaintext());

    const expected_range: Range = .{
        .start = .{ .row = 1, .col = 1 },
        .end = .{ .row = 1, .col = 17 },
        .start_byte = 0,
        .end_byte = 17,
    };
    heading.setRange(expected_range);
    try std.testing.expectEqualDeep(expected_range, heading.range());

    const link = findType(root, .LINK).?;
    try std.testing.expectEqualStrings("https://example.com", link.link().?);
    link.setTitle("example");
    try std.testing.expectEqualStrings("example", link.title().?);

    var directive: TestDirective = .{ .name = "heading" };
    const stored = try heading.setDirective(moved.allocator(), &directive, true);
    try std.testing.expect(stored != &directive);
    try std.testing.expectEqualStrings("heading", heading.getDirective().?.name);

    const list = findType(root, .LIST).?;
    try std.testing.expectEqual(TestContract.Node.ListType.ul, list.listType());
    try std.testing.expectEqual(@as(?u30, null), list.listStart());
    try std.testing.expect(list.listIsTight());

    const table = findType(root, .TABLE).?;
    try std.testing.expectEqualSlices(u8, &.{ 'l', 'c', 'r' }, table.getTableAlignments());
    try std.testing.expect(table.firstChild().?.isTableHeader());

    try std.testing.expect(heading.store == moved.store);
    try std.testing.expectEqualStrings("Hello world", try heading.renderPlaintext());
}

test "iterator emits compatible enter and exit events and supports reset" {
    var ast = try parseTestAst(
        \\# heading
        \\
        \\paragraph
        \\
    );
    defer ast.deinit();

    const expected = [_]struct { TestContract.Iter.Event.Dir, NodeType }{
        .{ .enter, .DOCUMENT },
        .{ .enter, .HEADING },
        .{ .enter, .TEXT },
        .{ .exit, .HEADING },
        .{ .enter, .PARAGRAPH },
        .{ .enter, .TEXT },
        .{ .exit, .PARAGRAPH },
        .{ .exit, .DOCUMENT },
    };

    var iterator = TestContract.Iter.init(ast.root());
    defer iterator.deinit();
    for (expected) |want| {
        const event = iterator.next().?;
        try std.testing.expectEqual(want[0], event.dir);
        try std.testing.expectEqual(want[1], event.node.nodeType());
    }
    try std.testing.expectEqual(@as(?TestContract.Iter.Event, null), iterator.next());

    const heading = ast.root().firstChild().?;
    iterator = TestContract.Iter.init(ast.root());
    _ = iterator.next();
    iterator.reset(heading, .enter);
    try std.testing.expectEqual(NodeType.TEXT, iterator.next().?.node.nodeType());
    iterator.reset(heading, .exit);
    try std.testing.expectEqual(NodeType.PARAGRAPH, iterator.next().?.node.nodeType());

    iterator = TestContract.Iter.init(heading);
    try std.testing.expectEqual(NodeType.HEADING, iterator.next().?.node.nodeType());
    try std.testing.expectEqual(NodeType.TEXT, iterator.next().?.node.nodeType());
    try std.testing.expectEqual(.exit, iterator.next().?.dir);
    try std.testing.expect(iterator.next() == null);
}

test "code, ordered-list, and footnote sidecar metadata are accessible" {
    var ast = try parseTestAst(
        \\3. item
        \\
        \\```zig
        \\const value = 1;
        \\```
        \\
    );
    defer ast.deinit();

    const root = ast.root();
    const list = findType(root, .LIST).?;
    try std.testing.expectEqual(TestContract.Node.ListType.ol, list.listType());
    try std.testing.expectEqual(@as(?u30, 3), list.listStart());

    const code = findType(root, .CODE_BLOCK).?;
    try std.testing.expectEqualStrings("zig", code.fenceInfo().?);
    try std.testing.expectEqualStrings("const value = 1;\n", code.literal().?);

    code.setFootnoteMetadata(list.index, 4, 2);
    try std.testing.expect(code.parentFootnoteDef().?.eql(list));
    try std.testing.expectEqual(@as(i32, 4), code.footnoteDefCount());
    try std.testing.expectEqual(@as(i32, 2), code.footnoteRefIx());
}

test "relation sidecars support audited structural mutations" {
    var ast = try parseTestAst(
        \\before [label](target) after
        \\
    );
    defer ast.deinit();

    const paragraph = ast.root().firstChild().?;
    const before = paragraph.firstChild().?;
    const link = before.nextSibling().?;
    const label = link.firstChild().?;
    const after = link.nextSibling().?;

    try std.testing.expectError(error.ExpectedSingleChild, paragraph.replaceWithChild());
    label.unlink();
    try std.testing.expect(link.firstChild() == null);
    try std.testing.expect(label.parent() == null);
    try link.prependChild(label);
    try std.testing.expect(link.firstChild().?.eql(label));

    try link.replaceWithChild();
    try std.testing.expect(before.nextSibling().?.eql(label));
    try std.testing.expect(label.nextSibling().?.eql(after));
    try std.testing.expect(label.parent().?.eql(paragraph));
    try std.testing.expect(link.parent() == null);
    try std.testing.expect(link.firstChild() == null);

    try std.testing.expectError(error.Cycle, label.prependChild(paragraph));
    try std.testing.expectError(error.InvalidParent, after.prependChild(link));
}
