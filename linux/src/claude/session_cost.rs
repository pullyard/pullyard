use super::accounts::{self, AccountInfo, Status};
use crate::settings;

pub const CHOICES: [f64; 7] = [0.0, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0];

pub fn budget() -> f64 {
    settings::read(|s| s.agent_session_budget).max(0.0)
}

pub fn set_budget(value: f64) {
    settings::update(|s| s.agent_session_budget = value.max(0.0));
}

pub fn total(base: f64, reported: f64) -> f64 {
    base + reported.max(0.0)
}

pub fn over_budget(cost: f64, budget: f64, allowance: f64) -> bool {
    budget > 0.0 && cost >= budget + allowance
}

pub fn next_allowance(cost: f64, budget: f64) -> f64 {
    if budget <= 0.0 {
        return 0.0;
    }
    (cost - budget).max(0.0) + budget
}

pub fn format(value: f64) -> String {
    if value < 100.0 {
        format!("${value:.2}")
    } else {
        format!("${value:.0}")
    }
}

pub fn choice_label(value: f64) -> String {
    if value <= 0.0 {
        "No limit".into()
    } else {
        format(value)
    }
}

pub fn billed_per_use_for(endpoint: bool, info: Option<&AccountInfo>) -> bool {
    if endpoint {
        return true;
    }
    let Some(info) = info else { return false };
    let method = info.method.as_deref().unwrap_or("");
    let provider = info.provider.as_deref().unwrap_or("firstParty");
    info.subscription.is_none() && (method == "console" || method == "api_key" || method == "endpoint" || provider != "firstParty")
}

pub fn billed_per_use() -> bool {
    let endpoint = accounts::active().endpoint.is_some();
    let status = accounts::store().status.borrow().clone();
    let info = match &status {
        Status::LoggedIn(info) => Some(info),
        _ => None,
    };
    billed_per_use_for(endpoint, info)
}

pub fn show_in_header(cost: f64, billed_per_use: bool, budget: f64) -> bool {
    cost > 0.0 && (billed_per_use || budget > 0.0)
}

pub fn header_tooltip(budget: f64) -> String {
    if budget > 0.0 {
        format!("Session cost · limit {}", format(budget))
    } else {
        "Session cost".into()
    }
}

pub fn banner_title(cost: f64, budget: f64) -> String {
    format!("Session cost {} reached your {} limit", format(cost), format(budget))
}

pub const BANNER_DETAIL: &str = "New messages wait until you continue. Change the limit in Settings › Agents.";

pub fn continue_label(budget: f64) -> String {
    format!("Continue (+{})", format(budget))
}

pub const SETTINGS_TITLE: &str = "Pause a session at";

pub const SETTINGS_CAPTION: &str = "When an agent session's reported cost reaches the limit, new messages wait until you continue. Useful with API keys, OpenRouter or another endpoint; with a subscription plan the cost is an estimate.";

#[cfg(test)]
mod tests {
    use super::*;

    fn info(subscription: Option<&str>, method: Option<&str>, provider: Option<&str>) -> AccountInfo {
        AccountInfo { email: None, org_name: None, subscription: subscription.map(String::from), method: method.map(String::from), provider: provider.map(String::from) }
    }

    #[test]
    fn math() {
        assert_eq!(total(0.5, 0.25), 0.75);
        assert_eq!(total(0.5, -1.0), 0.5);
        assert!(!over_budget(10.0, 0.0, 0.0));
        assert!(over_budget(2.0, 2.0, 0.0));
        assert!(!over_budget(3.0, 2.0, 2.0));
        assert_eq!(next_allowance(2.5, 2.0), 2.5);
        assert_eq!(next_allowance(1.0, 2.0), 2.0);
        assert_eq!(next_allowance(1.0, 0.0), 0.0);
    }

    #[test]
    fn formats() {
        assert_eq!(format(0.043), "$0.04");
        assert_eq!(format(12.5), "$12.50");
        assert_eq!(format(250.0), "$250");
        assert_eq!(choice_label(0.0), "No limit");
        assert_eq!(choice_label(5.0), "$5.00");
        assert_eq!(CHOICES, [0.0, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0]);
        assert_eq!(banner_title(2.1, 2.0), "Session cost $2.10 reached your $2.00 limit");
        assert_eq!(continue_label(5.0), "Continue (+$5.00)");
        assert_eq!(header_tooltip(0.0), "Session cost");
        assert_eq!(header_tooltip(1.0), "Session cost · limit $1.00");
    }

    #[test]
    fn billing() {
        assert!(billed_per_use_for(true, None));
        assert!(!billed_per_use_for(false, None));
        assert!(billed_per_use_for(false, Some(&info(None, Some("api_key"), None))));
        assert!(billed_per_use_for(false, Some(&info(None, Some("console"), None))));
        assert!(billed_per_use_for(false, Some(&info(None, Some("oauth"), Some("bedrock")))));
        assert!(!billed_per_use_for(false, Some(&info(Some("Max"), Some("api_key"), None))));
        assert!(!billed_per_use_for(false, Some(&info(None, Some("claude.ai"), Some("firstParty")))));
    }

    #[test]
    fn header_visibility() {
        assert!(!show_in_header(0.0, true, 5.0));
        assert!(show_in_header(0.01, true, 0.0));
        assert!(show_in_header(0.01, false, 1.0));
        assert!(!show_in_header(0.01, false, 0.0));
    }
}
