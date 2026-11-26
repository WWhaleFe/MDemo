#!/usr/bin/env python3
"""마크다운 엔진용 숫자 표(core/crates/mdemo-markdown/src/numeric_table.rs)를 다시 만든다.

Swift의 `Character.isNumber`는 첫 스칼라의 Numeric_Type이 None이 아닌지를 본다. 한자 숫자(一, 十), 분수(½),
동그라미 숫자(①) 같은 글자가 모두 들어가므로 Rust `char::is_numeric`으로는 맞출 수 없다.
정규식 `\\d`(ICU)는 Numeric_Type=Decimal(범주 Nd)과 같다.
Swift 런타임의 `Unicode.Scalar.Properties.numericType` 전체와 대조해 차이 0건임을 확인했다(Unicode 17.0.0).
"""
import pathlib, unicodedata

root = pathlib.Path(__file__).resolve().parent.parent


def ranges(predicate):
    result = []
    for cp in range(0x110000):
        if not predicate(chr(cp)):
            continue
        if result and cp == result[-1][1] + 1:
            result[-1][1] = cp
        else:
            result.append([cp, cp])
    return result


numeric = ranges(lambda c: unicodedata.numeric(c, None) is not None)
decimal = ranges(lambda c: unicodedata.decimal(c, None) is not None)
lines = [
    f"// Unicode {unicodedata.unidata_version}의 Numeric_Type 표. Scripts/generate-markdown-tables.py 로 만든다. 손으로 고치지 않는다.",
    "/// Numeric_Type이 None이 아닌 글자(Swift `Character.isNumber`).",
    "pub(crate) const NUMERIC: &[(u32, u32)] = &[",
]
lines += [f"    (0x{s:X}, 0x{e:X})," for s, e in numeric]
lines += ["];", "/// Numeric_Type=Decimal인 글자(ICU `\\d`).", "pub(crate) const DECIMAL: &[(u32, u32)] = &["]
lines += [f"    (0x{s:X}, 0x{e:X})," for s, e in decimal]
lines.append("];")
(root / "core/crates/mdemo-markdown/src/numeric_table.rs").write_text("\n".join(lines) + "\n")
