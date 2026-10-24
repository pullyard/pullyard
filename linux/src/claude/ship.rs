use std::sync::LazyLock;

use regex::Regex;

static PR_URL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+/pull/\d+").expect("pr url regex"));

pub fn open_pr_prompt(branch: &str, default_branch: Option<&str>, has_changes: bool, ahead: usize) -> String {
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
    steps.push("Open a pull request with `gh pr create`. Write a concise title and a description with a short summary, the list of changes and how it was tested.".into());
    steps.push("Reply with the pull request URL on its own line.".into());
    let list: Vec<String> = steps.iter().enumerate().map(|(i, s)| format!("{}. {s}", i + 1)).collect();
    format!("Open a pull request for this work:\n{}", list.join("\n"))
}

pub fn commit_prompt(pr: i64) -> String {
    format!("Commit the current changes with a clear message and push them so pull request #{pr} is updated. Reply with a one-line summary.")
}

pub fn pull_request_url(text: &str) -> Option<String> {
    PR_URL.find(text).map(|m| m.as_str().to_string())
}

pub fn is_pr_create(command: &str) -> bool {
    command.contains("gh pr create")
}

pub fn pr_number(url: &str) -> String {
    url.rsplit('/').next().unwrap_or("").to_string()
}

pub fn pr_repo(url: &str) -> String {
    let parts: Vec<&str> = url.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() >= 5 {
        format!("{}/{}", parts[2], parts[3])
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_pr_prompt_on_default_branch_creates_branch() {
        let p = open_pr_prompt("main", None, true, 0);
        assert!(p.starts_with("Open a pull request for this work:\n1. We are on the default branch `main`"));
        assert!(p.contains("2. Commit the current changes"));
        assert!(p.contains("gh pr create"));
        assert!(p.ends_with("Reply with the pull request URL on its own line."));
    }

    #[test]
    fn open_pr_prompt_without_work_says_stop() {
        let p = open_pr_prompt("feature", Some("main"), false, 0);
        assert!(p.contains("1. There are no local changes"));
        assert!(!p.contains("default branch"));
        let ahead = open_pr_prompt("feature", Some("main"), false, 2);
        assert!(ahead.starts_with("Open a pull request for this work:\n1. Push the branch"));
        let custom = open_pr_prompt("trunk", Some("trunk"), false, 0);
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
}
