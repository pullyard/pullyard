use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};

use crate::api::models::{PullRequestDetail, RepoRef};
use crate::fix_prompt;
use crate::host::{self, HostCmd};

#[derive(Clone, Debug, PartialEq)]
pub struct PrWorktree {
    pub path: String,
    pub branch: String,
    pub remote: String,
    pub head_oid: String,
    pub reused: bool,
    pub dirty: bool,
}

fn clean(p: &str) -> PathBuf {
    let mut out = PathBuf::new();
    for c in Path::new(p).components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn canon(p: &str) -> String {
    let full = clean(p);
    let mut base = full.clone();
    let mut rest: Vec<std::ffi::OsString> = vec![];
    loop {
        if let Ok(real) = std::fs::canonicalize(&base) {
            let mut out = real;
            for part in rest.iter().rev() {
                out.push(part);
            }
            return out.to_string_lossy().to_string();
        }
        match (base.file_name().map(|n| n.to_os_string()), base.parent().map(Path::to_path_buf)) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                base = parent;
            }
            _ => return full.to_string_lossy().to_string(),
        }
    }
}

pub fn path(clone: &str, number: i64) -> String {
    let c = clean(clone);
    let name = c.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let parent = c.parent().map(Path::to_path_buf).unwrap_or_default();
    parent.join(format!("{name}-worktrees")).join(format!("pr-{number}")).to_string_lossy().to_string()
}

pub fn branch(number: i64) -> String {
    format!("pullyard/pr-{number}")
}

pub fn git(args: &[&str], dir: &str) -> Result<String, String> {
    let (out, err, ok) = HostCmd::new(&host::git_binary()).args(args.iter().copied()).cwd(dir).env("GIT_TERMINAL_PROMPT", "0").env("LC_ALL", "C").unset("WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS").output();
    if ok {
        return Ok(out.trim().to_string());
    }
    let msg = err.trim();
    Err(format!("git {} failed: {}", args.first().copied().unwrap_or(""), if msg.is_empty() { "unknown error" } else { msg }))
}

pub fn remote(repo: &RepoRef, remotes: &str) -> Option<String> {
    let target = repo.full().to_lowercase();
    for line in remotes.lines() {
        let parts: Vec<&str> = line.split([' ', '\t']).filter(|s| !s.is_empty()).collect();
        if parts.len() < 2 {
            continue;
        }
        let mut url = parts[1].to_lowercase();
        if url.ends_with(".git") {
            url.truncate(url.len() - 4);
        }
        if url.ends_with(&format!("/{target}")) || url.ends_with(&format!(":{target}")) {
            return Some(parts[0].to_string());
        }
    }
    None
}

pub fn registered(porcelain: &str) -> HashSet<String> {
    porcelain.lines().filter_map(|l| l.strip_prefix("worktree ")).map(canon).collect()
}

pub fn prepare(clone: &str, repo: &RepoRef, number: i64) -> Result<PrWorktree, String> {
    let remotes = git(&["remote", "-v"], clone).unwrap_or_default();
    let remote = remote(repo, &remotes).unwrap_or_else(|| "origin".into());
    git(&["fetch", "--quiet", &remote, &format!("pull/{number}/head")], clone)?;
    let head = git(&["rev-parse", "FETCH_HEAD"], clone)?;
    let path = path(clone, number);
    let branch = branch(number);
    let known = registered(&git(&["worktree", "list", "--porcelain"], clone)?);
    let is_known = known.contains(&canon(&path));
    if is_known && Path::new(&path).exists() {
        let dirty = !git(&["status", "--porcelain"], &path)?.is_empty();
        if !dirty {
            git(&["checkout", "--quiet", "-B", &branch, &head], &path)?;
        }
        let current = git(&["rev-parse", "HEAD"], &path)?;
        return Ok(PrWorktree { path, branch, remote, head_oid: current, reused: true, dirty });
    }
    if is_known {
        let _ = git(&["worktree", "prune"], clone);
    }
    if let Some(parent) = Path::new(&path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    git(&["worktree", "add", "--quiet", "-B", &branch, &path, &head], clone)?;
    Ok(PrWorktree { path, branch, remote, head_oid: head, reused: false, dirty: false })
}

pub fn existing(clone: &str, number: i64) -> Option<String> {
    let path = path(clone, number);
    if !Path::new(&path).exists() {
        return None;
    }
    let list = git(&["worktree", "list", "--porcelain"], clone).ok()?;
    registered(&list).contains(&canon(&path)).then_some(path)
}

pub fn remove(clone: &str, number: i64) -> Result<(), String> {
    let path = path(clone, number);
    if !git(&["status", "--porcelain"], &path)?.is_empty() {
        return Err("The worktree has uncommitted changes. Commit or discard them first.".into());
    }
    git(&["worktree", "remove", &path], clone)?;
    let _ = git(&["branch", "-D", &branch(number)], clone);
    Ok(())
}

pub fn adapt(prompt: &str, worktree: &PrWorktree, pr: &PullRequestDetail, repo: &RepoRef) -> String {
    let fork = pr.head_repository.as_ref().is_some_and(|h| h.name_with_owner.to_lowercase() != repo.full().to_lowercase());
    let short: String = worktree.head_oid.chars().take(12).collect();
    let mut note = format!(
        "You are working in an isolated git worktree at {} on local branch {}, checked out at the pull request head {}. Do not run `gh pr checkout` and do not switch branches; my main checkout is not affected.",
        worktree.path, worktree.branch, short
    );
    if worktree.dirty {
        note.push_str(" The worktree already has uncommitted changes from an earlier session; keep them unless they conflict with this task.");
    }
    let before = fix_prompt::before_starting_step(pr.number);
    let step = fix_prompt::checkout_step(pr.number);
    let out = if prompt.contains(&before) {
        prompt.replace(&before, &format!("Before starting: {note}"))
    } else if prompt.contains(&step) {
        prompt.replace(&step, &note)
    } else {
        format!("{note}\n\n{prompt}")
    };
    let push = if fork {
        format!("ask me before pushing: this pull request's branch lives in the fork {}", pr.head_repository.as_ref().map(|h| h.name_with_owner.as_str()).unwrap_or(""))
    } else {
        format!("`git push {} HEAD:{}`", worktree.remote, pr.head_ref_name)
    };
    out.replace("(`git push`)", &format!("({push})"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fix_prompt::FixOptions;

    struct Fixture {
        root: PathBuf,
    }

    impl Fixture {
        fn origin(&self) -> String {
            self.root.join("o/r").to_string_lossy().to_string()
        }

        fn clone(&self) -> String {
            self.root.join("work/r").to_string_lossy().to_string()
        }

        fn new() -> Fixture {
            let root = std::env::temp_dir().join(format!("wt-{}", uuid::Uuid::new_v4()));
            let f = Fixture { root };
            let origin = f.origin();
            std::fs::create_dir_all(&origin).unwrap();
            std::fs::create_dir_all(f.root.join("work")).unwrap();
            g(&["init", "--quiet", "-b", "main"], &origin);
            std::fs::write(format!("{origin}/a.txt"), "a").unwrap();
            g(&["add", "."], &origin);
            g(&["commit", "--quiet", "-m", "base"], &origin);
            g(&["checkout", "--quiet", "-b", "feature"], &origin);
            std::fs::write(format!("{origin}/b.txt"), "b").unwrap();
            g(&["add", "."], &origin);
            g(&["commit", "--quiet", "-m", "pr"], &origin);
            g(&["update-ref", "refs/pull/7/head", "feature"], &origin);
            g(&["checkout", "--quiet", "main"], &origin);
            g(&["clone", "--quiet", &origin, &f.clone()], &f.root.to_string_lossy());
            f
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn try_g(args: &[&str], dir: &str) -> Result<String, String> {
        let mut full = vec!["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"];
        full.extend_from_slice(args);
        git(&full, dir)
    }

    fn g(args: &[&str], dir: &str) -> String {
        try_g(args, dir).unwrap()
    }

    fn repo() -> RepoRef {
        RepoRef::new("o", "r")
    }

    #[test]
    fn creates_worktree_at_pr_head_without_touching_clone() {
        let f = Fixture::new();
        let clone = f.clone();
        let wt = prepare(&clone, &repo(), 7).unwrap();
        assert_eq!(wt.path, f.root.join("work/r-worktrees/pr-7").to_string_lossy());
        assert_eq!(wt.remote, "origin");
        assert!(!wt.reused);
        assert!(Path::new(&format!("{}/b.txt", wt.path)).exists());
        assert_eq!(wt.head_oid, g(&["rev-parse", "feature"], &f.origin()));
        assert_eq!(g(&["branch", "--show-current"], &wt.path), "pullyard/pr-7");
        assert_eq!(g(&["branch", "--show-current"], &clone), "main");
        assert!(!Path::new(&format!("{clone}/b.txt")).exists());
        assert_eq!(existing(&clone, 7), Some(wt.path.clone()));
    }

    #[test]
    fn reuse_updates_clean_worktree_and_keeps_dirty_one() {
        let f = Fixture::new();
        let clone = f.clone();
        let origin = f.origin();
        prepare(&clone, &repo(), 7).unwrap();
        g(&["checkout", "--quiet", "feature"], &origin);
        std::fs::write(format!("{origin}/c.txt"), "c").unwrap();
        g(&["add", "."], &origin);
        g(&["commit", "--quiet", "-m", "more"], &origin);
        g(&["update-ref", "refs/pull/7/head", "feature"], &origin);
        let updated = prepare(&clone, &repo(), 7).unwrap();
        assert!(updated.reused);
        assert!(!updated.dirty);
        assert!(Path::new(&format!("{}/c.txt", updated.path)).exists());

        std::fs::write(format!("{}/b.txt", updated.path), "local").unwrap();
        let dirty = prepare(&clone, &repo(), 7).unwrap();
        assert!(dirty.dirty);
        assert_eq!(std::fs::read_to_string(format!("{}/b.txt", dirty.path)).unwrap(), "local");
        assert!(remove(&clone, 7).is_err());

        g(&["checkout", "--quiet", "--", "b.txt"], &dirty.path);
        remove(&clone, 7).unwrap();
        assert!(!Path::new(&dirty.path).exists());
        assert_eq!(existing(&clone, 7), None);
        assert!(!g(&["branch", "--list"], &clone).contains("pullyard/pr-7"));
    }

    #[test]
    fn missing_pull_ref_fails() {
        let f = Fixture::new();
        assert!(prepare(&f.clone(), &repo(), 99).is_err());
    }

    #[test]
    fn remote_matching() {
        let remotes = "fork\tgit@github.com:me/r.git (fetch)\nupstream\thttps://github.com/O/R.git (fetch)\n";
        assert_eq!(remote(&repo(), remotes).as_deref(), Some("upstream"));
        assert_eq!(remote(&RepoRef::new("x", "y"), remotes), None);
    }

    #[test]
    fn prompt_adaptation() {
        let pr: PullRequestDetail = serde_json::from_value(serde_json::json!({
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "feature", "baseRefName": "main", "headRefOid": "abc",
            "headRepository": { "nameWithOwner": "o/r" }, "additions": 1, "deletions": 1, "changedFiles": 1, "viewerCanUpdate": true, "viewerDidAuthor": false
        }))
        .unwrap();
        let wt = PrWorktree { path: "/tmp/r-worktrees/pr-7".into(), branch: "pullyard/pr-7".into(), remote: "upstream".into(), head_oid: "abcdef1234567890".into(), reused: false, dirty: false };
        let options = FixOptions { include_general: true, commit: true, push: true, reply_and_resolve: false };
        let prompt = fix_prompt::build(&pr, &repo(), &[], &[], &options);
        let adapted = adapt(&prompt, &wt, &pr, &repo());
        assert!(!adapted.contains(&fix_prompt::checkout_step(7)));
        assert!(adapted.contains("isolated git worktree at /tmp/r-worktrees/pr-7"));
        assert!(adapted.contains("`git push upstream HEAD:feature`"));
        let other = adapt("Custom prompt", &wt, &pr, &RepoRef::new("up", "r"));
        assert!(other.starts_with("You are working in an isolated git worktree"));
        let fork = adapt(&prompt, &wt, &pr, &RepoRef::new("up", "r"));
        assert!(fork.contains("ask me before pushing: this pull request's branch lives in the fork o/r"));
        let found = fix_prompt::FoundFixPrompt { text: "Do it".into(), author: "a".into(), date: None, url: None };
        let wrapped = adapt(&fix_prompt::wrap(&found, &pr, &options), &wt, &pr, &repo());
        assert!(wrapped.starts_with("Before starting: You are working in an isolated git worktree"));
        assert!(!wrapped.contains("gh pr checkout 7"));
        let ci = crate::ci_fix::build(&crate::ci_fix::PrInfo::new(&pr, &repo()), &[], &options, "n0nce");
        let ci_adapted = adapt(&ci, &wt, &pr, &repo());
        assert!(!ci_adapted.contains(&fix_prompt::checkout_step(7)));
        assert!(ci_adapted.contains("isolated git worktree"));
        assert!(ci_adapted.contains("`git push upstream HEAD:feature`"));
    }
}
