using System.Globalization;
using PullYard.Core.Util;

namespace PullYard.Core.Claude;

public static class SessionCost
{
    public const string BudgetKey = "agent.sessionBudget";
    public static readonly double[] Choices = { 0, 1, 2, 5, 10, 20, 50 };

    public static double Budget
    {
        get => Math.Max(Settings.Shared.GetDouble(BudgetKey, 0), 0);
        set => Settings.Shared.Set(BudgetKey, value);
    }

    public static double Total(double baseCost, double reported) => baseCost + Math.Max(reported, 0);

    public static bool OverBudget(double cost, double budget, double allowance) => budget > 0 && cost >= budget + allowance;

    public static double NextAllowance(double cost, double budget) => budget > 0 ? Math.Max(cost - budget, 0) + budget : 0;

    public static string Format(double value) =>
        "$" + value.ToString(value < 100 ? "0.00" : "0", CultureInfo.InvariantCulture);

    public static bool IsBilledPerUse(bool hasEndpoint, ClaudeAccountInfo? info)
    {
        if (hasEndpoint) return true;
        if (info is null) return false;
        return info.Subscription is null && (info.Method == "console" || info.Method == "api_key" || (info.Provider ?? "firstParty") != "firstParty");
    }

    public static bool BilledPerUse => IsBilledPerUse(ClaudeProfiles.Shared.Active.Endpoint is not null, ClaudeAccountStore.Shared.Info);
}

public sealed class SessionCostTracker
{
    private double costBase;
    private double allowance;

    public double Total { get; private set; }
    public bool Paused { get; private set; }

    public void ProcessStarted() => costBase = Total;

    public void Report(double reported, double budget)
    {
        Total = SessionCost.Total(costBase, reported);
        if (SessionCost.OverBudget(Total, budget, allowance)) Paused = true;
    }

    public void Continue(double budget)
    {
        allowance = SessionCost.NextAllowance(Total, budget);
        Paused = false;
    }
}
