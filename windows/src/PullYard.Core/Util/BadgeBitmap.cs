namespace PullYard.Core.Util;

public static class BadgeBitmap
{
    private static readonly Dictionary<char, string[]> Glyphs = new()
    {
        ['0'] = new[] { "111", "101", "101", "101", "111" },
        ['1'] = new[] { "010", "110", "010", "010", "111" },
        ['2'] = new[] { "111", "001", "111", "100", "111" },
        ['3'] = new[] { "111", "001", "111", "001", "111" },
        ['4'] = new[] { "101", "101", "111", "001", "001" },
        ['5'] = new[] { "111", "100", "111", "001", "111" },
        ['6'] = new[] { "111", "100", "111", "101", "111" },
        ['7'] = new[] { "111", "001", "010", "010", "010" },
        ['8'] = new[] { "111", "101", "111", "101", "111" },
        ['9'] = new[] { "111", "101", "111", "001", "111" },
        ['+'] = new[] { "000", "010", "111", "010", "000" }
    };

    public static string Label(int count) => count <= 0 ? "" : count > 9 ? "9+" : count.ToString(System.Globalization.CultureInfo.InvariantCulture);

    public static byte[] Render(int count, int size, uint top = 0xFB7185, uint bottom = 0xD61F4E)
    {
        var pixels = new byte[size * size * 4];
        var label = Label(count);
        if (label.Length == 0 || size < 8) return pixels;
        var r = size / 2.0;
        for (var y = 0; y < size; y++)
        {
            var t = size <= 1 ? 0 : y / (double)(size - 1);
            var cr = Mix(top >> 16, bottom >> 16, t);
            var cg = Mix((top >> 8) & 0xFF, (bottom >> 8) & 0xFF, t);
            var cb = Mix(top & 0xFF, bottom & 0xFF, t);
            for (var x = 0; x < size; x++)
            {
                var dx = x + 0.5 - r;
                var dy = y + 0.5 - r;
                var coverage = Math.Clamp(r - Math.Sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
                if (coverage <= 0) continue;
                Put(pixels, size, x, y, cr, cg, cb, coverage);
            }
        }
        var scale = Math.Max(1, (int)Math.Floor(size / (label.Length == 1 ? 9.0 : 12.0)));
        var gap = scale;
        var width = label.Length * 3 * scale + (label.Length - 1) * gap;
        var height = 5 * scale;
        var ox = (size - width) / 2;
        var oy = (size - height) / 2;
        for (var i = 0; i < label.Length; i++)
        {
            var glyph = Glyphs[label[i]];
            var gx = ox + i * (3 * scale + gap);
            for (var row = 0; row < 5; row++)
                for (var col = 0; col < 3; col++)
                {
                    if (glyph[row][col] != '1') continue;
                    for (var sy = 0; sy < scale; sy++)
                        for (var sx = 0; sx < scale; sx++)
                        {
                            var px = gx + col * scale + sx;
                            var py = oy + row * scale + sy;
                            if (px < 0 || py < 0 || px >= size || py >= size) continue;
                            Put(pixels, size, px, py, 255, 255, 255, 1);
                        }
                }
        }
        return pixels;
    }

    private static byte Mix(uint a, uint b, double t) => (byte)Math.Round(a + (b - (double)a) * t);

    private static void Put(byte[] pixels, int size, int x, int y, byte r, byte g, byte b, double alpha)
    {
        var i = (y * size + x) * 4;
        var a = (byte)Math.Round(alpha * 255);
        pixels[i] = (byte)Math.Round(b * alpha);
        pixels[i + 1] = (byte)Math.Round(g * alpha);
        pixels[i + 2] = (byte)Math.Round(r * alpha);
        pixels[i + 3] = a;
    }
}
