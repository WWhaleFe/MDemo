//! 보드 계산 경계. 좌표는 보드 좌표(pt)이고 UI와 파일 시스템에 의존하지 않는다.
use mdemo_core::board as core;

#[derive(uniffi::Record)]
pub struct BoardPointFfi {
    pub x: f64,
    pub y: f64,
}

/// 선 하나의 점열. 선마다 하나씩 입력 순서대로 오간다.
#[derive(uniffi::Record)]
pub struct BoardPathFfi {
    pub points: Vec<BoardPointFfi>,
}

#[derive(uniffi::Record)]
pub struct BoardEdgeFfi {
    pub from: String,
    pub to: String,
    pub kind: String,
}

#[derive(uniffi::Record)]
pub struct BoardPlaceFfi {
    pub id: String,
    pub x: f64,
    pub y: f64,
}

#[derive(uniffi::Record)]
pub struct BoardCrossingFfi {
    pub x: f64,
    pub y: f64,
    pub horizontal_pipe: u32,
    pub segment: u32,
}

#[derive(uniffi::Record)]
pub struct BoardDirectFfi {
    pub kind: String,
    pub outgoing: bool,
    pub other: String,
}

#[derive(uniffi::Record)]
pub struct BoardIndirectFfi {
    pub via: String,
    pub kind: String,
    pub outgoing: bool,
    pub other: String,
}

#[derive(uniffi::Record)]
pub struct BoardRelationsFfi {
    pub direct: Vec<BoardDirectFfi>,
    pub indirect: Vec<BoardIndirectFfi>,
}

fn edge(e: BoardEdgeFfi) -> core::Edge {
    core::Edge { from: e.from, to: e.to, kind: e.kind }
}

fn pipe(edge: &core::Edge, path: BoardPathFfi) -> core::Pipe {
    core::Pipe { edge: edge.clone(), points: path.points.into_iter().map(|p| core::Point::new(p.x, p.y)).collect() }
}

/// 보드 재정렬. 반환은 `ids` 입력 순서다. `edges`는 저장기 순서 그대로 받는다.
#[uniffi::export]
pub fn board_arrange(ids: Vec<String>, edges: Vec<BoardEdgeFfi>) -> Vec<BoardPlaceFfi> {
    let edges: Vec<_> = edges.into_iter().map(edge).collect();
    core::arrange(&ids, &edges).into_iter().map(|(id, x, y)| BoardPlaceFfi { id, x, y }).collect()
}

/// 선 길찾기. 양 끝 자리가 있는 선만 입력 순서로 점열을 돌려준다.
/// `avoiding`은 끄는 중 다시 찾지 않는 선들의 '쓴 길'이다.
#[uniffi::export]
pub fn board_route(edges: Vec<BoardEdgeFfi>, positions: Vec<BoardPlaceFfi>, avoiding: Vec<BoardPathFfi>) -> Vec<BoardPathFfi> {
    let edges: Vec<_> = edges.into_iter().map(edge).collect();
    let positions: core::Positions = positions.into_iter().map(|p| (p.id, core::Point::new(p.x, p.y))).collect();
    let placeholder = core::Edge { from: String::new(), to: String::new(), kind: String::new() };
    let avoiding: Vec<_> = avoiding.into_iter().map(|p| pipe(&placeholder, p)).collect();
    core::route(&edges, &positions, &avoiding)
        .into_iter()
        .map(|p| BoardPathFfi { points: p.points.into_iter().map(|p| BoardPointFfi { x: p.x, y: p.y }).collect() })
        .collect()
}

/// 선끼리 엇갈리는 점. 가로 선 번호와 구간 번호는 입력 점열 기준이다.
#[uniffi::export]
pub fn board_crossings(paths: Vec<BoardPathFfi>) -> Vec<BoardCrossingFfi> {
    let placeholder = core::Edge { from: String::new(), to: String::new(), kind: String::new() };
    let pipes: Vec<_> = paths.into_iter().map(|p| pipe(&placeholder, p)).collect();
    core::crossings(&pipes)
        .into_iter()
        .map(|c| BoardCrossingFfi { x: c.point.x, y: c.point.y, horizontal_pipe: c.horizontal_pipe as u32, segment: c.segment as u32 })
        .collect()
}

/// 스티키 창 관계 줄. 흐름(flow)은 Swift가 들고 있으므로 넘기지 않는다.
#[uniffi::export]
pub fn board_relations(current: String, edges: Vec<BoardEdgeFfi>, depth: u32, show_relations: bool) -> BoardRelationsFfi {
    let edges: Vec<_> = edges.into_iter().map(edge).collect();
    let r = core::relations(&current, None, &edges, depth as usize, show_relations);
    BoardRelationsFfi {
        direct: r.direct.into_iter().map(|d| BoardDirectFfi { kind: d.kind, outgoing: d.outgoing, other: d.other }).collect(),
        indirect: r
            .indirect
            .into_iter()
            .map(|d| BoardIndirectFfi { via: d.via, kind: d.kind, outgoing: d.outgoing, other: d.other })
            .collect(),
    }
}
