//! Swift 기준선과 같은 순서로 보드 좌표와 관계를 계산한다.
use std::collections::{BTreeMap, HashSet};
pub mod golden;
mod routing;
pub use routing::route;
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Edge {
    pub from: String,
    pub to: String,
    pub kind: String,
}
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
impl Point {
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}
pub type Positions = BTreeMap<String, Point>;
#[derive(Clone, Debug, PartialEq)]
pub struct Pipe {
    pub edge: Edge,
    pub points: Vec<Point>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Crossing {
    pub point: Point,
    pub horizontal_pipe: usize,
    pub segment: usize,
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Direct {
    pub kind: String,
    pub outgoing: bool,
    pub other: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Indirect {
    pub via: String,
    pub kind: String,
    pub outgoing: bool,
    pub other: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Relations {
    pub flow: Option<Vec<String>>,
    pub direct: Vec<Direct>,
    pub indirect: Vec<Indirect>,
}
impl Relations {
    pub fn is_visible(&self, show_relations: bool) -> bool {
        self.flow.is_some() || (show_relations && !self.direct.is_empty())
    }
}
/// 입력 순서를 보존하고 두 단계 목적지는 처음 발견한 경로로 최대 열두 개 반환한다.
pub fn relations(
    current: &str,
    flow: Option<Vec<String>>,
    edges: &[Edge],
    depth: usize,
    show_relations: bool,
) -> Relations {
    let neighbors = |id: &str| {
        let mut seen = HashSet::new();
        edges
            .iter()
            .filter(|e| {
                e.from != e.to
                    && (show_relations || e.kind == "flow")
                    && (e.from == id || e.to == id)
            })
            .filter_map(|e| {
                let d = Direct {
                    kind: e.kind.clone(),
                    outgoing: e.from == id,
                    other: if e.from == id {
                        e.to.clone()
                    } else {
                        e.from.clone()
                    },
                };
                seen.insert(d.clone()).then_some(d)
            })
            .collect::<Vec<_>>()
    };
    let direct = neighbors(current);
    let mut excluded: HashSet<String> = direct.iter().map(|d| d.other.clone()).collect();
    excluded.insert(current.into());
    let mut indirect = Vec::new();
    if depth == 2 {
        'outer: for n in &direct {
            for d in neighbors(&n.other) {
                if excluded.insert(d.other.clone()) {
                    indirect.push(Indirect {
                        via: n.other.clone(),
                        kind: d.kind,
                        outgoing: d.outgoing,
                        other: d.other,
                    });
                    if indirect.len() == 12 {
                        break 'outer;
                    }
                }
            }
        }
    }
    Relations {
        flow,
        direct,
        indirect,
    }
}
/// 메모 입력 순서로 결과를 반환한다. 흐름 종류와 무관하게 모든 선으로 무리를 만든다.
pub fn arrange(memos: &[String], edges: &[Edge]) -> Vec<(String, f64, f64)> {
    let n = memos.len();
    let ranks: BTreeMap<_, _> = memos
        .iter()
        .enumerate()
        .map(|(i, id)| (id.as_str(), i))
        .collect();
    let connections: Vec<_> = edges
        .iter()
        .filter_map(|e| Some((*ranks.get(e.from.as_str())?, *ranks.get(e.to.as_str())?)))
        .filter(|(a, b)| a != b)
        .collect();
    fn find(p: &mut [usize], mut i: usize) -> usize {
        let mut r = i;
        while p[r] != r {
            r = p[r]
        }
        while p[i] != r {
            let next = p[i];
            p[i] = r;
            i = next
        }
        r
    }
    let mut parent: Vec<_> = (0..n).collect();
    for &(a, b) in &connections {
        let a = find(&mut parent, a);
        let b = find(&mut parent, b);
        parent[b] = a;
    }
    let mut groups: Vec<Vec<usize>> = Vec::new();
    let mut roots = Vec::new();
    for i in 0..n {
        let r = find(&mut parent, i);
        let j = roots.iter().position(|v| *v == r).unwrap_or_else(|| {
            roots.push(r);
            groups.push(Vec::new());
            groups.len() - 1
        });
        groups[j].push(i);
    }
    let singles: Vec<_> = groups
        .iter()
        .filter(|g| g.len() == 1)
        .map(|g| g[0])
        .collect();
    groups.retain(|g| g.len() > 1);
    groups.sort_by_key(|g| (std::cmp::Reverse(g.len()), g[0]));
    let mut result = vec![Point::default(); n];
    let (mut x, mut y, mut shelf) = (40.0, 100.0, 0.0_f64);
    let half = |v: f64| (v * 2.0 + 0.5).floor() / 2.0;
    for members in &groups {
        let links: Vec<_> = connections
            .iter()
            .copied()
            .filter(|(a, b)| members.contains(a) && members.contains(b))
            .collect();
        let mut levels = vec![0; n];
        for _ in members {
            for &(a, b) in &links {
                levels[b] = levels[b].max(levels[a] + 1)
            }
        }
        for &id in members {
            if !links.iter().any(|&(_, b)| b == id) {
                if let Some(next) = links
                    .iter()
                    .filter(|&&(a, _)| a == id)
                    .map(|&(_, b)| levels[b])
                    .min()
                {
                    levels[id] = 0.max(next - 1)
                }
            }
        }
        let mut layers: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
        for &id in members {
            layers.entry(levels[id]).or_default().push(id)
        }
        let columns: Vec<_> = layers.keys().copied().collect();
        let mut neighbors = vec![Vec::new(); n];
        for &(a, b) in &links {
            neighbors[a].push(b);
            neighbors[b].push(a)
        }
        let mut slots = vec![0.0; n];
        for ids in layers.values() {
            for (i, &id) in ids.iter().enumerate() {
                slots[id] = i as f64 - (ids.len() - 1) as f64 / 2.0
            }
        }
        for iteration in 0..12 {
            let mut cols = columns.clone();
            if iteration % 2 == 1 {
                cols.reverse()
            }
            for col in cols {
                let ids = layers.get_mut(&col).unwrap();
                let mut wanted = vec![0.0; n];
                for &id in ids.iter() {
                    let others: Vec<_> = neighbors[id]
                        .iter()
                        .filter(|&&v| levels[v] != levels[id])
                        .collect();
                    wanted[id] = half(if others.is_empty() {
                        slots[id]
                    } else {
                        others.iter().fold(0.0, |s, &&v| s + slots[v]) / others.len() as f64
                    })
                }
                ids.sort_by(|&a, &b| wanted[a].partial_cmp(&wanted[b]).unwrap().then(a.cmp(&b)));
                let mut values: Vec<_> = ids.iter().map(|&id| wanted[id]).collect();
                for i in 1..values.len() {
                    values[i] = values[i].max(values[i - 1] + 1.0)
                }
                let shift = half(
                    (ids.iter().fold(0.0, |s, &id| s + wanted[id]) - values.iter().sum::<f64>())
                        / ids.len() as f64,
                );
                for (i, &id) in ids.iter().enumerate() {
                    slots[id] = values[i] + shift
                }
            }
        }
        let min = members
            .iter()
            .map(|&i| slots[i])
            .fold(f64::INFINITY, f64::min);
        let places: Vec<_> = members
            .iter()
            .map(|&i| (i, levels[i] as f64 * 280.0, (slots[i] - min) * 200.0))
            .collect();
        let width = places.iter().map(|p| p.1).fold(0.0, f64::max) + 200.0;
        let height = places.iter().map(|p| p.2).fold(0.0, f64::max) + 120.0;
        if x > 40.0 && x + width > 1440.0 {
            x = 40.0;
            y += shelf + 80.0;
            shelf = 0.0
        }
        for (i, px, py) in places {
            result[i] = Point::new(x + px, y + py)
        }
        x += width + 80.0;
        shelf = shelf.max(height);
    }
    let top = if groups.is_empty() {
        100.0
    } else {
        y + shelf + 80.0
    };
    for (i, &id) in singles.iter().enumerate() {
        result[id] = Point::new(40.0 + (i % 5) as f64 * 280.0, top + (i / 5) as f64 * 200.0)
    }
    memos
        .iter()
        .enumerate()
        .map(|(i, id)| (id.clone(), result[i].x, result[i].y))
        .collect()
}
pub fn simplified(points: &[Point]) -> Vec<Point> {
    let mut r: Vec<Point> = Vec::new();
    for &p in points {
        if r.last().is_some_and(|l| (l.x - p.x).hypot(l.y - p.y) < 0.5) {
            continue;
        }
        r.push(p);
        while r.len() >= 3 {
            let n = r.len();
            let (a, b, c) = (r[n - 3], r[n - 2], r[n - 1]);
            if ((a.x - b.x).abs() < 0.5 && (b.x - c.x).abs() < 0.5)
                || ((a.y - b.y).abs() < 0.5 && (b.y - c.y).abs() < 0.5)
            {
                r.remove(n - 2);
            } else {
                break;
            }
        }
    }
    r
}
/// 점열 전체 길이의 절반 지점을 구한다. 빈 점열은 원점으로 처리한다.
pub fn midpoint(points: &[Point]) -> Point {
    let Some(&first) = points.first() else {
        return Point::default();
    };
    let lengths: Vec<_> = points
        .windows(2)
        .map(|p| (p[1].x - p[0].x).hypot(p[1].y - p[0].y))
        .collect();
    let mut rem = lengths.iter().sum::<f64>() / 2.0;
    for (i, l) in lengths.into_iter().enumerate() {
        if rem <= l && l > 0.0 {
            let (a, b, t) = (points[i], points[i + 1], rem / l);
            return Point::new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
        }
        rem -= l
    }
    first
}
/// 두 구간의 끝점을 제외한 교차를 입력 순서대로 반환한다.
pub fn crossings(pipes: &[Pipe]) -> Vec<Crossing> {
    let mut r = Vec::new();
    for p in 0..pipes.len() {
        for q in p + 1..pipes.len() {
            for (i, ab) in pipes[p].points.windows(2).enumerate() {
                for (j, cd) in pipes[q].points.windows(2).enumerate() {
                    let (a, b, c, d) = (ab[0], ab[1], cd[0], cd[1]);
                    let (ph, qh) = ((a.y - b.y).abs() < 0.5, (c.y - d.y).abs() < 0.5);
                    if ph == qh {
                        continue;
                    }
                    let (h0, h1, v0, v1) = if ph { (a, b, c, d) } else { (c, d, a, b) };
                    if (v0.x - v1.x).abs() < 0.5
                        && v0.x > h0.x.min(h1.x) + 0.5
                        && v0.x < h0.x.max(h1.x) - 0.5
                        && h0.y > v0.y.min(v1.y) + 0.5
                        && h0.y < v0.y.max(v1.y) - 0.5
                    {
                        let c = Crossing {
                            point: Point::new(v0.x, h0.y),
                            horizontal_pipe: if ph { p } else { q },
                            segment: if ph { i } else { j },
                        };
                        if !r.contains(&c) {
                            r.push(c)
                        }
                    }
                }
            }
        }
    }
    r
}
#[cfg(test)]
mod tests;
