using System.Diagnostics;
using PullYard.Core.Util;

namespace PullYard.Services;

public static class OpenIn
{
    private static List<ExternalApp>? apps;

    public static IReadOnlyList<ExternalApp> Apps => apps ??= Detect();

    private static List<ExternalApp> Detect()
    {
        try
        {
            return ExternalApps.Detect(new SystemAppProbe());
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, "detecting external apps failed");
            return new List<ExternalApp> { new(ExternalApps.ExplorerId, "File Explorer", ExternalAppKind.Explorer, "explorer.exe") };
        }
    }

    public static ExternalApp? Primary => ExternalApps.Primary(Apps, Settings.Shared.GetString(Keys.AgentsOpenIn));

    public static void Remember(ExternalApp app) => Settings.Shared.Set(Keys.AgentsOpenIn, app.Id);

    public static string Glyph(ExternalAppKind? kind) => kind switch
    {
        ExternalAppKind.Terminal => "",
        ExternalAppKind.Explorer => "",
        ExternalAppKind.Editor => "",
        _ => ""
    };

    public static void Open(ExternalApp app, string folder)
    {
        var spec = ExternalApps.Launch(app, folder);
        try
        {
            var psi = new ProcessStartInfo(spec.File)
            {
                UseShellExecute = false,
                CreateNoWindow = !spec.Console && spec.File.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)
            };
            foreach (var a in spec.Args) psi.ArgumentList.Add(a);
            if (spec.WorkingDirectory is { } wd && Directory.Exists(wd)) psi.WorkingDirectory = wd;
            Process.Start(psi)?.Dispose();
        }
        catch (Exception e)
        {
            ErrorLog.Write(e, $"opening {app.Name} failed");
            Proc.Reveal(folder);
        }
    }
}
