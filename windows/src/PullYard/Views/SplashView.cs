using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using PullYard.Controls;
using PullYard.Core;

namespace PullYard.Views;

public sealed class SplashView : Grid
{
    public const double DrawSeconds = 0.9;

    public static TimeSpan Hold => TimeSpan.FromSeconds(Motion.Enabled ? DrawSeconds + 0.15 : 0.6);

    public SplashView()
    {
        var logo = new LogoLoader(200, once: true, drawSeconds: DrawSeconds) { HorizontalAlignment = HorizontalAlignment.Center };
        var title = Ui.Text(AppInfo.DisplayName, 32, "text", FontWeights.Bold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var tagline = Ui.Text(AppInfo.Tagline, 14, "muted");
        tagline.HorizontalAlignment = HorizontalAlignment.Center;
        var words = Ui.V(6, title, tagline);
        if (Motion.Enabled) words.Transitions = new TransitionCollection { new EntranceThemeTransition { FromVerticalOffset = 10 } };
        var stack = Ui.V(20, logo, words);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(stack);
    }
}
