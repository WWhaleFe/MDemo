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
    search_cases(root, count, &mut r)?;
    markdown_cases(root, count, &mut r)?;
    Ok(())
}
/// 본문 검색 일치 비교용 무작위 (본문, 검색어) 쌍. 결합 문자 · 한글 자모 · 대소문자 접기 · 숫자 · 이모지 조각을 섞는다.
fn search_cases(root: &Path, count: usize, r: &mut Random) -> Result<(), Box<dyn Error>> {
    const POOL: &[&str] = &[
        "a", "B", "x", "é", "e\u{301}", "É", "\u{323}", "\u{301}", "한", "ᄒ", "ᅡ", "ᆫ", "각", "ᆨ", "ß", "SS", "ss", "ẞ",
        "ﬁ", "fi", "ﬃ", "İ", "ı", "i", "I", "Σ", "σ", "ς", "ǅ", "ǆ", "\u{212a}", "\u{212b}", "ᾳ", "\u{345}", "Α", "ι",
        "１", "1", "²", "①", "⑩", "10", "٣", "3", "⒈", "Ａ", "ａ", "ｱ", "ア", "ｶﾞ", "ガ", "\u{3099}", "👩", "\u{200d}",
        "👦", "🏽", "👋", "🇰", "🇷", "1\u{fe0f}\u{20e3}", "#", "\u{fe0f}", " ", "\t", "\n", "\u{a0}", "\u{3000}", "\u{200b}",
        "-", "(", ")", "日", "本", "😀", "™", "ℓ", "Ⅳ", "½",
    ];
    let mut cases = Vec::new();
    for _ in 0..count {
        let mut body = String::new();
        for _ in 0..r.next() % 10 + 1 {
            body.push_str(r.pick(POOL));
        }
        let chars: Vec<char> = body.chars().collect();
        let mut query: String = match r.next() % 4 {
            0 | 1 => {
                let start = r.next() as usize % chars.len();
                let len = r.next() as usize % (chars.len() - start) + 1;
                chars[start..start + len].iter().collect()
            }
            2 => (0..r.next() % 3 + 1).map(|_| r.pick(POOL)).collect(),
            _ => {
                let start = r.next() as usize % chars.len();
                let len = r.next() as usize % (chars.len() - start) + 1;
                let part: String = chars[start..start + len].iter().collect();
                if r.next() % 2 == 0 { part.to_uppercase() } else { part.to_lowercase() }
            }
        };
        match r.next() % 8 {
            0 => query = format!(" {query}"),
            1 => query = format!("{query}\n"),
            2 => query.clear(),
            _ => {}
        }
        cases.push(json!({"body": body, "query": query}));
    }
    fs::write(root.join("search-cases.json"), serde_json::to_vec(&json!({ "cases": cases }))?)?;
    Ok(())
}

// 마크다운 엔진 비교용 무작위 조각(P5)
const MD_BLOCK: &[&str] = &[
    "# ", "## ", "###### ", "####### ", "#", "- ", "* ", "+ ", "-", "1. ", "12. ", "007. ", "1) ", "١. ", "一. ", "①. ", "- [ ] ", "- [x] ", "- [X] ",
    "[ ] ", "[x] ", "[] ", "> ", ">", "---", "--- ", "***", "```", "``` ", "```js", "| ", "|", "• ", "◦ ", "☐ ", "☑ ", "✅ ", "❝ ", "  ", "    ", "\t", "      ", " ",
];
const MD_INLINE: &[&str] = &[
    "**", "*", "***", "~~", "==", "`", "``", "<span style=\"color:#D93025\">", "<span style='color: #d93025;'>", "</span>",
    "<mark style=\"background:#A7D3FF\">", "<mark style='background-color: #a7d3ff;'>", "</mark>", "<span style=\"background:#A7D3FF\">",
    "<span  style = \"color : #D93025 ;\" >", "<mark style=\"color:#A7D3FF\">", "<span style=\"color:#GGGGGG\">", "<span style=\"color:#D9302\">",
    "![a](attachments/p.png =12)", "![](attachments/x.png)", "![a](attachments/", ")", "(", "[", "]", "\\", "\"", "=12", " =",
];
const MD_TEXT: &[&str] = &[
    "한글", "abc", "가나다", "a b", "x", "1", "23", "😀", "👩\u{200d}👩\u{200d}👧\u{200d}👦", "🇰🇷", "e\u{301}", "\u{301}", "a\u{301}", "\u{200d}",
    "\u{1112}\u{1161}\u{11ab}", "\u{1fef}", "\u{37e}", "\u{212a}", "①", "١", "一", "½", "\u{200b}", "\u{fe0f}", "é", "ß", "İ", "Σ",
    "क्ष", "\u{600}", "\u{e33}", "\u{903}", "\u{1f1f0}", "\u{1f3fd}", "👋🏽", "1\u{fe0f}\u{20e3}", "\u{1f3f4}\u{e0067}\u{e007f}", "\u{387}", "\u{2126}", "\u{2260}",
    "\u{344}", "\u{ac00}", "\u{1100}", "\u{11a8}", "\u{ff9e}", "\u{200c}", "\u{1d7d8}", "𝟑",
];
const MD_SPACE: &[&str] = &[
    " ", " ", " ", "  ", "\t", "\u{a0}", "\u{3000}", "\u{2003}", "\u{85}", "\u{2028}", "\u{b}", "\u{c}", "\u{1c}", "\u{180e}", "\u{200a}",
    "\u{202f}", "\u{205f}", "\u{feff}", "\u{2060}", "\u{200b}", "\u{1680}", "\u{2029}",
];
const MD_BREAK: &[&str] = &["\n", "\n", "\n", "\n", "\r\n", "\r", "\n\n", "\u{2028}"];
const MD_CELL: &[&str] = &["|", "|", " | ", "---", ":---", "---:", ":-:", " ", "한글", "a", "😀", "\u{301}", "\t", "\u{a0}", "|--|", "-", "::", "\u{2212}"];
const MD_PAIRS: &[&str] = &["**", "*", "***", "~~", "==", "`"];
const MD_COLOR_OPEN: &[(&str, &str)] = &[
    ("<span style=\"color:#D93025\">", "</span>"),
    ("<span style='color: #d93025;'>", "</span>"),
    ("<mark style=\"background:#A7D3FF\">", "</mark>"),
    ("<mark style='background-color: #a7d3ff;'>", "</mark>"),
    ("<span  style = \"color : #D93025 ;\" >", "</span>"),
    ("<span\tstyle=\"color:#D93025\">", "</span>"),
    ("<span\u{a0}style=\"color:#D93025\">", "</span>"),
    ("<span style=\"background:#A7D3FF\">", "</span>"),
    ("<mark style=\"color:#A7D3FF\">", "</mark>"),
    ("<span style=\"color:#GGGGGG\">", "</span>"),
    ("<span style=\"color:#D9302\">", "</span>"),
    ("<mark style=\"background-color:#abcdef;\" >", "</mark>"),
];

/// 조각을 이어 붙이며 조각 경계의 문자소 위치(입력 규칙의 커서 후보)를 함께 돌려준다.
fn md_build(r: &mut Random, pools: &[&[&str]], max: u64) -> (String, Vec<usize>) {
    let mut text = String::new();
    let mut cuts = vec![0];
    for _ in 0..r.next() % max + 1 {
        let pool = pools[r.next() as usize % pools.len()];
        text.push_str(r.pick(pool));
        cuts.push(mdemo_markdown::text::count(&text));
    }
    (text, cuts)
}

/// 짝이 맞는 인라인 서식을 중첩해 만든다. 가끔 닫는 기호를 빼거나 다른 기호로 바꾼다.
fn md_inline(r: &mut Random, depth: u32) -> String {
    let mut out = String::new();
    for _ in 0..r.next() % 4 + 1 {
        if depth >= 3 || r.next() % 5 < 2 {
            let pool = if r.next() % 4 == 0 { MD_SPACE } else { MD_TEXT };
            out.push_str(r.pick(pool));
            continue;
        }
        let (open, close) = if r.next() % 4 == 0 {
            let (o, c) = MD_COLOR_OPEN[r.next() as usize % MD_COLOR_OPEN.len()];
            (o.to_string(), c.to_string())
        } else {
            let m = r.pick(MD_PAIRS);
            (m.to_string(), m.to_string())
        };
        let inner = md_inline(r, depth + 1);
        out.push_str(&open);
        out.push_str(&inner);
        match r.next() % 12 {
            0 => {}
            1 => out.push_str(r.pick(MD_PAIRS)),
            2 => {
                out.push_str(&close);
                out.push_str(r.pick(MD_TEXT))
            }
            _ => out.push_str(&close),
        }
    }
    out
}

/// 올바른 블록 앞머리에 인라인 내용을 붙인 한 줄. 가끔 앞머리를 비튼다.
fn md_structured_line(r: &mut Random) -> String {
    const PREFIX: &[&str] = &[
        "# ", "## ", "### ", "###### ", "- ", "* ", "+ ", "1. ", "23. ", "- [ ] ", "- [x] ", "- [X] ", "> ", "", "", "", "| ", "![a](attachments/p.png =12)", "---", "```", "``` js",
    ];
    const INDENT: &[&str] = &["", "", "", "  ", "    ", "\t", "\t\t", " ", "   ", " \t", "\u{a0}", "\u{3000}"];
    let mut line = String::new();
    line.push_str(r.pick(INDENT));
    let prefix = r.pick(PREFIX);
    line.push_str(prefix);
    if prefix.starts_with("| ") {
        for _ in 0..r.next() % 3 + 1 {
            line.push_str(&md_inline(r, 2));
            line.push_str(" | ");
        }
    } else if !prefix.starts_with("![") && prefix != "---" {
        line.push_str(&md_inline(r, 0));
    }
    if r.next() % 8 == 0 {
        line.push_str(r.pick(MD_TEXT));
    }
    line
}

fn md_line(r: &mut Random) -> String {
    if r.next() % 2 == 0 { md_structured_line(r) } else { md_build(r, &[MD_BLOCK, MD_INLINE, MD_TEXT, MD_TEXT, MD_SPACE], 7).0 }
}

/// 입력 규칙 사례: 규칙이 실제로 걸릴 만한 꼴(앞머리 직후 커서, 닫는 기호 직후 커서)을 자주 만든다.
fn md_rule_case(r: &mut Random) -> (String, usize) {
    const MARKERS: &[&str] = &["# ", "## ", "###### ", "####### ", "- ", "* ", "1. ", "12. ", "- [ ] ", "- [x] ", "[ ] ", "[] ", "[x] ", "[X] ", "``` ", "007. "];
    const INDENT: &[&str] = &["", "", "", "  ", "    ", "\t", " ", "\u{a0}"];
    let count = mdemo_markdown::text::count;
    match r.next() % 4 {
        0 => {
            let head = format!("{}{}", r.pick(INDENT), r.pick(MARKERS));
            let tail = if r.next() % 3 == 0 { String::new() } else { md_inline(r, 2) };
            let mut caret = count(&head);
            if r.next() % 5 == 0 {
                caret = (caret + r.next() as usize % 3).saturating_sub(1);
            }
            (format!("{head}{tail}"), caret)
        }
        1 => {
            let m = r.pick(MD_PAIRS);
            let before = if r.next() % 2 == 0 { String::new() } else { md_inline(r, 2) };
            let inner = if r.next() % 8 == 0 { r.pick(MD_SPACE).to_string() } else { md_inline(r, 2) };
            let text = format!("{before}{m}{inner}{m}");
            let mut caret = count(&text);
            let extra = if r.next() % 4 == 0 { r.pick(MD_TEXT).to_string() } else { String::new() };
            if r.next() % 6 == 0 {
                caret = caret.saturating_sub(1);
            }
            (format!("{text}{extra}"), caret)
        }
        2 => {
            let (content, cuts) = md_build(r, &[MD_BLOCK, MD_INLINE, MD_TEXT, MD_SPACE], 6);
            let caret = cuts[r.next() as usize % cuts.len()];
            (content, caret)
        }
        _ => {
            let content = md_line(r);
            let n = count(&content);
            (content, r.next() as usize % (n + 2))
        }
    }
}

/// 마크다운 엔진 비교용 무작위 입력(P5). 블록 · 인라인 기호 조각에 한글 · 이모지 · 결합 문자 · 줄바꿈 종류를 섞는다.
/// 건수는 문서 · 한 줄 · 인라인 · 붙여넣기 · 표 · 입력 규칙 · 이미지 문법이 같고, OCR · 이미지 이름 · 슬래시 · 표식은 그 절반이다.
fn markdown_cases(root: &Path, count: usize, r: &mut Random) -> Result<(), Box<dyn Error>> {
    let document = |r: &mut Random| -> String {
        let mut out = String::new();
        for i in 0..r.next() % 8 + 1 {
            if i > 0 {
                out.push_str(r.pick(MD_BREAK));
            }
            out.push_str(&md_line(r));
        }
        out
    };
    let pasted = |r: &mut Random| -> String {
        const LIST: &[&str] = &["- ", "* ", "+ ", "• ", "◦ ", "☐ ", "☑ ", "[ ] ", "1. ", "2) ", "- [ ] ", "❝ ", "> ", "# ", "```"];
        const INDENT: &[&str] = &["", "", "  ", "    ", "\t", "\t\t", "   ", "      ", " \t", "\u{a0}\u{a0}"];
        let mut out = String::new();
        for i in 0..r.next() % 8 + 1 {
            if i > 0 {
                out.push_str(r.pick(MD_BREAK));
            }
            out.push_str(r.pick(INDENT));
            out.push_str(r.pick(LIST));
            out.push_str(&if r.next() % 2 == 0 { md_inline(r, 1) } else { md_build(r, &[MD_TEXT, MD_INLINE, MD_SPACE], 3).0 });
        }
        if r.next() % 3 == 0 {
            out.push_str(r.pick(MD_BREAK));
        }
        out
    };
    let n = count;
    let half = (count / 2).max(1);
    let mut documents = Vec::new();
    let mut lines = Vec::new();
    let mut inlines = Vec::new();
    let mut tables = Vec::new();
    let mut pastes = Vec::new();
    let mut rules = Vec::new();
    let mut images = Vec::new();
    for _ in 0..n {
        documents.push(document(r));
        lines.push(md_line(r));
        inlines.push(if r.next() % 4 != 0 { md_inline(r, 0) } else { md_build(r, &[MD_INLINE, MD_INLINE, MD_TEXT, MD_TEXT, MD_SPACE], 9).0 });
        tables.push(if r.next() % 3 == 0 {
            let cells: Vec<String> = (0..r.next() % 4 + 1).map(|_| r.pick(&["---", ":---", "---:", ":-:", "--", "a", "", " --- ", "한글"]).to_string()).collect();
            format!("{}|{}|{}", r.pick(&["", " ", "\t", "\u{a0}"]), cells.join("|"), r.pick(&["", " ", "\t", "\u{3000}", "\u{200b}"]))
        } else {
            md_build(r, &[MD_CELL, MD_CELL, MD_TEXT, MD_SPACE], 10).0
        });
        pastes.push(pasted(r));
        let (content, caret) = md_rule_case(r);
        let block = match r.next() % 10 {
            0 => json!({"kind": "bullet", "indent": r.next() % 3}),
            1 => json!({"kind": "heading", "level": r.next() % 6 + 1}),
            2 => json!({"kind": "checkbox", "indent": r.next() % 3, "checked": r.next() % 2 == 0}),
            3 => json!({"kind": r.pick(&["quote", "codeBlock", "divider", "tableRow", "ordered"]), "indent": 0, "number": 1}),
            _ => json!({"kind": "paragraph"}),
        };
        rules.push(json!({"content": content, "caret": caret, "block": block}));
        let alt = md_build(r, &[MD_TEXT, MD_INLINE, MD_SPACE], 3).0;
        let name = if r.next() % 4 == 0 { md_build(r, &[MD_TEXT, MD_INLINE, MD_SPACE], 3).0 } else { format!("p{}.png", r.next() % 100) };
        let size = match r.next() % 8 {
            0 => String::new(),
            1 => format!(" ={}", r.next() % 100000),
            2 => format!("{}={}", r.pick(MD_SPACE), r.next() % 500),
            3 => format!(" ={}", r.pick(&["0", "٣", "１２", "99999999999999999999", "50%", "-1", ""])),
            _ => format!(" ={}", r.next() % 2000 + 1),
        };
        let head = r.pick(&["![", "![", "![", "![", "![", "!", ""]);
        let prefix = r.pick(&["attachments/", "attachments/", "attachments/", "attachments/", "../", "attachments/a/", "attachments\\", ""]);
        let tail = r.pick(&[")", ")", ")", ")", ")", "))", "", ") ", ")\u{301}"]);
        let lead = r.pick(&["", "", "", " ", "\t", "\u{3000}"]);
        images.push(format!("{lead}{head}{alt}]({prefix}{name}{size}{tail}"));
    }
    let mut ocr = Vec::new();
    let mut names = Vec::new();
    let mut slash = Vec::new();
    let mut markers = Vec::new();
    for _ in 0..half {
        // 줄 간격 0.05 안팎, 가끔 큰 틈 · 같은 줄 조각 · 높이 변화
        let mut fragments = Vec::new();
        let mut y = 0.95f64;
        for _ in 0..r.next() % 10 {
            let height = [0.02, 0.03, 0.03, 0.03, 0.04, 0.05, 0.06, 0.0][r.next() as usize % 8];
            let x = (r.next() % 600) as f64 / 1000.0;
            let jitter = (r.next() % 21) as f64 / 1000.0 - 0.01;
            let text = match r.next() % 4 {
                0 => md_build(r, &[MD_BLOCK, MD_TEXT, MD_SPACE], 3).0,
                1 => format!("{}{}", r.pick(&["• ", "· ", "▪ ", "◦ ", "- ", "* ", "☐ ", "☑ ", "✓ ", "■ ", "① ", "⑩ ", "1. ", "12) ", "123. ", "1234. ", "١. ", "3.5", "-5", "*", "•", "\u{387} ", "1.\u{3000}", "1.\n"]), r.pick(MD_TEXT)),
                _ => md_build(r, &[MD_TEXT, MD_SPACE], 3).0,
            };
            fragments.push(json!({"text": text, "x": x, "y": y + jitter, "width": 0.3, "height": height}));
            if r.next() % 5 != 0 {
                y -= [0.05, 0.05, 0.05, 0.1, 0.2][r.next() as usize % 5];
            }
        }
        ocr.push(json!({"lines": fragments}));
        let title = if r.next() % 3 == 0 { json!(null) } else { json!(md_build(r, &[MD_TEXT, MD_INLINE, MD_SPACE], 3).0) };
        let ordinal = if r.next() % 10 == 0 { r.next() as i64 } else { r.next() as i64 % 60 - 5 };
        let alt = if r.next() % 2 == 0 { String::new() } else { md_build(r, &[MD_TEXT, MD_INLINE, MD_SPACE, &["/", ":", "\\", ".", "\n", "\0"]], 4).0 };
        names.push(json!({"alt": alt, "title": title, "ordinal": ordinal, "ext": r.pick(&["png", "", "jpeg", "tar.gz", ".x", "한"])}));
        const WORDS: &[&str] = &["제목", "체크", "check", "todo", "목록", "코드", "표", "h1", "본문", "divider", "line", "quote", "인용", "박스", "없음", "list", "번호", "ordered"];
        slash.push(match r.next() % 3 {
            0 => r.pick(WORDS).to_string(),
            1 => format!("{}{}{}", r.pick(MD_SPACE), r.pick(WORDS).to_uppercase(), r.pick(&["", " ", "\u{301}"])),
            _ => md_build(r, &[WORDS, MD_TEXT, MD_SPACE], 3).0,
        });
        markers.push(json!({"number": r.next() % 6000, "indent": r.next() as i64 % 10 - 2}));
    }
    fs::write(
        root.join("markdown-cases.json"),
        serde_json::to_vec(&json!({
            "documents": documents, "lines": lines, "inlines": inlines, "tables": tables, "pastes": pastes, "ocr": ocr,
            "imageNames": names, "slash": slash, "inputRules": rules, "images": images, "markers": markers
        }))?,
    )?;
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
