pub mod mcp;
pub mod notes;
pub mod store;

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::api::models::{RepoRef, VisualState};

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StackNode {
    pub number: i64,
    pub title: String,
    pub state: String,
    pub is_draft: bool,
    pub head_ref_name: String,
    pub base_ref_name: String,
    #[serde(default)]
    pub head_repo: Option<String>,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default)]
    pub updated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub review_decision: Option<String>,
    #[serde(default)]
    pub ci: Option<String>,
    #[serde(default)]
    pub commit_oid: Option<String>,
    #[serde(default)]
    pub commit_headline: Option<String>,
}

static JIRA: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new("^[A-Z][A-Z0-9]+-[0-9]+").expect("regex"));

pub fn jira_key(text: &str) -> Option<String> {
    let mut prev: Option<char> = None;
    for (i, c) in text.char_indices() {
        if c.is_ascii_uppercase() && !prev.is_some_and(|p| p.is_ascii_alphanumeric()) {
            if let Some(m) = JIRA.find(&text[i..]) {
                return Some(m.as_str().to_string());
            }
        }
        prev = Some(c);
    }
    None
}

impl StackNode {
    pub fn visual_state(&self) -> VisualState {
        VisualState::pr(&self.state, self.is_draft)
    }

    pub fn status(&self) -> StackStatus {
        StackStatus::of(self)
    }

    pub fn jira_key(&self) -> Option<String> {
        jira_key(&self.head_ref_name).or_else(|| jira_key(&self.title))
    }

    pub fn merging(&self, fresh: &StackNode) -> StackNode {
        StackNode {
            number: self.number,
            title: fresh.title.clone(),
            state: fresh.state.clone(),
            is_draft: fresh.is_draft,
            head_ref_name: fresh.head_ref_name.clone(),
            base_ref_name: fresh.base_ref_name.clone(),
            head_repo: fresh.head_repo.clone().or_else(|| self.head_repo.clone()),
            author: fresh.author.clone().or_else(|| self.author.clone()),
            updated_at: fresh.updated_at.or(self.updated_at),
            review_decision: fresh.review_decision.clone().or_else(|| self.review_decision.clone()),
            ci: fresh.ci.clone().or_else(|| self.ci.clone()),
            commit_oid: fresh.commit_oid.clone().or_else(|| self.commit_oid.clone()),
            commit_headline: fresh.commit_headline.clone().or_else(|| self.commit_headline.clone()),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StackStatus {
    Merged,
    Closed,
    Draft,
    CiFailed,
    ChangesRequested,
    Ready,
    Checking,
    Review,
}

impl StackStatus {
    pub fn of(n: &StackNode) -> Self {
        match n.state.as_str() {
            "MERGED" => StackStatus::Merged,
            "CLOSED" => StackStatus::Closed,
            _ => {
                let ci = n.ci.as_deref();
                if n.is_draft {
                    StackStatus::Draft
                } else if matches!(ci, Some("FAILURE") | Some("ERROR")) {
                    StackStatus::CiFailed
                } else if n.review_decision.as_deref() == Some("CHANGES_REQUESTED") {
                    StackStatus::ChangesRequested
                } else if matches!(ci, Some("PENDING") | Some("EXPECTED")) {
                    StackStatus::Checking
                } else if n.review_decision.as_deref() == Some("APPROVED") {
                    StackStatus::Ready
                } else {
                    StackStatus::Review
                }
            }
        }
    }

    pub fn title(&self) -> &'static str {
        match self {
            StackStatus::Merged => "Merged",
            StackStatus::Closed => "Closed",
            StackStatus::Draft => "Draft",
            StackStatus::CiFailed => "CI failed",
            StackStatus::ChangesRequested => "Changes requested",
            StackStatus::Ready => "Ready",
            StackStatus::Checking => "Checks running",
            StackStatus::Review => "In review",
        }
    }

    pub fn color(&self) -> &'static str {
        match self {
            StackStatus::Merged => "violet",
            StackStatus::Closed | StackStatus::CiFailed | StackStatus::ChangesRequested => "red",
            StackStatus::Draft => "slate",
            StackStatus::Ready => "green",
            StackStatus::Checking | StackStatus::Review => "amber",
        }
    }

    pub fn needs_attention(&self) -> bool {
        matches!(self, StackStatus::CiFailed | StackStatus::ChangesRequested)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StackTree {
    pub base: String,
    pub current: i64,
    pub nodes: HashMap<i64, StackNode>,
    pub parent: HashMap<i64, i64>,
    pub children: HashMap<i64, Vec<i64>>,
    pub root: i64,
}

pub const NODE_LIMIT: usize = 60;

impl StackTree {
    pub fn count(&self) -> usize {
        self.nodes.len()
    }

    pub fn kids(&self, n: i64) -> &[i64] {
        self.children.get(&n).map(|v| v.as_slice()).unwrap_or(&[])
    }

    pub fn line(&self) -> Vec<&StackNode> {
        let mut up: Vec<i64> = vec![];
        let mut seen: HashSet<i64> = HashSet::new();
        let mut n = Some(self.current);
        while let Some(x) = n {
            if !seen.insert(x) {
                break;
            }
            up.insert(0, x);
            n = self.parent.get(&x).copied();
        }
        let mut down = self.current;
        while let Some(next) = self.kids(down).first().copied() {
            if !seen.insert(next) {
                break;
            }
            up.push(next);
            down = next;
        }
        up.iter().filter_map(|x| self.nodes.get(x)).collect()
    }

    pub fn path_set(&self) -> HashSet<i64> {
        let mut out: HashSet<i64> = HashSet::new();
        let mut n = Some(self.current);
        while let Some(x) = n {
            if !out.insert(x) {
                break;
            }
            n = self.parent.get(&x).copied();
        }
        let mut stack: Vec<i64> = self.kids(self.current).to_vec();
        while let Some(x) = stack.pop() {
            if out.insert(x) {
                stack.extend_from_slice(self.kids(x));
            }
        }
        out
    }

    pub fn on_path(&self, number: i64) -> bool {
        self.path_set().contains(&number)
    }

    pub fn build(current: &StackNode, open: &[StackNode], repo: &str, limit: usize) -> Option<StackTree> {
        let mut all: HashMap<i64, StackNode> = HashMap::with_capacity(open.len() + 1);
        for n in open {
            all.insert(n.number, n.clone());
        }
        let merged = match all.get(&current.number) {
            Some(existing) => existing.merging(current),
            None => current.clone(),
        };
        all.insert(current.number, merged);

        let repo_key = repo.to_lowercase();
        let cur = current.number;
        let preferred = |a: &StackNode, b: &StackNode| -> bool {
            if a.number == cur || b.number == cur {
                return a.number == cur;
            }
            let da = a.updated_at.unwrap_or(DateTime::<Utc>::MIN_UTC);
            let db = b.updated_at.unwrap_or(DateTime::<Utc>::MIN_UTC);
            if da == db {
                a.number > b.number
            } else {
                da > db
            }
        };
        let mut owner: HashMap<&str, i64> = HashMap::new();
        for n in all.values() {
            if n.head_repo.as_deref().map(|h| h.to_lowercase()) != Some(repo_key.clone()) || !(n.state == "OPEN" || n.number == cur) {
                continue;
            }
            if let Some(existing) = owner.get(n.head_ref_name.as_str()).and_then(|e| all.get(e)) {
                if !preferred(n, existing) {
                    continue;
                }
            }
            owner.insert(n.head_ref_name.as_str(), n.number);
        }

        let parent_of = |n: &StackNode| -> Option<i64> { owner.get(n.base_ref_name.as_str()).copied().filter(|p| *p != n.number) };

        let mut kids: HashMap<i64, Vec<i64>> = HashMap::new();
        for n in all.values() {
            if let Some(p) = parent_of(n) {
                kids.entry(p).or_default().push(n.number);
            }
        }
        for v in kids.values_mut() {
            v.sort_unstable();
        }

        let mut path: Vec<i64> = vec![cur];
        let mut seen: HashSet<i64> = HashSet::from([cur]);
        let mut top = cur;
        while let Some(p) = all.get(&top).and_then(&parent_of) {
            if !seen.insert(p) {
                break;
            }
            path.insert(0, p);
            top = p;
        }

        let mut included: HashSet<i64> = path.iter().copied().collect();
        let mut queue: Vec<i64> = vec![top];
        let mut queued: HashSet<i64> = HashSet::from([top]);
        let mut i = 0;
        while i < queue.len() {
            let x = queue[i];
            i += 1;
            for &c in kids.get(&x).map(|v| v.as_slice()).unwrap_or(&[]) {
                if queued.contains(&c) {
                    continue;
                }
                if !(included.contains(&c) || included.len() < limit) {
                    continue;
                }
                included.insert(c);
                queued.insert(c);
                queue.push(c);
            }
        }
        if included.len() <= 1 {
            return None;
        }

        let mut nodes: HashMap<i64, StackNode> = HashMap::with_capacity(included.len());
        let mut parent: HashMap<i64, i64> = HashMap::new();
        let mut children: HashMap<i64, Vec<i64>> = HashMap::new();
        for &x in &included {
            let Some(node) = all.get(&x) else { continue };
            if x != top {
                if let Some(p) = parent_of(node).filter(|p| included.contains(p)) {
                    parent.insert(x, p);
                }
            }
            let cs: Vec<i64> = kids.get(&x).map(|v| v.iter().copied().filter(|c| included.contains(c) && *c != top).collect()).unwrap_or_default();
            if !cs.is_empty() {
                children.insert(x, cs);
            }
            nodes.insert(x, node.clone());
        }
        let base = all.get(&top).map(|n| n.base_ref_name.clone()).unwrap_or_default();
        Some(StackTree { base, current: cur, nodes, parent, children, root: top })
    }

    pub fn rows(&self) -> Vec<(i64, usize)> {
        let mut out = vec![];
        let mut seen: HashSet<i64> = HashSet::new();
        let mut stack: Vec<(i64, usize)> = vec![(self.root, 0)];
        while let Some((n, depth)) = stack.pop() {
            if !seen.insert(n) {
                continue;
            }
            if self.nodes.contains_key(&n) {
                out.push((n, depth));
            }
            for &c in self.kids(n).iter().rev() {
                stack.push((c, depth + 1));
            }
        }
        out
    }

    pub fn ordered(&self) -> Vec<&StackNode> {
        let mut out = vec![];
        let mut seen: HashSet<i64> = HashSet::new();
        let mut queue = std::collections::VecDeque::from([self.root]);
        while let Some(n) = queue.pop_front() {
            if !seen.insert(n) {
                continue;
            }
            if let Some(node) = self.nodes.get(&n) {
                out.push(node);
            }
            queue.extend(self.kids(n).iter().copied());
        }
        out
    }

    pub fn anchor_key(&self) -> String {
        format!("{}|{}", self.root, self.base)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Slot {
    pub column: f64,
    pub level: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StackLayout {
    pub slots: HashMap<i64, Slot>,
    pub columns: usize,
    pub levels: usize,
}

impl StackLayout {
    pub fn new(tree: &StackTree) -> Self {
        let mut slots: HashMap<i64, Slot> = HashMap::new();
        let mut next = 0usize;
        let mut depth = 0usize;
        let mut visiting: HashSet<i64> = HashSet::new();
        fn place(tree: &StackTree, n: i64, level: usize, slots: &mut HashMap<i64, Slot>, next: &mut usize, depth: &mut usize, visiting: &mut HashSet<i64>) {
            if !visiting.insert(n) {
                return;
            }
            *depth = (*depth).max(level);
            let cs = tree.kids(n);
            let mut cols: Vec<f64> = vec![];
            for &c in cs {
                place(tree, c, level + 1, slots, next, depth, visiting);
                if let Some(s) = slots.get(&c) {
                    cols.push(s.column);
                }
            }
            if cols.is_empty() {
                slots.insert(n, Slot { column: *next as f64, level });
                *next += 1;
                return;
            }
            let lo = cols.iter().cloned().fold(f64::INFINITY, f64::min);
            let hi = cols.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
            slots.insert(n, Slot { column: (lo + hi) / 2.0, level });
        }
        place(tree, tree.root, 1, &mut slots, &mut next, &mut depth, &mut visiting);
        StackLayout { slots, columns: next.max(1), levels: depth }
    }
}

pub mod metrics {
    pub const PAD: f64 = 28.0;
    pub const CARD_WIDTH: f64 = 256.0;
    pub const CARD_HEIGHT: f64 = 120.0;
    pub const GAP_X: f64 = 28.0;
    pub const GAP_Y: f64 = 58.0;
    pub const PILL_HEIGHT: f64 = 30.0;
    pub const PILL_WIDTH: f64 = 150.0;
    pub const NOTE_GAP: f64 = 8.0;
    pub const NOTE_HEIGHT: f64 = 76.0;
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec2 {
    pub x: f64,
    pub y: f64,
}

impl Vec2 {
    pub const fn new(x: f64, y: f64) -> Self {
        Vec2 { x, y }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StackGeometry {
    pub layout: StackLayout,
    pub noted: HashSet<i64>,
    pub size: Vec2,
    tops: HashMap<usize, f64>,
}

impl StackGeometry {
    pub fn new(layout: StackLayout, noted: HashSet<i64>) -> Self {
        use metrics::*;
        let noted_levels: HashSet<usize> = noted.iter().filter_map(|n| layout.slots.get(n).map(|s| s.level)).collect();
        let mut tops = HashMap::new();
        let mut y = PAD + PILL_HEIGHT + GAP_Y;
        for level in 1..=layout.levels.max(1) {
            tops.insert(level, y);
            y += CARD_HEIGHT + if noted_levels.contains(&level) { NOTE_GAP + NOTE_HEIGHT } else { 0.0 } + GAP_Y;
        }
        let size = Vec2::new(PAD * 2.0 + layout.columns as f64 * (CARD_WIDTH + GAP_X) - GAP_X, y - GAP_Y + PAD);
        StackGeometry { layout, noted, size, tops }
    }

    pub fn origin(&self, number: i64) -> Option<Vec2> {
        use metrics::*;
        let slot = self.layout.slots.get(&number)?;
        Some(Vec2::new(PAD + slot.column * (CARD_WIDTH + GAP_X), self.tops.get(&slot.level).copied().unwrap_or(0.0)))
    }

    pub fn bottom(&self, number: i64) -> Option<f64> {
        use metrics::*;
        let o = self.origin(number)?;
        Some(o.y + CARD_HEIGHT + if self.noted.contains(&number) { NOTE_GAP + NOTE_HEIGHT } else { 0.0 })
    }

    pub fn center(&self, number: i64) -> Option<Vec2> {
        self.origin(number).map(|o| Vec2::new(o.x + metrics::CARD_WIDTH / 2.0, o.y + metrics::CARD_HEIGHT / 2.0))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StackViewport {
    pub zoom: f64,
    pub pan: Vec2,
}

impl Default for StackViewport {
    fn default() -> Self {
        StackViewport { zoom: 1.0, pan: Vec2::default() }
    }
}

pub const ZOOM_MIN: f64 = 0.12;
pub const ZOOM_MAX: f64 = 1.6;
pub const PAN_MARGIN: f64 = 80.0;
pub const CULL_MARGIN: f64 = 60.0;
pub const COMPACT_BELOW: f64 = 0.45;

impl StackViewport {
    pub fn centered(point: Vec2, zoom: f64, content: Vec2, viewport: Vec2) -> Self {
        StackViewport { zoom, pan: Vec2::new(viewport.x / 2.0 - point.x * zoom, viewport.y / 2.0 - point.y * zoom) }.clamped(content, viewport)
    }

    pub fn fit(content: Vec2, viewport: Vec2) -> Self {
        if content.x <= 0.0 || content.y <= 0.0 {
            return StackViewport::default();
        }
        let z = 1f64.min((viewport.x - 24.0) / content.x).min((viewport.y - 24.0) / content.y).clamp(ZOOM_MIN, ZOOM_MAX);
        StackViewport { zoom: z, pan: Vec2::default() }.clamped(content, viewport)
    }

    pub fn zoomed(&self, value: f64, anchor: Vec2, content: Vec2, viewport: Vec2) -> Self {
        let z = value.clamp(ZOOM_MIN, ZOOM_MAX);
        let k = z / self.zoom;
        StackViewport { zoom: z, pan: Vec2::new(anchor.x - (anchor.x - self.pan.x) * k, anchor.y - (anchor.y - self.pan.y) * k) }.clamped(content, viewport)
    }

    pub fn panned(&self, delta: Vec2, content: Vec2, viewport: Vec2) -> Self {
        StackViewport { zoom: self.zoom, pan: Vec2::new(self.pan.x + delta.x, self.pan.y + delta.y) }.clamped(content, viewport)
    }

    pub fn clamped(&self, content: Vec2, viewport: Vec2) -> Self {
        let zoom = self.zoom;
        let axis = |p: f64, length: f64, visible: f64| -> f64 {
            let scaled = length * zoom;
            if scaled <= visible {
                return (visible - scaled) / 2.0;
            }
            p.min(PAN_MARGIN).max(visible - scaled - PAN_MARGIN)
        };
        StackViewport { zoom, pan: Vec2::new(axis(self.pan.x, content.x, viewport.x), axis(self.pan.y, content.y, viewport.y)) }
    }

    pub fn lerp(&self, to: &StackViewport, t: f64) -> Self {
        StackViewport { zoom: self.zoom + (to.zoom - self.zoom) * t, pan: Vec2::new(self.pan.x + (to.pan.x - self.pan.x) * t, self.pan.y + (to.pan.y - self.pan.y) * t) }
    }

    pub fn to_screen(&self, p: Vec2) -> Vec2 {
        Vec2::new(self.pan.x + p.x * self.zoom, self.pan.y + p.y * self.zoom)
    }

    pub fn to_content(&self, p: Vec2) -> Vec2 {
        Vec2::new((p.x - self.pan.x) / self.zoom, (p.y - self.pan.y) / self.zoom)
    }
}

pub fn visible_cards(tree: &StackTree, geometry: &StackGeometry, vp: &StackViewport, size: Vec2) -> HashSet<i64> {
    let margin = CULL_MARGIN / vp.zoom.max(0.25);
    let x0 = -vp.pan.x / vp.zoom - margin;
    let y0 = -vp.pan.y / vp.zoom - margin;
    let x1 = x0 + size.x / vp.zoom + margin * 2.0;
    let y1 = y0 + size.y / vp.zoom + margin * 2.0;
    tree.nodes
        .keys()
        .copied()
        .filter(|&n| {
            let (Some(o), Some(bottom)) = (geometry.origin(n), geometry.bottom(n)) else { return false };
            o.x < x1 && o.x + metrics::CARD_WIDTH > x0 && o.y < y1 && bottom > y0
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum EdgeShape {
    Line(Vec2, Vec2),
    Curve(Vec2, Vec2),
    Elbow(Vec2, Vec2, f64),
}

impl EdgeShape {
    pub fn bounds(&self) -> (Vec2, Vec2) {
        let (a, b) = match self {
            EdgeShape::Line(a, b) | EdgeShape::Curve(a, b) | EdgeShape::Elbow(a, b, _) => (*a, *b),
        };
        (Vec2::new(a.x.min(b.x), a.y.min(b.y)), Vec2::new(a.x.max(b.x), a.y.max(b.y)))
    }

    pub fn elbow_radius(from: Vec2, to: Vec2, bus_y: f64) -> f64 {
        18f64.min((to.x - from.x).abs() / 2.0).min(bus_y - from.y).min(to.y - bus_y).max(0.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Edge {
    pub shape: EdgeShape,
    pub lit: bool,
    pub label: Option<(Vec2, bool)>,
}

pub fn edges(tree: &StackTree, geometry: &StackGeometry) -> Vec<Edge> {
    use metrics::*;
    let half = CARD_WIDTH / 2.0;
    let path = tree.path_set();
    let mut out = vec![];
    if let Some(o) = geometry.origin(tree.root) {
        let top = Vec2::new(o.x + half, o.y);
        out.push(Edge { shape: EdgeShape::Line(Vec2::new(o.x + half, PAD + PILL_HEIGHT), top), lit: true, label: Some((top, false)) });
    }
    let mut parents: Vec<&i64> = tree.children.keys().collect();
    parents.sort_unstable();
    for &parent in parents {
        let kids = tree.kids(parent);
        let (Some(p), Some(pb)) = (geometry.origin(parent), geometry.bottom(parent)) else { continue };
        let from = Vec2::new(p.x + half, pb);
        let tops: Vec<(i64, Vec2)> = kids.iter().filter_map(|&k| geometry.origin(k).map(|o| (k, Vec2::new(o.x + half, o.y)))).collect();
        let Some(first_top) = tops.iter().map(|t| t.1.y).reduce(f64::min) else { continue };
        let mid_y = pb + (first_top - pb) / 2.0;
        let fan = tops.len() > 4;
        for (k, top) in tops {
            let shape = if fan { EdgeShape::Elbow(from, top, mid_y) } else { EdgeShape::Curve(from, top) };
            let from_right = from.x > top.x + 1.0;
            let lit = path.contains(&k) && path.contains(&parent);
            let label = if lit || !fan { Some((top, from_right)) } else { None };
            out.push(Edge { shape, lit, label });
        }
    }
    out
}

#[derive(Clone, Debug, PartialEq)]
pub struct StackEntry {
    pub repo: RepoRef,
    pub tree: StackTree,
    pub mine: Vec<i64>,
    pub updated: Option<DateTime<Utc>>,
}

impl StackEntry {
    pub fn id(&self) -> String {
        format!("{}#{}", self.repo.full(), self.tree.root)
    }

    pub fn collect(repo: &RepoRef, mine: &[i64], open: &[StackNode]) -> Vec<StackEntry> {
        let index: HashMap<i64, &StackNode> = open.iter().map(|n| (n.number, n)).collect();
        let mut by_root: Vec<StackEntry> = vec![];
        let full = repo.full();
        for number in mine {
            let Some(node) = index.get(number) else { continue };
            let Some(tree) = StackTree::build(node, open, &full, NODE_LIMIT) else { continue };
            if by_root.iter().any(|e| e.tree.root == tree.root) {
                continue;
            }
            let mine_here: Vec<i64> = mine.iter().copied().filter(|m| tree.nodes.contains_key(m)).collect();
            let updated = tree.nodes.values().filter_map(|n| n.updated_at).max();
            by_root.push(StackEntry { repo: repo.clone(), tree, mine: mine_here, updated });
        }
        by_root.sort_by(|a, b| b.updated.cmp(&a.updated));
        by_root
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const REPO: &str = "acme/app";

    fn node(number: i64, head: &str, base: &str) -> StackNode {
        StackNode {
            number,
            title: format!("PR {number}"),
            state: "OPEN".into(),
            is_draft: false,
            head_ref_name: head.into(),
            base_ref_name: base.into(),
            head_repo: Some(REPO.into()),
            author: Some("dev".into()),
            updated_at: Some(DateTime::<Utc>::from_timestamp(0, 0).unwrap()),
            review_decision: None,
            ci: None,
            commit_oid: None,
            commit_headline: None,
        }
    }

    fn with(mut n: StackNode, f: impl FnOnce(&mut StackNode)) -> StackNode {
        f(&mut n);
        n
    }

    fn build(current: &StackNode, open: &[StackNode]) -> Option<StackTree> {
        StackTree::build(current, open, REPO, NODE_LIMIT)
    }

    #[test]
    fn linear_stack() {
        let (p1, p2) = (node(1, "p1", "dev"), node(2, "p2", "p1"));
        let tree = build(&p1, &[p1.clone(), p2.clone()]).unwrap();
        assert_eq!(tree.base, "dev");
        assert_eq!(tree.root, 1);
        assert_eq!(tree.children.get(&1), Some(&vec![2]));
        assert_eq!(tree.parent.get(&2), Some(&1));
        assert_eq!(tree.line().iter().map(|n| n.number).collect::<Vec<_>>(), vec![1, 2]);
    }

    #[test]
    fn branching_stack_keeps_siblings() {
        let (p1, p2, p3) = (node(1, "p1", "dev"), node(2, "p2", "p1"), node(3, "p3", "p1"));
        let tree = build(&p2, &[p3.clone(), p1.clone(), p2.clone()]).unwrap();
        assert_eq!(tree.count(), 3);
        assert_eq!(tree.children.get(&1), Some(&vec![2, 3]));
        assert!(tree.on_path(1));
        assert!(tree.on_path(2));
        assert!(!tree.on_path(3));
        assert_eq!(tree.line().iter().map(|n| n.number).collect::<Vec<_>>(), vec![1, 2]);
    }

    #[test]
    fn unrelated_pull_requests_on_base_are_left_out() {
        let (p1, p2, other) = (node(1, "p1", "dev"), node(2, "p2", "p1"), node(9, "other", "dev"));
        let tree = build(&p2, &[p1, p2.clone(), other]).unwrap();
        let mut keys: Vec<i64> = tree.nodes.keys().copied().collect();
        keys.sort();
        assert_eq!(keys, vec![1, 2]);
    }

    #[test]
    fn single_pull_request_is_not_a_stack() {
        let (p1, other) = (node(1, "p1", "dev"), node(9, "other", "dev"));
        assert!(build(&p1, &[p1.clone(), other]).is_none());
    }

    #[test]
    fn fork_branch_with_same_name_is_not_a_parent() {
        let fork = with(node(5, "dev", "main"), |n| n.head_repo = Some("someone/app".into()));
        let p1 = node(1, "p1", "dev");
        assert!(build(&p1, &[fork, p1.clone()]).is_none());
    }

    #[test]
    fn current_pull_request_missing_from_open_list_is_added() {
        let merged = with(node(1, "p1", "dev"), |n| n.state = "MERGED".into());
        let p2 = node(2, "p2", "p1");
        let tree = build(&merged, &[p2]).unwrap();
        assert_eq!(tree.root, 1);
        assert_eq!(tree.children.get(&1), Some(&vec![2]));
    }

    #[test]
    fn cycle_does_not_hang() {
        let (a, b) = (node(1, "a", "b"), node(2, "b", "a"));
        let tree = build(&a, &[a.clone(), b]).unwrap();
        assert_eq!(tree.count(), 2);
        assert_eq!(StackLayout::new(&tree).slots.len(), 2);
        assert_eq!(tree.rows().len(), 2);
        assert_eq!(tree.line().len(), 2);
    }

    #[test]
    fn duplicate_head_prefers_most_recent() {
        let old = with(node(1, "p1", "dev"), |n| n.updated_at = DateTime::<Utc>::from_timestamp(10, 0));
        let fresh = with(node(4, "p1", "dev"), |n| n.updated_at = DateTime::<Utc>::from_timestamp(20, 0));
        let child = node(2, "p2", "p1");
        let tree = build(&child, &[old, fresh, child.clone()]).unwrap();
        assert_eq!(tree.parent.get(&2), Some(&4));
    }

    #[test]
    fn limit_always_keeps_current_path() {
        let mut open = vec![node(1, "root", "dev")];
        for n in 2..=40 {
            open.push(node(n, &format!("leaf{n}"), "root"));
        }
        let deep = node(100, "deep", "leaf40");
        open.push(deep.clone());
        let tree = StackTree::build(&deep, &open, REPO, 5).unwrap();
        assert!(tree.nodes.contains_key(&100));
        assert!(tree.nodes.contains_key(&40));
        assert!(tree.count() <= 5);
    }

    #[test]
    fn layout_centers_parent_over_children() {
        let (p1, p2, p3) = (node(1, "p1", "dev"), node(2, "p2", "p1"), node(3, "p3", "p1"));
        let layout = StackLayout::new(&build(&p1, &[p1.clone(), p2, p3]).unwrap());
        assert_eq!(layout.columns, 2);
        assert_eq!(layout.levels, 2);
        assert_eq!(layout.slots.get(&1), Some(&Slot { column: 0.5, level: 1 }));
        assert_eq!(layout.slots.get(&2), Some(&Slot { column: 0.0, level: 2 }));
        assert_eq!(layout.slots.get(&3), Some(&Slot { column: 1.0, level: 2 }));
    }

    #[test]
    fn rows_are_depth_first_with_depth() {
        let open = [node(1, "p1", "dev"), node(2, "p2", "p1"), node(3, "p3", "p2"), node(4, "p4", "p1")];
        let tree = build(&open[0], &open).unwrap();
        assert_eq!(tree.rows(), vec![(1, 0), (2, 1), (3, 2), (4, 1)]);
        assert_eq!(tree.ordered().iter().map(|n| n.number).collect::<Vec<_>>(), vec![1, 2, 4, 3]);
    }

    #[test]
    fn status() {
        let base = node(1, "a", "b");
        assert_eq!(with(base.clone(), |n| n.is_draft = true).status(), StackStatus::Draft);
        assert_eq!(
            with(base.clone(), |n| {
                n.ci = Some("FAILURE".into());
                n.review_decision = Some("APPROVED".into());
            })
            .status(),
            StackStatus::CiFailed
        );
        assert_eq!(with(base.clone(), |n| n.review_decision = Some("CHANGES_REQUESTED".into())).status(), StackStatus::ChangesRequested);
        assert_eq!(
            with(base.clone(), |n| {
                n.ci = Some("PENDING".into());
                n.review_decision = Some("APPROVED".into());
            })
            .status(),
            StackStatus::Checking
        );
        assert_eq!(
            with(base.clone(), |n| {
                n.ci = Some("SUCCESS".into());
                n.review_decision = Some("APPROVED".into());
            })
            .status(),
            StackStatus::Ready
        );
        assert_eq!(with(base.clone(), |n| n.ci = Some("SUCCESS".into())).status(), StackStatus::Review);
        assert_eq!(with(base, |n| n.state = "MERGED".into()).status(), StackStatus::Merged);
    }

    #[test]
    fn jira_keys() {
        assert_eq!(jira_key("COM-1640-fe-implement-onboarding").as_deref(), Some("COM-1640"));
        assert_eq!(jira_key("feature/ABC2-12_fix").as_deref(), Some("ABC2-12"));
        assert_eq!(jira_key("fix-123-login"), None);
        assert_eq!(jira_key("release/v2-1"), None);
        assert_eq!(jira_key("xABC-12"), None);
        assert_eq!(with(node(1, "feature/thing", "dev"), |n| n.title = "PAY-7 Retry".into()).jira_key().as_deref(), Some("PAY-7"));
    }

    #[test]
    fn one_entry_per_stack() {
        let open = [node(1, "a", "dev"), node(2, "b", "a"), node(3, "c", "a"), node(4, "lone", "dev")];
        let entries = StackEntry::collect(&RepoRef::new("acme", "app"), &[2, 3, 4], &open);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].tree.root, 1);
        assert_eq!(entries[0].mine, vec![2, 3]);
        assert_eq!(entries[0].tree.ordered().iter().map(|n| n.number).collect::<Vec<_>>(), vec![1, 2, 3]);
    }

    #[test]
    fn geometry_adds_room_for_notes() {
        let (p1, p2) = (node(1, "p1", "dev"), node(2, "p2", "p1"));
        let tree = build(&p1, &[p1.clone(), p2]).unwrap();
        let plain = StackGeometry::new(StackLayout::new(&tree), HashSet::new());
        let noted = StackGeometry::new(StackLayout::new(&tree), HashSet::from([1]));
        assert_eq!(noted.size.y - plain.size.y, metrics::NOTE_GAP + metrics::NOTE_HEIGHT);
        assert_eq!(noted.bottom(1).unwrap() - noted.origin(1).unwrap().y, metrics::CARD_HEIGHT + metrics::NOTE_GAP + metrics::NOTE_HEIGHT);
        assert!(noted.origin(2).unwrap().y > plain.origin(2).unwrap().y);
    }

    #[test]
    fn wide_fans_use_a_bus() {
        let mut open = vec![node(1, "root", "dev")];
        for n in 2..=7 {
            open.push(node(n, &format!("leaf{n}"), "root"));
        }
        let tree = build(&open[2], &open).unwrap();
        let geometry = StackGeometry::new(StackLayout::new(&tree), HashSet::new());
        let all = edges(&tree, &geometry);
        assert_eq!(all.len(), 7);
        assert!(all.iter().skip(1).all(|e| matches!(e.shape, EdgeShape::Elbow(..))));
        assert_eq!(all.iter().filter(|e| e.lit).count(), 2);
        assert_eq!(all.iter().filter(|e| e.label.is_some()).count(), 2);
        let few = build(&open[0], &open[..3]).unwrap();
        let g = StackGeometry::new(StackLayout::new(&few), HashSet::new());
        assert!(edges(&few, &g).iter().skip(1).all(|e| matches!(e.shape, EdgeShape::Curve(..))));
    }

    #[test]
    fn visible_cards_are_culled() {
        let mut open = vec![node(1, "root", "dev")];
        for n in 2..=30 {
            open.push(node(n, &format!("leaf{n}"), "root"));
        }
        let tree = build(&open[0], &open).unwrap();
        let geometry = StackGeometry::new(StackLayout::new(&tree), HashSet::new());
        let size = Vec2::new(1000.0, 700.0);
        let vp = StackViewport::default();
        let visible = visible_cards(&tree, &geometry, &vp, size);
        assert!(visible.len() < tree.count());
        assert!(visible.contains(&2));
        let all = visible_cards(&tree, &geometry, &StackViewport::fit(geometry.size, size), size);
        assert_eq!(all.len(), tree.count());
    }

    const CONTENT: Vec2 = Vec2::new(6000.0, 2000.0);
    const VIEWPORT: Vec2 = Vec2::new(1000.0, 700.0);

    #[test]
    fn zoom_keeps_point_under_cursor() {
        let start = StackViewport { zoom: 1.0, pan: Vec2::new(-2000.0, -500.0) };
        let anchor = Vec2::new(300.0, 200.0);
        let before = start.to_content(anchor);
        let next = start.zoomed(1.4, anchor, CONTENT, VIEWPORT);
        let after = next.to_content(anchor);
        assert!((before.x - after.x).abs() < 0.001);
        assert!((before.y - after.y).abs() < 0.001);
    }

    #[test]
    fn zoom_is_clamped_to_range() {
        assert_eq!(StackViewport::default().zoomed(50.0, Vec2::default(), CONTENT, VIEWPORT).zoom, ZOOM_MAX);
        assert_eq!(StackViewport::default().zoomed(0.001, Vec2::default(), CONTENT, VIEWPORT).zoom, ZOOM_MIN);
    }

    #[test]
    fn small_content_is_centered() {
        let v = StackViewport { zoom: 1.0, pan: Vec2::new(400.0, -300.0) }.clamped(Vec2::new(500.0, 300.0), VIEWPORT);
        assert_eq!(v.pan.x, 250.0);
        assert_eq!(v.pan.y, 200.0);
    }

    #[test]
    fn pan_stops_at_margin() {
        let far = StackViewport::default().panned(Vec2::new(10_000.0, -10_000.0), CONTENT, VIEWPORT);
        assert_eq!(far.pan.x, PAN_MARGIN);
        assert_eq!(far.pan.y, VIEWPORT.y - CONTENT.y - PAN_MARGIN);
    }

    #[test]
    fn centered_puts_point_in_middle() {
        let v = StackViewport::centered(Vec2::new(3000.0, 1000.0), 1.0, CONTENT, VIEWPORT);
        assert_eq!(v.pan.x + 3000.0, VIEWPORT.x / 2.0);
        assert_eq!(v.pan.y + 1000.0, VIEWPORT.y / 2.0);
    }

    #[test]
    fn fit_shows_everything() {
        let content = Vec2::new(3000.0, 800.0);
        let v = StackViewport::fit(content, VIEWPORT);
        assert!(3000.0 * v.zoom <= VIEWPORT.x);
        assert!(800.0 * v.zoom <= VIEWPORT.y);
        assert!((v.pan.x - (VIEWPORT.x - 3000.0 * v.zoom) / 2.0).abs() < 0.001);
    }

    #[test]
    fn elbow_radius_fits_the_gap() {
        assert_eq!(EdgeShape::elbow_radius(Vec2::new(0.0, 0.0), Vec2::new(200.0, 60.0), 30.0), 18.0);
        assert_eq!(EdgeShape::elbow_radius(Vec2::new(0.0, 0.0), Vec2::new(10.0, 60.0), 30.0), 5.0);
        assert_eq!(EdgeShape::elbow_radius(Vec2::new(0.0, 0.0), Vec2::new(200.0, 20.0), 10.0), 10.0);
    }
}
