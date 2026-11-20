use std::sync::LazyLock;

use regex::Regex;

pub use super::git_remote::{GitRemote, RemoteKind};

static PR_URL: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-/]+/(pull|pulls|pull-requests|-/merge_requests)/\d+").expect("pr url regex"));

pub const CREATE_COMMANDS: [&str; 3] = ["gh pr create", "glab mr create", "merge_request.create"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreatedRequest {
    pub repo: String,
    pub number: String,
    pub merge_request: bool,
}

impl CreatedRequest {
    pub fn title(&self) -> String {
        if self.merge_request {
            format!("Merge request !{} is open", self.number)
        } else {
            format!("Pull request #{} is open", self.number)
        }
    }
}

pub fn describe(url: &str) -> CreatedRequest {
    let number = pr_number(url);
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    let rest = rest.split(['?', '#']).next().unwrap_or("");
    let parts: Vec<&str> = rest.split('/').skip(1).filter(|p| !p.is_empty()).collect();
    if let Some(i) = parts.iter().position(|p| *p == "-").filter(|i| parts.get(i + 1) == Some(&"merge_requests")) {
        return CreatedRequest { repo: parts[..i].join("/"), number, merge_request: true };
    }
    CreatedRequest { repo: pr_repo(url), number, merge_request: false }
}

pub fn open_pr_prompt(branch: &str, default_branch: Option<&str>, has_changes: bool, ahead: usize) -> String {
    open_request_prompt(branch, default_branch, has_changes, ahead, None)
}

pub fn open_request_prompt(branch: &str, default_branch: Option<&str>, has_changes: bool, ahead: usize, remote: Option<&GitRemote>) -> String {
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
    if !on_default {
        if let Some(jira) = crate::jira::ship_step(branch) {
            steps.push(jira);
        }
    }
    let target = default_branch.unwrap_or("the default branch");
    steps.push("Push the branch to origin and set the upstream.".into());
    let kind = remote.map(|r| r.kind).unwrap_or(RemoteKind::Github);
    match kind {
        RemoteKind::Github => {
            steps.push("Open a pull request with `gh pr create`. Write a concise title and a description with a short summary, the list of changes and how it was tested.".into());
            steps.push("Reply with the pull request URL on its own line.".into());
        }
        RemoteKind::Gitlab => {
            steps.push(format!("Open a merge request into {target}. If `glab` is installed and signed in, use `glab mr create` with a concise title and a description (short summary, list of changes, how it was tested). Otherwise create it while pushing: `git push -u origin HEAD -o merge_request.create -o merge_request.target=<target branch> -o merge_request.title=\"<title>\"`, then show the description you would add."));
            steps.push("Reply with the merge request URL on its own line.".into());
        }
        RemoteKind::Bitbucket => {
            steps.push("Bitbucket has no command-line tool for pull requests here, so do not try to create it. Write a concise title and a description (short summary, list of changes, how it was tested) for me to paste.".into());
            let link = remote.map(|r| r.new_request_url(branch)).unwrap_or_else(|| "Bitbucket printed after the push".into());
            steps.push(format!("Reply with the create link {link} on its own line."));
        }
        RemoteKind::Other => {
            steps.push("Open a pull request with the CLI for this host if one is installed (for example `tea`), with a concise title and description, and reply with its URL on its own line. If none is available, do not guess: if the push output contains a link to create a pull request, reply with it on its own line, together with a concise title and description. Otherwise just confirm the push.".into());
        }
    }
    let noun = kind.request_noun();
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
    CREATE_COMMANDS.iter().any(|c| command.contains(c))
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
        let p = open_pr_prompt("main", None, true, 0);
        assert!(p.starts_with("Open a pull request for this work:\n1. We are on the default branch `main`"));
        assert!(p.contains("2. Commit the current changes"));
        assert!(p.contains("gh pr create"));
        assert!(p.ends_with("Reply with the pull request URL on its own line."));
    }

    #[test]
    fn open_pr_prompt_mentions_jira_key_from_branch() {
        let p = open_pr_prompt("fix/SOC-1235-search", Some("main"), true, 0);
        assert!(p.contains("2. The branch refers to Jira issue SOC-1235. Start the title with SOC-1235"));
        assert!(p.contains("3. Push the branch"));
        let gitlab = open_request_prompt("fix/soc-1235-search", Some("main"), true, 0, Some(&GitRemote::new("gitlab.com", "g/a", RemoteKind::Gitlab)));
        assert!(gitlab.contains("Start the title with SOC-1235"));
        assert!(!open_pr_prompt("main", Some("main"), true, 0).contains("Jira"));
        assert!(!open_pr_prompt("feature/login", Some("main"), true, 0).contains("Jira"));
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

    #[test]
    fn parses_remotes() {
        let gh = GitRemote::parse("git@github.com:pullyard/pullyard.git\n");
        assert_eq!(gh, Some(GitRemote::new("github.com", "pullyard/pullyard", RemoteKind::Github)));
        assert_eq!(gh.and_then(|r| r.github_repo()).map(|r| r.full()).as_deref(), Some("pullyard/pullyard"));
        assert_eq!(GitRemote::parse("https://github.com/o/r").map(|r| r.kind), Some(RemoteKind::Github));
        assert_eq!(GitRemote::parse("ssh://git@ssh.github.com:443/o/r.git").map(|r| r.host).as_deref(), Some("github.com"));
        assert_eq!(GitRemote::parse("ssh://git@altssh.gitlab.com:443/g/a.git"), Some(GitRemote::new("gitlab.com", "g/a", RemoteKind::Gitlab)));

        let lab = GitRemote::parse("git@gitlab.example.com:group/sub/app.git");
        assert_eq!(lab, Some(GitRemote::new("gitlab.example.com", "group/sub/app", RemoteKind::Gitlab)));
        assert_eq!(lab.and_then(|r| r.github_repo()), None);
        assert_eq!(GitRemote::parse("https://gitlab.com/group/app.git/").map(|r| r.path).as_deref(), Some("group/app"));

        assert_eq!(GitRemote::parse("https://sofia@bitbucket.org/acme/api.git"), Some(GitRemote::new("bitbucket.org", "acme/api", RemoteKind::Bitbucket)));
        assert_eq!(GitRemote::parse("git@bitbucket.org:acme/api.git").map(|r| r.kind), Some(RemoteKind::Bitbucket));
        assert_eq!(GitRemote::parse("https://bitbucket.org/scm/acme/api.git").map(|r| r.path).as_deref(), Some("acme/api"));
        assert_eq!(GitRemote::parse("https://git.example.com/team/app.git").map(|r| r.kind), Some(RemoteKind::Other));
        assert_eq!(GitRemote::parse(""), None);
        assert_eq!(GitRemote::parse("/Users/me/repo"), None);
    }

    #[test]
    fn new_request_links() {
        assert_eq!(GitRemote::new("github.com", "o/r", RemoteKind::Github).new_request_url("feat/x"), "https://github.com/o/r/pull/new/feat/x");
        assert_eq!(GitRemote::new("gitlab.com", "g/a", RemoteKind::Gitlab).new_request_url("fix"), "https://gitlab.com/g/a/-/merge_requests/new?merge_request%5Bsource_branch%5D=fix");
        assert_eq!(GitRemote::new("bitbucket.org", "acme/api", RemoteKind::Bitbucket).new_request_url("fix"), "https://bitbucket.org/acme/api/pull-requests/new?source=fix");
        assert_eq!(GitRemote::new("gitlab.com", "g/a", RemoteKind::Gitlab).noun(), "merge request");
        assert_eq!(GitRemote::new("git.example.com", "t/a", RemoteKind::Other).new_request_url("x"), "https://git.example.com/t/a/pulls");
        assert_eq!(GitRemote::new("git.example.com", "t/a", RemoteKind::Other).web_url(), "https://git.example.com/t/a");
    }

    #[test]
    fn prompts_follow_the_host() {
        let github = open_request_prompt("feat", Some("main"), true, 0, None);
        assert!(github.contains("gh pr create"));
        assert!(github.starts_with("Open a pull request"));

        let gitlab = open_request_prompt("feat", Some("main"), false, 2, Some(&GitRemote::new("gitlab.com", "g/a", RemoteKind::Gitlab)));
        assert!(gitlab.starts_with("Open a merge request"));
        assert!(gitlab.contains("glab mr create"));
        assert!(gitlab.contains("merge_request.create"));
        assert!(gitlab.contains("into main"));
        assert!(!gitlab.contains("gh pr create"));

        let bitbucket = open_request_prompt("feat", None, false, 1, Some(&GitRemote::new("bitbucket.org", "acme/api", RemoteKind::Bitbucket)));
        assert!(bitbucket.contains("https://bitbucket.org/acme/api/pull-requests/new?source=feat"));
        assert!(!bitbucket.contains("gh pr create"));

        let on_default = open_request_prompt("main", Some("main"), true, 0, Some(&GitRemote::new("git.example.com", "t/a", RemoteKind::Other)));
        assert!(on_default.contains("Create a new branch"));
        assert!(on_default.contains("link to create a pull request"));
    }

    #[test]
    fn detects_created_requests() {
        assert_eq!(pull_request_url("Done:\nhttps://github.com/o/r/pull/12\n").as_deref(), Some("https://github.com/o/r/pull/12"));
        assert_eq!(pull_request_url("remote: View merge request:\nremote:   https://gitlab.com/group/sub/app/-/merge_requests/7 \n").as_deref(), Some("https://gitlab.com/group/sub/app/-/merge_requests/7"));
        assert_eq!(pull_request_url("https://bitbucket.org/acme/api/pull-requests/5").as_deref(), Some("https://bitbucket.org/acme/api/pull-requests/5"));
        assert_eq!(pull_request_url("https://bitbucket.org/acme/api/pull-requests/new?source=feat"), None);
        assert_eq!(pull_request_url("first https://gitlab.com/g/a/-/merge_requests/2 then https://github.com/o/r/pull/9").as_deref(), Some("https://gitlab.com/g/a/-/merge_requests/2"));
        assert_eq!(describe("https://gitlab.com/group/sub/app/-/merge_requests/7"), CreatedRequest { repo: "group/sub/app".into(), number: "7".into(), merge_request: true });
        assert_eq!(describe("https://github.com/o/r/pull/12").title(), "Pull request #12 is open");
        assert_eq!(describe("https://github.com/o/r/pull/12").repo, "o/r");
        assert_eq!(describe("https://gitlab.com/g/a/-/merge_requests/3").title(), "Merge request !3 is open");
        assert!(is_pr_create("git push -u origin HEAD -o merge_request.create"));
        assert!(is_pr_create("glab mr create --fill"));
    }

    #[test]
    fn open_prompt_matches_host() {
        let lab = open_request_prompt("feat/x", Some("main"), true, 0, Some(&GitRemote::new("gitlab.com", "g/a", RemoteKind::Gitlab)));
        assert!(lab.starts_with("Open a merge request for this work:\n1. Commit the current changes"));
        assert!(lab.contains("glab mr create"));
        assert!(!lab.contains("gh pr create"));
        assert!(lab.ends_with("Reply with the merge request URL on its own line."));
        let other = open_request_prompt("feat/x", Some("main"), true, 0, Some(&GitRemote::new("git.example.com", "t/a", RemoteKind::Other)));
        assert!(other.starts_with("Open a pull request for this work:"));
        assert!(other.contains("do not guess"));
        assert!(!other.contains("gh pr create"));
    }

    #[test]
    fn finds_requests_on_other_hosts() {
        let lab = "https://gitlab.com/group/sub/app/-/merge_requests/12";
        assert_eq!(pull_request_url(&format!("done: {lab} ok")).as_deref(), Some(lab));
        assert_eq!(pr_number(lab), "12");
        assert_eq!(pr_repo(lab), "group/sub/app");
        assert!(describe(lab).merge_request);
        let bucket = "https://bitbucket.org/team/app/pull-requests/3";
        assert_eq!(pull_request_url(bucket).as_deref(), Some(bucket));
        assert_eq!(pr_repo(bucket), "team/app");
        assert_eq!(describe(bucket).repo, "team/app");
        assert_eq!(pull_request_url("https://github.com/acme/app/pull/7").as_deref(), Some("https://github.com/acme/app/pull/7"));
        assert!(!describe("https://github.com/acme/app/pull/7").merge_request);
        assert_eq!(pull_request_url("https://gitlab.com/group/app/-/issues/4"), None);
        assert!(is_pr_create("glab mr create --fill"));
    }
}
