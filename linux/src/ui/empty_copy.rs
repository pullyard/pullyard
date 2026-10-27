use super::lists::StateFilter;
use crate::app::{IssueFilter, PrFilter};

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct EmptyCopy {
    pub title: String,
    pub message: String,
}

fn copy(title: impl Into<String>, message: impl Into<String>) -> EmptyCopy {
    EmptyCopy { title: title.into(), message: message.into() }
}

fn capitalized(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

pub fn prs(filter: PrFilter, noun: &str, state: StateFilter) -> EmptyCopy {
    let nouns = format!("{noun}s");
    let lead = capitalized(&nouns);
    let message = match filter {
        PrFilter::ReviewRequested => "When someone requests your review, it shows up here.".to_string(),
        PrFilter::Mine => format!("{lead} you open show up here."),
        PrFilter::Assigned => format!("{lead} assigned to you show up here."),
        PrFilter::Mentioned => format!("{lead} that mention you show up here."),
        PrFilter::Reviewed => format!("{lead} you’ve reviewed show up here."),
    };
    if state == StateFilter::Closed {
        return copy(format!("No closed {nouns}"), message);
    }
    match filter {
        PrFilter::ReviewRequested => copy("No reviews waiting", message),
        PrFilter::Mine => copy(if state == StateFilter::Open { format!("No open {nouns}") } else { format!("No {nouns} yet") }, message),
        PrFilter::Assigned => copy("Nothing assigned to you", message),
        PrFilter::Mentioned => copy("No mentions", message),
        PrFilter::Reviewed => copy("Nothing reviewed yet", message),
    }
}

pub fn issues(filter: IssueFilter, state: StateFilter) -> EmptyCopy {
    let message = match filter {
        IssueFilter::Assigned => "Issues assigned to you show up here.",
        IssueFilter::Mine => "Issues you open show up here.",
        IssueFilter::Mentioned => "Issues that mention you show up here.",
    };
    if state == StateFilter::Closed {
        return copy("No closed issues", message);
    }
    match filter {
        IssueFilter::Assigned => copy("No issues assigned to you", message),
        IssueFilter::Mine => copy(if state == StateFilter::Open { "No open issues" } else { "No issues yet" }, message),
        IssueFilter::Mentioned => copy("No mentions", message),
    }
}

pub fn search(kind: &str, base_query: &str, state: StateFilter) -> EmptyCopy {
    if kind == "issue" {
        if let Some(f) = IssueFilter::ALL.into_iter().find(|f| f.query() == base_query) {
            return issues(f, state);
        }
    }
    if kind == "pr" {
        if let Some(f) = PrFilter::ALL.into_iter().find(|f| f.query() == base_query) {
            return prs(f, "pull request", state);
        }
    }
    let noun = if kind == "issue" { "issues" } else { "pull requests" };
    let title = if state == StateFilter::All { format!("No {noun}") } else { format!("No {} {noun}", state.title().to_lowercase()) };
    copy(title, format!("Matching {noun} show up here."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pull_request_copy_follows_filter_and_state() {
        assert_eq!(prs(PrFilter::ReviewRequested, "pull request", StateFilter::Open).title, "No reviews waiting");
        assert_eq!(prs(PrFilter::Mine, "pull request", StateFilter::Open).title, "No open pull requests");
        assert_eq!(prs(PrFilter::Mine, "merge request", StateFilter::All).title, "No merge requests yet");
        assert_eq!(prs(PrFilter::Mine, "merge request", StateFilter::All).message, "Merge requests you open show up here.");
        assert_eq!(prs(PrFilter::Assigned, "pull request", StateFilter::Closed).title, "No closed pull requests");
    }

    #[test]
    fn issue_and_search_copy() {
        assert_eq!(issues(IssueFilter::Mine, StateFilter::All).title, "No issues yet");
        assert_eq!(search("issue", "label:x", StateFilter::Open), copy("No open issues", "Matching issues show up here."));
        assert_eq!(search("pr", "", StateFilter::All).title, "No pull requests");
    }
}
