#!/usr/bin/env python3
"""Swift 문자열 비교용 정규 분해 표만 재생성한다. 원문과 비교 규칙은 바꾸지 않는다."""
import pathlib
import unicodedata

if unicodedata.unidata_version != '17.0.0':
    raise SystemExit('Unicode 17.0.0 데이터를 가진 Python이 필요합니다.')
path = pathlib.Path(__file__).resolve().parent.parent / 'core/crates/mdemo-core/src/unicode.rs'
source = path.read_text()
start = source.index('const DECOMPOSITION:')
end = source.index('#[cfg(test)]', start)
rows = ['const DECOMPOSITION: &[(u32, &[u32])] = &[']
for scalar in range(0x110000):
    decomposition = unicodedata.decomposition(chr(scalar))
    if decomposition and not decomposition.startswith('<'):
        values = ', '.join(str(int(value, 16)) for value in decomposition.split())
        rows.append(f'    ({scalar}, &[{values}]),')
rows.extend(['];', 'const CLASS: &[(u32, u8)] = &['])
for scalar in range(0x110000):
    combining = unicodedata.combining(chr(scalar))
    if combining:
        rows.append(f'    ({scalar}, {combining}),')
rows.append('];\n')
path.write_text(source[:start] + '\n'.join(rows) + source[end:])
print('정규 분해 표를 갱신했습니다. cargo fmt와 cargo test를 실행하세요.')
