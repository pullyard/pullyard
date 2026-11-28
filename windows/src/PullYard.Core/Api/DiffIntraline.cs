namespace PullYard.Core.Api;

public readonly record struct IntralineRange(int Start, int Length);

public static class DiffIntraline
{
    public const int MaxLength = 500;
    public const double MinCommonRatio = 0.4;

    public static IntralineRange? ChangedRange(string text, string other)
    {
        if (text.Length == 0 || text.Length >= MaxLength || other.Length >= MaxLength) return null;
        var prefix = 0;
        while (prefix < text.Length && prefix < other.Length && text[prefix] == other[prefix]) prefix++;
        if (prefix > 0 && char.IsHighSurrogate(text[prefix - 1])) prefix--;
        var suffix = 0;
        while (suffix < text.Length - prefix && suffix < other.Length - prefix && text[text.Length - 1 - suffix] == other[other.Length - 1 - suffix]) suffix++;
        if (suffix > 0 && char.IsLowSurrogate(text[text.Length - suffix])) suffix--;
        var common = prefix + suffix;
        var length = text.Length - common;
        if (length <= 0 || common <= 0 || (double)common / Math.Max(text.Length, other.Length) < MinCommonRatio) return null;
        return new IntralineRange(prefix, length);
    }

    public static Dictionary<int, string> Partners(IEnumerable<DiffLine> lines)
    {
        var output = new Dictionary<int, string>();
        var dels = new List<DiffLine>();
        var matched = 0;
        foreach (var line in lines)
        {
            switch (line.Kind)
            {
                case DiffLineKind.Del:
                    if (matched > 0)
                    {
                        dels.Clear();
                        matched = 0;
                    }
                    dels.Add(line);
                    break;
                case DiffLineKind.Add:
                    if (matched < dels.Count)
                    {
                        output[dels[matched].Id] = line.Text;
                        output[line.Id] = dels[matched].Text;
                        matched++;
                    }
                    break;
                default:
                    dels.Clear();
                    matched = 0;
                    break;
            }
        }
        return output;
    }
}
