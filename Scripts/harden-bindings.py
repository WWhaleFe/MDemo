#!/usr/bin/env python3
"""UniFFI 0.28의 비밀 전송 버퍼를 해제 전에 덮는다. 템플릿이 바뀌면 빌드를 중단한다."""
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
replacements = {
    '    func deallocate() {\n        try! rustCall': '''    func deallocate() {
        // Rust에서 소유권을 넘긴 전송 버퍼도 해제 전에 덮는다.
        data?.initialize(repeating: 0, count: Int(capacity))
        try! rustCall''',
    '        var reader = createReader(data: Data(rustBuffer: buf))': '''        defer { buf.deallocate() }
        var reader = createReader(data: Data(rustBuffer: buf))
        defer { reader.data.resetBytes(in: 0..<reader.data.count) }''',
    '        buf.deallocate()\n        return value': '        return value',
    '          var writer = createWriter()': '''          var writer = createWriter()
          defer { _ = writer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }''',
    '        return String(bytes: try readBytes(&buf, count: Int(len)), encoding: String.Encoding.utf8)!': '''        var bytes = try readBytes(&buf, count: Int(len))
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return String(bytes: bytes, encoding: String.Encoding.utf8)!''',
    '        return Data(try readBytes(&buf, count: Int(len)))': '''        var bytes = try readBytes(&buf, count: Int(len))
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return Data(bytes)''',
}
for original, replacement in replacements.items():
    if source.count(original) != 1:
        raise SystemExit(f'UniFFI 버퍼 보강 위치 불일치: {original!r}')
    source = source.replace(original, replacement)
path.write_text(source)
