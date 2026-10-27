namespace PullYard.Core.Util;

public static class PaletteMatch
{
    public static string[] Tokens(string query) =>
        query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    public static int? Score(string title, string extra, IReadOnlyList<string> tokens)
    {
        if (tokens.Count == 0) return 0;
        var t = title.ToLowerInvariant();
        var x = extra.ToLowerInvariant();
        var total = 0;
        foreach (var token in tokens)
        {
            if (Score(t, token) is { } s) total += s;
            else if (Score(x, token) is { } e) total += e / 2;
            else return null;
        }
        return total;
    }

    public static int? Score(string text, string token)
    {
        if (token.Length == 0) return 0;
        if (text.StartsWith(token, StringComparison.Ordinal)) return 1000;
        var at = text.IndexOf(token, StringComparison.Ordinal);
        if (at >= 0)
        {
            var boundary = !char.IsLetter(text[at - 1]);
            return (boundary ? 800 : 600) - Math.Min(at, 100);
        }
        var gaps = 0;
        var index = 0;
        foreach (var ch in token)
        {
            var found = text.IndexOf(ch, index);
            if (found < 0) return null;
            gaps += found - index;
            index = found + 1;
        }
        return Math.Max(1, 300 - gaps * 4);
    }

    public static List<T> Rank<T>(IEnumerable<T> items, IReadOnlyList<string> tokens, Func<T, string> title, Func<T, string> extra)
    {
        if (tokens.Count == 0) return items.ToList();
        return items
            .Select((item, i) => (Item: item, Score: Score(title(item), extra(item), tokens), Index: i))
            .Where(x => x.Score is not null)
            .OrderByDescending(x => x.Score)
            .ThenBy(x => x.Index)
            .Select(x => x.Item)
            .ToList();
    }
}
