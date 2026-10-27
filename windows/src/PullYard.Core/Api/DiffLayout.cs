using System.Text;

namespace PullYard.Core.Api;

public static class DiffPrefs
{
    public const string WrapKey = "diff.wrapLines";
    public const string SplitKey = "diff.splitView";
    public const double SplitMinWidth = 900;
    public const int MaxHighlightLength = 2000;
    public const int MaxHighlightLines = 20000;
}

public sealed record SplitDiffRow(DiffLine? Left, DiffLine? Right, bool Full = false)
{
    public static SplitDiffRow FullWidth(DiffLine line) => new(line, null, true);
    public static SplitDiffRow Pair(DiffLine? left, DiffLine? right) => new(left, right);
}

public static class DiffSplit
{
    public static List<SplitDiffRow> Pair(IReadOnlyList<DiffLine> lines)
    {
        var output = new List<SplitDiffRow>(lines.Count);
        var removed = new List<DiffLine>();
        var added = new List<DiffLine>();
        void Flush()
        {
            for (var i = 0; i < Math.Max(removed.Count, added.Count); i++)
                output.Add(SplitDiffRow.Pair(i < removed.Count ? removed[i] : null, i < added.Count ? added[i] : null));
            removed.Clear();
            added.Clear();
        }
        foreach (var line in lines)
        {
            switch (line.Kind)
            {
                case DiffLineKind.Del:
                    if (added.Count > 0) Flush();
                    removed.Add(line);
                    break;
                case DiffLineKind.Add:
                    added.Add(line);
                    break;
                case DiffLineKind.Context:
                    Flush();
                    output.Add(SplitDiffRow.Pair(line, line));
                    break;
                default:
                    Flush();
                    output.Add(SplitDiffRow.FullWidth(line));
                    break;
            }
        }
        Flush();
        return output;
    }
}

public static class DiffText
{
    public const int ContinuationIndent = 2;

    public static int LeadingColumns(string text, int tabWidth = 4)
    {
        var columns = 0;
        foreach (var c in text)
        {
            if (c == ' ') columns++;
            else if (c == '\t') columns += tabWidth - columns % tabWidth;
            else break;
        }
        return columns;
    }

    public static int HangingColumns(string text, int limit, int tabWidth = 4) =>
        Math.Max(0, Math.Min(limit, 1 + LeadingColumns(text, tabWidth) + ContinuationIndent));

    public static string ExpandTabs(string text, int tabWidth = 4)
    {
        if (!text.Contains('\t')) return text;
        var sb = new StringBuilder(text.Length + tabWidth * 2);
        var column = 0;
        foreach (var c in text)
        {
            if (c == '\t')
            {
                var n = tabWidth - column % tabWidth;
                sb.Append(' ', n);
                column += n;
            }
            else
            {
                sb.Append(c);
                column++;
            }
        }
        return sb.ToString();
    }
}
