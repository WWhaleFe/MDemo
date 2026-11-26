use super::*;
fn edge(a: &str, b: &str, kind: &str) -> Edge {
    Edge {
        from: a.into(),
        to: b.into(),
        kind: kind.into(),
    }
}
fn pos(values: &[(&str, f64, f64)]) -> Positions {
    values
        .iter()
        .map(|&(id, x, y)| (id.into(), Point::new(x, y)))
        .collect()
}
#[test]
fn golden_bytes() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../golden");
    let input = root.join("inputs/board-calculations.json");
    for (name, result) in [
        (
            "board-calculations.json",
            golden::board_calculations(&input),
        ),
        ("relations.json", golden::relations(&input)),
    ] {
        assert_eq!(
            result.unwrap().as_bytes(),
            std::fs::read(root.join("expected").join(name)).unwrap(),
            "{name}"
        );
    }
}
#[test]
fn straight_ports() {
    let p = pos(&[("a", 0., 0.), ("b", 280., 0.), ("c", 0., 200.)]);
    let pipes = route(&[edge("a", "b", "flow"), edge("b", "c", "flow")], &p, &[]);
    assert_eq!(
        pipes[0].points,
        vec![Point::new(200., 60.), Point::new(280., 60.)]
    );
}
#[test]
fn retry_fallback_and_vertical() {
    let e = edge("a", "b", "flow");
    let mut p = pos(&[("a", 0., 0.), ("b", 840., 0.)]);
    for y in (-600..=600).step_by(120) {
        p.insert(y.to_string(), Point::new(420., y as f64));
    }
    let r = route(std::slice::from_ref(&e), &p, &[]);
    assert!(r[0].points.iter().any(|p| p.y < -600. || p.y > 720.));
    assert_eq!(r[0].points.first(), Some(&Point::new(200., 60.)));
    assert_eq!(r[0].points.last(), Some(&Point::new(840., 60.)));
    let p = pos(&[("a", 0., 0.), ("b", 840., 0.), ("c", 200., 0.)]);
    assert_eq!(
        route(std::slice::from_ref(&e), &p, &[])[0].points,
        routing::fallback(p["a"], p["b"])
    );
    let p = pos(&[("a", 0., 0.), ("b", 280., 220.)]);
    let r = route(&[e], &p, &[]);
    assert_eq!(r[0].points.first(), Some(&Point::new(100., 120.)));
    assert_eq!(r[0].points.last(), Some(&Point::new(380., 220.)));
}
#[test]
fn midpoint_and_crossings() {
    assert_eq!(
        midpoint(&[
            Point::new(0., 0.),
            Point::new(100., 0.),
            Point::new(100., 20.),
            Point::new(300., 20.)
        ]),
        Point::new(140., 20.)
    );
    let pipes: Vec<_> = [
        vec![(0., 0.), (100., 0.)],
        vec![(50., -40.), (50., 40.)],
        vec![(100., 0.), (100., 40.)],
    ]
    .into_iter()
    .map(|p| Pipe {
        edge: edge("a", "b", "flow"),
        points: p.into_iter().map(|(x, y)| Point::new(x, y)).collect(),
    })
    .collect();
    assert_eq!(
        crossings(&pipes),
        vec![Crossing {
            point: Point::new(50., 0.),
            horizontal_pipe: 0,
            segment: 0
        }]
    );
    assert_eq!(midpoint(&[]), Point::default());
}
#[test]
fn relations_order_and_limit() {
    let edges = vec![
        edge("a", "a", "related"),
        edge("a", "b", "related"),
        edge("a", "b", "related"),
        edge("c", "a", "dashto"),
        edge("b", "c", "both"),
        edge("b", "d", "contain"),
        edge("c", "d", "related"),
    ];
    let one = relations("a", None, &edges, 1, true);
    assert_eq!(one.direct.len(), 2);
    assert!(one.direct[0].outgoing);
    assert!(!one.direct[1].outgoing);
    assert!(one.indirect.is_empty());
    let two = relations("a", None, &edges, 2, true);
    assert_eq!(
        two.indirect,
        vec![Indirect {
            via: "b".into(),
            kind: "contain".into(),
            outgoing: true,
            other: "d".into()
        }]
    );
    assert!(two.is_visible(true));
    assert!(!two.is_visible(false));
    assert!(relations("a", None, &edges, 2, false).direct.is_empty());
    let mut edges = vec![edge("a", "b", "flow")];
    for i in 0..20 {
        edges.push(edge("b", &i.to_string(), "related"))
    }
    assert_eq!(relations("a", None, &edges, 2, true).indirect.len(), 12);
    let r = relations("a", Some(vec!["a".into(), "b".into()]), &edges, 2, false);
    assert_eq!(r.direct.len(), 1);
    assert!(r.indirect.is_empty());
    assert!(r.is_visible(false));
}
#[test]
fn arrange_branch_cycle_singles() {
    let ids: Vec<_> = (0..12).map(|i| i.to_string()).collect();
    let edges: Vec<_> = [(0, 1), (0, 2), (1, 3), (2, 3), (4, 5), (5, 6), (6, 4)]
        .into_iter()
        .map(|(a, b)| edge(&ids[a], &ids[b], "flow"))
        .collect();
    let p = arrange(&ids, &edges);
    assert_eq!(p, arrange(&ids, &edges));
    assert_eq!(p[1].1, p[2].1);
    assert!((p[1].2 - p[2].2).abs() >= 200.);
    for i in 0..p.len() {
        for j in i + 1..p.len() {
            assert!((p[i].1 - p[j].1).abs() >= 200. || (p[i].2 - p[j].2).abs() >= 120.)
        }
    }
    let p = arrange(&ids, &[]);
    assert_eq!((p[5].1, p[5].2), (40., 300.));
}
#[test]
#[ignore = "release 길찾기 성능 측정"]
fn routing_performance() {
    let mut seed = 0x5eed_u64;
    let mut next = || {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        seed >> 32
    };
    let ids: Vec<_> = (0..150).map(|i| i.to_string()).collect();
    let positions: Positions = ids
        .iter()
        .map(|id| {
            (
                id.clone(),
                Point::new((next() % 301) as f64 * 20., (next() % 201) as f64 * 20.),
            )
        })
        .collect();
    let edges: Vec<_> = (0..200)
        .map(|_| {
            let a = next() as usize % 150;
            let b = (a + 1 + next() as usize % 149) % 150;
            edge(&ids[a], &ids[b], "flow")
        })
        .collect();
    let start = std::time::Instant::now();
    let pipes = route(&edges, &positions, &[]);
    println!(
        "무작위 보드: {:?}, 메모 150, 선 200, 범위 6000×4000, 시드 0x5eed",
        start.elapsed()
    );
    assert_eq!(pipes.len(), 200);
}

#[test]
fn obstacle_ports_and_simplification() {
    let p = pos(&[
        ("a", 0., 200.),
        ("b", 840., 0.),
        ("c", 840., 400.),
        ("obstacle", 420., 200.),
    ]);
    let e = [edge("a", "c", "flow"), edge("a", "b", "flow")];
    let pipes = route(&e, &p, &[]);
    assert_eq!(pipes[0].points[0], Point::new(200., 300.));
    assert_eq!(pipes[1].points[0], Point::new(200., 220.));
    assert_eq!(pipes, route(&e, &p, &[]));
    for pipe in &pipes {
        for ab in pipe.points.windows(2) {
            let (a, b) = (ab[0], ab[1]);
            assert!(a.x == b.x || a.y == b.y);
            if a.y == b.y && a.y > 190. && a.y < 330. {
                assert!(a.x.max(b.x) <= 410. || a.x.min(b.x) >= 630.);
            }
            if a.x == b.x && a.x > 410. && a.x < 630. {
                assert!(a.y.max(b.y) <= 190. || a.y.min(b.y) >= 330.);
            }
        }
        assert_eq!(pipe.points, simplified(&pipe.points));
    }
}
#[test]
fn shelves_and_isolates() {
    let ids: Vec<_> = (0..9).map(|i| i.to_string()).collect();
    let e: Vec<_> = [(0, 1), (1, 2), (2, 7), (3, 4), (5, 6)]
        .into_iter()
        .map(|(a, b)| edge(&ids[a], &ids[b], "flow"))
        .collect();
    let p = arrange(&ids, &e);
    for (i, x, y) in [
        (0, 40., 100.),
        (1, 320., 100.),
        (2, 600., 100.),
        (7, 880., 100.),
        (3, 40., 300.),
        (4, 320., 300.),
        (5, 600., 300.),
        (6, 880., 300.),
        (8, 40., 500.),
    ] {
        assert_eq!((p[i].1, p[i].2), (x, y));
    }
}
#[test]
fn existing_segments_are_avoided() {
    let p = pos(&[("a", 0., 0.), ("b", 840., 0.)]);
    let e = [edge("a", "b", "flow")];
    let initial = route(&e, &p, &[]);
    let next = route(&e, &p, &initial);
    assert_ne!(initial[0].points, next[0].points);
    assert_eq!(initial[0].points.first(), next[0].points.first());
    assert_eq!(initial[0].points.last(), next[0].points.last());
    let outside = Pipe {
        edge: e[0].clone(),
        points: vec![Point::new(-10000., -10000.), Point::new(-10000., 10000.)],
    };
    assert_eq!(initial, route(&e, &p, &[outside]));
}
