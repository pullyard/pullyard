use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

use crate::api::models::RepoRef;

const BRANCH_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'!')
    .remove(b'$')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')')
    .remove(b'*')
    .remove(b',')
    .remove(b'-')
    .remove(b'.')
    .remove(b'/')
    .remove(b':')
    .remove(b';')
    .remove(b'@')
    .remove(b'_')
    .remove(b'~');

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum RemoteKind {
    Github,
    Gitlab,
    Bitbucket,
    Other,
}

impl RemoteKind {
    pub fn request_noun(&self) -> &'static str {
        match self {
            RemoteKind::Gitlab => "merge request",
            _ => "pull request",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Hash, Debug)]
pub struct GitRemote {
    pub host: String,
    pub path: String,
}

impl GitRemote {
    pub fn parse(raw: &str) -> Option<GitRemote> {
        let url = raw.trim();
        if url.is_empty() {
            return None;
        }
        let (host, path) = if let Some((_, rest)) = url.split_once("://") {
            let (host, path) = rest.split_once('/')?;
            let host = host.rsplit_once('@').map(|(_, h)| h).unwrap_or(host);
            let host = host.split_once(':').map(|(h, _)| h).unwrap_or(host);
            (host, path)
        } else if let Some((host, path)) = url.split_once(':') {
            if host.contains('/') {
                return None;
            }
            let host = host.rsplit_once('@').map(|(_, h)| h).unwrap_or(host);
            (host, path)
        } else {
            return None;
        };
        let path = path.trim_matches('/');
        let path = path.strip_suffix(".git").unwrap_or(path);
        if host.is_empty() || !path.contains('/') {
            return None;
        }
        Some(GitRemote { host: host.to_string(), path: path.to_string() })
    }

    pub fn kind(&self) -> RemoteKind {
        let h = self.host.to_lowercase();
        if h.contains("github") {
            RemoteKind::Github
        } else if h.contains("gitlab") {
            RemoteKind::Gitlab
        } else if h.contains("bitbucket") {
            RemoteKind::Bitbucket
        } else {
            RemoteKind::Other
        }
    }

    pub fn web_url(&self) -> String {
        format!("https://{}/{}", self.host, self.path)
    }

    pub fn repo(&self) -> Option<RepoRef> {
        let h = self.host.to_lowercase();
        if h == "github.com" || h.ends_with(".github.com") {
            RepoRef::from_full(&self.path)
        } else {
            None
        }
    }

    pub fn new_request_url(&self, branch: &str, kind: RemoteKind) -> String {
        let b = utf8_percent_encode(branch, BRANCH_SET);
        let web = self.web_url();
        match kind {
            RemoteKind::Github => format!("{web}/pull/new/{b}"),
            RemoteKind::Gitlab => format!("{web}/-/merge_requests/new?merge_request%5Bsource_branch%5D={b}"),
            RemoteKind::Bitbucket => format!("{web}/pull-requests/new?source={b}"),
            RemoteKind::Other => format!("{web}/pulls"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn remote(host: &str, path: &str) -> GitRemote {
        GitRemote { host: host.into(), path: path.into() }
    }

    #[test]
    fn parses_common_url_forms() {
        assert_eq!(GitRemote::parse("git@github.com:acme/app.git\n"), Some(remote("github.com", "acme/app")));
        assert_eq!(GitRemote::parse("https://github.com/acme/app"), Some(remote("github.com", "acme/app")));
        assert_eq!(GitRemote::parse("https://user@gitlab.example.com:8443/group/sub/app.git"), Some(remote("gitlab.example.com", "group/sub/app")));
        assert_eq!(GitRemote::parse("ssh://git@bitbucket.org/team/app.git"), Some(remote("bitbucket.org", "team/app")));
        assert_eq!(GitRemote::parse("https://github.com/acme/app/"), Some(remote("github.com", "acme/app")));
        assert_eq!(GitRemote::parse(""), None);
        assert_eq!(GitRemote::parse("/local/path/repo.git"), None);
        assert_eq!(GitRemote::parse("https://github.com/only-owner"), None);
    }

    #[test]
    fn only_github_dot_com_yields_repo_ref() {
        assert_eq!(GitRemote::parse("git@github.com:acme/app.git").and_then(|r| r.repo()).map(|r| r.full()).as_deref(), Some("acme/app"));
        assert_eq!(GitRemote::parse("ssh://git@ssh.github.com:443/acme/app.git").and_then(|r| r.repo()).map(|r| r.full()).as_deref(), Some("acme/app"));
        assert!(GitRemote::parse("git@gitlab.com:acme/app.git").and_then(|r| r.repo()).is_none());
        assert!(GitRemote::parse("git@github.example.com:acme/app.git").and_then(|r| r.repo()).is_none());
    }

    #[test]
    fn kind_and_new_request_url() {
        let lab = remote("gitlab.com", "acme/app");
        assert_eq!(lab.kind(), RemoteKind::Gitlab);
        assert_eq!(lab.new_request_url("feat/x", lab.kind()), "https://gitlab.com/acme/app/-/merge_requests/new?merge_request%5Bsource_branch%5D=feat/x");
        let bb = remote("bitbucket.org", "team/app");
        assert_eq!(bb.new_request_url("a&b", bb.kind()), "https://bitbucket.org/team/app/pull-requests/new?source=a%26b");
        let hub = remote("github.com", "acme/app");
        assert_eq!(hub.new_request_url("fix #1", hub.kind()), "https://github.com/acme/app/pull/new/fix%20%231");
        let own = remote("git.example.com", "acme/app");
        assert_eq!(own.kind(), RemoteKind::Other);
        assert_eq!(own.new_request_url("x", RemoteKind::Other), "https://git.example.com/acme/app/pulls");
        assert_eq!(RemoteKind::Gitlab.request_noun(), "merge request");
        assert_eq!(RemoteKind::Other.request_noun(), "pull request");
    }
}
