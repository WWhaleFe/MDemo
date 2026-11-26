use mdemo_core::{
    frontmatter::quote,
    link::{percent_encode, MemoLinkKind},
};
use serde_json::json;
use std::{env, error::Error, fs, path::Path};
/// 외부 난수 의존성 없이 시드로 재현하는 SplitMix64.
struct Random(u64);
impl Random {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }
    fn pick<'a>(&mut self, a: &'a [&'a str]) -> &'a str {
        a[self.next() as usize % a.len()]
    }
}
fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = env::args().collect();
    if args.len() != 4 {
        return Err("사용법: mdemo-fuzzgen <출력> <건수> <시드>".into());
    }
    let root = Path::new(&args[1]);
    let count: usize = args[2].parse()?;
    let mut r = Random(args[3].parse()?);
    fs::create_dir_all(root.join("memos"))?;
    let id = "01ARZ3NDEKTSV4RRFFQ69G5F00";
    for i in 0..count {
        let mut links = Vec::new();
        for kind in MemoLinkKind::ALL {
            let label = r.pick(&[
                "a,b:c~d",
                "한글 /?_%",
                "👩‍👩‍👧‍👦",
                "e\u{301}",
                "한",
                "",
                "abcdefghijklmnopqrstuvwxyz",
                "👋🏽🇰🇷❤️\n\r\\\"",
            ]);
            let label = label.repeat((r.next() % 4 + 1) as usize);
            let raw = if r.next() % 5 == 0 {
                r.pick(&["%ZZ", "%FF", "%", "%C3%28"]).to_string()
            } else {
                percent_encode(&label)
            };
            let tail = r.pick(&["", "~future", "~~x", "~%ZZ"]);
            links.push(format!("{}:{id}~{raw}{tail}", kind.token()));
        }
        links.push(
            r.pick(&["unknown:fake~tail", "not-a-link", " line:bad "])
                .into(),
        );
        if r.next() % 2 == 0 {
            links.push(links[0].clone())
        }
        let title = r.pick(&[
            "a\\\"b",
            "한글😀",
            "a\nb\rc\\n",
            "\\\\\"",
            "",
            "e\u{301}",
            "# / ~ :",
            "\\n\u{301}",
            "\"\u{301}\\\u{301}",
        ]);
        let date = r.pick(&[
            "1970-01-01T00:00:00Z",
            "2000-02-29T23:59:59.999Z",
            "1999-12-31T23:59:59.001-03:30",
            "2026-01-01T09:00:00.123+09:00",
            "2038-01-19T03:14:07.500Z",
            "1969-12-31T23:59:59.999Z",
            "2001-01-01T00:00:00.000499Z",
            "2001-01-01T00:00:00.999999Z",
            "2024-02-29T23:59:59.123456789Z",
        ]);
        let alpha = if r.next() % 3 == 0 {
            r.pick(&["nan", "-1", "2", "0.000001", "1.0", "0.15"])
                .to_string()
        } else {
            format!("{:.12}", (r.next() % 2000000000000) as f64 / 1e12)
        };
        let text=format!("---\nschemaVersion: {}\nid: {id}\ntitle: {}\ngroup: {}\ncolor: {}\nbgAlpha: {alpha}\ntextAlpha: {alpha}\nopen: {}\npinned: {}\ncreated: {date}\nmodified: {date}\nlinks: {}\n# 주석 : 보존\n콜론 없는 줄\nfuture: {}\n\t \n---\n본문 😀 é\r단독 CR\n",r.next()%6,quote(title),quote(title),quote(r.pick(&["#FFF3B0","#abcdEF","\\n\"x"])),r.pick(&["true","YES","0","bad"]),r.pick(&["false","no","1","TRUE"]),links.join(","),quote(title));
        let text = if r.next() % 2 == 0 {
            text.replace('\n', "\r\n")
        } else {
            text
        };
        fs::write(root.join("memos").join(format!("{i:06}.md")), text)?;
    }
    let mut placements = serde_json::Map::new();
    for i in 0..20 {
        let x = match r.next() % 6 {
            0 => -0.0,
            1 => 1e-7,
            2 => 1e16,
            _ => (r.next() as i64) as f64 / (r.next() % 1000 + 1) as f64,
        };
        let y = (r.next() as i64) as f64 / 1000.;
        placements.insert(format!("fake{i:02}"), json!({"x":x,"y":y}));
    }
    fs::write(
        root.join("board.json"),
        serde_json::to_vec(
            &json!({"placements":placements,"manualOrder":[{"rawValue":id},{"rawValue":id}],"bentoSpans":{"fake00":"wide"}}),
        )?,
    )?;
    let groups: Vec<_> = (0..30)
        .map(|_| r.pick(&["한글", "a/b", "\n\\\"", "😀", "é", ""]))
        .collect();
    fs::write(root.join("groups.json"), serde_json::to_vec(&groups)?)?;
    board_calculations(root, &mut r)?;
    Ok(())
}
/// v0.14 · v0.15 보드 계산용 무작위 입력: 재정렬 · 관계(ids · edges), 길찾기(routingCases), 엇갈림(crossingPaths).
fn board_calculations(root: &Path, r: &mut Random) -> Result<(), Box<dyn Error>> {
    const CROCKFORD: &[u8] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    let kinds = ["line", "flow", "both", "related", "dashto", "dashboth", "contain", "block", "oppose", "same"];
    let id = |r: &mut Random| -> String {
        let mut s = String::from("01ARZ3NDEKTSV4RRFFQ69G");
        for _ in 0..4 { s.push(CROCKFORD[r.next() as usize % CROCKFORD.len()] as char); }
        s
    };
    let edges_for = |ids: &[String], n: usize, r: &mut Random| -> Vec<serde_json::Value> {
        (0..n).map(|_| {
            let a = &ids[r.next() as usize % ids.len()];
            // 가끔 자기 자신 · 같은 선 반복도 넣는다
            let b = if r.next() % 15 == 0 { a } else { &ids[r.next() as usize % ids.len()] };
            json!({"from": a, "to": b, "kind": kinds[r.next() as usize % kinds.len()]})
        }).collect()
    };
    let n = (r.next() % 25 + 4) as usize;
    let mut ids: Vec<String> = Vec::new();
    while ids.len() < n { let v = id(r); if !ids.contains(&v) { ids.push(v); } }
    let e = (r.next() % (n as u64 * 2)) as usize + 1;
    let edges = edges_for(&ids, e, r);
    let grid = |r: &mut Random, span: u64| -> f64 { ((r.next() % (span * 2 / 20)) as i64 * 20 - span as i64) as f64 };
    let mut positions = serde_json::Map::new();
    for i in ids.iter().take(6) { positions.insert(i.clone(), json!({"x": grid(r, 1200), "y": grid(r, 800)})); }
    let mut cases = Vec::new();
    for c in 0..3 {
        let m = (r.next() % 12 + 2) as usize;
        let cids: Vec<String> = ids.iter().take(m.min(ids.len())).cloned().collect();
        let mut pos = serde_json::Map::new();
        // 0번 사례는 280 · 200 칸에 맞춘 깔끔한 배치, 나머지는 20pt 격자 아무 곳(겹침 포함)
        for (k, i) in cids.iter().enumerate() {
            let (x, y) = if c == 0 { ((k % 4) as f64 * 280.0, (k / 4) as f64 * 200.0) } else { (grid(r, 1400), grid(r, 900)) };
            pos.insert(i.clone(), json!({"x": x, "y": y}));
        }
        let ce = (r.next() % (cids.len() as u64 * 2 + 1)) as usize;
        cases.push(json!({"name": format!("무작위 {c}"), "positions": pos, "edges": edges_for(&cids, ce, r)}));
    }
    let mut paths = Vec::new();
    for _ in 0..(r.next() % 6 + 2) {
        let mut pts = vec![[grid(r, 400), grid(r, 400)]];
        for k in 0..(r.next() % 4 + 1) {
            let last = *pts.last().unwrap();
            let step = grid(r, 300);
            pts.push(if k % 2 == 0 { [last[0] + step, last[1]] } else { [last[0], last[1] + step] });
        }
        paths.push(json!({"points": pts}));
    }
    fs::write(root.join("board-calculations.json"), serde_json::to_vec(&json!({
        "ids": ids, "edges": edges, "positions": positions, "crossingPaths": paths, "routingCases": cases
    }))?)?;
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("퍼즈 입력 생성 실패: {e}");
        std::process::exit(1)
    }
}
