use serde::Serialize;
use serde_json::Value;
/// Foundation JSONEncoder의 공백, 슬래시, 빈 컨테이너와 숫자 서식을 따른다.
pub fn encode<T: Serialize + ?Sized>(
    value: &T,
    pretty: bool,
    sorted_keys: bool,
) -> Result<Vec<u8>, serde_json::Error> {
    // serde_json은 NaN을 null로 바꾸지만 Foundation은 오류를 반환한다.
    fn finite(v: &serde_value::Value) -> bool {
        use serde_value::Value;
        match v {
            Value::F32(v) => v.is_finite(),
            Value::F64(v) => v.is_finite(),
            Value::Option(Some(v)) | Value::Newtype(v) => finite(v),
            Value::Seq(values) => values.iter().all(finite),
            Value::Map(values) => values.iter().all(|(k, v)| finite(k) && finite(v)),
            _ => true,
        }
    }
    let checked = serde_value::to_value(value).map_err(serde::ser::Error::custom)?;
    if !finite(&checked) {
        return Err(serde::ser::Error::custom("유한하지 않은 JSON 숫자"));
    }
    let value = serde_json::to_value(value)?;
    Ok(render(&value, pretty, sorted_keys, 0).into_bytes())
}
pub fn double(value: f64) -> String {
    if value == 0.0 {
        return if value.is_sign_negative() { "-0" } else { "0" }.into();
    }
    // serde_json의 최단 표기는 정확히 중간인 십진수에서 짝수 쪽을 고른다.
    let raw = serde_json::Number::from_f64(value.abs())
        .unwrap()
        .to_string();
    let (mantissa, shift) = if let Some((m, e)) = raw.split_once('e') {
        (m, e.parse::<i32>().unwrap())
    } else {
        (raw.as_str(), 0)
    };
    let decimal = mantissa.find('.').unwrap_or(mantissa.len()) as i32;
    let all: String = mantissa.chars().filter(|c| *c != '.').collect();
    let leading = all.bytes().take_while(|b| *b == b'0').count();
    let exponent = decimal - leading as i32 - 1 + shift;
    let digits = all[leading..].trim_end_matches('0');
    let sign = if value.is_sign_negative() { "-" } else { "" };
    // Swift는 정확한 정수 범위를 넘는 Double을 지수 형태로 쓴다.
    if value.abs() < 0.0001 || value.abs() > 9_007_199_254_740_992.0 {
        let tail = if digits.len() > 1 {
            format!(".{}", &digits[1..])
        } else {
            String::new()
        };
        format!(
            "{sign}{}{tail}e{}{:02}",
            &digits[..1],
            if exponent < 0 { "-" } else { "+" },
            exponent.abs()
        )
    } else {
        let point = exponent + 1;
        if point <= 0 {
            format!("{sign}0.{}{digits}", "0".repeat((-point) as usize))
        } else if point as usize >= digits.len() {
            format!(
                "{sign}{digits}{}",
                "0".repeat(point as usize - digits.len())
            )
        } else {
            format!(
                "{sign}{}.{}",
                &digits[..point as usize],
                &digits[point as usize..]
            )
        }
    }
}

fn string(s: &str) -> String {
    serde_json::to_string(s).unwrap().replace('/', "\\/")
}
fn render(v: &Value, p: bool, sorted: bool, depth: usize) -> String {
    let indent = |d| "  ".repeat(d);
    let join = |items: Vec<String>, open: &str, close: &str| {
        if p {
            format!("{open}\n{}\n{}{close}", items.join(",\n"), indent(depth))
        } else {
            format!("{open}{}{close}", items.join(","))
        }
    };
    match v {
        Value::Null => "null".into(),
        Value::Bool(b) => b.to_string(),
        Value::String(s) => string(s),
        Value::Number(n) => {
            if n.is_f64() {
                double(n.as_f64().unwrap())
            } else {
                n.to_string()
            }
        }
        Value::Array(a) => join(
            a.iter()
                .map(|v| {
                    format!(
                        "{}{}",
                        if p { indent(depth + 1) } else { String::new() },
                        render(v, p, sorted, depth + 1)
                    )
                })
                .collect(),
            "[",
            "]",
        ),
        Value::Object(o) => {
            let mut entries: Vec<_> = o.iter().collect();
            if sorted {
                entries.sort_by(|a, b| a.0.cmp(b.0));
            }
            join(
                entries
                    .into_iter()
                    .map(|(k, v)| {
                        format!(
                            "{}{}{}{}",
                            if p { indent(depth + 1) } else { String::new() },
                            string(k),
                            if p { " : " } else { ":" },
                            render(v, p, sorted, depth + 1)
                        )
                    })
                    .collect(),
                "{",
                "}",
            )
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn foundation_format() {
        assert_eq!(
            encode(&vec!["a/b"], true, false).unwrap(),
            b"[\n  \"a\\/b\"\n]"
        );
        assert_eq!(encode(&Vec::<i32>::new(), true, false).unwrap(), b"[\n\n]");
        assert_eq!(double(1e-7), "1e-07");
        assert_eq!(double(1e16), "1e+16");
        assert_eq!(double(-0.), "-0");
    }
}
#[cfg(test)]
mod boundary_tests {
    use super::*;
    #[test]
    fn swift_shortest_numbers() {
        for (n, s) in [
            (9740568903986940., "9.74056890398694e+15"),
            (2152022966501068.25, "2152022966501068.2"),
            (9007199254740992., "9007199254740992"),
            (1e-4, "0.0001"),
            (1e-5, "1e-05"),
            (1.0, "1"),
        ] {
            assert_eq!(double(n), s);
        }
    }
    #[test]
    fn sorted_keys_and_empty_containers() {
        let mut m = serde_json::Map::new();
        m.insert("z/".into(), Value::Array(vec![]));
        m.insert("a".into(), serde_json::json!({}));
        assert_eq!(
            encode(&m, true, true).unwrap(),
            b"{\n  \"a\" : {\n\n  },\n  \"z\\/\" : [\n\n  ]\n}"
        );
        assert!(String::from_utf8(encode(&m, false, false).unwrap())
            .unwrap()
            .starts_with("{\"z"));
    }
}
#[cfg(test)]
mod nonfinite_tests {
    #[test]
    fn foundation_rejects_nan_and_infinity() {
        assert!(super::encode(&vec![f64::NAN], true, false).is_err());
        assert!(super::encode(&f64::INFINITY, false, false).is_err());
        assert_eq!(
            super::encode(&Option::<f64>::None, false, false).unwrap(),
            b"null"
        );
    }
}
