#!/usr/bin/env python3
"""본문 검색용 숫자 접기 표(core/crates/mdemo-core/src/store/digits.rs)를 다시 만든다.

Swift의 localizedCaseInsensitiveContains는 다른 문자 체계의 숫자를 ASCII 숫자와 같게 본다(골든 search-cases로 확인).
- 호환 분해가 숫자로만 이루어진 글자: 전각 ０-９, 위 · 아래 첨자, 동그라미 숫자 ①, ⑩ 등. ⑩은 "10"이 된다.
- 분해가 없고 Numeric_Type이 Decimal 또는 Digit인 글자: 아랍 인도 숫자, 수학용 숫자, ❶, ⓪ 등.
호환 분해에 숫자가 아닌 글자가 섞인 ⒈, ⑴, 🄀은 같게 보지 않는다.
"""
import pathlib, unicodedata

root = pathlib.Path(__file__).resolve().parent.parent
entries = []  # (코드 포인트, 접은 숫자 문자열)
for cp in range(0x30 + 10, 0x110000):
    ch = chr(cp)
    decomposition = unicodedata.decomposition(ch)
    folded = None
    if decomposition.startswith('<'):
        parts = [int(p, 16) for p in decomposition.split()[1:]]
        if all(0x30 <= p <= 0x39 for p in parts):
            folded = ''.join(chr(p) for p in parts)
    elif not decomposition:
        try:
            folded = str(unicodedata.digit(ch))
        except ValueError:
            pass
    if folded:
        entries.append((cp, folded))

# 한 글자 숫자가 이어지면 범위로 묶는다: [시작, 끝, 시작 글자의 숫자 문자열]
ranges = []
for cp, folded in entries:
    last = ranges[-1] if ranges else None
    if last and len(folded) == 1 and len(last[2]) == 1 and cp == last[1] + 1 and int(folded) == int(last[2]) + (cp - last[0]):
        last[1] = cp
    else:
        ranges.append([cp, cp, folded])
lines = [
    f"// Unicode {unicodedata.unidata_version}의 호환 분해와 Numeric_Type으로 만든 숫자 접기 표(시작, 끝, 시작 글자의 숫자 문자열).",
    "// Scripts/generate-search-tables.py 로 만든다. 손으로 고치지 않는다.",
    "pub(super) const DIGITS: &[(u32, u32, &str)] = &[",
]
lines += [f'    (0x{s:X}, 0x{e:X}, "{v}"),' for s, e, v in ranges]
lines.append("];")
# Numeric_Type이 Decimal인 글자의 범위(검색어가 이런 글자로 시작하는지 판단하는 데 쓴다).
decimal = []
for cp in range(0x110000):
    try:
        unicodedata.decimal(chr(cp))
    except ValueError:
        continue
    if decimal and cp == decimal[-1][1] + 1:
        decimal[-1][1] = cp
    else:
        decimal.append([cp, cp])
lines.append("pub(super) const DECIMAL: &[(u32, u32)] = &[")
lines += [f"    (0x{s:X}, 0x{e:X})," for s, e in decimal]
lines.append("];")
(root / "core/crates/mdemo-core/src/store/digits.rs").write_text("\n".join(lines) + "\n")
