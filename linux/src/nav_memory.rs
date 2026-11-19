use crate::api::models::{ItemRef, RepoRef, Route};

pub fn encode(route: &Route, account: &str) -> Option<String> {
    match route {
        Route::Pr(r) => Some(format!("{account}|pr|{}|{}", r.repo.full(), r.number)),
        Route::Issue(r) => Some(format!("{account}|issue|{}|{}", r.repo.full(), r.number)),
        Route::Repo(repo) => Some(format!("{account}|repo|{}|0", repo.full())),
        _ => None,
    }
}

pub fn decode(stored: &str, account: &str) -> Option<Route> {
    let mut parts = stored.rsplitn(4, '|');
    let number = parts.next()?;
    let repo = RepoRef::from_full(parts.next()?)?;
    let kind = parts.next()?;
    if parts.next()? != account {
        return None;
    }
    match kind {
        "pr" => number.parse::<i64>().ok().map(|n| Route::Pr(ItemRef { repo, number: n })),
        "issue" => number.parse::<i64>().ok().map(|n| Route::Issue(ItemRef { repo, number: n })),
        "repo" => Some(Route::Repo(repo)),
        _ => None,
    }
}

#[derive(Default)]
pub struct ForwardStack {
    routes: Vec<Route>,
}

impl ForwardStack {
    pub fn popped(&mut self, route: Route) {
        self.routes.push(route);
    }

    pub fn pushed(&mut self, route: &Route) {
        if self.routes.last() == Some(route) {
            self.routes.pop();
        } else {
            self.routes.clear();
        }
    }

    pub fn clear(&mut self) {
        self.routes.clear();
    }

    pub fn peek(&self) -> Option<Route> {
        self.routes.last().cloned()
    }

    pub fn is_empty(&self) -> bool {
        self.routes.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr(n: i64) -> Route {
        Route::Pr(ItemRef { repo: RepoRef::new("a", "b"), number: n })
    }

    #[test]
    fn routes_round_trip_for_the_same_account() {
        for route in [pr(12), Route::Issue(ItemRef { repo: RepoRef::new("a", "b"), number: 3 }), Route::Repo(RepoRef::new("org", "repo"))] {
            let stored = encode(&route, "alice").unwrap();
            assert_eq!(decode(&stored, "alice"), Some(route));
        }
        assert_eq!(encode(&pr(12), "alice").as_deref(), Some("alice|pr|a/b|12"));
        assert_eq!(encode(&Route::Commit(RepoRef::new("a", "b"), "abc".into()), "alice"), None);
        assert_eq!(encode(&Route::Forge("https://gitlab.com/x".into()), "alice"), None);
    }

    #[test]
    fn other_accounts_and_garbage_are_rejected() {
        let stored = encode(&pr(12), "alice").unwrap();
        assert_eq!(decode(&stored, "bob"), None);
        assert_eq!(decode(&stored, ""), None);
        assert_eq!(decode("", "alice"), None);
        assert_eq!(decode("alice|pr|a/b", "alice"), None);
        assert_eq!(decode("alice|pr|nope|1", "alice"), None);
        assert_eq!(decode("alice|pr|a/b|x", "alice"), None);
        assert_eq!(decode("alice|tag|a/b|1", "alice"), None);
        let forge = encode(&pr(5), "bob-gitlab-git|lab").unwrap();
        assert_eq!(decode(&forge, "bob-gitlab-git|lab"), Some(pr(5)));
    }

    #[test]
    fn forward_stack_follows_back_and_forward() {
        let mut f = ForwardStack::default();
        assert!(f.is_empty());
        f.popped(pr(3));
        f.popped(pr(2));
        assert_eq!(f.peek(), Some(pr(2)));
        f.pushed(&pr(2));
        assert_eq!(f.peek(), Some(pr(3)));
        f.pushed(&pr(9));
        assert!(f.is_empty());
        f.popped(pr(1));
        f.clear();
        assert_eq!(f.peek(), None);
    }
}
