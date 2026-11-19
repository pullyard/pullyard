#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum ListSort {
    #[default]
    Updated,
    Created,
    Comments,
}

impl ListSort {
    pub const ALL: [ListSort; 3] = [ListSort::Updated, ListSort::Created, ListSort::Comments];

    pub fn key(&self) -> &'static str {
        match self {
            ListSort::Updated => "updated",
            ListSort::Created => "created",
            ListSort::Comments => "comments",
        }
    }

    pub fn from_key(k: &str) -> Self {
        Self::ALL.into_iter().find(|s| s.key() == k).unwrap_or_default()
    }

    pub fn title(&self) -> &'static str {
        match self {
            ListSort::Updated => "Recently updated",
            ListSort::Created => "Newest",
            ListSort::Comments => "Most commented",
        }
    }

    pub fn query(&self) -> &'static str {
        match self {
            ListSort::Updated => "sort:updated-desc",
            ListSort::Created => "sort:created-desc",
            ListSort::Comments => "sort:comments-desc",
        }
    }
}

pub fn capped(count: usize, cap: usize) -> String {
    if count >= cap {
        format!("{cap}+")
    } else {
        count.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sort_keys_round_trip() {
        for s in ListSort::ALL {
            assert_eq!(ListSort::from_key(s.key()), s);
        }
        assert_eq!(ListSort::from_key(""), ListSort::Updated);
        assert_eq!(ListSort::from_key("stars"), ListSort::Updated);
        assert_eq!(ListSort::Updated.query(), "sort:updated-desc");
        assert_eq!(ListSort::Created.query(), "sort:created-desc");
        assert_eq!(ListSort::Comments.query(), "sort:comments-desc");
        assert_eq!(ListSort::Comments.title(), "Most commented");
    }

    #[test]
    fn counters_show_a_plus_at_the_cap() {
        assert_eq!(capped(0, 100), "0");
        assert_eq!(capped(99, 100), "99");
        assert_eq!(capped(100, 100), "100+");
        assert_eq!(capped(250, 100), "100+");
    }
}
