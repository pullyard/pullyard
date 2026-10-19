namespace PullYard.Core.Util;

public static class ZoomLevels
{
    public static readonly double[] All = { 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5 };

    public static double Nearest(double value)
    {
        if (double.IsNaN(value) || value <= 0) return 1;
        return All.OrderBy(l => Math.Abs(l - value)).First();
    }

    public static double Next(double value) => All.FirstOrDefault(l => l > value + 0.001, All[^1]);

    public static double Previous(double value) => All.LastOrDefault(l => l < value - 0.001, All[0]);
}
