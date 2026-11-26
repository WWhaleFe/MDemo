use super::*;
#[derive(Clone, Copy, Default)]
struct Cell {
    blocked: bool,
    used_h: bool,
    used_v: bool,
    node_h: bool,
    node_v: bool,
    owner: isize,
}
#[derive(Clone, Copy)]
struct State {
    cost: usize,
    priority: usize,
    previous: isize,
    stamp: usize,
    prev: isize,
    next: isize,
    queued: bool,
}
impl Default for State {
    fn default() -> Self {
        Self {
            cost: 0,
            priority: 0,
            previous: -1,
            stamp: 0,
            prev: -1,
            next: -1,
            queued: false,
        }
    }
}
#[derive(Clone)]
struct Route {
    edge: Edge,
    side: usize,
    a: Point,
    b: Point,
}
struct Router {
    positions: Positions,
    x0: f64,
    y0: f64,
    width: usize,
    height: usize,
    routes: Vec<Route>,
    cells: Vec<Cell>,
    states: Vec<State>,
    generation: usize,
}
const DIR: [(isize, isize); 4] = [(1, 0), (0, 1), (-1, 0), (0, -1)];
/// 양 끝 자리가 있는 선만 입력 순서로 반환하고 기존 점열의 격자 구간을 회피한다.
pub fn route(edges: &[Edge], positions: &Positions, avoiding: &[Pipe]) -> Vec<Pipe> {
    let valid: Vec<_> = edges
        .iter()
        .filter(|e| positions.contains_key(&e.from) && positions.contains_key(&e.to))
        .cloned()
        .collect();
    if valid.is_empty() {
        return Vec::new();
    }
    let mut r = Router::new(valid, positions);
    r.mark_used(avoiding);
    r.route()
}
/// 비용이 같으면 뒤쪽 후보를 고르는 Swift 변 나누기를 보존한다.
fn slots(wanted: &[f64], length: usize) -> Vec<usize> {
    let candidates: Vec<_> = (20..=length - 20).step_by(20).collect();
    let (n, m) = (wanted.len(), candidates.len());
    if n <= 1 {
        return vec![length / 2];
    }
    if n > m {
        return candidates;
    }
    let mut cost = vec![vec![f64::INFINITY; m + 1]; n + 1];
    let mut take = vec![vec![false; m + 1]; n + 1];
    cost[0].fill(0.0);
    for i in 1..=n {
        for j in i..=m {
            let skip = cost[i][j - 1];
            let use_it = cost[i - 1][j - 1] + (candidates[j - 1] as f64 - wanted[i - 1]).abs();
            if use_it <= skip {
                cost[i][j] = use_it;
                take[i][j] = true
            } else {
                cost[i][j] = skip
            }
        }
    }
    let (mut i, mut j) = (n, m);
    let mut result = Vec::new();
    while i > 0 {
        if take[i][j] {
            result.push(candidates[j - 1]);
            i -= 1
        }
        j -= 1
    }
    result.reverse();
    result
}
impl Router {
    fn new(edges: Vec<Edge>, positions: &Positions) -> Self {
        let min_x = positions
            .values()
            .map(|p| p.x)
            .fold(f64::INFINITY, f64::min);
        let min_y = positions
            .values()
            .map(|p| p.y)
            .fold(f64::INFINITY, f64::min);
        let max_x = positions
            .values()
            .map(|p| p.x)
            .fold(f64::NEG_INFINITY, f64::max);
        let max_y = positions
            .values()
            .map(|p| p.y)
            .fold(f64::NEG_INFINITY, f64::max);
        let x0 = ((min_x - 100.0) / 20.0).floor() * 20.0;
        let y0 = ((min_y - 100.0) / 20.0).floor() * 20.0;
        let width = ((((max_x + 300.0) / 20.0).ceil() * 20.0 - x0) / 20.0) as usize + 1;
        let height = ((((max_y + 220.0) / 20.0).ceil() * 20.0 - y0) / 20.0) as usize + 1;
        let routes = edges
            .into_iter()
            .map(|edge| {
                let (a, b) = (positions[&edge.from], positions[&edge.to]);
                let (dx, dy) = ((b.x - a.x) / 280.0, (b.y - a.y) / 200.0);
                let side = if dx.abs() >= dy.abs() {
                    if dx >= 0.0 {
                        0
                    } else {
                        2
                    }
                } else if dy >= 0.0 {
                    1
                } else {
                    3
                };
                Route {
                    edge,
                    side,
                    a: Point::default(),
                    b: Point::default(),
                }
            })
            .collect();
        let mut r = Self {
            positions: positions.clone(),
            x0,
            y0,
            width,
            height,
            routes,
            cells: vec![
                Cell {
                    owner: -1,
                    ..Cell::default()
                };
                width * height
            ],
            states: vec![State::default(); width * height * 4],
            generation: 0,
        };
        for p in positions.values() {
            let left = 0.max(((p.x - 10.0 - x0) / 20.0).floor() as isize + 1);
            let right = (width as isize - 1).min(((p.x + 210.0 - x0) / 20.0).ceil() as isize - 1);
            let top = 0.max(((p.y - 10.0 - y0) / 20.0).floor() as isize + 1);
            let bottom = (height as isize - 1).min(((p.y + 130.0 - y0) / 20.0).ceil() as isize - 1);
            for y in top..=bottom {
                for x in left..=right {
                    r.cells[y as usize * width + x as usize].blocked = true
                }
            }
        }
        let mut ports: BTreeMap<(String, usize), Vec<(usize, bool, f64)>> = BTreeMap::new();
        for (i, v) in r.routes.iter().enumerate() {
            for start in [true, false] {
                let side = if start { v.side } else { (v.side + 2) % 4 };
                let other = positions[if start { &v.edge.to } else { &v.edge.from }];
                ports
                    .entry((
                        if start {
                            v.edge.from.clone()
                        } else {
                            v.edge.to.clone()
                        },
                        side,
                    ))
                    .or_default()
                    .push((
                        i,
                        start,
                        if side % 2 == 0 {
                            other.y + 60.0
                        } else {
                            other.x + 100.0
                        },
                    ));
            }
        }
        for ((id, side), mut list) in ports {
            list.sort_by(|a, b| a.2.partial_cmp(&b.2).unwrap().then(a.0.cmp(&b.0)));
            let p = positions[&id];
            let wanted: Vec<_> = list
                .iter()
                .map(|v| v.2 - if side % 2 == 0 { p.y } else { p.x })
                .collect();
            let s = slots(&wanted, if side % 2 == 0 { 120 } else { 200 });
            for (i, (index, start, _)) in list.into_iter().enumerate() {
                let offset = s[i.min(s.len() - 1)] as f64;
                let point = match side {
                    0 => Point::new(p.x + 200.0, p.y + offset),
                    1 => Point::new(p.x + offset, p.y + 120.0),
                    2 => Point::new(p.x, p.y + offset),
                    _ => Point::new(p.x + offset, p.y),
                };
                if start {
                    r.routes[index].a = point
                } else {
                    r.routes[index].b = point
                }
            }
        }
        for (i, v) in r.routes.iter().enumerate() {
            for (p, side) in [(v.a, v.side), (v.b, (v.side + 2) % 4)] {
                let node = r.index(r.stub(p, side));
                let owner = r.cells[node].owner;
                r.cells[node].owner = if owner == -1 || owner == i as isize {
                    i as isize
                } else {
                    -2
                };
            }
        }
        r
    }
    fn stub(&self, p: Point, side: usize) -> Point {
        Point::new(
            p.x + (DIR[side].0 * 20) as f64,
            p.y + (DIR[side].1 * 20) as f64,
        )
    }
    fn index(&self, p: Point) -> usize {
        (((p.y - self.y0) / 20.0).round() as isize * self.width as isize
            + ((p.x - self.x0) / 20.0).round() as isize) as usize
    }
    fn point(&self, node: usize) -> Point {
        Point::new(
            self.x0 + (node % self.width * 20) as f64,
            self.y0 + (node / self.width * 20) as f64,
        )
    }
    fn search(
        &mut self,
        start: Point,
        sd: usize,
        goal: Point,
        gd: usize,
        owner: usize,
        local: bool,
    ) -> Option<Vec<Point>> {
        self.generation += 1;
        let stamp = self.generation;
        let mut queue = [-1isize; 64];
        let (si, gi) = (self.index(start), self.index(goal));
        let (sx, sy, gx, gy) = (
            si % self.width,
            si / self.width,
            gi % self.width,
            gi / self.width,
        );
        let (left, right, top, bottom) = if local {
            (
                sx.min(gx).saturating_sub(20),
                (sx.max(gx) + 20).min(self.width - 1),
                sy.min(gy).saturating_sub(20),
                (sy.max(gy) + 20).min(self.height - 1),
            )
        } else {
            (0, self.width - 1, 0, self.height - 1)
        };
        let initial = si * 4 + sd;
        let mut priority = sx.abs_diff(gx) + sy.abs_diff(gy);
        self.states[initial] = State {
            priority,
            stamp,
            queued: true,
            ..State::default()
        };
        queue[priority % 64] = initial as isize;
        let (mut count, mut best, mut best_state) = (1, usize::MAX, -1isize);
        while count > 0 {
            while queue[priority % 64] < 0 {
                priority += 1
            }
            if priority >= best {
                break;
            }
            let current = queue[priority % 64] as usize;
            let next = self.states[current].next;
            queue[priority % 64] = next;
            if next >= 0 {
                self.states[next as usize].prev = -1
            }
            self.states[current].queued = false;
            count -= 1;
            let (node, direction, cost) = (current / 4, current % 4, self.states[current].cost);
            if node == gi {
                let total = cost + if direction == gd { 0 } else { 6 };
                if total < best {
                    best = total;
                    best_state = current as isize
                }
                continue;
            }
            let (x, y) = (node % self.width, node / self.width);
            for (nd, &(dx, dy)) in DIR.iter().enumerate() {
                if nd == (direction + 2) % 4 {
                    continue;
                }
                let (nx, ny) = (x as isize + dx, y as isize + dy);
                if nx < left as isize
                    || nx > right as isize
                    || ny < top as isize
                    || ny > bottom as isize
                {
                    continue;
                }
                let (nx, ny) = (nx as usize, ny as usize);
                let next = ny * self.width + nx;
                let cell = self.cells[next];
                if next != gi
                    && (cell.blocked || (cell.owner != -1 && cell.owner != owner as isize))
                {
                    continue;
                }
                let horizontal = nd % 2 == 0;
                let segment = self.cells[node.min(next)];
                let extra = if if horizontal {
                    segment.used_h
                } else {
                    segment.used_v
                } {
                    30
                } else {
                    0
                };
                let crossing = if if horizontal { cell.node_v } else { cell.node_h } {
                    2
                } else {
                    0
                };
                let total = cost + 1 + if nd == direction { 0 } else { 3 } + extra + crossing;
                let state = next * 4 + nd;
                let old = self.states[state];
                if old.stamp == stamp && total >= old.cost {
                    continue;
                }
                let estimate = total + nx.abs_diff(gx) + ny.abs_diff(gy);
                if old.stamp == stamp && old.queued {
                    if old.prev < 0 {
                        queue[old.priority % 64] = old.next
                    } else {
                        self.states[old.prev as usize].next = old.next
                    }
                    if old.next >= 0 {
                        self.states[old.next as usize].prev = old.prev
                    }
                } else {
                    count += 1
                }
                // 같은 버킷은 나중에 넣은 상태부터 꺼낸다. 갱신은 기존 연결을 지운 뒤 재삽입한다.
                let bucket = estimate % 64;
                let head = queue[bucket];
                self.states[state] = State {
                    cost: total,
                    priority: estimate,
                    previous: current as isize,
                    stamp,
                    prev: -1,
                    next: head,
                    queued: true,
                };
                if head >= 0 {
                    self.states[head as usize].prev = state as isize
                }
                queue[bucket] = state as isize;
            }
        }
        if best_state < 0 {
            return None;
        }
        let mut result = Vec::new();
        let mut state = best_state;
        while state >= 0 {
            result.push(self.point(state as usize / 4));
            state = self.states[state as usize].previous
        }
        result.reverse();
        Some(result)
    }
    fn mark_segment(&mut self, a: usize, b: usize, horizontal: bool) {
        if horizontal {
            self.cells[a.min(b)].used_h = true;
            self.cells[a].node_h = true;
            self.cells[b].node_h = true
        } else {
            self.cells[a.min(b)].used_v = true;
            self.cells[a].node_v = true;
            self.cells[b].node_v = true
        }
    }
    fn mark_used(&mut self, pipes: &[Pipe]) {
        for pipe in pipes {
            for ab in pipe.points.windows(2) {
                let (a, b) = (ab[0], ab[1]);
                let horizontal = (a.y - b.y).abs() < 0.5;
                let steps = ((b.x - a.x).abs().max((b.y - a.y).abs()) / 20.0).round() as usize;
                for k in 0..steps {
                    let (t0, t1) = (k as f64 / steps as f64, (k + 1) as f64 / steps as f64);
                    let p = Point::new(a.x + (b.x - a.x) * t0, a.y + (b.y - a.y) * t0);
                    let q = Point::new(a.x + (b.x - a.x) * t1, a.y + (b.y - a.y) * t1);
                    let (max_x, max_y) = (
                        self.x0 + ((self.width - 1) * 20) as f64,
                        self.y0 + ((self.height - 1) * 20) as f64,
                    );
                    if [p, q]
                        .iter()
                        .all(|p| p.x >= self.x0 && p.x <= max_x && p.y >= self.y0 && p.y <= max_y)
                    {
                        self.mark_segment(self.index(p), self.index(q), horizontal)
                    }
                }
            }
        }
    }
    fn route(&mut self) -> Vec<Pipe> {
        let length = |r: &Route| (r.a.x - r.b.x).abs() + (r.a.y - r.b.y).abs();
        let mut order: Vec<_> = (0..self.routes.len()).collect();
        order.sort_by(|&a, &b| {
            length(&self.routes[a])
                .partial_cmp(&length(&self.routes[b]))
                .unwrap()
                .then(a.cmp(&b))
        });
        let mut result = vec![None; order.len()];
        for i in order {
            let r = self.routes[i].clone();
            let start = self.stub(r.a, r.side);
            let goal = self.stub(r.b, (r.side + 2) % 4);
            let path = self
                .search(start, r.side, goal, r.side, i, true)
                .or_else(|| self.search(start, r.side, goal, r.side, i, false));
            let points = if let Some(path) = path {
                for ab in path.windows(2) {
                    self.mark_segment(self.index(ab[0]), self.index(ab[1]), ab[0].y == ab[1].y)
                }
                let mut p = vec![r.a];
                p.extend(path);
                p.push(r.b);
                simplified(&p)
            } else {
                fallback(self.positions[&r.edge.from], self.positions[&r.edge.to])
            };
            result[i] = Some(Pipe {
                edge: r.edge,
                points,
            })
        }
        result.into_iter().flatten().collect()
    }
}
pub(super) fn fallback(a: Point, b: Point) -> Vec<Point> {
    if ((a.x + 100.0) - (b.x + 100.0)).abs() > ((a.y + 60.0) - (b.y + 60.0)).abs() {
        let p = Point::new(
            if a.x + 100.0 < b.x + 100.0 {
                a.x + 200.0
            } else {
                a.x
            },
            a.y + 60.0,
        );
        let q = Point::new(
            if a.x + 100.0 < b.x + 100.0 {
                b.x
            } else {
                b.x + 200.0
            },
            b.y + 60.0,
        );
        vec![
            p,
            Point::new((p.x + q.x) / 2.0, p.y),
            Point::new((p.x + q.x) / 2.0, q.y),
            q,
        ]
    } else {
        let p = Point::new(
            a.x + 100.0,
            if a.y + 60.0 < b.y + 60.0 {
                a.y + 120.0
            } else {
                a.y
            },
        );
        let q = Point::new(
            b.x + 100.0,
            if a.y + 60.0 < b.y + 60.0 {
                b.y
            } else {
                b.y + 120.0
            },
        );
        vec![
            p,
            Point::new(p.x, (p.y + q.y) / 2.0),
            Point::new(q.x, (p.y + q.y) / 2.0),
            q,
        ]
    }
}

#[cfg(test)]
mod tests {
    use super::slots;
    #[test]
    fn port_dynamic_programming() {
        assert_eq!(slots(&[1000.], 120), vec![60]);
        assert_eq!(slots(&[60., 60.], 120), vec![60, 80]);
        assert_eq!(slots(&[0., 200.], 120), vec![20, 100]);
        assert_eq!(slots(&[0.; 6], 120), vec![20, 40, 60, 80, 100]);
    }
}
