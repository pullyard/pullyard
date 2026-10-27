using System.Text;
using PullYard.Core.Api;
using PullYard.Core.Util;

namespace PullYard.Core.Html;

public sealed class DiffRenderOptions
{
    public bool Commentable { get; init; }
    public bool ShowViewed { get; init; }
    public bool ShowOpen { get; init; }
    public bool ShowBlame { get; init; }
    public string BlameLabel { get; init; } = "Blame";
    public string BlameTitle { get; init; } = "Blame this file at the pull request head";
    public IReadOnlySet<string> Viewed { get; init; } = new HashSet<string>();
    public IReadOnlySet<string> Collapsed { get; init; } = new HashSet<string>();
    public IReadOnlyDictionary<string, List<ReviewThread>> Threads { get; init; } = new Dictionary<string, List<ReviewThread>>();
    public IReadOnlyDictionary<string, List<ReviewThread>> Outdated { get; init; } = new Dictionary<string, List<ReviewThread>>();
    public IReadOnlyList<PendingComment> Pending { get; init; } = Array.Empty<PendingComment>();
    public string Filter { get; init; } = "";
    public bool Wrap { get; init; } = true;
    public bool Split { get; init; }
    public bool Review { get; init; }
}

public static class DiffHtml
{
    public static string Esc(string? s) => ConversationHtml.Esc(s);

    public static string StatusColor(string status) => status switch
    {
        "added" => "var(--green)",
        "removed" => "var(--red)",
        "renamed" => "var(--purple)",
        _ => "var(--amber)"
    };

    public static string Render(IReadOnlyList<DiffFile> files, DiffRenderOptions o)
    {
        var sb = new StringBuilder();
        var visible = files.Where(f => o.Filter.Length == 0 || f.Id.Contains(o.Filter, StringComparison.OrdinalIgnoreCase)).ToList();
        sb.Append(o.Wrap ? "<div class=\"diff\">" : "<div class=\"diff nw\">");
        if (visible.Count == 0) sb.Append("<p class=\"empty\">No files</p>");
        foreach (var f in visible)
        {
            var collapsed = o.Collapsed.Contains(f.Id);
            sb.Append($"<section class=\"file{(collapsed ? " collapsed" : "")}\" data-path=\"{Esc(f.Id)}\">");
            sb.Append(Header(f, o, collapsed));
            sb.Append("<div class=\"fbody\">");
            if (!collapsed) sb.Append(Body(f, o));
            sb.Append("</div></section>");
        }
        sb.Append("</div>");
        if (!o.Wrap) sb.Append("<div class=\"hbar\" id=\"hbar\" aria-hidden=\"true\"><div></div></div>");
        return sb.ToString();
    }

    public static int Widest(DiffFile f)
    {
        var widest = 0;
        foreach (var line in f.Lines)
        {
            if (line.Kind == DiffLineKind.Hunk) continue;
            var width = (line.Text.Contains('\t') ? DiffText.ExpandTabs(line.Text).Length : line.Text.Length) + 1;
            if (width > widest) widest = width;
        }
        return widest;
    }

    private static string Header(DiffFile f, DiffRenderOptions o, bool collapsed)
    {
        var path = Esc(f.Id);
        var name = f.PreviousFilename is { } prev ? $"{Esc(prev)} → {path}" : path;
        var sb = new StringBuilder();
        sb.Append("<div class=\"fh\">");
        sb.Append($"<button class=\"chev\" onclick=\"toggleFile(this)\" title=\"Collapse or expand\" aria-label=\"Collapse or expand file\" aria-expanded=\"{(collapsed ? "false" : "true")}\">{(collapsed ? "▸" : "▾")}</button>");
        sb.Append($"<span class=\"st\" style=\"color:{StatusColor(f.Status)}\">{f.StatusLetter}</span>");
        sb.Append($"<span class=\"fp\" title=\"{path}\">{name}</span>");
        sb.Append($"<span class=\"stat\"><span class=\"plus\">+{f.Additions}</span> <span class=\"minus\">−{f.Deletions}</span></span>");
        sb.Append("<span class=\"sp\"></span>");
        if (o.ShowViewed)
        {
            var on = o.Viewed.Contains(f.Id) ? " checked" : "";
            sb.Append($"<label class=\"viewed\" title=\"{(o.Review ? "Mark file as viewed (V)" : "Mark file as viewed")}\"><input type=\"checkbox\"{on} onchange=\"postFile(this,'viewed')\">Viewed</label>");
        }
        if (o.ShowOpen) sb.Append($"<button class=\"ghost\" onclick=\"postFile(this,'open')\">Open</button>");
        if (o.ShowBlame && f.Status != "removed") sb.Append($"<button class=\"ghost\" onclick=\"postFile(this,'blame')\" title=\"{Esc(o.BlameTitle)}\">{Esc(o.BlameLabel)}</button>");
        sb.Append($"<button class=\"ghost\" onclick=\"postFile(this,'copy')\" title=\"Copy path\" aria-label=\"Copy path\">⧉</button>");
        sb.Append("</div>");
        return sb.ToString();
    }

    public static string Body(DiffFile f, DiffRenderOptions o)
    {
        if (!f.HasPatch) return "<div class=\"note\">Diff unavailable (binary or too large)</div>";
        var sb = new StringBuilder(f.Lines.Count * 140);
        var path = Esc(f.Id);
        var code = HighlightedLines(f);
        var filePending = o.Pending.Where(p => p.Path == f.Id).ToList();
        var mode = o.Wrap ? "" : " nw";
        var widest = o.Wrap ? "" : $" data-maxch=\"{Widest(f)}\"";
        if (o.Split)
        {
            sb.Append($"<table class=\"dt split{mode}\"{widest}><colgroup><col class=\"gc\"><col><col class=\"gc\"><col></colgroup><tbody>");
            foreach (var row in DiffSplit.Pair(f.Lines))
            {
                if (row.Full && row.Left is { } full)
                {
                    sb.Append(FullRow(full, 1));
                    continue;
                }
                sb.Append(SplitRow(row.Left, row.Right, code, path, o.Commentable));
                if (row.Left is { } left) Extras(sb, f, left, o, filePending, 4);
                if (row.Right is { } right && !ReferenceEquals(right, row.Left)) Extras(sb, f, right, o, filePending, 4);
            }
        }
        else
        {
            sb.Append($"<table class=\"dt{mode}\"{widest}><tbody>");
            foreach (var line in f.Lines)
            {
                sb.Append(line.Kind == DiffLineKind.Hunk ? FullRow(line, 2) : LineRow(line, code, path, o.Commentable));
                Extras(sb, f, line, o, filePending, 3);
            }
        }
        sb.Append("</tbody></table>");
        if (o.Outdated.TryGetValue(f.Id, out var outdated) && outdated.Count > 0)
        {
            sb.Append("<div class=\"note\">Outdated comments</div>");
            foreach (var t in outdated) sb.Append(ConversationHtml.InlineThread(t));
        }
        return sb.ToString();
    }

    private static void Extras(StringBuilder sb, DiffFile f, DiffLine line, DiffRenderOptions o, List<PendingComment> filePending, int span)
    {
        if (!line.Commentable) return;
        var keys = new List<string>(2);
        if (line.NewLine is { } n && line.Kind != DiffLineKind.Del) keys.Add($"{f.Id}|RIGHT|{n}");
        if (line.OldLine is { } old && line.Kind != DiffLineKind.Add) keys.Add($"{f.Id}|LEFT|{old}");
        foreach (var k in keys)
            if (o.Threads.TryGetValue(k, out var threads))
                foreach (var t in threads) sb.Append($"<tr class=\"ins\"><td colspan=\"{span}\">{ConversationHtml.InlineThread(t)}</td></tr>");
        if (line.AnchorLine is { } anchor)
            foreach (var p in filePending.Where(p => p.Line == anchor && p.Side == line.AnchorSide))
                sb.Append($"<tr class=\"ins\"><td colspan=\"{span}\"><div class=\"pending\"><span class=\"tag\">pending</span><div class=\"pbody\">{Esc(p.Body)}</div><button class=\"ghost\" onclick=\"post('deletePending','{p.Id}')\" title=\"Delete pending comment\" aria-label=\"Delete pending comment\">✕</button></div></td></tr>");
    }

    public static string SyntaxExt(DiffFile f)
    {
        if (f.Lines.Count > DiffPrefs.MaxHighlightLines) return "";
        var ext = Path.GetExtension(f.FileName);
        return ext.Length > 1 ? ext[1..] : f.FileName;
    }

    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<DiffFile, string[]> Highlighted = new();

    private static string[] HighlightedLines(DiffFile f) => Highlighted.GetValue(f, file =>
    {
        var ext = SyntaxExt(file);
        var lines = file.Lines;
        var result = new string[lines.Count];
        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            if (!IsCode(line.Kind))
            {
                result[i] = Esc(line.Text);
                continue;
            }
            var text = DiffText.ExpandTabs(line.Text);
            result[i] = ext.Length > 0 && text.Length <= DiffPrefs.MaxHighlightLength ? CodeHtml.Highlight(text, ext) : Esc(text);
        }
        return result;
    });

    private static bool IsCode(DiffLineKind kind) => kind is DiffLineKind.Add or DiffLineKind.Del or DiffLineKind.Context;

    private static string Sign(DiffLineKind kind) => kind switch
    {
        DiffLineKind.Add => "+",
        DiffLineKind.Del => "-",
        DiffLineKind.Context => " ",
        _ => ""
    };

    private static string Code(DiffLine line, string[] code)
    {
        var body = line.Id >= 0 && line.Id < code.Length ? code[line.Id] : Esc(line.Text);
        if (!IsCode(line.Kind)) return $"<div class=\"w\">{body}</div>";
        return $"<div class=\"w\" style=\"--h:{DiffText.HangingColumns(line.Text, 200)}\">{Sign(line.Kind)}{body}</div>";
    }

    private static string FullRow(DiffLine line, int gutters)
    {
        var cls = line.Kind == DiffLineKind.Hunk ? "hk" : "m";
        var span = gutters == 1 ? " colspan=\"3\"" : "";
        var cells = gutters == 1 ? "<td class=\"g\"></td>" : "<td class=\"g\"></td><td class=\"g\"></td>";
        return $"<tr class=\"{cls}\">{cells}<td class=\"c\"{span}>{Esc(line.Text)}</td></tr>";
    }

    private static string Gutter(DiffLine? line, int? number, string path, bool commentable, string side = "")
    {
        var canComment = line is not null && commentable && line.Commentable && line.AnchorLine is not null;
        var attr = canComment ? $" data-c=\"{path}|{line!.AnchorSide}|{line.AnchorLine}\" title=\"Comment on this line\"" : "";
        return $"<td class=\"g{side}{(canComment ? " cm" : "")}\"{attr}>{number?.ToString() ?? ""}</td>";
    }

    private static string LineRow(DiffLine line, string[] code, string path, bool commentable)
    {
        var cls = line.Kind switch
        {
            DiffLineKind.Add => "a",
            DiffLineKind.Del => "d",
            DiffLineKind.Meta => "m",
            _ => ""
        };
        return $"<tr class=\"{cls}\">{Gutter(line, line.OldLine, path, commentable)}{Gutter(line, line.NewLine, path, commentable)}<td class=\"c\">{Code(line, code)}</td></tr>";
    }

    private static string SplitRow(DiffLine? left, DiffLine? right, string[] code, string path, bool commentable)
    {
        static string Side(DiffLine? line) => line is null ? " e" : line.Kind switch
        {
            DiffLineKind.Add => " a",
            DiffLineKind.Del => " d",
            _ => ""
        };
        var leftCode = left is null ? "" : Code(left, code);
        var rightCode = right is null ? "" : Code(right, code);
        return $"<tr class=\"sp\">{Gutter(left, left?.OldLine, path, commentable, Side(left))}<td class=\"c{Side(left)}\">{leftCode}</td>{Gutter(right, right?.NewLine, path, commentable, Side(right))}<td class=\"c{Side(right)}\">{rightCode}</td></tr>";
    }

    public const string Css = """
    .diff{font-size:12px}
    .file{margin:0 0 12px;border:1px solid var(--border);border-radius:10px;overflow:hidden;background:var(--card);content-visibility:auto;contain-intrinsic-size:auto 400px}
    .fh{position:sticky;top:0;z-index:2;display:flex;align-items:center;gap:8px;padding:6px 10px;background:var(--raised);border-bottom:1px solid var(--border)}
    .file.collapsed .fh{border-bottom:0}
    .fh .chev{border:0;background:transparent;padding:0 4px;color:var(--muted);font-size:12px}
    .fh .st{font:700 11px "Cascadia Mono",Consolas,monospace;width:12px}
    .fh .fp{font:600 12.5px "Cascadia Mono",Consolas,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;direction:rtl;text-align:left;min-width:0}
    .fh .stat{font-size:12px;white-space:nowrap}.plus{color:var(--green)}.minus{color:var(--red)}
    .fh .sp{flex:1}
    .fh .viewed{display:flex;align-items:center;gap:4px;color:var(--muted);font-size:12px;cursor:pointer;white-space:nowrap}
    .dt{border-collapse:collapse;width:100%;font:12px/1.55 "Cascadia Mono","Cascadia Code",Consolas,monospace;table-layout:fixed}
    .dt td{padding:0;vertical-align:top}
    .dt td.g{width:50px;min-width:50px;text-align:right;padding:0 8px 0 0;color:var(--gutter);user-select:none;white-space:nowrap}
    .dt td.g.cm{cursor:pointer}
    .dt tr:hover td.g.cm{color:var(--link);background:var(--hunkbg)}
    .dt td.c{padding-left:8px;color:var(--fg)}
    .dt tr.a td{background:var(--add)}.dt tr.d td{background:var(--del)}
    .dt td.c>.w{white-space:pre-wrap;overflow-wrap:anywhere;tab-size:4;--hi:min(calc(var(--h,0) * 1ch),50%);padding-left:var(--hi);text-indent:calc(var(--hi) * -1)}
    .dt.nw td.c{overflow:hidden}
    .dt.nw td.c>.w{white-space:pre;overflow-wrap:normal;padding-left:0;text-indent:0;transform:translateX(calc(var(--sx,0px) * -1))}
    .dt tr.hk td.c,.dt tr.m td.c{white-space:pre-wrap;overflow-wrap:anywhere}
    .dt.nw tr.hk td.c{white-space:pre;overflow:hidden;text-overflow:ellipsis}
    .dt col.gc{width:50px}
    .dt.split td.g{width:auto;min-width:0}
    .dt.split td.c{border-right:0}
    .dt.split td.g.a,.dt.split td.c.a{background:var(--add)}
    .dt.split td.g.d,.dt.split td.c.d{background:var(--del)}
    .dt.split td.g.e,.dt.split td.c.e{background:var(--sub)}
    .dt.split tr.sp td.g:nth-child(3){border-left:1px solid var(--border)}
    .dt .k{color:var(--k)}.dt .n{color:var(--purple)}.dt .s{color:var(--green)}.dt .cm{color:var(--gutter);font-style:italic}
    :root{--k:#d8513f}@media (prefers-color-scheme: dark){:root{--k:#ee6f5f}}
    .diff.nw{padding-bottom:14px}
    .hbar{position:fixed;left:0;right:0;bottom:0;height:12px;overflow-x:auto;overflow-y:hidden;z-index:5;display:none}
    .hbar>div{height:1px}
    .diff.nw~.hbar.on{display:block}
    .dt tr.m td.c{color:var(--muted)}
    .dt tr.hk td{background:var(--hunkbg);color:var(--muted);padding-top:3px;padding-bottom:3px}
    .dt tr.ins td{background:transparent;padding:4px 12px 4px 108px;font-family:"Segoe UI",sans-serif;white-space:normal}
    .thread.inline{margin:4px 0;max-width:900px;background:var(--raised)}
    .pending{display:flex;align-items:flex-start;gap:8px;padding:8px 10px;border:1px solid var(--amber);border-radius:8px;max-width:900px;font:13px "Segoe UI",sans-serif}
    .pending .tag{font-size:11px;font-weight:600;padding:0 6px;border-radius:8px;background:rgba(232,180,76,.25)}
    .pending .pbody{flex:1;white-space:pre-wrap}
    .note{padding:8px 12px;color:var(--muted);font:12px "Segoe UI",sans-serif}
    """;
}
