use std::collections::{BTreeMap, HashMap, HashSet};

use regex::Regex;

use super::models::PullRequestDetail;

pub const CODE_OWNERS_PATHS: [&str; 3] = [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"];
pub const GITLAB_CODE_OWNERS_PATHS: [&str; 3] = ["CODEOWNERS", "docs/CODEOWNERS", ".gitlab/CODEOWNERS"];
pub const BITBUCKET_CODE_OWNERS_PATHS: [&str; 2] = [".bitbucket/CODEOWNERS", "CODEOWNERS"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CodeOwnersFlavor {
    #[default]
    GitHub,
    GitLab,
}

#[derive(Debug, Clone)]
pub struct CodeOwnersRule {
    pub owners: Vec<String>,
    pub section: usize,
    regex: Regex,
}

#[derive(Debug, Clone)]
pub struct CodeOwners {
    pub path: String,
    pub rules: Vec<CodeOwnersRule>,
    pub invalid_lines: Vec<usize>,
    pub flavor: CodeOwnersFlavor,
}

impl CodeOwners {
    pub fn parse(text: &str, path: &str) -> Self {
        Self::parse_flavored(text, path, CodeOwnersFlavor::GitHub)
    }

    pub fn parse_flavored(text: &str, path: &str, flavor: CodeOwnersFlavor) -> Self {
        let mut rules = Vec::new();
        let mut invalid = Vec::new();
        let mut section = 0;
        let mut defaults: Vec<String> = Vec::new();
        for (index, raw) in text.split(['\n', '\r']).enumerate() {
            if flavor == CodeOwnersFlavor::GitLab {
                if let Some(header) = Self::section_header(raw) {
                    section += 1;
                    defaults = header;
                    continue;
                }
            }
            let tokens = Self::tokens(raw);
            let Some(pattern) = tokens.first() else { continue };
            let mut owners: Vec<String> = tokens[1..].to_vec();
            let regex = if owners.iter().all(|o| Self::is_owner(o)) { Self::regex_for(pattern) } else { None };
            match regex {
                Some(regex) => {
                    if owners.is_empty() && flavor == CodeOwnersFlavor::GitLab {
                        owners = defaults.clone();
                    }
                    rules.push(CodeOwnersRule { owners, section, regex })
                }
                None => invalid.push(index + 1),
            }
        }
        CodeOwners { path: path.to_string(), rules, invalid_lines: invalid, flavor }
    }

    pub fn section_header(line: &str) -> Option<Vec<String>> {
        let mut s = line.trim_matches([' ', '\t']);
        if let Some(rest) = s.strip_prefix('^') {
            s = rest;
        }
        let inner = s.strip_prefix('[')?;
        let close = inner.find(']')?;
        if close == 0 {
            return None;
        }
        let mut rest = &inner[close + 1..];
        if let Some(after) = rest.strip_prefix('[') {
            if let Some(count) = after.find(']') {
                rest = &after[count + 1..];
            }
        }
        let owners = Self::tokens(rest);
        owners.iter().all(|o| Self::is_owner(o)).then_some(owners)
    }

    pub fn rule_for(&self, file: &str) -> Option<&CodeOwnersRule> {
        self.rules.iter().rev().find(|r| r.regex.is_match(file))
    }

    pub fn owners_for(&self, file: &str) -> Vec<String> {
        if self.flavor != CodeOwnersFlavor::GitLab {
            return self.rule_for(file).map(|r| r.owners.clone()).unwrap_or_default();
        }
        let mut last_by_section: BTreeMap<usize, &CodeOwnersRule> = BTreeMap::new();
        for rule in self.rules.iter().filter(|r| r.regex.is_match(file)) {
            last_by_section.insert(rule.section, rule);
        }
        let mut seen = HashSet::new();
        last_by_section.values().flat_map(|r| r.owners.iter()).filter(|o| seen.insert(o.to_lowercase())).cloned().collect()
    }

    pub fn is_owner(token: &str) -> bool {
        match token.strip_prefix('@') {
            Some(rest) => !rest.is_empty(),
            None => token.contains('@'),
        }
    }

    fn tokens(line: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut current = String::new();
        let mut escaped = false;
        for ch in line.chars() {
            if escaped {
                current.push(ch);
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '#' {
                break;
            } else if ch == ' ' || ch == '\t' {
                if !current.is_empty() {
                    out.push(std::mem::take(&mut current));
                }
            } else {
                current.push(ch);
            }
        }
        if !current.is_empty() {
            out.push(current);
        }
        out
    }

    pub fn regex_for(pattern: &str) -> Option<Regex> {
        if pattern.starts_with('!') || pattern.contains('[') || pattern.contains(']') {
            return None;
        }
        let mut p = pattern;
        let dir_only = p.ends_with('/');
        if dir_only {
            p = &p[..p.len() - 1];
        }
        let anchored = p.contains('/');
        if let Some(rest) = p.strip_prefix('/') {
            p = rest;
        }
        if p.is_empty() {
            return None;
        }
        let last = p.split('/').filter(|s| !s.is_empty()).last().unwrap_or(p);
        let wildcard_tail = last.contains('*') || last.contains('?');
        let chars: Vec<char> = p.chars().collect();
        let mut body = String::new();
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            if c == '*' {
                if chars.get(i + 1) == Some(&'*') {
                    if chars.get(i + 2) == Some(&'/') {
                        body.push_str("(?:.*/)?");
                        i += 3;
                    } else {
                        body.push_str(".*");
                        i += 2;
                    }
                    continue;
                }
                body.push_str("[^/]*");
            } else if c == '?' {
                body.push_str("[^/]");
            } else {
                body.push_str(&regex::escape(&c.to_string()));
            }
            i += 1;
        }
        let prefix = if anchored { "^" } else { "^(?:.*/)?" };
        let suffix = if dir_only {
            "/.*$"
        } else if wildcard_tail {
            "$"
        } else {
            "(?:/.*)?$"
        };
        Regex::new(&format!("{prefix}{body}{suffix}")).ok()
    }
}

#[derive(Debug, Clone, Default)]
pub enum CodeOwnersStatus {
    #[default]
    Loading,
    Missing,
    Failed,
    Loaded(CodeOwners),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum OwnerStatus {
    ChangesRequested,
    NotRequested,
    Requested,
    Approved,
}

impl OwnerStatus {
    pub fn title(self) -> &'static str {
        match self {
            OwnerStatus::Approved => "approved",
            OwnerStatus::ChangesRequested => "changes requested",
            OwnerStatus::Requested => "review requested",
            OwnerStatus::NotRequested => "not requested",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct OwnerEntry {
    pub handle: String,
    pub is_team: bool,
    pub status: OwnerStatus,
}

#[derive(Debug, Clone)]
pub struct OwnerGroup {
    pub owners: Vec<OwnerEntry>,
    pub files: Vec<String>,
}

impl OwnerGroup {
    pub fn satisfied(&self) -> bool {
        self.owners.iter().any(|o| o.status == OwnerStatus::Approved)
    }
}

#[derive(Debug, Clone)]
pub struct OwnershipSummary {
    pub groups: Vec<OwnerGroup>,
    pub unowned: Vec<String>,
    pub source_path: String,
}

impl OwnershipSummary {
    pub fn build(owners: &CodeOwners, files: &[String], pr: &PullRequestDetail) -> Self {
        let reviewers = |state: &str| -> HashSet<String> { pr.latest_opinionated_reviews.nodes.iter().filter(|r| r.state == state).filter_map(|r| r.author.as_ref().map(|a| a.login.to_lowercase())).collect() };
        let approved = reviewers("APPROVED");
        let blocked = reviewers("CHANGES_REQUESTED");
        let requested: HashSet<String> = pr.review_requests.nodes.iter().filter_map(|r| r.requested_reviewer.as_ref().map(|r| r.display().to_lowercase())).collect();
        let mut by_owners: HashMap<Vec<String>, Vec<String>> = HashMap::new();
        let mut order: Vec<Vec<String>> = Vec::new();
        let mut unowned = Vec::new();
        for file in files {
            let list = owners.owners_for(file);
            if list.is_empty() {
                unowned.push(file.clone());
                continue;
            }
            if !by_owners.contains_key(&list) {
                order.push(list.clone());
            }
            by_owners.entry(list).or_default().push(file.clone());
        }
        let groups = order
            .into_iter()
            .map(|list| {
                let entries = list
                    .iter()
                    .map(|raw| {
                        let handle = raw.strip_prefix('@').unwrap_or(raw).to_string();
                        let key = handle.to_lowercase();
                        let status = if blocked.contains(&key) {
                            OwnerStatus::ChangesRequested
                        } else if approved.contains(&key) {
                            OwnerStatus::Approved
                        } else if requested.contains(&key) {
                            OwnerStatus::Requested
                        } else {
                            OwnerStatus::NotRequested
                        };
                        OwnerEntry { is_team: handle.contains('/'), handle, status }
                    })
                    .collect();
                let files = by_owners.remove(&list).unwrap_or_default();
                OwnerGroup { owners: entries, files }
            })
            .collect();
        OwnershipSummary { groups, unowned, source_path: owners.path.clone() }
    }

    pub fn owners_of(&self, file: &str) -> Option<&[OwnerEntry]> {
        self.groups.iter().find(|g| g.files.iter().any(|f| f == file)).map(|g| g.owners.as_slice())
    }

    pub fn suggestions(&self, excluding: &HashSet<String>) -> Vec<OwnerEntry> {
        let mut seen = HashSet::new();
        self.groups
            .iter()
            .filter(|g| !g.satisfied())
            .flat_map(|g| g.owners.iter())
            .filter(|o| o.status == OwnerStatus::NotRequested && !o.handle.contains('@') && !excluding.contains(&o.handle.to_lowercase()) && seen.insert(o.handle.to_lowercase()))
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const SAMPLE: &str = "# comment
*       @global-owner1 @global-owner2
*.js    @js-owner #This is an inline comment.
*.go docs@example.com
*.txt @octo-org/octocats
/build/logs/ @doctocat
docs/*  docs@example.com
apps/ @octocat
/docs/ @doctocat
/scripts/ @doctocat @octocat
**/logs @octocat
/apps/ @octocat
/apps/github
/lib/features/chat/   @chat-owner
\\#hash.md @hash-owner
!negated @nobody
[abc].md @nobody
bad-owner notanowner";

    fn owners() -> CodeOwners {
        CodeOwners::parse(SAMPLE, ".github/CODEOWNERS")
    }

    fn list(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn last_match_wins() {
        let o = owners();
        assert_eq!(o.owners_for("README.md"), list(&["@global-owner1", "@global-owner2"]));
        assert_eq!(o.owners_for("src/app.js"), list(&["@js-owner"]));
        assert_eq!(o.owners_for("main.go"), list(&["docs@example.com"]));
        assert_eq!(o.owners_for("notes.txt"), list(&["@octo-org/octocats"]));
    }

    #[test]
    fn directory_patterns() {
        let o = owners();
        assert_eq!(o.owners_for("build/logs/a/b.log"), list(&["@octocat"]));
        assert_eq!(o.owners_for("scripts/deploy.sh"), list(&["@doctocat", "@octocat"]));
        assert_eq!(o.owners_for("deeply/nested/logs/x.txt"), list(&["@octocat"]));
        assert_eq!(o.owners_for("lib/features/chat/view/chat_page.dart"), list(&["@chat-owner"]));
        assert_eq!(o.owners_for("other/lib/features/chat/x.dart"), list(&["@global-owner1", "@global-owner2"]));
    }

    #[test]
    fn root_docs_and_single_level_wildcard() {
        assert_eq!(owners().owners_for("docs/getting-started.md"), list(&["@doctocat"]));
        let only_star = CodeOwners::parse("docs/* @docs-team", ".github/CODEOWNERS");
        assert_eq!(only_star.owners_for("docs/getting-started.md"), list(&["@docs-team"]));
        assert!(only_star.owners_for("docs/build-app/troubleshooting.md").is_empty());
    }

    #[test]
    fn rule_without_owners_clears_ownership() {
        let o = owners();
        assert!(o.owners_for("apps/github/main.swift").is_empty());
        assert_eq!(o.owners_for("apps/other/main.swift"), list(&["@octocat"]));
        assert!(o.rule_for("apps/github/main.swift").is_some());
    }

    #[test]
    fn escapes_and_unsupported_syntax() {
        let o = owners();
        assert_eq!(o.owners_for("#hash.md"), list(&["@hash-owner"]));
        assert_eq!(o.invalid_lines.len(), 3);
        assert_eq!(o.owners_for("negated"), list(&["@global-owner1", "@global-owner2"]));
    }

    #[test]
    fn unanchored_file_name_and_double_star() {
        let o = CodeOwners::parse("Makefile @make\nsrc/**/test_*.py @py\n", ".github/CODEOWNERS");
        assert_eq!(o.owners_for("a/b/Makefile"), list(&["@make"]));
        assert_eq!(o.owners_for("src/test_x.py"), list(&["@py"]));
        assert_eq!(o.owners_for("src/a/b/test_x.py"), list(&["@py"]));
        assert!(o.owners_for("lib/src/test_x.py").is_empty());
    }

    #[test]
    fn summary_groups_and_statuses() {
        let pr: PullRequestDetail = serde_json::from_value(json!({
            "id": "PR_1", "number": 1, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main", "headRefOid": "h",
            "additions": 1, "deletions": 1, "changedFiles": 3, "viewerCanUpdate": true, "viewerDidAuthor": true,
            "labels": { "nodes": [] }, "assignees": { "nodes": [] },
            "reviewRequests": { "nodes": [{ "requestedReviewer": { "__typename": "Team", "name": "Octocats", "combinedSlug": "octo-org/octocats" } }] },
            "latestOpinionatedReviews": { "nodes": [{ "state": "APPROVED", "author": { "login": "JS-Owner", "avatarUrl": "" } }] },
            "lastCommit": { "nodes": [] }, "allCommits": { "nodes": [] }, "timelineItems": { "nodes": [] }, "reviewThreads": { "nodes": [] }
        }))
        .unwrap();
        let o = CodeOwners::parse("*.js @js-owner\n*.txt @octo-org/octocats\n/scripts/ @doctocat\n", ".github/CODEOWNERS");
        let s = OwnershipSummary::build(&o, &list(&["a.js", "b.txt", "scripts/run.sh", "README.md"]), &pr);
        assert_eq!(s.unowned, list(&["README.md"]));
        let statuses: Vec<Vec<OwnerStatus>> = s.groups.iter().map(|g| g.owners.iter().map(|o| o.status).collect()).collect();
        assert_eq!(statuses, vec![vec![OwnerStatus::Approved], vec![OwnerStatus::Requested], vec![OwnerStatus::NotRequested]]);
        assert!(s.groups[1].owners[0].is_team);
        let handles = |ex: &HashSet<String>| s.suggestions(ex).into_iter().map(|o| o.handle).collect::<Vec<_>>();
        assert_eq!(handles(&HashSet::new()), list(&["doctocat"]));
        assert!(handles(&HashSet::from(["doctocat".to_string()])).is_empty());
    }

    const GITLAB: &str = "* @everyone
[Backend] @backend-team
app/
app/billing/ @billing @alice
^[Docs][2] @docs/writers
*.md
[Security]
app/auth/ @security
";

    #[test]
    fn gitlab_sections_union_owners() {
        let o = CodeOwners::parse_flavored(GITLAB, "CODEOWNERS", CodeOwnersFlavor::GitLab);
        assert!(o.invalid_lines.is_empty());
        assert_eq!(o.flavor, CodeOwnersFlavor::GitLab);
        assert_eq!(o.owners_for("app/billing/pay.rb"), list(&["@everyone", "@billing", "@alice"]));
        assert_eq!(o.owners_for("app/models/user.rb"), list(&["@everyone", "@backend-team"]));
        assert_eq!(o.owners_for("app/README.md"), list(&["@everyone", "@backend-team", "@docs/writers"]));
        assert_eq!(o.owners_for("app/auth/login.rb"), list(&["@everyone", "@backend-team", "@security"]));
        assert_eq!(o.owners_for("Gemfile"), list(&["@everyone"]));
        let deduped = CodeOwners::parse_flavored("* @Alice\n[Extra]\n* @alice @bob\n", "CODEOWNERS", CodeOwnersFlavor::GitLab);
        assert_eq!(deduped.owners_for("x"), list(&["@Alice", "@bob"]));
        let github = CodeOwners::parse(GITLAB, "CODEOWNERS");
        assert!(!github.invalid_lines.is_empty());
        assert_eq!(github.flavor, CodeOwnersFlavor::GitHub);
    }

    #[test]
    fn gitlab_section_headers() {
        assert_eq!(CodeOwners::section_header("^[Docs][2] @docs/writers"), Some(list(&["@docs/writers"])));
        assert_eq!(CodeOwners::section_header("[Security]"), Some(vec![]));
        assert_eq!(CodeOwners::section_header("  [Ops] @ops ops@example.com"), Some(list(&["@ops", "ops@example.com"])));
        assert_eq!(CodeOwners::section_header("app/ @x"), None);
        assert_eq!(CodeOwners::section_header("[]"), None);
        assert_eq!(CodeOwners::section_header("[abc].md @nobody"), None);
    }

    #[test]
    fn owners_of_file() {
        let pr: PullRequestDetail = serde_json::from_value(json!({
            "id": "PR_1", "number": 7, "title": "T", "url": "u", "state": "OPEN", "isDraft": false, "merged": false, "mergeable": "MERGEABLE",
            "body": "", "bodyHTML": "", "createdAt": "2026-01-01T00:00:00Z", "headRefName": "f", "baseRefName": "main", "headRefOid": "h",
            "additions": 1, "deletions": 1, "changedFiles": 2, "viewerCanUpdate": true, "viewerDidAuthor": false,
            "labels": { "nodes": [] }, "assignees": { "nodes": [] }, "reviewRequests": { "nodes": [] },
            "latestOpinionatedReviews": { "nodes": [{ "state": "APPROVED", "author": { "login": "alice", "avatarUrl": "" } }] },
            "lastCommit": { "nodes": [] }, "allCommits": { "nodes": [] }, "timelineItems": { "nodes": [] }, "reviewThreads": { "nodes": [] }
        }))
        .unwrap();
        let s = OwnershipSummary::build(&CodeOwners::parse("app/ @alice @bob", "CODEOWNERS"), &list(&["app/a.rb", "README.md"]), &pr);
        let owners = s.owners_of("app/a.rb").unwrap();
        assert_eq!(owners.iter().map(|o| o.handle.as_str()).collect::<Vec<_>>(), vec!["alice", "bob"]);
        assert_eq!(owners[0].status, OwnerStatus::Approved);
        assert!(s.owners_of("README.md").is_none());
        assert_eq!(s.unowned, list(&["README.md"]));
    }
}
