using System.Text;
using System.Text.RegularExpressions;

namespace PullYard.Core.Html;

public static partial class MarkdownHtml
{
    [GeneratedRegex(@"^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")]
    private static partial Regex HeadingPattern();

    [GeneratedRegex(@"^\s{0,3}([-*_])(\s*\1){2,}\s*$")]
    private static partial Regex RulePattern();

    [GeneratedRegex(@"^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$")]
    private static partial Regex ListPattern();

    [GeneratedRegex(@"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")]
    private static partial Regex TableSeparator();

    [GeneratedRegex(@"^\s{0,3}(```+|~~~+)\s*([^\s`]*)")]
    private static partial Regex FencePattern();

    [GeneratedRegex(@" src=""data:image/gif;base64,[^""]*""")]
    private static partial Regex PlaceholderImage();

    [GeneratedRegex(@"(href|src)=""(/[^/""][^""]*)""")]
    private static partial Regex RelativeAttribute();

    public static string Render(string markdown, string? baseUrl = null)
    {
        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        var sb = new StringBuilder();
        var paragraph = new List<string>();

        void Flush()
        {
            if (paragraph.Count == 0) return;
            sb.Append("<p>").Append(Inline(string.Join("\n", paragraph), baseUrl)).Append("</p>");
            paragraph.Clear();
        }

        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (line.Trim().Length == 0)
            {
                Flush();
                continue;
            }
            if (FencePattern().Match(line) is { Success: true } fence)
            {
                Flush();
                var marker = fence.Groups[1].Value;
                var lang = fence.Groups[2].Value;
                var code = new List<string>();
                for (i++; i < lines.Length && !lines[i].TrimStart().StartsWith(marker, StringComparison.Ordinal); i++) code.Add(lines[i]);
                var cls = lang.Length == 0 ? "" : $" class=\"language-{ConversationHtml.Esc(lang)}\"";
                sb.Append($"<pre><code{cls}>{ConversationHtml.Esc(string.Join("\n", code))}</code></pre>");
                continue;
            }
            if (HeadingPattern().Match(line) is { Success: true } heading)
            {
                Flush();
                var level = heading.Groups[1].Value.Length;
                sb.Append($"<h{level}>{Inline(heading.Groups[2].Value, baseUrl)}</h{level}>");
                continue;
            }
            if (RulePattern().IsMatch(line))
            {
                Flush();
                sb.Append("<hr>");
                continue;
            }
            if (line.TrimStart().StartsWith('>'))
            {
                Flush();
                var quoted = new List<string>();
                for (; i < lines.Length && lines[i].TrimStart().StartsWith('>'); i++)
                {
                    var t = lines[i].TrimStart()[1..];
                    quoted.Add(t.StartsWith(' ') ? t[1..] : t);
                }
                i--;
                sb.Append("<blockquote>").Append(Render(string.Join("\n", quoted), baseUrl)).Append("</blockquote>");
                continue;
            }
            if (ListPattern().IsMatch(line))
            {
                Flush();
                var items = new List<(int Indent, string Marker, string Text)>();
                for (; i < lines.Length; i++)
                {
                    var current = lines[i];
                    if (ListPattern().Match(current) is { Success: true } m)
                        items.Add((m.Groups[1].Value.Replace("\t", "    ").Length / 2, m.Groups[2].Value, m.Groups[3].Value));
                    else if (current.Trim().Length > 0 && items.Count > 0 && (current.StartsWith(' ') || current.StartsWith('\t')))
                        items[^1] = (items[^1].Indent, items[^1].Marker, items[^1].Text + "\n" + current.Trim());
                    else break;
                }
                i--;
                sb.Append(List(items, baseUrl));
                continue;
            }
            if (line.Contains('|') && i + 1 < lines.Length && TableSeparator().IsMatch(lines[i + 1]) && lines[i + 1].Contains('-'))
            {
                Flush();
                var rows = new List<List<string>> { Cells(line) };
                for (i += 2; i < lines.Length && lines[i].Contains('|') && lines[i].Trim().Length > 0; i++) rows.Add(Cells(lines[i]));
                i--;
                sb.Append(Table(rows, baseUrl));
                continue;
            }
            paragraph.Add(line.Trim());
        }
        Flush();
        return sb.ToString();
    }

    private static string List(List<(int Indent, string Marker, string Text)> items, string? baseUrl)
    {
        var ordered = items.Count > 0 && char.IsDigit(items[0].Marker[0]);
        var sb = new StringBuilder(ordered ? "<ol>" : "<ul>");
        foreach (var (indent, _, raw) in items)
        {
            var text = raw;
            var box = "";
            if (text.StartsWith("[ ] ", StringComparison.Ordinal) || text == "[ ]")
            {
                box = "<input type=\"checkbox\" disabled> ";
                text = text.Length > 4 ? text[4..] : "";
            }
            else if (text.StartsWith("[x] ", StringComparison.OrdinalIgnoreCase) || text.Equals("[x]", StringComparison.OrdinalIgnoreCase))
            {
                box = "<input type=\"checkbox\" checked disabled> ";
                text = text.Length > 4 ? text[4..] : "";
            }
            var style = indent > 0 ? $" style=\"margin-left:{indent * 16}px\"" : "";
            sb.Append($"<li{style}>{box}{Inline(text, baseUrl)}</li>");
        }
        return sb.Append(ordered ? "</ol>" : "</ul>").ToString();
    }

    private static List<string> Cells(string line)
    {
        var t = line.Trim();
        if (t.StartsWith('|')) t = t[1..];
        if (t.EndsWith('|') && !t.EndsWith("\\|", StringComparison.Ordinal)) t = t[..^1];
        return t.Split('|').Select(c => c.Trim()).ToList();
    }

    private static string Table(List<List<string>> rows, string? baseUrl)
    {
        var head = string.Concat(rows[0].Select(c => $"<th>{Inline(c, baseUrl)}</th>"));
        var body = string.Concat(rows.Skip(1).Select(r => "<tr>" + string.Concat(r.Select(c => $"<td>{Inline(c, baseUrl)}</td>")) + "</tr>"));
        return $"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>";
    }

    public static string Inline(string text, string? baseUrl = null)
    {
        var sb = new StringBuilder(text.Length + 16);
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            if (c == '\\' && i + 1 < text.Length && (char.IsPunctuation(text[i + 1]) || char.IsSymbol(text[i + 1])))
            {
                sb.Append(ConversationHtml.Esc(text[i + 1].ToString()));
                i += 2;
                continue;
            }
            if (c == '`')
            {
                var ticks = Run(text, i, '`');
                var close = text.IndexOf(new string('`', ticks), i + ticks, StringComparison.Ordinal);
                if (close > 0)
                {
                    sb.Append("<code>").Append(ConversationHtml.Esc(text[(i + ticks)..close].Trim())).Append("</code>");
                    i = close + ticks;
                    continue;
                }
            }
            if (c == '!' && i + 1 < text.Length && text[i + 1] == '[' && Bracket(text, i + 1) is { } image)
            {
                sb.Append($"<img src=\"{ConversationHtml.Esc(Absolute(image.Url, baseUrl))}\" alt=\"{ConversationHtml.Esc(image.Label)}\">");
                i = image.End;
                continue;
            }
            if (c == '[' && Bracket(text, i) is { } link)
            {
                sb.Append($"<a href=\"{ConversationHtml.Esc(Absolute(link.Url, baseUrl))}\">{Inline(link.Label, baseUrl)}</a>");
                i = link.End;
                continue;
            }
            if ((c == '*' || c == '_' || c == '~') && Emphasis(text, i, baseUrl) is { } em)
            {
                sb.Append(em.Html);
                i = em.End;
                continue;
            }
            if (c == '<' && text.IndexOf('>', i) is var gt and > 0 && text[(i + 1)..gt] is var inner && IsUrl(inner) && !inner.Contains(' '))
            {
                sb.Append($"<a href=\"{ConversationHtml.Esc(inner)}\">{ConversationHtml.Esc(inner)}</a>");
                i = gt + 1;
                continue;
            }
            if ((c == 'h' || c == 'H') && (i == 0 || !char.IsLetterOrDigit(text[i - 1])) && IsUrl(text[i..]))
            {
                var end = i;
                while (end < text.Length && !char.IsWhiteSpace(text[end]) && text[end] != '<') end++;
                while (end > i && ".,;:!?)'\"".Contains(text[end - 1])) end--;
                var url = text[i..end];
                sb.Append($"<a href=\"{ConversationHtml.Esc(url)}\">{ConversationHtml.Esc(url)}</a>");
                i = end;
                continue;
            }
            sb.Append(c == '\n' ? "<br>" : ConversationHtml.Esc(c.ToString()));
            i++;
        }
        return sb.ToString();
    }

    private static bool IsUrl(string s) =>
        s.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || s.StartsWith("http://", StringComparison.OrdinalIgnoreCase);

    private static int Run(string text, int i, char ch)
    {
        var n = 0;
        while (i + n < text.Length && text[i + n] == ch) n++;
        return n;
    }

    private sealed record Linked(string Label, string Url, int End);

    private static Linked? Bracket(string text, int open)
    {
        var depth = 0;
        var close = -1;
        for (var j = open; j < text.Length; j++)
        {
            if (text[j] == '\\') { j++; continue; }
            if (text[j] == '[') depth++;
            else if (text[j] == ']' && --depth == 0) { close = j; break; }
        }
        if (close < 0 || close + 1 >= text.Length || text[close + 1] != '(') return null;
        var end = text.IndexOf(')', close + 2);
        if (end < 0) return null;
        var target = text[(close + 2)..end].Trim();
        if (target.StartsWith('<') && target.EndsWith('>')) target = target[1..^1];
        var space = target.IndexOf(' ');
        if (space > 0) target = target[..space];
        if (!Safe(target)) return null;
        return new Linked(text[(open + 1)..close], target, end + 1);
    }

    private static bool Safe(string url)
    {
        var colon = url.IndexOf(':');
        if (colon < 0) return true;
        var slash = url.IndexOfAny(new[] { '/', '?', '#' });
        if (slash >= 0 && slash < colon) return true;
        var scheme = url[..colon].ToLowerInvariant();
        return scheme is "http" or "https" or "mailto";
    }

    private sealed record Emphasized(string Html, int End);

    private static Emphasized? Emphasis(string text, int i, string? baseUrl)
    {
        var ch = text[i];
        var run = Run(text, i, ch);
        if (ch == '~')
        {
            if (run < 2) return null;
            var close = text.IndexOf("~~", i + 2, StringComparison.Ordinal);
            return close > i + 2 ? new($"<del>{Inline(text[(i + 2)..close], baseUrl)}</del>", close + 2) : null;
        }
        if (ch == '_' && i > 0 && char.IsLetterOrDigit(text[i - 1])) return null;
        var size = run >= 2 ? 2 : 1;
        var marker = new string(ch, size);
        var start = i + size;
        if (start >= text.Length || char.IsWhiteSpace(text[start])) return null;
        var search = start;
        while (true)
        {
            var close = text.IndexOf(marker, search, StringComparison.Ordinal);
            if (close <= start) return null;
            var after = close + size;
            var boundary = ch != '_' || after >= text.Length || !char.IsLetterOrDigit(text[after]);
            if (!char.IsWhiteSpace(text[close - 1]) && boundary && (size == 2 || after >= text.Length || text[after] != ch))
            {
                var inner = Inline(text[start..close], baseUrl);
                return new(size == 2 ? $"<strong>{inner}</strong>" : $"<em>{inner}</em>", after);
            }
            search = close + 1;
        }
    }

    public static string Absolute(string url, string? baseUrl)
    {
        if (!url.StartsWith('/') || url.StartsWith("//", StringComparison.Ordinal) || baseUrl is null || !Uri.TryCreate(baseUrl, UriKind.Absolute, out var root)) return url;
        if (url.StartsWith("/uploads/", StringComparison.Ordinal)) return baseUrl.TrimEnd('/') + url;
        return $"{root.Scheme}://{root.Authority}{url}";
    }

    public static string AbsolutizeHtml(string html, string baseUrl)
    {
        var output = PlaceholderImage().Replace(html, "").Replace(" data-src=\"", " src=\"");
        return RelativeAttribute().Replace(output, m => $"{m.Groups[1].Value}=\"{Absolute(m.Groups[2].Value, baseUrl)}\"");
    }
}
