//! 계산 골든 전용 JSON 읽기와 키 정렬, 소수 여섯 자리 출력.
use super::*;
use std::{fs, path::Path};
#[derive(Clone, Debug)]
enum Json {
    String(String),
    Number(f64),
    Bool(bool),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
    Null,
}
use Json::{Array as A, Bool as B, Number as N, String as S};
fn object(items: Vec<(&str, Json)>) -> Json {
    Json::Object(items.into_iter().map(|(k, v)| (k.into(), v)).collect())
}
fn quote(s: &str) -> String {
    let mut r = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => r.push_str("\\\""),
            '\\' => r.push_str("\\\\"),
            '/' => r.push_str("\\/"),
            '\n' => r.push_str("\\n"),
            '\r' => r.push_str("\\r"),
            '\t' => r.push_str("\\t"),
            c if c < ' ' => r.push_str(&format!("\\u{:04x}", c as u32)),
            c => r.push(c),
        }
    }
    r.push('"');
    r
}
impl Json {
    fn get(&self, key: &str) -> Result<&Json, String> {
        if let Self::Object(o) = self {
            o.get(key).ok_or_else(|| format!("누락된 키: {key}"))
        } else {
            Err("객체가 필요합니다".into())
        }
    }
    fn array(&self) -> Result<&[Json], String> {
        if let Self::Array(a) = self {
            Ok(a)
        } else {
            Err("배열이 필요합니다".into())
        }
    }
    fn string(&self) -> Result<&str, String> {
        if let S(s) = self {
            Ok(s)
        } else {
            Err("문자열이 필요합니다".into())
        }
    }
    fn number(&self) -> Result<f64, String> {
        if let N(n) = self {
            Ok(*n)
        } else {
            Err("숫자가 필요합니다".into())
        }
    }
    fn text(&self) -> String {
        match self {
            S(s) => quote(s),
            N(n) => format!("{n:.6}"),
            B(b) => b.to_string(),
            A(a) => format!(
                "[{}]",
                a.iter().map(Self::text).collect::<Vec<_>>().join(",")
            ),
            Self::Object(o) => format!(
                "{{{}}}",
                o.iter()
                    .map(|(k, v)| format!("{}:{}", quote(k), v.text()))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
            Self::Null => "null".into(),
        }
    }
}
struct Parser<'a> {
    s: &'a [u8],
    i: usize,
}
impl Parser<'_> {
    fn ws(&mut self) {
        while self.s.get(self.i).is_some_and(u8::is_ascii_whitespace) {
            self.i += 1
        }
    }
    fn string(&mut self) -> Result<String, String> {
        self.i += 1;
        let mut bytes = Vec::new();
        loop {
            let c = *self.s.get(self.i).ok_or("끝나지 않은 문자열")?;
            self.i += 1;
            match c {
                b'"' => return String::from_utf8(bytes).map_err(|e| e.to_string()),
                b'\\' => {
                    let c = *self.s.get(self.i).ok_or("잘못된 이스케이프")?;
                    self.i += 1;
                    match c {
                        b'"' | b'\\' | b'/' => bytes.push(c),
                        b'n' => bytes.push(10),
                        b'r' => bytes.push(13),
                        b't' => bytes.push(9),
                        b'b' => bytes.push(8),
                        b'f' => bytes.push(12),
                        b'u' => {
                            let mut cp = self.hex()?;
                            if (0xd800..=0xdbff).contains(&cp) {
                                if self.s.get(self.i..self.i + 2) != Some(b"\\u") {
                                    return Err("잘못된 유니코드 쌍".into());
                                }
                                self.i += 2;
                                let low = self.hex()?;
                                if !(0xdc00..=0xdfff).contains(&low) {
                                    return Err("잘못된 유니코드 쌍".into());
                                }
                                cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00)
                            }
                            let ch = char::from_u32(cp).ok_or("잘못된 유니코드")?;
                            let mut buf = [0; 4];
                            bytes.extend(ch.encode_utf8(&mut buf).as_bytes())
                        }
                        _ => return Err("잘못된 이스케이프".into()),
                    }
                }
                0..=31 => return Err("문자열 안 제어 문자".into()),
                _ => bytes.push(c),
            }
        }
    }
    fn hex(&mut self) -> Result<u32, String> {
        let s = self.s.get(self.i..self.i + 4).ok_or("짧은 유니코드")?;
        self.i += 4;
        u32::from_str_radix(std::str::from_utf8(s).map_err(|e| e.to_string())?, 16)
            .map_err(|e| e.to_string())
    }
    fn value(&mut self) -> Result<Json, String> {
        self.ws();
        let c = *self.s.get(self.i).ok_or("빈 JSON")?;
        match c {
            b'"' => Ok(S(self.string()?)),
            b'[' => {
                self.i += 1;
                let mut a = Vec::new();
                self.ws();
                if self.s.get(self.i) == Some(&b']') {
                    self.i += 1;
                    return Ok(A(a));
                }
                loop {
                    a.push(self.value()?);
                    self.ws();
                    match self.s.get(self.i) {
                        Some(b']') => {
                            self.i += 1;
                            return Ok(A(a));
                        }
                        Some(b',') => self.i += 1,
                        _ => return Err("배열 구분 오류".into()),
                    }
                }
            }
            b'{' => {
                self.i += 1;
                let mut o = BTreeMap::new();
                self.ws();
                if self.s.get(self.i) == Some(&b'}') {
                    self.i += 1;
                    return Ok(Json::Object(o));
                }
                loop {
                    self.ws();
                    if self.s.get(self.i) != Some(&b'"') {
                        return Err("객체 키 오류".into());
                    }
                    let k = self.string()?;
                    self.ws();
                    if self.s.get(self.i) != Some(&b':') {
                        return Err("객체 구분 오류".into());
                    }
                    self.i += 1;
                    o.insert(k, self.value()?);
                    self.ws();
                    match self.s.get(self.i) {
                        Some(b'}') => {
                            self.i += 1;
                            return Ok(Json::Object(o));
                        }
                        Some(b',') => self.i += 1,
                        _ => return Err("객체 구분 오류".into()),
                    }
                }
            }
            b't' | b'f' | b'n' => {
                let (lit, v) = match c {
                    b't' => ("true", B(true)),
                    b'f' => ("false", B(false)),
                    _ => ("null", Json::Null),
                };
                if self.s.get(self.i..self.i + lit.len()) != Some(lit.as_bytes()) {
                    return Err("리터럴 오류".into());
                }
                self.i += lit.len();
                Ok(v)
            }
            _ => {
                let start = self.i;
                while self
                    .s
                    .get(self.i)
                    .is_some_and(|c| c.is_ascii_digit() || b"-+.eE".contains(c))
                {
                    self.i += 1
                }
                let s = std::str::from_utf8(&self.s[start..self.i]).map_err(|e| e.to_string())?;
                Ok(N(s.parse::<f64>().map_err(|e| e.to_string())?))
            }
        }
    }
}
fn read(path: &Path) -> Result<Json, String> {
    let s = fs::read(path).map_err(|e| e.to_string())?;
    let mut p = Parser { s: &s, i: 0 };
    let v = p.value()?;
    p.ws();
    if p.i != s.len() {
        return Err("JSON 뒤 불필요한 입력".into());
    }
    Ok(v)
}
fn edges(j: &Json) -> Result<Vec<Edge>, String> {
    j.array()?
        .iter()
        .map(|e| {
            Ok(Edge {
                from: e.get("from")?.string()?.into(),
                to: e.get("to")?.string()?.into(),
                kind: e.get("kind")?.string()?.into(),
            })
        })
        .collect()
}
fn positions(j: &Json) -> Result<Positions, String> {
    let Json::Object(o) = j else {
        return Err("자리 객체가 필요합니다".into());
    };
    o.iter()
        .map(|(id, p)| {
            Ok((
                id.clone(),
                Point::new(p.get("x")?.number()?, p.get("y")?.number()?),
            ))
        })
        .collect()
}
fn point(p: Point) -> Json {
    A(vec![N(p.x), N(p.y)])
}
fn points(p: &Pipe) -> Json {
    A(p.points.iter().copied().map(point).collect())
}
/// 입력 JSON 파일을 읽어 보드 계산 결과를 만든다. 반환값은 마지막 줄바꿈을 포함한다.
pub fn board_calculations(path: impl AsRef<Path>) -> Result<String, String> {
    let j = read(path.as_ref())?;
    let ids: Vec<String> = j
        .get("ids")?
        .array()?
        .iter()
        .map(|v| v.string().map(str::to_owned))
        .collect::<Result<_, _>>()?;
    let e = edges(j.get("edges")?)?;
    // Swift 저장기의 ID 순서와 무방향 쌍 중복 제거를 재현한다.
    let mut arranged_edges = e.clone();
    arranged_edges.sort_by(|a, b| a.from.cmp(&b.from));
    let mut seen = HashSet::new();
    arranged_edges.retain(|e| {
        let mut pair = [e.from.clone(), e.to.clone()];
        pair.sort();
        e.from != e.to && ids.contains(&e.from) && ids.contains(&e.to) && seen.insert(pair)
    });
    let arranged = arrange(&ids, &arranged_edges);
    let pipes = route(&e, &positions(j.get("positions")?)?, &[]);
    let cp: Vec<_> = j
        .get("crossingPaths")?
        .array()?
        .iter()
        .map(|p| {
            Ok(Pipe {
                edge: e.first().ok_or("선이 필요합니다")?.clone(),
                points: p
                    .get("points")?
                    .array()?
                    .iter()
                    .map(|p| {
                        let a = p.array()?;
                        if a.len() != 2 {
                            return Err("점 좌표 수 오류".into());
                        }
                        Ok(Point::new(a[0].number()?, a[1].number()?))
                    })
                    .collect::<Result<_, String>>()?,
            })
        })
        .collect::<Result<_, String>>()?;
    let routing = j
        .get("routingCases")?
        .array()?
        .iter()
        .map(|item| {
            let p = route(
                &edges(item.get("edges")?)?,
                &positions(item.get("positions")?)?,
                &[],
            );
            Ok(object(vec![
                ("name", S(item.get("name")?.string()?.into())),
                ("points", A(p.iter().map(points).collect())),
            ]))
        })
        .collect::<Result<_, String>>()?;
    let result = object(vec![
        (
            "arranged",
            Json::Object(
                arranged
                    .into_iter()
                    .map(|(id, x, y)| (id, A(vec![N(x), N(y)])))
                    .collect(),
            ),
        ),
        (
            "pipes",
            A(pipes
                .iter()
                .map(|p| {
                    object(vec![
                        ("from", S(p.edge.from.clone())),
                        ("to", S(p.edge.to.clone())),
                        ("points", points(p)),
                    ])
                })
                .collect()),
        ),
        (
            "crossings",
            A(crossings(&cp)
                .into_iter()
                .map(|c| {
                    object(vec![
                        ("point", point(c.point)),
                        ("horizontalPipe", N(c.horizontal_pipe as f64)),
                        ("segment", N(c.segment as f64)),
                    ])
                })
                .collect()),
        ),
        ("routingCases", A(routing)),
    ]);
    Ok(result.text() + "\n")
}
/// 같은 입력 파일에서 관계 계산 결과를 만든다.
pub fn relations(path: impl AsRef<Path>) -> Result<String, String> {
    let j = read(path.as_ref())?;
    let ids = j.get("ids")?.array()?;
    let current = ids.first().ok_or("ID가 필요합니다")?.string()?;
    let edges = edges(j.get("edges")?)?;
    let mut result = BTreeMap::new();
    for (name, depth, enabled) in [
        ("direct", 1, true),
        ("twoSteps", 2, true),
        ("disabled", 2, false),
    ] {
        let r = super::relations(current, None, &edges, depth, enabled);
        result.insert(
            name.into(),
            object(vec![
                (
                    "direct",
                    A(r.direct
                        .into_iter()
                        .map(|d| {
                            object(vec![
                                ("kind", S(d.kind)),
                                ("other", S(d.other)),
                                ("outgoing", B(d.outgoing)),
                            ])
                        })
                        .collect()),
                ),
                (
                    "indirect",
                    A(r.indirect
                        .into_iter()
                        .map(|d| {
                            object(vec![
                                ("kind", S(d.kind)),
                                ("other", S(d.other)),
                                ("outgoing", B(d.outgoing)),
                                ("via", S(d.via)),
                            ])
                        })
                        .collect()),
                ),
            ]),
        );
    }
    Ok(Json::Object(result).text() + "\n")
}
