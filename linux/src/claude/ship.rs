use std::sync::LazyLock;

use regex::Regex;

use super::git_remote::RemoteKind;

static PR_URL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-/]+/(pull|pulls|pull-requests|-/merge_requests)/\d+").expect("pr url regex"));

pub fn open_pr_prompt(branch: &str, default_branch: Option<&str>, has_changes: bool, ahead: usize, kind: RemoteKind) -> String {
    let on_default = match default_branch {
        Some(d) => d == branch,
        None => ["main", "master", "develop"].contains(&branch),
    };
    let mut steps: Vec<String> = vec![];
    if on_default {
        steps.push(format!("We are on the default branch `{branch}`. Create a new branch with a short descriptive name for this work first."));
    }
    if has_changes {
        steps.push("Commit the current changes with a clear, conventional commit message. Do not commit secrets, build output or unrelated files.".into());
    } else if ahead == 0 && !on_default {
        steps.push("There are no local changes or unpushed commits. If there is nothing to open a pull request for, say so and stop.".into());
    }
    steps.push("Push the branch to origin and set the upstream.".into());
    let details = "Write a concise title and a description with a short summary, the list of changes and how it was tested.";
    steps.push(match kind {
        RemoteKind::Github => format!("Open a pull request with `gh pr create`. {details}"),
        RemoteKind::Gitlab => format!("Open a merge request with `glab mr create`. If `glab` is not installed, push with `-o merge_request.create` instead. {details}"),
        RemoteKind::Bitbucket | RemoteKind::Other => {
            format!("Open a pull request with the CLI for this host if one is installed (for example `tea` or `bb`). If none is available, do not guess: reply with the web URL where it can be created. {details}")
        }
    });
    let noun = kind.request_noun();
    steps.push(format!("Reply with the {noun} URL on its own line."));
    let list: Vec<String> = steps.iter().enumerate().map(|(i, s)| format!("{}. {s}", i + 1)).collect();
    format!("Open a {noun} for this work:\n{}", list.join("\n"))
}

pub fn commit_prompt(pr: i64) -> String {
    format!("Commit the current changes with a clear message and push them so pull request #{pr} is updated. Reply with a one-line summary.")
}

pub fn pull_request_url(text: &str) -> Option<String> {
    PR_URL.find(text).map(|m| m.as_str().to_string())
}

pub fn is_pr_create(command: &str) -> bool {
    command.contains("gh pr create") || command.contains("glab mr create")
}

pub fn request_title(url: &str) -> &'static str {
    if url.contains("/merge_requests/") {
        "Merge request"
    } else {
        "Pull request"
    }
}

pub fn pr_number(url: &str) -> String {
    url.rsplit('/').next().unwrap_or("").to_string()
}

pub fn pr_repo(url: &str) -> String {
    let parts: Vec<&str> = url.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() < 5 {
        return String::new();
    }
    let end = parts.iter().rposition(|p| matches!(*p, "pull" | "pulls" | "pull-requests" | "-")).filter(|i| *i > 2).unwrap_or(4);
    parts[2..end].join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_pr_prompt_on_default_branch_creates_branch() {
        let p = open_pr_prompt("main", None, true, 0, RemoteKind::Github);
        assert!(p.starts_with("Open a pull request for this work:\n1. We are on the default branch `main`"));
        assert!(p.contains("2. Commit the current changes"));
        assert!(p.contains("gh pr create"));
        assert!(p.ends_with("Reply with the pull request URL on its own line."));
    }

    #[test]
    fn open_pr_prompt_without_work_says_stop() {
        let p = open_pr_prompt("feature", Some("main"), false, 0, RemoteKind::Github);
        assert!(p.contains("1. There are no local changes"));
        assert!(!p.contains("default branch"));
        let ahead = open_pr_prompt("feature", Some("main"), false, 2, RemoteKind::Github);
        assert!(ahead.starts_with("Open a pull request for this work:\n1. Push the branch"));
        let custom = open_pr_prompt("trunk", Some("trunk"), false, 0, RemoteKind::Github);
        assert!(custom.contains("default branch `trunk`"));
    }

    #[test]
    fn commit_prompt_mentions_pr() {
        assert!(commit_prompt(42).contains("pull request #42"));
    }

    #[test]
    fn finds_pull_request_url() {
        let out = "Creating pull request for feat into main\n\nhttps://github.com/octo/hello-world/pull/17\n";
        assert_eq!(pull_request_url(out).as_deref(), Some("https://github.com/octo/hello-world/pull/17"));
        assert_eq!(pull_request_url("https://github.com/octo/hello/issues/3"), None);
        let url = "https://github.com/octo/hello-world/pull/17";
        assert_eq!(pr_number(url), "17");
        assert_eq!(pr_repo(url), "octo/hello-world");
        assert!(is_pr_create("git push -u origin feat && gh pr create --fill"));
    }

    #[test]
    fn open_prompt_matches_host() {
        let lab = open_pr_prompt("feat/x", Some("main"), true, 0, RemoteKind::Gitlab);
        assert!(lab.starts_with("Open a merge request for this work:\n1. Commit the current changes"));
        assert!(lab.contains("glab mr create"));
        assert!(!lab.contains("gh pr create"));
        assert!(lab.ends_with("Reply with the merge request URL on its own line."));
        let other = open_pr_prompt("feat/x", Some("main"), true, 0, RemoteKind::Other);
        assert!(other.contains("do not guess"));
        assert!(!other.contains("gh pr create"));
        assert!(other.ends_with("Reply with the pull request URL on its own line."));
    }

    #[test]
    fn finds_requests_on_other_hosts() {
        let lab = "https://gitlab.com/group/sub/app/-/merge_requests/12";
        assert_eq!(pull_request_url(&format!("done: {lab} ok")).as_deref(), Some(lab));
        assert_eq!(pr_number(lab), "12");
        assert_eq!(pr_repo(lab), "group/sub/app");
        assert_eq!(request_title(lab), "Merge request");
        let bucket = "https://bitbucket.org/team/app/pull-requests/3";
        assert_eq!(pull_request_url(bucket).as_deref(), Some(bucket));
        assert_eq!(pr_repo(bucket), "team/app");
        assert_eq!(pull_request_url("https://github.com/acme/app/pull/7").as_deref(), Some("https://github.com/acme/app/pull/7"));
        assert_eq!(request_title("https://github.com/acme/app/pull/7"), "Pull request");
        assert_eq!(pull_request_url("https://gitlab.com/group/app/-/issues/4"), None);
        assert!(is_pr_create("glab mr create --fill"));
    }
}
