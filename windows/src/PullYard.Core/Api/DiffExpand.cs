using System.Text.RegularExpressions;

namespace PullYard.Core.Api;

public readonly record struct DiffHunkHeader(int OldStart, int OldCount, int NewStart, int NewCount);

public static class DiffExpand
{
    public const int MaxLines = 20_000;

    private static readonly Regex HeaderRx = new(@"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", RegexOptions.Compiled);

    public static DiffHunkHeader? Header(string text)
    {
        var m = HeaderRx.Match(text);
        if (!m.Success) return null;
        static int Group(Match g, int i, int fallback) => g.Groups[i].Success && int.TryParse(g.Groups[i].Value, out var v) ? v : fallback;
        return new DiffHunkHeader(Group(m, 1, 0), Group(m, 2, 1), Group(m, 3, 0), Group(m, 4, 1));
    }

    public static List<string> SplitLines(string text)
    {
        var lines = new List<string>(text.Length / 32 + 1);
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '\n') continue;
            var end = i > start && text[i - 1] == '\r' ? i - 1 : i;
            lines.Add(text[start..end]);
            start = i + 1;
        }
        if (start < text.Length) lines.Add(text[start..].TrimEnd('\r'));
        return lines;
    }

    public static bool CanExpand(string text) => CountLines(text) <= MaxLines;

    private static int CountLines(string text)
    {
        var count = 0;
        foreach (var c in text)
            if (c == '\n') count++;
        return text.Length > 0 && text[^1] != '\n' ? count + 1 : count;
    }

    public static List<DiffLine> FullFile(IReadOnlyList<DiffLine> lines, IReadOnlyList<string> newText)
    {
        var output = new List<DiffLine>(newText.Count + lines.Count);
        var cursor = 1;
        var lastOld = 0;
        var lastNew = 0;
        void Fill(int end)
        {
            if (cursor > end) return;
            var delta = lastOld - lastNew;
            for (var n = cursor; n <= end && n - 1 < newText.Count; n++)
                output.Add(new DiffLine { Id = output.Count, Kind = DiffLineKind.Context, Text = newText[n - 1], OldLine = n + delta, NewLine = n, OutsideHunk = true });
            cursor = Math.Max(cursor, end + 1);
        }
        foreach (var line in lines)
        {
            if (line.Kind == DiffLineKind.Hunk)
            {
                if (Header(line.Text) is not { } h) continue;
                Fill(h.NewStart - 1);
                lastOld = h.OldStart - 1;
                lastNew = h.NewStart - 1;
                cursor = Math.Max(cursor, h.NewStart);
                continue;
            }
            if (line.Kind == DiffLineKind.Meta) continue;
            output.Add(new DiffLine { Id = output.Count, Kind = line.Kind, Text = line.Text, OldLine = line.OldLine, NewLine = line.NewLine });
            if (line.OldLine is { } o) lastOld = o;
            if (line.NewLine is { } n)
            {
                lastNew = n;
                cursor = Math.Max(cursor, n + 1);
            }
        }
        Fill(newText.Count);
        return output;
    }

    public static List<DiffLine> FullFile(IReadOnlyList<DiffLine> lines, string newText) => FullFile(lines, SplitLines(newText));
}
