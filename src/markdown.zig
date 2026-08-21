//! Compatibility re-export for Zine consumers.
//!
//! The independently versioned syntax parser lives in `zig-markdown-parser`.
//! Zine keeps its SuperMD AST facade and semantic pass under `src/markdown/`.

const parser = @import("markdown_parser");

pub const Document = parser.Document;
pub const Parser = parser.Parser;
pub const Ast = @import("markdown/Ast.zig");
pub const Source = parser.Source;
pub const Renderer = parser.Renderer;
pub const renderNodeInlineText = parser.renderNodeInlineText;
pub const fmtHtml = parser.fmtHtml;
