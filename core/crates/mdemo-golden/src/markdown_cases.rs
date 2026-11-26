//! 마크다운 엔진 비교 (Swift `MarkdownCases.swift`와 같은 출력, P5).
//! 사례마다 엔진을 그대로 호출하고, 키를 정렬한 한 줄 JSON으로 적는다.

use mdemo_markdown::{
    image_name,
    ocr::{self, OcrLine, OcrMode},
    parser, pasted, serializer, slash, table, BlockStyle, Flavor, InputRuleContext, InputRuleOutcome, InputRuleSet, MarkdownImage,
    OrderedListMarker, StyledLine, StyledSpan,
};
use serde_json::Value;
use std::{collections::BTreeMap, error::Error, fs, path::Path};

enum J {
    Null,
    Bool(bool),
    Int(i64),
    Str(String),
    Arr(Vec<J>),
    Obj(BTreeMap<&'static str, J>),
}

impl J {
    fn text(&self) -> String {
        match self {
            J::Null => "null".into(),
            J::Bool(v) => v.to_string(),
            J::Int(v) => v.to_string(),
            J::Str(v) => escape(v),
            J::Arr(v) => format!("[{}]", v.iter().map(J::text).collect::<Vec<_>>().join(",")),
            J::Obj(v) => format!("{{{}}}", v.iter().map(|(k, v)| format!("{}:{}", escape(k), v.text())).collect::<Vec<_>>().join(",")),
        }
    }
}

/// 따옴표 · 역슬래시 · 제어 문자(0x20 미만)만 바꾸고 나머지는 그대로 UTF-8로 적는다.
fn escape(value: &str) -> String {
    let mut out = String::from("\"");
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn obj<const N: usize>(items: [(&'static str, J); N]) -> J {
    J::Obj(items.into_iter().collect())
}
fn s(v: &str) -> J {
    J::Str(v.to_string())
}
fn opt(v: &Option<String>) -> J {
    v.as_ref().map_or(J::Null, |v| J::Str(v.clone()))
}
fn strings(v: &[String]) -> J {
    J::Arr(v.iter().map(|v| s(v)).collect())
}

fn block_json(block: &BlockStyle) -> J {
    match block {
        BlockStyle::Paragraph => obj([("kind", s("paragraph"))]),
        BlockStyle::Heading { level } => obj([("kind", s("heading")), ("level", J::Int(*level))]),
        BlockStyle::Bullet { indent } => obj([("kind", s("bullet")), ("indent", J::Int(*indent))]),
        BlockStyle::Ordered { indent, number } => obj([("kind", s("ordered")), ("indent", J::Int(*indent)), ("number", J::Int(*number))]),
        BlockStyle::Checkbox { indent, checked } => obj([("kind", s("checkbox")), ("indent", J::Int(*indent)), ("checked", J::Bool(*checked))]),
        BlockStyle::Quote => obj([("kind", s("quote"))]),
        BlockStyle::Divider => obj([("kind", s("divider"))]),
        BlockStyle::CodeBlock => obj([("kind", s("codeBlock"))]),
        BlockStyle::TableRow => obj([("kind", s("tableRow"))]),
        BlockStyle::Image(i) => obj([
            ("kind", s("image")),
            ("alt", s(&i.alt)),
            ("path", s(&i.path)),
            ("width", i.width.map_or(J::Null, J::Int)),
        ]),
    }
}

fn spans_json(spans: &[StyledSpan]) -> J {
    J::Arr(
        spans
            .iter()
            .map(|span| {
                obj([
                    ("text", s(&span.text)),
                    ("styles", J::Int(span.styles.0 as i64)),
                    ("textColor", opt(&span.text_color)),
                    ("highlightColor", opt(&span.highlight_color)),
                ])
            })
            .collect(),
    )
}

fn line_json(line: &StyledLine) -> J {
    obj([("block", block_json(&line.block)), ("spans", spans_json(&line.spans))])
}

fn image_json(image: Option<MarkdownImage>) -> J {
    let Some(image) = image else { return J::Null };
    obj([
        ("alt", s(&image.alt)),
        ("path", s(&image.path)),
        ("width", image.width.map_or(J::Null, J::Int)),
        ("fileName", s(&image.file_name())),
        ("markdown", s(&image.markdown())),
    ])
}

fn block_from(spec: &Value) -> BlockStyle {
    let int = |key: &str, default: i64| spec.get(key).and_then(Value::as_i64).unwrap_or(default);
    match spec.get("kind").and_then(Value::as_str).unwrap_or("") {
        "heading" => BlockStyle::Heading { level: int("level", 1) },
        "bullet" => BlockStyle::Bullet { indent: int("indent", 0) },
        "ordered" => BlockStyle::Ordered { indent: int("indent", 0), number: int("number", 1) },
        "checkbox" => BlockStyle::Checkbox { indent: int("indent", 0), checked: spec.get("checked").and_then(Value::as_bool).unwrap_or(false) },
        "quote" => BlockStyle::Quote,
        "divider" => BlockStyle::Divider,
        "codeBlock" => BlockStyle::CodeBlock,
        "tableRow" => BlockStyle::TableRow,
        "image" => BlockStyle::Image(MarkdownImage::new(
            spec.get("alt").and_then(Value::as_str).unwrap_or(""),
            spec.get("path").and_then(Value::as_str).unwrap_or(""),
            spec.get("width").and_then(Value::as_i64),
        )),
        _ => BlockStyle::Paragraph,
    }
}

fn list<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value.get(key).and_then(Value::as_array).map_or(&[], Vec::as_slice)
}

fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str, Box<dyn Error>> {
    value.get(key).and_then(Value::as_str).ok_or_else(|| format!("markdown-cases 형식 오류: {key}").into())
}

fn num(value: &Value, key: &str) -> Result<f64, Box<dyn Error>> {
    value.get(key).and_then(Value::as_f64).ok_or_else(|| format!("markdown-cases 형식 오류: {key}").into())
}

pub fn run(cases_file: &Path) -> Result<String, Box<dyn Error>> {
    let value: Value = serde_json::from_slice(&fs::read(cases_file)?)?;
    let strs = |key: &str| -> Result<Vec<&str>, Box<dyn Error>> {
        list(&value, key).iter().map(|v| v.as_str().ok_or_else(|| format!("markdown-cases 형식 오류: {key}").into())).collect()
    };

    let documents: Vec<J> = strs("documents")?
        .into_iter()
        .map(|source| {
            let lines = parser::parse(source);
            obj([
                ("lines", J::Arr(lines.iter().map(line_json).collect())),
                ("file", s(&serializer::serialize(&lines, Flavor::File))),
                ("clipboard", s(&serializer::serialize(&lines, Flavor::Clipboard))),
            ])
        })
        .collect();
    let lines: Vec<J> = strs("lines")?
        .into_iter()
        .map(|source| {
            let line = parser::parse_line(source);
            obj([
                ("line", line_json(&line)),
                ("file", s(&serializer::serialize_line(&line, Flavor::File))),
                ("clip", s(&serializer::serialize_line(&line, Flavor::Clipboard))),
            ])
        })
        .collect();
    let inlines: Vec<J> = strs("inlines")?.into_iter().map(|t| spans_json(&parser::parse_inline(t))).collect();
    let tables: Vec<J> = strs("tables")?
        .into_iter()
        .map(|source| {
            obj([
                ("isRow", J::Bool(table::is_row(source))),
                ("isSeparator", J::Bool(table::is_separator_row(source))),
                ("isEmptyRow", J::Bool(table::is_empty_row(source))),
                ("cells", strings(&table::cells_of(source))),
                ("columns", J::Int(table::column_count_of(source) as i64)),
            ])
        })
        .collect();
    let pastes: Vec<J> = strs("pastes")?
        .into_iter()
        .map(|source| {
            let parsed = pasted::parse(source);
            obj([
                ("normalized", s(&pasted::normalize(source))),
                ("lines", J::Arr(parsed.iter().map(line_json).collect())),
                ("file", s(&serializer::serialize(&parsed, Flavor::File))),
            ])
        })
        .collect();
    let mut ocr_out = Vec::new();
    for item in list(&value, "ocr") {
        let mut fragments = Vec::new();
        for f in list(item, "lines") {
            fragments.push(OcrLine::new(text(f, "text")?, num(f, "x")?, num(f, "y")?, num(f, "width")?, num(f, "height")?));
        }
        ocr_out.push(obj([
            ("markdown", s(&ocr::build(&fragments, OcrMode::Markdown))),
            ("plain", s(&ocr::build(&fragments, OcrMode::Plain))),
        ]));
    }
    let mut image_names = Vec::new();
    for item in list(&value, "imageNames") {
        let alt = text(item, "alt")?;
        let title = item.get("title").and_then(Value::as_str);
        let ordinal = item.get("ordinal").and_then(Value::as_i64).ok_or("ordinal 없음")?;
        image_names.push(obj([
            ("name", s(&image_name::default_name(alt, title, ordinal, text(item, "ext")?))),
            ("sanitized", s(&image_name::sanitized(alt))),
        ]));
    }
    let slash_out: Vec<J> = strs("slash")?.into_iter().map(|q| J::Arr(slash::filter_standard(q).iter().map(|c| s(&c.id)).collect())).collect();
    let rules = InputRuleSet::m1();
    let mut input_rules = Vec::new();
    for item in list(&value, "inputRules") {
        let caret = item.get("caret").and_then(Value::as_i64).ok_or("caret 없음")?;
        let context = InputRuleContext::new(text(item, "content")?, caret.max(0) as usize, block_from(item.get("block").unwrap_or(&Value::Null)));
        input_rules.push(match rules.first_match(&context) {
            None => J::Null,
            Some(m) => {
                let outcome = match &m.outcome {
                    InputRuleOutcome::Block(b) => obj([("kind", s("block")), ("block", block_json(b))]),
                    InputRuleOutcome::Inline(styles) => obj([("kind", s("inline")), ("styles", J::Int(styles.0 as i64))]),
                };
                obj([
                    ("range", J::Arr(vec![J::Int(m.range.start as i64), J::Int(m.range.end as i64)])),
                    ("replacement", s(&m.replacement)),
                    ("outcome", outcome),
                ])
            }
        });
    }
    let images: Vec<J> = strs("images")?
        .into_iter()
        .map(|source| obj([("image", image_json(MarkdownImage::parse(source))), ("validName", J::Bool(MarkdownImage::is_valid_file_name(source)))]))
        .collect();
    let mut markers = Vec::new();
    for item in list(&value, "markers") {
        let number = item.get("number").and_then(Value::as_i64).ok_or("number 없음")?;
        let indent = item.get("indent").and_then(Value::as_i64).ok_or("indent 없음")?;
        markers.push(obj([
            ("text", s(&OrderedListMarker::text(number, indent))),
            ("letters", s(&OrderedListMarker::letters(number))),
            ("roman", s(&OrderedListMarker::roman(number))),
            ("style", J::Int(OrderedListMarker::style(indent) as i64)),
        ]));
    }

    let result = obj([
        ("documents", J::Arr(documents)),
        ("lines", J::Arr(lines)),
        ("inlines", J::Arr(inlines)),
        ("tables", J::Arr(tables)),
        ("pastes", J::Arr(pastes)),
        ("ocr", J::Arr(ocr_out)),
        ("imageNames", J::Arr(image_names)),
        ("slash", J::Arr(slash_out)),
        ("inputRules", J::Arr(input_rules)),
        ("images", J::Arr(images)),
        ("markers", J::Arr(markers)),
    ]);
    Ok(result.text() + "\n")
}
