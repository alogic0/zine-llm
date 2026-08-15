pub const Fixture = struct {
    name: []const u8,
    source: []const u8,
};

pub const all: []const Fixture = &.{
    .{
        .name = "commonmark",
        .source =
        \\# Representative document
        \\
        \\This paragraph has *emphasis*, **strong text**, `inline code`, and
        \\a [link](https://example.com/path?q=value "Example").
        \\
        \\> A block quote with two lines.
        \\> The second line contains an ![image](/images/example.png).
        \\
        \\1. First ordered item
        \\2. Second ordered item
        \\   - Nested unordered item
        \\   - Another nested item
        \\
        \\```zig
        \\const answer: u8 = 42;
        \\```
        \\
        \\Reference [one][target] and [two][target].
        \\
        \\[target]: /reference "Reference title"
        \\ 
        ,
    },
    .{
        .name = "gfm",
        .source =
        \\# GFM extensions
        \\
        \\- [ ] open task
        \\- [x] completed task
        \\- [X] another completed task
        \\
        \\| Feature | State | Notes |
        \\| :------ | :---: | ----: |
        \\| Tables | ready | `|` in code |
        \\| Strike | ready | ~~removed~~ |
        \\
        \\Visit https://ziglang.org and <https://example.com/docs>.
        \\
        \\A repeated footnote[^note] and another reference[^note].
        \\
        \\[^note]: Footnote body with **formatting**.
        \\    Continued on an indented line.
        \\ 
        ,
    },
    .{
        .name = "supermd",
        .source =
        \\# [Overview]($section.id('overview'))
        \\
        \\A [styled span]($text.id('intro').attrs('lead')) and a
        \\[site link]($link.page('/').ref('overview')).
        \\
        \\> []($block.attrs('notice').collapsible(true))
        \\> ## Notice
        \\> Content inside a collapsible block.
        \\
        \\[`x + y`]($mathtex)
        \\
        \\## [Media]($section.id('media'))
        \\
        \\[Diagram]($image.asset('diagram.png').alt('Architecture diagram'))
        \\
        \\```=html
        \\<aside>validated fenced HTML</aside>
        \\```
        \\ 
        ,
    },
};
