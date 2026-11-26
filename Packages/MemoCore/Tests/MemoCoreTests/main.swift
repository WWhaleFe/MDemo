import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MemoCore
import TestKit

let rustStorage = CommandLine.arguments.contains("--rust-storage")
let runner = TestRunner("MemoCore [\(rustStorage ? "Rust" : "Swift")]")

/// 테스트가 이 맥의 실제 키체인을 건드리지 않게, 저장소는 모두 메모리 키체인을 쓴다.
final class TestMemoKeychain: MemoKeychain, @unchecked Sendable {
    private let mutex = NSLock()
    private var failures: [MemoID: Int] = [:]
    func readFailures(id: MemoID) throws -> Int { mutex.lock(); defer { mutex.unlock() }; return failures[id] ?? 0 }
    func writeFailures(_ count: Int, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; failures[id] = count }
    private var values: [MemoID: Data] = [:]
    func read(id: MemoID) throws -> Data? { mutex.lock(); defer { mutex.unlock() }; return values[id] }
    func write(_ value: Data, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; values[id] = value }
    func delete(id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; values[id] = nil; failures[id] = nil }
}
let testKeychain = TestMemoKeychain()

if CommandLine.arguments.contains("--measure-storage") {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MDemoMeasure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let swift = try FileMemoRepository(rootDirectory: root, keychain: testKeychain)
    let rust = try RustMemoRepository(rootDirectory: root, keychain: testKeychain)
    for i in 0..<300 { try swift.save(MemoDocument(meta: MemoMeta(id: .generate(), title: "측정 \(i)"), body: String(repeating: "한글 본문 🙂\n", count: 500))) }
    for repository in [swift as any MemoRepository, rust] { _ = try repository.loadSummaries() }
    var samples = [[Double](), [Double]()]
    for round in 0..<30 {
        for index in (round % 2 == 0 ? [0, 1] : [1, 0]) {
            let repository: any MemoRepository = index == 0 ? swift : rust
            let start = Date()
            let summaries = try repository.loadSummaries()
            precondition(summaries.count == 300)
            samples[index].append(Date().timeIntervalSince(start) * 1000)
        }
    }
    let medians = samples.map { $0.sorted()[$0.count / 2] }
    print("300개, 30회 중앙값 ms: Swift \(medians[0]), Rust \(medians[1]), 증감 \((medians[1] / medians[0] - 1) * 100)%")
    exit(0)
}

if CommandLine.arguments.contains("--shadow-tests-only") {
    registerShadowTests(runner)
    runner.finish()
}

// MARK: - 식별자와 모델

runner.test("ULID는 26자이며 생성 시각순으로 정렬된다") { t in
    let earlier = MemoID.generate(date: Date(timeIntervalSince1970: 1_000_000))
    let later = MemoID.generate(date: Date(timeIntervalSince1970: 2_000_000))

    t.expect(earlier.isValid, "이른 ID가 유효하지 않음: \(earlier)")
    t.expect(later.isValid, "늦은 ID가 유효하지 않음: \(later)")
    t.expectEqual(earlier.rawValue.count, 26)
    t.expect(earlier.rawValue < later.rawValue, "ULID는 문자열 정렬이 곧 시간순 정렬이어야 한다")
}

runner.test("같은 시각에 만들어도 ID는 충돌하지 않는다") { t in
    let now = Date()
    let ids = Set((0..<500).map { _ in MemoID.generate(date: now).rawValue })
    t.expectEqual(ids.count, 500, "중복 ID 발생")
}

runner.test("알파값은 하한선 아래로 내려가지 않는다 (OPA-03)") { t in
    let floored = MemoMeta(id: .generate(), backgroundAlpha: 0.0, textAlpha: 0.0)
    t.expectEqual(floored.backgroundAlpha, 0.15, "배경 알파 하한")
    t.expectEqual(floored.textAlpha, 0.3, "텍스트 알파 하한")

    let capped = MemoMeta(id: .generate(), backgroundAlpha: 2.0, textAlpha: 2.0)
    t.expectEqual(capped.backgroundAlpha, 1.0, "배경 알파 상한")
    t.expectEqual(capped.textAlpha, 1.0, "텍스트 알파 상한")
}

runner.test("배경색 프리셋 8가지가 모두 유효한 16진수다 (WIN-11)") { t in
    t.expectEqual(MemoColor.presets.count, 8)
    for preset in MemoColor.presets {
        t.expectNotNil(MemoColor.components(fromHex: preset.hex), "\(preset.name) 색상 파싱 실패")
    }
    t.expectNil(MemoColor.components(fromHex: "#XYZ"), "잘못된 색상 문자열은 거부해야 한다")
}

// MARK: - 프론트매터 (DOC-02)

runner.test("프론트매터는 왕복해도 값이 보존된다") { t in
    let meta = MemoMeta(
        id: .generate(),
        group: "업무",
        colorHex: "#FFF3B0",
        backgroundAlpha: 0.85,
        textAlpha: 0.7,
        isOpen: true,
        isPinned: false
    )
    let original = MemoDocument(meta: meta, body: "# 제목\n본문 내용\n- [ ] 할 일")

    let encoded = FrontmatterCodec.encode(original)
    let decoded = try FrontmatterCodec.decode(fileContents: encoded)

    t.expectEqual(decoded.meta.id, meta.id)
    t.expectEqual(decoded.meta.group, "업무")
    t.expectEqual(decoded.meta.colorHex, "#FFF3B0")
    t.expectEqual(decoded.meta.backgroundAlpha, 0.85)
    t.expectEqual(decoded.meta.textAlpha, 0.7)
    t.expectEqual(decoded.meta.isOpen, true)
    t.expectEqual(decoded.meta.isPinned, false)
    t.expectEqual(decoded.body, original.body, "본문이 변형되면 안 된다")
}

runner.test("따옴표와 역슬래시 및 줄바꿈을 한 번만 해석한다") { t in
    for value in ["역슬래시 뒤 따옴표 \\\"", "줄\n바꿈\r복귀\r\n끝", #"문자 그대로 \n \r \x \\"#, "끝\\", "한글 👩‍💻"] {
        let document = MemoDocument(meta: MemoMeta(id: .generate(), title: value, group: value, created: Date(timeIntervalSince1970: 1_000), modified: Date(timeIntervalSince1970: 1_000)), body: "본문\n유지")
        let encoded = FrontmatterCodec.encode(document)
        let decoded = try FrontmatterCodec.decode(fileContents: encoded)
        t.expectEqual(decoded.meta.title, value)
        t.expectEqual(decoded.meta.group, value)
        t.expectEqual(decoded.body, document.body)
        t.expectEqual(Data(FrontmatterCodec.encode(decoded).utf8), Data(encoded.utf8))
    }
    let document = MemoDocument(meta: MemoMeta(id: .generate(), title: "자리"), body: "")
    let unknownEscape = FrontmatterCodec.encode(document).replacingOccurrences(of: "title: \"자리\"", with: #"title: "알 수 없는 \x""#)
    t.expectEqual(try FrontmatterCodec.decode(fileContents: unknownEscape).meta.title, #"알 수 없는 \x"#)
}

runner.test("기존 작성기가 쓴 줄바꿈 없는 파일은 바이트 그대로 왕복한다") { t in
    for value in ["일반 제목", #"따옴표 "와 역슬래시 \"#, #"C:\notes\new \"인용\" \\"#, #"\n과 \r은 글자"#] {
        let document = MemoDocument(meta: MemoMeta(id: .generate(), title: "자리", group: "자리", created: Date(timeIntervalSince1970: 1_000), modified: Date(timeIntervalSince1970: 1_000)), body: "본문")
        // 기존 작성기의 치환 순서로 만든 값을 골든 파일에 넣는다.
        let legacyQuoted = "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        let legacy = FrontmatterCodec.encode(document).replacingOccurrences(of: "\"자리\"", with: legacyQuoted)
        let decoded = try FrontmatterCodec.decode(fileContents: legacy)
        t.expectEqual(decoded.meta.title, value)
        t.expectEqual(decoded.meta.group, value)
        t.expectEqual(Data(FrontmatterCodec.encode(decoded).utf8), Data(legacy.utf8))
    }
}

runner.test("해석하지 못한 라벨 꼬리도 세 번 저장한 뒤 원문과 같다") { t in
    let id = MemoID.generate()
    for tail in ["~%ZZ", "~%ZZ~future", "~~future", "~~%ZZ", "~label~future"] {
        let document = MemoDocument(meta: MemoMeta(id: .generate(), created: Date(timeIntervalSince1970: 1_000), modified: Date(timeIntervalSince1970: 1_000)), body: "본문")
        let original = FrontmatterCodec.encode(document).replacingOccurrences(of: "\n---\n", with: "\nlinks: flow:\(id.rawValue)\(tail)\n---\n")
        var text = original
        for _ in 0..<3 {
            let decoded = try FrontmatterCodec.decode(fileContents: text)
            t.expectEqual(decoded.meta.links.count, 1)
            text = FrontmatterCodec.encode(decoded)
        }
        t.expectEqual(Data(text.utf8), Data(original.utf8))
    }
}

runner.test("시험 실행의 설정 접근자는 standard와 분리되고 실행 인자를 읽는다") { t in
    let defaults = AppSettings.defaults(arguments: ["MDemo", "--data-dir=/tmp/mdemo-settings-test"])
    t.expect(defaults !== UserDefaults.standard)
    t.expect(AppSettings.defaults(arguments: ["MDemo"]) === UserDefaults.standard)
    let key = "mdemo.test.argument." + UUID().uuidString
    var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let saved = arguments
    defer { defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
    arguments[key] = "인자 값"
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    t.expectEqual(defaults.string(forKey: key), "인자 값")
}

runner.test("제목은 프론트매터에 남고 왕복해도 그대로다 (TXT-06)") { t in
    let meta = MemoMeta(id: .generate(), title: "장보기 목록")
    let encoded = FrontmatterCodec.encode(MemoDocument(meta: meta, body: "우유"))
    t.expect(encoded.contains("title: \"장보기 목록\""), "제목 줄이 없다:\n\(encoded)")

    let decoded = try FrontmatterCodec.decode(fileContents: encoded)
    t.expectEqual(decoded.meta.title, "장보기 목록")
    t.expectEqual(decoded.meta.schemaVersion, MemoMeta.currentSchemaVersion)
}

runner.test("제목이 없던 옛 파일도 그대로 읽힌다 (v1 → v2 마이그레이션)") { t in
    let id = MemoID.generate()
    let old = """
    ---
    schemaVersion: 1
    id: \(id.rawValue)
    color: "#FFF3B0"
    bgAlpha: 0.9
    textAlpha: 1.0
    open: true
    pinned: true
    created: 2026-08-26T00:00:00.000Z
    modified: 2026-08-26T00:00:00.000Z
    ---
    첫 줄이 제목 노릇을 한다
    """

    let decoded = try FrontmatterCodec.decode(fileContents: old)
    t.expectEqual(decoded.meta.title, nil, "없던 제목이 생겼다")
    t.expectEqual(decoded.meta.schemaVersion, MemoMeta.currentSchemaVersion, "스키마 버전이 올라가지 않았다")

    // 제목이 없으면 목록에는 본문 첫 줄이 보인다 (TXT-05).
    let summary = MemoSummary(meta: decoded.meta, preview: decoded.body)
    t.expectEqual(summary.title, "첫 줄이 제목 노릇을 한다")
}

runner.test("본문의 --- 구분선은 프론트매터로 오인되지 않는다 (MD-12)") { t in
    let meta = MemoMeta(id: .generate())
    let body = "위 문단\n\n---\n\n아래 문단"
    let encoded = FrontmatterCodec.encode(MemoDocument(meta: meta, body: body))
    let decoded = try FrontmatterCodec.decode(fileContents: encoded)
    t.expectEqual(decoded.body, body)
}

runner.test("모르는 프론트매터 필드는 보존된다 (상위 버전 호환)") { t in
    let id = MemoID.generate()
    let text = """
    ---
    schemaVersion: 1
    id: \(id.rawValue)
    color: "#FFF3B0"
    futureField: 미래에추가될값
    ---
    본문
    """
    let decoded = try FrontmatterCodec.decode(fileContents: text)
    t.expect(decoded.unknownFrontmatterLines.contains { $0.contains("futureField") }, "모르는 필드가 버려졌다")

    let reencoded = FrontmatterCodec.encode(decoded)
    t.expect(reencoded.contains("futureField"), "저장 시 모르는 필드가 사라지면 안 된다")
}

runner.test("수정 시각은 밀리초까지 보존된다 (SYNC-06 충돌 판정 기준)") { t in
    let precise = Date(timeIntervalSince1970: 1_700_000_000.456)
    let meta = MemoMeta(id: .generate(), created: precise, modified: precise)
    let decoded = try FrontmatterCodec.decode(fileContents: FrontmatterCodec.encode(MemoDocument(meta: meta, body: "")))

    let drift = abs(decoded.meta.modified.timeIntervalSince1970 - precise.timeIntervalSince1970)
    t.expect(drift < 0.01, "시각 오차가 \(drift)초 — 같은 초에 일어난 두 기기의 수정을 구분할 수 없다")
}

runner.test("소수점 없이 기록된 시각도 읽을 수 있다 (손으로 편집한 파일)") { t in
    let id = MemoID.generate()
    let text = """
    ---
    id: \(id.rawValue)
    modified: 2026-08-26T03:49:54Z
    ---
    본문
    """
    let decoded = try FrontmatterCodec.decode(fileContents: text)
    t.expect(decoded.meta.modified.timeIntervalSince1970 > 1_700_000_000, "예전 형식 시각 파싱 실패")
}

runner.test("한글 그룹명과 따옴표가 든 값도 안전하게 왕복한다") { t in
    let meta = MemoMeta(id: .generate(), group: "업무: \"중요\" 항목")
    let encoded = FrontmatterCodec.encode(MemoDocument(meta: meta, body: ""))
    let decoded = try FrontmatterCodec.decode(fileContents: encoded)
    t.expectEqual(decoded.meta.group, "업무: \"중요\" 항목")
}

runner.test("구분자가 없는 파일은 오류로 거부한다") { t in
    do {
        _ = try FrontmatterCodec.decode(fileContents: "구분자 없는 그냥 텍스트")
        t.expect(false, "오류가 발생해야 한다")
    } catch let error as FrontmatterError {
        t.expectEqual(error, .missingOpeningDelimiter)
    }
}

// MARK: - 파일 저장소 (DAT-08, IMG-07, TRS-01)

func makeRepository(root: URL, keychain: any MemoKeychain) throws -> any MemoRepository {
    if rustStorage { return try RustMemoRepository(rootDirectory: root, keychain: keychain) }
    return try FileMemoRepository(rootDirectory: root, keychain: keychain)
}

func makeTemporarySwiftRepository() throws -> (FileMemoRepository, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MDemoTests-\(UUID().uuidString)")
    return (try FileMemoRepository(rootDirectory: root, keychain: testKeychain), root)
}

func makeTemporaryRepository(keychain: any MemoKeychain = testKeychain) throws -> (any MemoRepository, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("MDemoTests-\(UUID().uuidString)", isDirectory: true)
    return (try makeRepository(root: root, keychain: keychain), root)
}

runner.test("저장한 메모를 그대로 다시 읽는다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let meta = MemoMeta(id: .generate(), group: "개인")
    let document = MemoDocument(meta: meta, body: "장보기 목록\n- [ ] 우유")
    try repository.save(document)

    let loaded = try repository.load(id: meta.id)
    t.expectEqual(loaded.body, document.body)
    t.expectEqual(loaded.meta.group, "개인")

    // 메모 하나가 폴더 하나 (설계서 §3-1)
    let expectedPath = root.appendingPathComponent("memos/\(meta.id.rawValue)/memo.md").path
    t.expect(FileManager.default.fileExists(atPath: expectedPath), "예상 경로에 파일이 없음: \(expectedPath)")
}

runner.test("요약 목록은 본문 전체를 읽지 않고도 제목과 미리보기를 만든다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let longBody = "# 회의록\n" + String(repeating: "긴 본문 내용입니다. ", count: 3000)
    let meta = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: meta, body: longBody))

    let summaries = try repository.loadSummaries()
    t.expectEqual(summaries.count, 1)
    t.expectEqual(summaries.first?.title, "회의록")
    t.expect((summaries.first?.preview.count ?? 0) <= 200, "미리보기가 200자를 넘으면 안 된다")
}

runner.test("요약은 수정일 최신순으로 정렬된다 (SRC-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let older = MemoMeta(id: .generate(), modified: Date(timeIntervalSince1970: 1_000_000))
    let newer = MemoMeta(id: .generate(), modified: Date(timeIntervalSince1970: 2_000_000))
    try repository.save(MemoDocument(meta: older, body: "예전 메모"))
    try repository.save(MemoDocument(meta: newer, body: "최근 메모"))

    let summaries = try repository.loadSummaries()
    t.expectEqual(summaries.first?.id, newer.id, "최신 메모가 앞에 와야 한다")
}

runner.test("덮어 써도 이전 내용이 남지 않는다 (원자적 저장, DAT-08)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let meta = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: meta, body: "아주 긴 원래 내용을 여기에 넣는다"))
    try repository.save(MemoDocument(meta: meta, body: "짧게"))

    let loaded = try repository.load(id: meta.id)
    t.expectEqual(loaded.body, "짧게", "이전 내용의 잔재가 남았다")
}

runner.test("휴지통 이동 시 첨부 폴더까지 함께 간다 (TRS-01, TRS-05)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let meta = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: meta, body: "사진 있는 메모"))

    let attachments = repository.attachmentsDirectory(for: meta.id)
    try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
    try Data("가짜 이미지".utf8).write(to: attachments.appendingPathComponent("img.png"))

    try repository.moveToTrash(id: meta.id)

    t.expectEqual(try repository.loadSummaries().count, 0, "휴지통 메모가 목록에 남아 있다")
    let trashedImage = root.appendingPathComponent("trash/\(meta.id.rawValue)/attachments/img.png")
    t.expect(FileManager.default.fileExists(atPath: trashedImage.path), "첨부가 함께 이동하지 않았다")
}

runner.test("깨진 파일 하나가 다른 메모 목록을 막지 않는다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let healthy = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: healthy, body: "정상 메모"))

    let brokenID = MemoID.generate()
    let brokenDirectory = root.appendingPathComponent("memos/\(brokenID.rawValue)", isDirectory: true)
    try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
    try Data("깨진 내용".utf8).write(to: brokenDirectory.appendingPathComponent("memo.md"))

    let summaries = try repository.loadSummaries()
    t.expectEqual(summaries.count, 1, "정상 메모는 읽혀야 한다")
    t.expectEqual(summaries.first?.id, healthy.id)
}

// MARK: - 첨부 이미지 (IMG-06, IMG-07)

/// 시험용 단색 이미지 데이터.
func makeImageData(width: Int, height: Int, type: UTType) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

runner.test("작은 PNG는 원본 그대로, 짧은 이름으로 저장된다 (IMG-07)") { t in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = makeImageData(width: 300, height: 200, type: .png)

    let saved = try AttachmentImages.save(imageData: data, into: directory)
    t.expect(saved.fileName.hasSuffix(".png"), "PNG는 PNG로 저장해야 한다: \(saved.fileName)")
    t.expect(saved.fileName.count <= 14, "이름이 짧아야 한다")
    t.expectEqual(saved.relativePath, "attachments/\(saved.fileName)")
    t.expectEqual(saved.pixelWidth, 300)
    t.expectEqual(try Data(contentsOf: directory.appendingPathComponent(saved.fileName)), data, "원본 바이트가 바뀌었다")
    let other = try AttachmentImages.save(imageData: data, into: directory)
    t.expect(other.fileName != saved.fileName, "이름이 겹쳤다")
}

runner.test("긴 변이 2400px을 넘으면 줄여서 저장한다 (IMG-06)") { t in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let png = try AttachmentImages.save(imageData: makeImageData(width: 3000, height: 1500, type: .png), into: directory)
    t.expect(png.fileName.hasSuffix(".png"))
    t.expectEqual(png.pixelWidth, 2400)
    t.expectEqual(png.pixelHeight, 1200, "비율이 유지되어야 한다")
    let size = AttachmentImages.pixelSize(of: directory.appendingPathComponent(png.fileName))
    t.expectEqual(size?.width, 2400)

    let jpeg = try AttachmentImages.save(imageData: makeImageData(width: 1000, height: 3200, type: .jpeg), into: directory)
    t.expect(jpeg.fileName.hasSuffix(".jpg"), "JPEG는 JPEG로 저장해야 한다")
    t.expectEqual(jpeg.pixelHeight, 2400)
    t.expectEqual(jpeg.pixelWidth, 750)
}

runner.test("PNG·JPEG가 아닌 입력은 JPEG로 바꿔 저장한다") { t in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let saved = try AttachmentImages.save(imageData: makeImageData(width: 100, height: 100, type: .tiff), into: directory)
    t.expect(saved.fileName.hasSuffix(".jpg"))
    t.expect(AttachmentImages.pixelSize(of: directory.appendingPathComponent(saved.fileName)) != nil)
}

runner.test("이미지가 아닌 데이터는 저장하지 않는다") { t in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("att-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var failed = false
    do { _ = try AttachmentImages.save(imageData: Data("글자".utf8), into: directory) } catch { failed = true }
    t.expect(failed, "이미지가 아닌데 저장됨")
}

runner.test("본문에서 쓰지 않는 오래된 첨부만 정리한다 (IMG-07)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    let meta = MemoMeta(id: .generate())
    try repository.save(MemoDocument(meta: meta, body: "![쓰는 것](attachments/used.png =100)\n글"))
    let attachments = repository.attachmentsDirectory(for: meta.id)
    try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
    let old = Date().addingTimeInterval(-3 * 86_400)
    for name in ["used.png", "unused-old.png", "unused-new.png"] {
        let url = attachments.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        if name != "unused-new.png" {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
    }

    let removed = repository.pruneUnusedAttachments(modifiedBefore: Date().addingTimeInterval(-86_400))
    t.expectEqual(removed, 1)
    let exists = { (name: String) in FileManager.default.fileExists(atPath: attachments.appendingPathComponent(name).path) }
    t.expect(exists("used.png"), "쓰는 파일을 지웠다")
    t.expect(!exists("unused-old.png"), "오래된 미사용 파일이 남았다")
    t.expect(exists("unused-new.png"), "방금 만든 파일은 되돌리기 대비로 남겨야 한다")
}

runner.test("이미지 줄은 제목 후보에서 빠진다") { t in
    let summary = MemoSummary(meta: MemoMeta(id: .generate()), preview: "![a](attachments/p.png)\n진짜 제목")
    t.expectEqual(summary.title, "진짜 제목")
}

// MARK: - 기기별 상태 (SYNC-07)

// MARK: - MemoStore (단일 진실 공급원, §4-3)

runner.test("본문을 저장하면 파일과 요약이 함께 갱신된다 (DAT-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let meta = store.createMemo()

        store.saveBody(id: meta.id, body: "# 장보기\n- [ ] 우유")

        // 파일에 실제로 기록됐는가
        let reloaded = try repository.load(id: meta.id)
        t.expectEqual(reloaded.body, "# 장보기\n- [ ] 우유")

        // 목록 요약도 즉시 반영됐는가 (리스트 창과 스티키 창이 서로를 보게 하는 경로)
        t.expectEqual(store.summaries.first(where: { $0.id == meta.id })?.title, "장보기")
        // 저장 정밀도가 1ms이므로 그만큼의 절삭은 허용한다.
        let drift = reloaded.meta.modified.timeIntervalSince1970 - meta.modified.timeIntervalSince1970
        t.expect(drift >= -0.001, "수정 시각이 뒤로 돌아갔다 (\(drift)초)")
    }
}

runner.test("열림 상태는 파일에 남아 재시작 복원의 근거가 된다 (WIN-06, SYNC-08)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let opened = store.createMemo()
        let closed = store.createMemo()

        store.setOpen(id: closed.id, isOpen: false)

        t.expectEqual(store.openMemos.count, 1, "열린 메모만 남아야 한다")
        t.expectEqual(store.openMemos.first?.id, opened.id)

        // 새 인스턴스가 파일에서 다시 읽어도 같아야 한다 (재시작 시나리오)
        let restarted = MemoStore(repository: repository, keychain: testKeychain)
        t.expectEqual(restarted.openMemos.count, 1)
        t.expectEqual(restarted.openMemos.first?.id, opened.id)
    }
}

runner.test("이미 열린 메모를 다시 열림으로 기록해도 파일과 수정 시각이 그대로다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let meta = store.createMemo()
        let file = root.appendingPathComponent("memos/\(meta.id.rawValue)/memo.md")
        let before = try Data(contentsOf: file)
        let beforeMtime = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        // 앱을 켤 때 열린 창마다 부르는 경로. 바뀐 것이 없으면 쓰지 않아야 동기화가 헛돌지 않는다.
        Thread.sleep(forTimeInterval: 0.01)
        store.setOpen(id: meta.id, isOpen: true)

        t.expectEqual(try Data(contentsOf: file), before, "바뀐 것이 없는데 파일을 다시 썼다")
        t.expectEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, beforeMtime)

        // 본문도 같다. 같은 내용을 다시 저장해도 쓰지 않는다.
        _ = store.saveBody(id: meta.id, body: "같은 내용")
        let saved = try Data(contentsOf: file)
        let savedMtime = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        Thread.sleep(forTimeInterval: 0.01)
        t.expect(store.saveBody(id: meta.id, body: "같은 내용"), "같은 내용 저장은 성공으로 본다")
        t.expectEqual(try Data(contentsOf: file), saved, "같은 본문인데 파일을 다시 썼다")
        t.expectEqual(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, savedMtime)
    }
}

runner.test("휴지통으로 옮기면 목록에서 사라진다 (TRS-01)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let meta = store.createMemo()
        t.expectEqual(store.summaries.count, 1)

        store.moveToTrash(id: meta.id)
        t.expectEqual(store.summaries.count, 0)
    }
}

// MARK: - 그룹 (LST-02, LST-03)

runner.test("그룹을 만들고 이름을 바꾸면 메모의 이름표도 따라간다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        store.createGroup(named: "업무")
        let meta = store.createMemo(group: "업무")

        t.expect(store.groups.contains("업무"))
        t.expectEqual(store.memoCount(inGroup: "업무"), 1)

        store.renameGroup(from: "업무", to: "회사")
        t.expect(store.groups.contains("회사"), "그룹 이름이 바뀌지 않았다")
        t.expectEqual(store.summaries.first(where: { $0.id == meta.id })?.meta.group, "회사", "메모의 그룹이 따라오지 않았다")
    }
}

runner.test("그룹을 지워도 메모는 남는다 (그룹 없음으로)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        store.createGroup(named: "임시")
        let meta = store.createMemo(group: "임시")

        store.deleteGroup("임시")
        t.expect(!store.groups.contains("임시"), "그룹이 지워지지 않았다")
        t.expectEqual(store.summaries.count, 1, "그룹을 지웠다고 메모가 사라지면 안 된다")
        t.expectNil(store.summaries.first(where: { $0.id == meta.id })?.meta.group)
    }
}

runner.test("그룹 목록은 다시 열어도 유지된다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        store.createGroup(named: "업무")
        store.createGroup(named: "개인")

        let reopened = MemoStore(repository: repository, keychain: testKeychain)
        t.expect(reopened.groups.contains("업무") && reopened.groups.contains("개인"), "그룹이 저장되지 않았다")
    }
}

// MARK: - 휴지통 (TRS-01~04)

runner.test("휴지통으로 옮긴 메모를 되돌릴 수 있다 (TRS-02)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let meta = store.createMemo()
        store.saveBody(id: meta.id, body: "지우면 안 되는 내용")

        store.moveToTrash(id: meta.id)
        t.expectEqual(store.summaries.count, 0, "목록에서 사라져야 한다")
        t.expectEqual(store.trashed.count, 1, "휴지통에 있어야 한다")

        store.restoreFromTrash(id: meta.id)
        t.expectEqual(store.summaries.count, 1, "복원되지 않았다")
        t.expectEqual(store.trashed.count, 0, "휴지통에 남아 있다")
        t.expectEqual(store.loadDocument(id: meta.id)?.body, "지우면 안 되는 내용", "내용이 보존되지 않았다")
    }
}

runner.test("영구 삭제하면 파일까지 사라진다 (TRS-04)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let meta = store.createMemo()
        store.moveToTrash(id: meta.id)
        store.permanentlyDelete(id: meta.id)

        t.expectEqual(store.trashed.count, 0)
        let path = root.appendingPathComponent("trash/\(meta.id.rawValue)").path
        t.expect(!FileManager.default.fileExists(atPath: path), "파일이 남아 있다")
    }
}

runner.test("보관 기간이 지나지 않은 항목은 자동으로 지워지지 않는다 (TRS-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let meta = store.createMemo()
        store.moveToTrash(id: meta.id)

        store.emptyTrash(olderThan: 30)
        t.expectEqual(store.trashed.count, 1, "방금 버린 메모가 사라졌다")

        store.emptyTrash()
        t.expectEqual(store.trashed.count, 0, "즉시 비우기가 동작하지 않았다")
    }
}

runner.test("오래 고치지 않은 메모도 버린 날부터 보관 기간을 센다 (TRS-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let meta = store.createMemo()
        // 40일 전에 마지막으로 고친 메모처럼 만든다.
        let old = Date().addingTimeInterval(-40 * 24 * 60 * 60)
        let folder = root.appendingPathComponent("memos/\(meta.id.rawValue)")
        if !FileManager.default.fileExists(atPath: folder.path) {
            // 저장 위치 이름이 바뀌어도 시험이 조용히 빗나가지 않게 실제 폴더를 찾는다.
            let found = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?
                .first { $0.hasSuffix(meta.id.rawValue) }
            t.expectNotNil(found, "메모 폴더를 찾지 못했다")
            if let found {
                try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(found).path)
            }
        } else {
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }

        let before = Date()
        store.moveToTrash(id: meta.id)
        let after = Date()
        let deleted = store.trashed.first!.deletedAt!
        t.expect(deleted >= before && deleted <= after, "폴더 mtime이 삭제 시각이어야 한다")
        store.emptyTrash(olderThan: 30)
        t.expectEqual(store.trashed.count, 1, "방금 버린 오래된 메모가 바로 지워졌다")
    }
}

runner.test("버린 지 보관 기간이 지난 항목은 자동으로 지워진다 (TRS-03)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let kept = store.createMemo()
        let expired = store.createMemo()
        store.moveToTrash(ids: [kept.id, expired.id])

        let old = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        let trashed = root.appendingPathComponent("trash/\(expired.id.rawValue)").path
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: trashed)

        store.emptyTrash(olderThan: 30)
        t.expectEqual(store.trashed.map(\.id), [kept.id], "기한이 지난 것만 지워져야 한다")
    }
}

// MARK: - 검색과 정렬 (SRC-01~03)

runner.test("제목과 본문 모두에서 찾는다 (SRC-01)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let titleHit = store.createMemo()
        store.saveBody(id: titleHit.id, body: "# 장보기 목록\n우유")

        let bodyHit = store.createMemo()
        // 제목에는 없고 본문 뒤쪽에만 있는 낱말 — 미리보기 범위를 넘어간다
        store.saveBody(id: bodyHit.id, body: "# 회의록\n" + String(repeating: "내용 ", count: 200) + "장보기")

        let miss = store.createMemo()
        store.saveBody(id: miss.id, body: "# 다른 메모\n관계없는 내용")

        let results = store.search(query: "장보기")
        t.expectEqual(results.count, 2, "제목과 본문 양쪽에서 찾아야 한다")
        t.expect(results.contains { $0.id == titleHit.id }, "제목으로 찾지 못했다")
        t.expect(results.contains { $0.id == bodyHit.id }, "본문으로 찾지 못했다")
        t.expect(!results.contains { $0.id == miss.id }, "관계없는 메모가 걸렸다")
    }
}

runner.test("그룹으로 검색 범위를 좁힌다 (SRC-02)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let work = store.createMemo(group: "업무")
        store.saveBody(id: work.id, body: "회의 준비")
        let personal = store.createMemo(group: "개인")
        store.saveBody(id: personal.id, body: "회의 참석")

        t.expectEqual(store.search(query: "회의").count, 2)
        t.expectEqual(store.search(query: "회의", group: "업무").count, 1)
        t.expectEqual(store.search(query: "회의", group: "업무").first?.id, work.id)
    }
}

runner.test("빈 검색어는 전체를 돌려준다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        store.createMemo()
        store.createMemo()
        t.expectEqual(store.search(query: "").count, 2)
        t.expectEqual(store.search(query: "   ").count, 2)
    }
}

runner.test("정렬 기준과 방향이 모두 동작한다 (SRC-03)") { t in
    let older = MemoSummary(
        meta: MemoMeta(id: .generate(), created: Date(timeIntervalSince1970: 100), modified: Date(timeIntervalSince1970: 100)),
        preview: "나중 제목"
    )
    let newer = MemoSummary(
        meta: MemoMeta(id: .generate(), created: Date(timeIntervalSince1970: 200), modified: Date(timeIntervalSince1970: 200)),
        preview: "가나다 제목"
    )
    let list = [older, newer]

    t.expectEqual(MemoSearch.sorted(list, by: .newestFirst).first?.id, newer.id, "최신순 정렬 실패")
    t.expectEqual(MemoSearch.sorted(list, by: MemoSortOrder(key: .modified, ascending: true)).first?.id, older.id)
    t.expectEqual(MemoSearch.sorted(list, by: MemoSortOrder(key: .title, ascending: true)).first?.id, newer.id, "제목 오름차순 실패")
    t.expectEqual(MemoSearch.sorted(list, by: MemoSortOrder(key: .created, ascending: false)).first?.id, newer.id)
}

runner.test("메모 1,000개에서도 검색이 0.3초 안에 끝난다 (NFR-05)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    // 실제 사용에 가까운 분량으로 만든다 — 메모당 30줄.
    let body = "# 회의록\n" + (0..<30).map { "- [ ] 항목 \($0) 내용입니다" }.joined(separator: "\n")
    var needleID: MemoID?
    for index in 0..<1000 {
        let meta = MemoMeta(id: .generate())
        // 제목·미리보기에는 없고 본문 끝에만 있는 낱말 — 가장 비싼 경로를 재게 한다.
        let text = index == 777 ? body + "\n숨겨진낱말특별표시" : body
        try repository.save(MemoDocument(meta: meta, body: text))
        if index == 777 { needleID = meta.id }
    }

    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        t.expectEqual(store.summaries.count, 1000, "1,000개가 모두 읽히지 않았다")

        let started = Date()
        let results = store.search(query: "숨겨진낱말특별표시")
        let elapsed = Date().timeIntervalSince(started)

        t.expectEqual(results.count, 1, "본문에만 있는 낱말을 찾지 못했다")
        t.expectEqual(results.first?.id, needleID)
        t.expect(elapsed < 0.3, String(format: "검색에 %.3f초 걸렸다 (목표 0.3초)", elapsed))

        // 제목으로 찾는 경우는 파일을 읽지 않으므로 훨씬 빨라야 한다.
        let quickStart = Date()
        _ = store.search(query: "회의록")
        let quickElapsed = Date().timeIntervalSince(quickStart)
        t.expect(quickElapsed < 0.1, String(format: "제목 검색에 %.3f초 걸렸다", quickElapsed))
    }
}

// MARK: - 기기별 상태 (SYNC-07)

runner.test("기기별 창 상태는 따로 저장되고 다시 읽힌다") { t in
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("device-state-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let id = MemoID.generate()
    let store = DeviceStateStore(fileURL: url)
    store.setState(DeviceMemoState(frame: [100, 200, 300, 400], displayID: "MAIN"), for: id)
    store.flush()

    let reopened = DeviceStateStore(fileURL: url)
    t.expectEqual(reopened.state(for: id)?.frame, [100, 200, 300, 400])
    t.expectEqual(reopened.state(for: id)?.displayID, "MAIN")
}

// MARK: - 연결과 보드 배치 (설계서 §4)

runner.test("연결 프론트매터 왕복과 v2 호환, 잘못된 항목 건너뛰기 (DOC-02)") { t in
    let id = MemoID.generate()
    let target = MemoID.generate()
    let links = [MemoLink(to: target, kind: .flow), MemoLink(to: target, kind: .related)]
    let date = Date(timeIntervalSince1970: 100)
    let document = MemoDocument(meta: MemoMeta(id: id, created: date, modified: date, links: links), body: "본문")
    let encoded = FrontmatterCodec.encode(document)
    t.expectEqual(try FrontmatterCodec.decode(fileContents: encoded), document)
    let old = "---\nschemaVersion: 2\nid: \(id.rawValue)\n---\n본문"
    let decoded = try FrontmatterCodec.decode(fileContents: old)
    t.expectEqual(decoded.meta.links, [])
    t.expectEqual(decoded.meta.schemaVersion, 3)
    t.expect(!FrontmatterCodec.encode(decoded).contains("links:"))
    let malformed = old.replacingOccurrences(of: "\n---\n", with:
        "\nlinks: flow: \(target.rawValue), garbage, related:no, other:\(target.rawValue), flow:\(target.rawValue), related:\(target.rawValue), flow:\(target.rawValue):extra\n---\n")
    t.expectEqual(try FrontmatterCodec.decode(fileContents: malformed).meta.links, links)
}

runner.test("연결 교체와 해제는 양방향이고 자기 연결은 무시한다 (설계서 §4)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let a = store.createMemo().id
        let b = store.createMemo().id
        store.link(from: a, to: a, kind: .flow)
        t.expectEqual(store.loadDocument(id: a)?.meta.links, [])
        store.link(from: a, to: b, kind: .flow)
        store.link(from: b, to: a, kind: .related)
        t.expectEqual(store.loadDocument(id: a)?.meta.links, [])
        t.expectEqual(store.loadDocument(id: b)?.meta.links, [MemoLink(to: a, kind: .related)])
        t.expectEqual(store.edges, [MemoEdge(from: b, to: a, kind: .related)])
        t.expectEqual(store.linkCount(of: a), 1)
        store.unlink(a, b)
        t.expectEqual(store.edges, [])
        t.expectEqual(store.loadDocument(id: b)?.meta.links, [])
    }
}

runner.test("연결은 휴지통에서 숨고 복원되며 영구 삭제하면 정리된다 (TRS-02, TRS-04)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let a = store.createMemo().id
        let b = store.createMemo().id
        let c = store.createMemo().id
        store.link(from: a, to: b, kind: .flow)
        store.link(from: c, to: b, kind: .related)
        store.moveToTrash(id: b)
        t.expectEqual(store.edges, [])
        t.expectEqual(store.loadDocument(id: a)?.meta.links.count, 1)
        store.restoreFromTrash(id: b)
        t.expectEqual(store.edges.count, 2)
        store.moveToTrash(ids: [b, c])
        let cFolder = root.appendingPathComponent("trash/\(c.rawValue)")
        let deletedAt = Date(timeIntervalSince1970: 100)
        try FileManager.default.setAttributes([.modificationDate: deletedAt], ofItemAtPath: cFolder.path)
        store.permanentlyDelete(id: b)
        t.expectEqual(store.loadDocument(id: a)?.meta.links, [])
        t.expectEqual(try cFolder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, deletedAt)
        store.restoreFromTrash(id: c)
        t.expectEqual(store.loadDocument(id: c)?.meta.links, [])
        store.updateMeta(id: a) { $0.links = [MemoLink(to: .generate(), kind: .flow)] }
        t.expectEqual(store.edges, [])
    }
}

runner.test("흐름은 분기 깊이 우선, 순환과 여러 시작점을 생성순으로 정렬한다 (설계서 §4)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let ids = (0..<10).map { _ in MemoID.generate() }
    let targets = [[2, 1], [3], [], [], [6], [4], [5], [3], [], []]
    for index in ids.indices {
        let meta = MemoMeta(id: ids[index], created: Date(timeIntervalSince1970: Double(index)),
            modified: Date(timeIntervalSince1970: Double(index)),
            links: targets[index].map { MemoLink(to: ids[$0], kind: .flow) })
        try repository.save(MemoDocument(meta: meta, body: ""))
    }
    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        store.link(from: ids[8], to: ids[9], kind: .related)
        let flows = store.flows
        t.expectEqual(flows.count, 2)
        t.expectEqual(flows[0].memoIDs, [ids[4], ids[5], ids[6]])
        t.expectEqual(flows[1].memoIDs, [ids[0], ids[1], ids[3], ids[2], ids[7]])
        t.expectEqual(flows[1].id, ids[0])
        t.expectEqual(store.flow(containing: ids[3]), flows[1])
        t.expectNil(store.flow(containing: ids[8]))
        store.updateMeta(id: ids[3]) { $0.links = [MemoLink(to: ids[0], kind: .flow)] }
        t.expectEqual(store.flow(containing: ids[0])?.memoIDs, [ids[7], ids[3], ids[0], ids[1], ids[2]])
    }
}

runner.test("외부 파일의 같은 쌍 연결은 종류와 방향에 관계없이 하나로 그린다 (설계서 §4)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = MemoID.generate()
    let b = MemoID.generate()
    try repository.save(MemoDocument(meta: MemoMeta(id: a, links: [MemoLink(to: b, kind: .flow), MemoLink(to: b, kind: .related)]), body: ""))
    try repository.save(MemoDocument(meta: MemoMeta(id: b, links: [MemoLink(to: a, kind: .flow)]), body: ""))
    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        t.expectEqual(store.edges.count, 1)
    }
}

runner.test("보드 배치는 저장과 재시작을 거치며 깨진 파일은 빈 값으로 읽힌다 (설계서 §4)") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    t.expectEqual(try repository.loadBoardLayout(), .empty)
    try MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let a = MemoID.generate()
        let b = MemoID.generate()
        store.setBoardPlacement(.init(x: -10, y: 20), for: a)
        store.setBoardPlacements([a: .init(x: 30, y: 40), b: .init(x: 50, y: 60)])
        store.setBentoSpan(.large, for: a)
        let restarted = MemoStore(repository: repository, keychain: testKeychain)
        t.expectEqual(restarted.boardLayout, store.boardLayout)
        t.expectEqual(restarted.boardLayout.placement(for: a), .init(x: 30, y: 40))
        t.expectEqual(restarted.boardLayout.placement(for: b), .init(x: 50, y: 60))
        t.expectEqual(restarted.boardLayout.bentoSpan(for: a), .large)
        store.setBentoSpan(nil, for: a)
        restarted.reloadBoardLayout()
        t.expectNil(restarted.boardLayout.bentoSpan(for: a))
        try Data("깨진 JSON".utf8).write(to: root.appendingPathComponent("board.json"))
        restarted.reloadBoardLayout()
        t.expectEqual(restarted.boardLayout, .empty)
    }
    t.expectEqual(BoardLayout.BentoSpan.allCases.map(\.columns), [1, 2, 1, 2])
    t.expectEqual(BoardLayout.BentoSpan.allCases.map(\.rows), [1, 1, 2, 2])
}

// MARK: - 찾는 범위 (제목 · 본문)

runner.test("프론트매터 낱말로는 본문 찾기에 걸리지 않는다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let memo = store.createMemo()
        store.saveBody(id: memo.id, body: "우유 사기")
        t.expectEqual(store.filter(store.summaries, query: "pinned", target: .body).count, 0, "pinned가 걸렸다")
        t.expectEqual(store.filter(store.summaries, query: "color", target: .body).count, 0, "color가 걸렸다")
        t.expectEqual(store.filter(store.summaries, query: "pinned", target: .titleAndBody).count, 0)
        t.expectEqual(store.filter(store.summaries, query: "우유", target: .body).count, 1)
    }
}

runner.test("본문 속 마크다운 제목은 본문으로 찾고, 제목 찾기에는 메모 제목만 쓴다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let memo = store.createMemo()
        store.saveBody(id: memo.id, body: "첫 줄 제목\n\n# 소제목\n내용")
        t.expectEqual(store.filter(store.summaries, query: "소제목", target: .body).count, 1)
        t.expectEqual(store.filter(store.summaries, query: "소제목", target: .title).count, 0)
        t.expectEqual(store.filter(store.summaries, query: "첫 줄", target: .title).count, 1)
    }
}

runner.test("직접 붙인 제목은 제목 찾기로만 걸린다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let memo = store.createMemo()
        store.saveBody(id: memo.id, body: "본문 내용")
        store.updateMeta(id: memo.id) { $0.title = "직접제목" }
        t.expectEqual(store.filter(store.summaries, query: "직접제목", target: .title).count, 1)
        t.expectEqual(store.filter(store.summaries, query: "직접제목", target: .body).count, 0)
        t.expectEqual(store.filter(store.summaries, query: "직접제목", target: .titleAndBody).count, 1)
        t.expectEqual(store.filter(store.summaries, query: "", target: .body).count, 1, "빈 검색어는 그대로")
    }
}

runner.test("휴지통 메모도 본문으로 찾는다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }

    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let memo = store.createMemo()
        store.saveBody(id: memo.id, body: "제목줄\n휴지통속낱말")
        store.moveToTrash(ids: [memo.id])
        store.reloadTrash()
        t.expectEqual(store.filter(store.trashed, query: "휴지통속낱말", target: .body).count, 1)
        t.expectEqual(store.filter(store.trashed, query: "없는낱말", target: .body).count, 0)
    }
}

// MARK: - 본문에 이미지 줄 끼우기 (목록 창 AirDrop 받기)

runner.test("본문 이미지 넣기: 맨 아래는 끝에 잇고 끝 줄바꿈을 지킨다") { t in
    let a = "![a](attachments/a.png)"
    let b = "![b](attachments/b.png)"
    t.expectEqual(BodyImageInsertion.inserting([a], into: "글", at: .bottom), "글\n\(a)")
    t.expectEqual(BodyImageInsertion.inserting([a, b], into: "글\n", at: .bottom), "글\n\(a)\n\(b)\n")
    t.expectEqual(BodyImageInsertion.inserting([a], into: "", at: .bottom), a)
}

runner.test("본문 이미지 넣기: 맨 위는 제목 줄 바로 아래, 제목이 아니면 맨 앞") { t in
    let a = "![a](attachments/a.png)"
    t.expectEqual(BodyImageInsertion.inserting([a], into: "# 제목\n본문", at: .top), "# 제목\n\(a)\n본문")
    t.expectEqual(BodyImageInsertion.inserting([a], into: "본문\n둘째", at: .top), "\(a)\n본문\n둘째")
    // `#`만 있는 글은 제목이 아니다.
    t.expectEqual(BodyImageInsertion.inserting([a], into: "#해시태그", at: .top), "\(a)\n#해시태그")
    t.expectEqual(BodyImageInsertion.inserting([a], into: "# 제목", at: .top), "# 제목\n\(a)")
    t.expectEqual(BodyImageInsertion.inserting([a], into: "", at: .top), a)
}

runner.test("본문 이미지 넣기: 여러 장을 맨 위에 받아도 받은 순서가 유지된다") { t in
    let lines = (1...3).map { "![\($0)](attachments/\($0).png)" }
    var body = "# 제목\n본문"
    for (count, line) in lines.enumerated() {
        body = BodyImageInsertion.inserting([line], into: body, at: .top, skippingInserted: count)
    }
    t.expectEqual(body, "# 제목\n\(lines.joined(separator: "\n"))\n본문")
}

runner.test("다른 이름으로 저장: 원본은 바이트 그대로, PNG·JPEG는 변환되고 덮어쓸 수 있다") { t in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let saved = try AttachmentImages.save(imageData: makeImageData(width: 120, height: 60, type: .png), into: directory)
    let source = directory.appendingPathComponent(saved.fileName)

    let copy = directory.appendingPathComponent("복사본.png")
    try AttachmentImages.export(from: source, to: copy, format: .original)
    t.expectEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
    // 같은 자리에 다시 저장하면 덮어쓴다.
    try AttachmentImages.export(from: source, to: copy, format: .original)

    let jpeg = directory.appendingPathComponent("변환.jpg")
    try AttachmentImages.export(from: source, to: jpeg, format: .jpeg)
    let bytes = try Data(contentsOf: jpeg)
    t.expectEqual(Array(bytes.prefix(2)), [0xFF, 0xD8], "JPEG 머리가 아님")
    t.expectEqual(AttachmentImages.pixelSize(of: jpeg)?.width, 120)

    let png = directory.appendingPathComponent("변환2.png")
    try AttachmentImages.export(from: jpeg, to: png, format: .png)
    t.expectEqual(Array(try Data(contentsOf: png).prefix(4)), [0x89, 0x50, 0x4E, 0x47])

    t.expectEqual(AttachmentImages.ExportFormat.jpeg.fileExtension, "jpg")
    t.expectNil(AttachmentImages.ExportFormat.original.fileExtension)
    var failed = false
    do { try AttachmentImages.export(from: directory.appendingPathComponent("없음.png"), to: png, format: .png) } catch { failed = true }
    t.expect(failed, "없는 파일은 실패해야 한다")
}


// MARK: - 메모 복제

runner.test("복제는 폴더 전체와 본문을 보존하고 새 메타데이터와 보드 자리를 기록한다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try MainActor.assumeIsolated {
        let old = Date(timeIntervalSince1970: 100)
        let source = MemoMeta(id: .generate(), title: "회의", group: "업무", colorHex: "#ABCDEF",
            backgroundAlpha: 0.6, textAlpha: 0.7, isOpen: true, isPinned: false,
            created: old, modified: old, conflictOf: .generate(),
            links: [MemoLink(to: .generate(), kind: .flow)])
        let body = "첫 줄\n![사진](attachments/사진.png)\n본문"
        let original = MemoDocument(meta: source, body: body, unknownFrontmatterLines: ["future: value"])
        try repository.save(original)
        let attachments = repository.attachmentsDirectory(for: source.id)
        try FileManager.default.createDirectory(at: attachments.appendingPathComponent("하위"), withIntermediateDirectories: true)
        let bytes = Data([0, 1, 2, 255])
        try bytes.write(to: attachments.appendingPathComponent("사진.png"))
        try bytes.write(to: attachments.appendingPathComponent("하위/파일.bin"))
        let extra = attachments.deletingLastPathComponent().appendingPathComponent("추가.json")
        try bytes.write(to: extra)
        let store = MemoStore(repository: repository, keychain: testKeychain)
        store.setBoardPlacement(.init(x: -40, y: 80), for: source.id)
        let started = Date()
        let copies = store.duplicate([source.id])
        t.expectEqual(copies.count, 1)
        guard let copyID = copies.first else { return }
        let copied = try repository.load(id: copyID)
        t.expect(copyID != source.id)
        t.expectEqual(copied.body, body)
        t.expectEqual(copied.meta.title, "회의 사본")
        t.expectEqual(copied.meta.group, source.group)
        t.expectEqual(copied.meta.colorHex, source.colorHex)
        t.expectEqual(copied.meta.backgroundAlpha, source.backgroundAlpha)
        t.expectEqual(copied.meta.textAlpha, source.textAlpha)
        t.expectEqual(copied.meta.isPinned, false)
        t.expectEqual(copied.meta.isOpen, false)
        t.expect(copied.meta.created.timeIntervalSince(started) > -0.01)
        t.expectEqual(copied.meta.created, copied.meta.modified)
        t.expectEqual(copied.meta.links, [])
        t.expectNil(copied.meta.conflictOf)
        t.expectEqual(copied.unknownFrontmatterLines, ["future: value"])
        let destination = repository.attachmentsDirectory(for: copyID)
        t.expectEqual(try Data(contentsOf: destination.appendingPathComponent("사진.png")), bytes)
        t.expectEqual(try Data(contentsOf: destination.appendingPathComponent("하위/파일.bin")), bytes)
        t.expectEqual(try Data(contentsOf: destination.deletingLastPathComponent().appendingPathComponent("추가.json")), bytes)
        t.expectEqual(try repository.load(id: source.id), original)
        t.expectEqual(store.summaries.map(\.id), [source.id, copyID])
        let restarted = MemoStore(repository: repository, keychain: testKeychain)
        t.expectEqual(restarted.boardLayout.placement(for: copyID), .init(x: -16, y: 104))
        t.expectEqual(restarted.summaries.first?.id, copyID)
        try Data([9]).write(to: destination.appendingPathComponent("사진.png"))
        t.expectEqual(try Data(contentsOf: attachments.appendingPathComponent("사진.png")), bytes)
    }
}

runner.test("복제 제목은 사본과 빈 번호를 쓰고 직접 제목이 없으면 본문 제목을 유지한다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let source = store.createMemo().id
        store.updateMeta(id: source) { $0.title = "계획" }
        let occupied = store.createMemo().id
        store.updateMeta(id: occupied) { $0.title = "계획 사본 3" }
        let copies = (0..<3).compactMap { _ in store.duplicate([source]).first }
        t.expectEqual(copies.compactMap { store.loadDocument(id: $0)?.meta.title },
            ["계획 사본", "계획 사본 2", "계획 사본 4"])
        let untitled = store.createMemo().id
        store.saveBody(id: untitled, body: "본문 제목\n내용")
        let ids = store.duplicate([untitled, source, untitled, .generate()])
        t.expectEqual(ids.count, 2)
        guard let id = ids.first else { return }
        t.expectNil(store.loadDocument(id: id)?.meta.title)
        t.expectEqual(store.summaries.first { $0.id == id }?.title, "본문 제목")
        let originalPosition = store.boardLayout.placement(for: untitled)
        t.expectEqual(store.boardLayout.placement(for: id), originalPosition.map { .init(x: $0.x + 24, y: $0.y + 24) })
    }
}

runner.test("잠긴 프론트매터를 읽고 보존하며 최신 파일이 잠겼으면 복제를 건너뛴다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try MainActor.assumeIsolated {
        let source = MemoMeta(id: .generate())
        try repository.save(MemoDocument(meta: source, body: "잠길 본문"))
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let unlocked = store.createMemo().id
        let lockedText = FrontmatterCodec.encode(MemoDocument(meta: source, body: "잠길 본문"))
            .replacingOccurrences(of: "\nopen:", with: "\nlocked: true\nopen:")
        var decoded = try FrontmatterCodec.decode(fileContents: lockedText)
        decoded.meta.lockSalt = Data(repeating: 1, count: 16).base64EncodedString()
        decoded.meta.lockVersion = 1
        decoded.meta.lockIterations = LockCrypto.minimumIterations
        decoded.meta.lockFailures = 0
        decoded.body = try LockCrypto.seal(Data("잠길 본문".utf8), key: Data(repeating: 2, count: 32), context: source.id.rawValue + "/body").base64EncodedString()
        t.expect(decoded.meta.isLocked)
        t.expect(FrontmatterCodec.encode(decoded).contains("locked: true"))
        t.expect(!source.isLocked)
        try repository.save(decoded)
        let layout = store.boardLayout
        t.expectEqual(store.duplicate([source.id]), [])
        t.expectEqual(store.boardLayout, layout)
        let copies = store.duplicate([source.id, unlocked])
        t.expectEqual(copies.count, 1)
        t.expectEqual(try repository.loadSummaries().count, 3)
        // 날짜는 파일에 밀리초까지만 적혀 통째로 비교하면 1밀리초 아래 차이로 흔들린다. 보존해야 할 것만 비교한다.
        let reloaded = try repository.load(id: source.id)
        t.expect(reloaded.meta.isLocked)
        t.expectEqual(reloaded.body, decoded.body)
        t.expectEqual(reloaded.meta.id, decoded.meta.id)
        store.moveToTrash(id: unlocked)
        t.expectEqual(store.duplicate([unlocked]), [])
    }
}

runner.test("보드 직접 순서는 JSON 왕복과 이전 형식, 중복과 삭제 정리를 지원한다") { t in
    let a = MemoID.generate()
    let b = MemoID.generate()
    let layout = BoardLayout(placements: [a.rawValue: .init(x: 12, y: 24)], bentoSpans: [b.rawValue: .wide], manualOrder: [b, a])
    t.expectEqual(try JSONDecoder().decode(BoardLayout.self, from: JSONEncoder().encode(layout)), layout)
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    try repository.saveBoardLayout(layout)
    t.expectEqual(try repository.loadBoardLayout(), layout)
    let old = Data("{\"placements\":{},\"bentoSpans\":{}}".utf8)
    try old.write(to: root.appendingPathComponent("board.json"))
    t.expectEqual(try repository.loadBoardLayout().manualOrder, [])
    let c = MemoID.generate()
    let dirty = BoardLayout(manualOrder: [b, b, MemoID.generate(), a])
    t.expectEqual(dirty.normalizedOrder(among: [a, b, c]), [c, b, a])
}

runner.test("선 열 종류와 모르는 연결 토큰은 다시 저장해도 남는다") { t in
    let id = MemoID.generate(), target = MemoID.generate()
    let links = MemoLinkKind.allCases.map { MemoLink(to: target, kind: $0) }
    for link in links where MemoLinkKind.basic.contains(link.kind) {
        t.expectEqual(MemoLink(to: target, lineStyle: link.lineStyle, arrows: link.arrows), link)
    }
    var changed = MemoLink(to: target, kind: .flow)
    changed.lineStyle = .dashed
    changed.arrows = .both
    t.expectEqual(changed.kind, .dashboth)
    let document = MemoDocument(meta: MemoMeta(id: id, links: links), body: "본문", unknownLinkTokens: ["future:\(target.rawValue)", "새토큰"])
    let encoded = FrontmatterCodec.encode(document)
    t.expect(encoded.contains("flow:\(target.rawValue)"))
    t.expect(encoded.contains("related:\(target.rawValue)"))
    let decoded = try FrontmatterCodec.decode(fileContents: encoded)
    t.expectEqual(decoded.meta.links, links)
    t.expectEqual(decoded.unknownLinkTokens, document.unknownLinkTokens)
    // 날짜는 밀리초까지만 기록되어 통째 비교는 1밀리초 아래 차이로 흔들린다. 다시 저장해도 남아야 하는 것만 비교한다.
    let again = try FrontmatterCodec.decode(fileContents: FrontmatterCodec.encode(decoded))
    t.expectEqual(again.meta.links, decoded.meta.links)
    t.expectEqual(again.unknownLinkTokens, decoded.unknownLinkTokens)
    t.expectEqual(again.body, decoded.body)
}

runner.test("실선 한쪽 화살표만 흐름을 만든다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    MainActor.assumeIsolated {
        let store = MemoStore(repository: repository, keychain: testKeychain)
        let a = store.createMemo().id, b = store.createMemo().id
        for kind in MemoLinkKind.allCases {
            store.link(from: a, to: b, kind: kind)
            t.expectEqual(store.flows.count, kind == .flow ? 1 : 0)
            t.expectEqual(store.edges.count, 1)
        }
        store.saveBody(id: a, body: "새 본문")
        t.expectEqual(store.loadDocument(id: a)?.meta.links.first?.kind, .same)
    }
}

runner.test("선 이름과 뜻은 확정한 열 종류에 대응한다") { t in
    t.expectEqual(MemoLinkKind.allCases.map(\.displayName), ["연결", "흐름", "상호", "관련", "참고", "서로 참고", "포함", "막힘", "반대", "같음"])
    t.expectEqual(MemoLinkKind.allCases.map(\.meaning), ["같은 주제로 이어진 메모", "다음 단계, 순서가 있는 이어짐", "서로 주고받는 대등한 관계", "느슨하게 관련된 메모", "이 메모가 저 메모를 참고하거나 기댐(화살표 쪽이 참고 대상)", "서로를 참고하는 약한 양방향 관계", "큰 주제(점 쪽)가 작은 메모를 품음", "이 일이 끝나야 저 일(⊣ 쪽)을 할 수 있음", "서로 부딪히는 생각 · 대안", "같은 내용 · 중복"])
}
runner.test("연결 칩은 종류 순서로 두 종류와 나머지 종류 수를 표시한다") { t in
    t.expectEqual(MemoLinkKind.chipText(counts: [:]), "")
    t.expectEqual(MemoLinkKind.chipText(counts: [.flow: 2]), "")
    t.expectEqual(MemoLinkKind.chipText(counts: [.dashto: 1, .both: 1]), "상호 1 · 참고 1")
    t.expectEqual(MemoLinkKind.chipText(counts: [.contain: 2, .block: 1, .same: 3, .oppose: 1]), "포함 2 · 막힘 1 · 외 2")
    t.expectEqual(MemoLinkKind.chipText(counts: [.line: 0, .same: 1]), "같음 1")
}
runner.test("선 라벨은 구분 문자를 인코딩하고 왕복하며 빈 이름은 지운다") { t in
    let id = MemoID.generate(), target = MemoID.generate()
    let label = "공백 한글:쉼표,물결~ ·"
    for kind in MemoLinkKind.allCases {
        var doc = MemoDocument(meta: MemoMeta(id: id, links: [MemoLink(to: target, kind: kind, label: label, unknownSuffix: "~future%21")]), body: "본문")
        let encoded = FrontmatterCodec.encode(doc)
        t.expect(encoded.contains("%20")); t.expect(encoded.contains("%3A")); t.expect(encoded.contains("%2C")); t.expect(encoded.contains("%7E"))
        let decoded = try FrontmatterCodec.decode(fileContents: encoded)
        t.expectEqual(decoded.meta.links, doc.meta.links)
        doc.meta.links[0].label = ""
        let cleared = FrontmatterCodec.encode(doc)
        t.expectEqual(try FrontmatterCodec.decode(fileContents: cleared).meta.links, doc.meta.links)
        t.expect(cleared.contains("\(kind.rawValue):\(target.rawValue)~~future%21"))
        doc.meta.links[0].unknownSuffix = ""
        t.expect(!FrontmatterCodec.encode(doc).contains("\(target.rawValue)~"))
    }
    var link = MemoLink(to: target, kind: .flow, label: String(repeating: "가", count: 21))
    t.expectEqual(link.label.count, 20)
    link.label = String(repeating: "👨‍👩‍👧", count: 21)
    t.expectEqual(link.label.count, 20)
    link.label = ""
    t.expectEqual(link.label, "")
}

runner.test("선의 모르는 꼬리와 이전 JSON 형식은 보존한다") { t in
    let id = MemoID.generate(), target = MemoID.generate()
    let document = MemoDocument(meta: MemoMeta(id: id, links: [MemoLink(to: target, kind: .flow)]), body: "본문")
    let text = FrontmatterCodec.encode(document).replacingOccurrences(of: "flow:\(target.rawValue)", with: "flow:\(target.rawValue)~%ZZ~future:tail")
    let decoded = try FrontmatterCodec.decode(fileContents: text)
    t.expectEqual(decoded.meta.links.first?.label, "")
    t.expectEqual(decoded.meta.links.first?.unknownSuffix, "~%ZZ~future:tail")
    let restoredLinks = try JSONDecoder().decode([MemoLink].self, from: JSONEncoder().encode(decoded.meta.links))
    t.expectEqual(restoredLinks, decoded.meta.links)
    t.expectEqual(try FrontmatterCodec.decode(fileContents: FrontmatterCodec.encode(decoded)).meta.links, decoded.meta.links)
    let data = try JSONEncoder().encode(MemoLink(to: target, kind: .flow))
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object.removeValue(forKey: "label")
    object.removeValue(forKey: "unknownSuffix")
    let old = try JSONDecoder().decode(MemoLink.self, from: JSONSerialization.data(withJSONObject: object))
    t.expectEqual(old, MemoLink(to: target, kind: .flow))
}

private enum InjectedMemoWriteFailure: Error { case expected }

final class MemoryLockKeychain: MemoKeychain, @unchecked Sendable {
    private let mutex = NSLock()
    private var failures: [MemoID: Int] = [:]
    func readFailures(id: MemoID) throws -> Int { mutex.lock(); defer { mutex.unlock() }; return failures[id] ?? 0 }
    func writeFailures(_ count: Int, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; failures[id] = count }
    private var values: [MemoID: Data] = [:]
    func read(id: MemoID) throws -> Data? { mutex.lock(); defer { mutex.unlock() }; return values[id] }
    func write(_ value: Data, id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; values[id] = value }
    func delete(id: MemoID) throws { mutex.lock(); defer { mutex.unlock() }; values[id] = nil; failures[id] = nil }
}

runner.test("암호 규칙은 ASCII 영숫자 4~6자이고 대소문자를 구분한다") { t in
    for valid in ["1234", "AbC9", "ABC123", "abcd"] { t.expect(LockCrypto.validPassword(valid)) }
    for invalid in ["123", "1234567", "가나다라", "ab c", "ab!C", "éabc", "Ａabc", ""] { t.expect(!LockCrypto.validPassword(invalid)) }
    t.expectEqual(LockCrypto.filteredPassword("가a B!c12한345"), "aBc123")
    t.expect(!LockCrypto.constantTimeEqual("Ab12", "ab12"))
    t.expect(LockCrypto.constantTimeEqual("Ab12", "Ab12"))
    t.expect(!LockCrypto.constantTimeEqual("123456A", "123456B"))
    t.expect(!LockCrypto.constantTimeEqual("123456", "123456A"))
}

runner.test("본문·첨부 AES-GCM 왕복과 잘못된 열쇠·문맥 거부") { t in
    let id = MemoID.generate()
    let session = MemoLockSession(id: id, key: try LockCrypto.random(count: 32))
    let other = MemoLockSession(id: id, key: try LockCrypto.random(count: 32))
    for name in ["body", "사진.png"] {
        let plain = Data("보호할 내용과 사진 바이트".utf8)
        let cipher = try session.seal(plain, name: name)
        t.expectEqual(try session.open(cipher, name: name), plain)
        t.expectNil(try? other.open(cipher, name: name))
        t.expectNil(try? session.open(cipher, name: "다른 첨부"))
    }
    session.clear()
    t.expectNil(try? session.seal(Data()))
}

await runner.testAsync("잠금 세션은 열쇠를 노출하지 않고 relock 뒤 기존 핸들도 폐기된다") { t in
    let keys = MemoryLockKeychain()
    let (repository, root) = try makeTemporaryRepository(keychain: keys)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoStore(repository: repository, keychain: keys)
    store.calibrateIterations = { 2_000_000 }
    let id = try await store.createLockedMemo(password: "1234")
    store.relock(id)
    try await store.unlock(id: id, password: "1234")
    let session = store.lockSession(for: id)!
    t.expect(store.lockSession(for: id) === session, "같은 세션 래퍼를 보존한다")
    let cipher = try session.seal(Data("첨부".utf8), name: "a.png")
    do { try await store.unlock(id: id, password: "!"); t.expect(false) }
    catch { if case MemoLockError.wrongPassword = error {} else { t.expect(false) } }
    t.expectEqual(try session.open(cipher, name: "a.png"), Data("첨부".utf8))
    if rustStorage {
        let storedKey = Mirror(reflecting: session).children.first { $0.label == "key" }?.value as? Data
        t.expectEqual(storedKey, Data())
    }
    store.relock(id)
    t.expectNil(store.lockSession(for: id))
    do { _ = try session.seal(Data()); t.expect(false) }
    catch { if case MemoLockError.locked = error {} else { t.expect(false) } }
    do { _ = try session.open(cipher, name: "a.png"); t.expect(false) }
    catch { if case MemoLockError.locked = error {} else { t.expect(false) } }
}

runner.test("영구 파기는 같은 길이 덮어쓰기와 fsync 뒤 휴지통 없이 삭제한다") { t in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = Data(repeating: 42, count: 150000)
    try original.write(to: root.appendingPathComponent("memo.md"))
    var observed = false
    try SecureMemoDeletion.remove(root) { folder in
        let erased = try Data(contentsOf: folder.appendingPathComponent("memo.md"))
        t.expectEqual(erased.count, 0)
        t.expect(erased != original)
        observed = true
    }
    t.expect(observed)
    t.expect(!FileManager.default.fileExists(atPath: root.path))
}

await runner.testAsync("새 암호 메모의 첫 저장·편집은 암호문이고 검색·복제·백업에서 제외된다") { t in
    let keychain = MemoryLockKeychain()
    let (repository, root) = try makeTemporaryRepository(keychain: keychain)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoStore(repository: repository, keychain: keychain)
    let id = try await store.createLockedMemo(password: "Ab1234")
    let folder = root.appendingPathComponent("memos").appendingPathComponent(id.rawValue)
    let first = try repository.load(id: id)
    t.expect(first.meta.isLocked)
    t.expectEqual(try store.decryptedDocument(id: id).body, "")
    t.expectNotNil(Data(base64Encoded: first.body))
    t.expect((first.meta.lockIterations ?? 0) >= 2_000_000)
    // macOS 27에서는 Foundation 조회가 실제 표시와 달리 false를 반환한다.
    // 디스크 속성 목록의 값을 직접 확인해 백업 제외가 실제 기록됐는지 검사한다.
    let attribute = "com.apple.metadata:com_apple_backup_excludeItem"
    let size = getxattr(folder.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
    t.expect(size > 0, "백업 제외 속성이 있어야 한다")
    if size > 0 {
        var bytes = Data(count: size)
        let count = bytes.withUnsafeMutableBytes { getxattr(folder.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        t.expectEqual(count, size)
        let marker = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? String
        t.expectEqual(marker, "com.apple.backupd")
    }
    store.saveBody(id: id, body: "절대디스크에평문으로남기지않을내용")
    t.expect(!(try String(contentsOf: folder.appendingPathComponent("memo.md"), encoding: .utf8)).contains("절대디스크"))
    t.expectEqual(try store.decryptedDocument(id: id).body, "절대디스크에평문으로남기지않을내용")
    t.expectEqual(try repository.searchBodies(matching: "절대디스크", in: [id]), [])
    t.expectEqual(store.duplicate([id]), [])
    t.expectEqual(store.summaries.first?.preview, "")
    let roundTrip = try FrontmatterCodec.decode(fileContents: FrontmatterCodec.encode(try repository.load(id: id)))
    t.expectEqual(roundTrip.meta.lockSalt, first.meta.lockSalt)
    t.expectEqual(roundTrip.meta.lockIterations, first.meta.lockIterations)
    t.expectEqual(roundTrip.meta.lockVersion, 1)
    store.relock(id)
    t.expectNil(try? store.decryptedDocument(id: id))
    try await store.unlock(id: id, password: "Ab1234")
    t.expectEqual(try store.decryptedDocument(id: id).body, "절대디스크에평문으로남기지않을내용")
    try await store.changePassword(id: id, password: "New123")
    t.expect(try repository.load(id: id).meta.lockSalt != first.meta.lockSalt)
    let ciphertext = try repository.load(id: id).body
    store.relock(id)
    do { try await store.unlock(id: id, password: "Ab1234"); t.expect(false) } catch {}
    t.expectEqual(try repository.load(id: id).meta.lockFailures, 1)
    try await store.unlock(id: id, password: "New123")
    t.expectEqual(try repository.load(id: id).meta.lockFailures, 0)
    t.expectEqual(try repository.load(id: id).body, ciphertext)
    store.relock(id)
    try keychain.delete(id: id)
    do { try await store.unlock(id: id, password: "New123"); t.expect(false) }
    catch { if case MemoLockError.missingKey = error {} else { t.expect(false, "열쇠 없음은 별도 오류로 처리") } }
    t.expectEqual(try repository.load(id: id).meta.lockFailures, 0)
}

await runner.testAsync("본문 손상은 맞는 암호의 실패 횟수를 올리지 않는다") { t in
    let keys = MemoryLockKeychain()
    let (repository, root) = try makeTemporaryRepository(keychain: keys)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoStore(repository: repository, keychain: keys)
    let id = try await store.createLockedMemo(password: "1234")
    store.relock(id)
    try keys.writeFailures(9, id: id)
    var document = try repository.load(id: id)
    document.meta.lockFailures = 9
    let original = document.body
    for broken in ["base64 아님", Data(repeating: 0, count: 40).base64EncodedString()] {
        document.body = broken
        let file = root.appendingPathComponent("memos").appendingPathComponent(id.rawValue).appendingPathComponent("memo.md")
        try Data(FrontmatterCodec.encode(document).utf8).write(to: file, options: .atomic)
        do { try await store.unlock(id: id, password: "1234"); t.expect(false) }
        catch { if case MemoLockError.damaged = error {} else { t.expect(false) } }
        t.expectEqual(try repository.load(id: id).meta.lockFailures, 9)
        t.expectEqual(try keys.readFailures(id: id), 9)
        t.expectNotNil(try keys.read(id: id))
        t.expectNil(store.lockSession(for: id))
    }
    document.body = original
    try repository.save(document)
    try await store.unlock(id: id, password: "1234")
    t.expectEqual(try keys.readFailures(id: id), 0)
    store.saveBody(id: id, body: "평문 미리보기 금지")
    store.updateMeta(id: id) { $0.title = "제목" }
    t.expectEqual(store.summaries.first?.preview, "")
    store.relock(id)
    t.expectEqual(store.summaries.first?.preview, "")
}

await runner.testAsync("열 번째 실패는 열쇠·폴더를 파기하고 묘비를 남긴다") { t in
    let keychain = MemoryLockKeychain()
    let (repository, root) = try makeTemporaryRepository(keychain: keychain)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoStore(repository: repository, keychain: keychain)
    let id = try await store.createLockedMemo(password: "1234")
    store.relock(id)
    do { try await store.unlock(id: id, password: "!"); t.expect(false) }
    catch { if case MemoLockError.wrongPassword = error {} else { t.expect(false) } }
    t.expectEqual(try keychain.readFailures(id: id), 0)
    t.expectEqual(try repository.load(id: id).meta.lockFailures, 0)
    for attempt in 1...10 {
        var edited = try repository.load(id: id)
        edited.meta.lockFailures = 0
        try repository.save(edited)
        do { try await store.unlock(id: id, password: "9999"); t.expect(false) } catch {}
        if attempt < 10 {
            t.expectEqual(try repository.load(id: id).meta.lockFailures, attempt)
            t.expectEqual(store.lockFailureCount(id: id), attempt)
        }
    }
    t.expectNil(try keychain.read(id: id))
    t.expectEqual(try keychain.readFailures(id: id), 0)
    t.expect((try MemoPrivacyLedger.read("destroyed", root: root)).contains(id.rawValue))
    t.expectEqual(try repository.loadTrashSummaries().count, 0)
    t.expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("memos").appendingPathComponent(id.rawValue).path))
}

await runner.testAsync("암호 메모 이동은 새 ID·첨부 암호화·원본 파기·연결 제거를 수행한다") { t in
    let keychain = MemoryLockKeychain()
    let (repository, root) = try makeTemporaryRepository(keychain: keychain)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoStore(repository: repository, keychain: keychain)
    let source = store.createMemo(group: "업무").id
    store.updateMeta(id: source) { $0.title = "보이는 제목"; $0.backgroundAlpha = 0.7 }
    store.saveBody(id: source, body: "내용 ![사진](attachments/test.png)")
    let attachment = store.attachmentsDirectory(for: source)
    try FileManager.default.createDirectory(at: attachment, withIntermediateDirectories: true)
    let photo = Data([1, 2, 3, 4, 5])
    try photo.write(to: attachment.appendingPathComponent("test.png"))
    let linked = store.createMemo().id
    store.link(from: linked, to: source, kind: .flow)
    let id = try await store.createLockedMemo(password: "1234", moving: source)
    t.expect(id != source)
    t.expectNil(store.loadDocument(id: source))
    t.expect((try MemoPrivacyLedger.read("destroyed", root: root)).contains(source.rawValue))
    t.expectEqual(store.loadDocument(id: linked)?.meta.links, [])
    let document = try store.decryptedDocument(id: id)
    t.expectEqual(document.meta.title, "보이는 제목")
    t.expectEqual(document.meta.group, "업무")
    t.expectEqual(document.meta.backgroundAlpha, 0.7)
    t.expectEqual(document.meta.links, [])
    let cipher = try Data(contentsOf: store.attachmentsDirectory(for: id).appendingPathComponent("test.png.enc"))
    t.expectEqual(try store.lockSession(for: id)?.open(cipher, name: "test.png"), photo)
    t.expect(!FileManager.default.fileExists(atPath: store.attachmentsDirectory(for: id).appendingPathComponent("test.png").path))
    let plainID = try store.moveToPlainMemo(id: id)
    t.expectEqual(store.loadDocument(id: plainID)?.body, document.body)
    t.expectNil(try keychain.read(id: id))
    t.expect((try MemoPrivacyLedger.read("destroyed", root: root)).contains(id.rawValue))
    t.expectEqual(try Data(contentsOf: store.attachmentsDirectory(for: plainID).appendingPathComponent("test.png")), photo)
}

if !rustStorage {
await runner.testAsync("[Swift 전용] 암호 메모 쓰기를 가로채도 평문이 없고 쓰기 실패 시 원본을 보존한다") { t in
    let (base, root) = try makeTemporarySwiftRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = MemoMeta(id: .generate())
    let original = MemoDocument(meta: source, body: "저장실패에도남아야하는원본")
    try base.save(original)
    var checked = base
    checked.beforeMemoWrite = { _, bytes in
        let document = try FrontmatterCodec.decode(fileContents: String(decoding: bytes, as: UTF8.self))
        if document.meta.isLocked {
            // 본문뿐 아니라 제목 등 파일 어디에도 원본 글이 평문으로 없어야 한다.
            guard Data(base64Encoded: document.body) != nil,
                  !String(decoding: bytes, as: UTF8.self).contains("저장실패에도남아야하는원본") else { throw MemoLockError.damaged }
            throw InjectedMemoWriteFailure.expected
        }
    }
    let store = MemoStore(repository: checked, keychain: MemoryLockKeychain())
    do { _ = try await store.createLockedMemo(password: "1234", moving: source.id); t.expect(false) }
    catch { if case InjectedMemoWriteFailure.expected = error {} else { t.expect(false, "쓰기 가로채기까지 도달하지 못함: \(error)") } }
    // 날짜는 파일에 밀리초로 적혀 다시 읽으면 소수점 끝자리가 달라질 수 있어, 보존돼야 할 것만 비교한다.
    let kept = try base.load(id: source.id)
    t.expectEqual(kept.body, original.body)
    t.expect(!kept.meta.isLocked)
    t.expectEqual(try base.loadSummaries().count, 1)
    t.expect(!(try MemoPrivacyLedger.read("destroyed", root: root)).contains(source.id.rawValue))
}
}

runner.test("구버전의 모르는 잠금 키 보존 규칙으로 암호문과 열쇠 메타데이터가 유지된다") { t in
    let id = MemoID.generate()
    var legacyMeta = MemoMeta(id: id, isLocked: true)
    legacyMeta.title = "제목"
    let ciphertext = Data(repeating: 1, count: 48).base64EncodedString()
    let legacy = MemoDocument(meta: legacyMeta, body: ciphertext, unknownFrontmatterLines: [
        "lockSalt: " + Data(repeating: 3, count: 16).base64EncodedString(),
        "lockIterations: 2000000", "lockVersion: 1", "lockFailures: 2", "futureLockField: 그대로"])
    let decoded = try FrontmatterCodec.decode(fileContents: FrontmatterCodec.encode(legacy))
    t.expectEqual(decoded.body, ciphertext)
    t.expectEqual(decoded.meta.lockFailures, 2)
    t.expectEqual(decoded.meta.lockVersion, 1)
    t.expectEqual(decoded.meta.lockIterations, 2_000_000)
    t.expect(decoded.unknownFrontmatterLines.contains("futureLockField: 그대로"))
}

if !rustStorage {
runner.test("[Swift 전용] 본문 저장 실패는 실패 결과를 돌려주고 원본을 보존한다") { t in
    let (base, root) = try makeTemporarySwiftRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = MemoID.generate()
    try base.save(MemoDocument(meta: MemoMeta(id: id), body: "원본"))
    var failing = base
    failing.beforeMemoWrite = { _, _ in throw InjectedMemoWriteFailure.expected }
    let store = MemoStore(repository: failing, keychain: MemoryLockKeychain())
    t.expect(!store.saveBody(id: id, body: "편집 내용"))
    t.expectEqual(try base.load(id: id).body, "원본")
    t.expect(!(try MemoPrivacyLedger.read("destroyed", root: root)).contains(id.rawValue))
}
}

runner.test("영구 삭제와 휴지통 비우기는 본문 대신 잠금 메타데이터로 경로를 고른다") { t in
    for emptyTrash in [false, true] {
        let (repository, root) = try makeTemporaryRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        var ids: [MemoID] = []
        for isLocked in [false, true] {
            let id = MemoID.generate()
            ids.append(id)
            var meta = MemoMeta(id: id, isLocked: isLocked)
            if isLocked {
                meta.lockVersion = 1
                meta.lockSalt = Data(repeating: 1, count: 16).base64EncodedString()
            }
            let body = isLocked ? Data(repeating: 2, count: 48).base64EncodedString() : "본문\nlocked: true\n일반 텍스트"
            try repository.save(MemoDocument(meta: meta, body: body))
            try repository.moveToTrash(id: id)
        }
        if emptyTrash {
            try repository.emptyTrash(deletedBefore: nil)
        } else {
            for id in ids { try repository.permanentlyDelete(id: id) }
        }
        let destroyed = try MemoPrivacyLedger.read("destroyed", root: root)
        t.expect(!destroyed.contains(ids[0].rawValue), "일반 메모에 파기 묘비가 생겼다")
        t.expect(destroyed.contains(ids[1].rawValue), "잠긴 메모가 안전 삭제를 건너뛰었다")
        for id in ids {
            t.expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("trash").appendingPathComponent(id.rawValue).path))
        }
    }
}

runner.test("손상된 암호 메모도 영구 삭제하면 열쇠와 폴더를 지운다") { t in
    let (_, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let keys = MemoryLockKeychain()
    let repository = try makeRepository(root: root, keychain: keys)
    let id = MemoID.generate()
    try keys.write(Data([1, 2, 3]), id: id)
    let folder = root.appendingPathComponent("trash").appendingPathComponent(id.rawValue)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("손상\nlocked: true".utf8).write(to: folder.appendingPathComponent("memo.md"))
    try repository.permanentlyDelete(id: id)
    t.expectNil(try keys.read(id: id))
    t.expect(!FileManager.default.fileExists(atPath: folder.path))
    t.expect((try MemoPrivacyLedger.read("destroyed", root: root)).contains(id.rawValue))
}

runner.test("묘비 기록 후 파기 실패에도 정리 콜백을 호출한다") { t in
    let (repository, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MemoStore(repository: repository, keychain: MemoryLockKeychain())
    let id = store.createMemo().id
    store.beforePrivacyRemoval = { _ in throw InjectedMemoWriteFailure.expected }
    var called = false
    store.onPrivacyChange = { called = true }
    do { try store.destroyMemo(id: id); t.expect(false) } catch {}
    t.expect(called)
    t.expect((try MemoPrivacyLedger.read("destroyed", root: root)).contains(id.rawValue))
}

runner.test("프론트매터 주석과 콜론 없는 줄 및 가로 공백과 CR의 현재 동작") { t in
    let base = "---\nid: 01ARZ3NDEKTSV4RRFFQ69G5FAV\ncreated: 2001-01-01T00:00:00.000Z\nmodified: 2001-01-01T00:00:00.000Z\n\t title \t: \t가로 공백\t\n# 주석: 보존\n콜론 없는 줄\n\t\n---\n본문\r단독 CR\n"
    let decoded = try FrontmatterCodec.decode(fileContents: base)
    t.expectEqual(decoded.meta.title, "가로 공백")
    t.expectEqual(decoded.unknownFrontmatterLines, ["# 주석: 보존", "콜론 없는 줄"])
    t.expectEqual(decoded.body, "본문\r단독 CR\n")
    t.expectEqual(try FrontmatterCodec.decode(fileContents: base.replacingOccurrences(of: "\n", with: "\r\n")), decoded)
    do {
        _ = try FrontmatterCodec.decode(fileContents: base.replacingOccurrences(of: "\n", with: "\r"))
        t.expect(false, "단독 CR 구분자는 현재 읽지 못한다")
    } catch { t.expectEqual(error as? FrontmatterError, .missingOpeningDelimiter) }
    let withNewline = base.replacingOccurrences(of: "가로 공백", with: "\u{2028}제목\u{2028}")
    t.expectEqual(try FrontmatterCodec.decode(fileContents: withNewline).meta.title, "\u{2028}제목\u{2028}")
}

runner.test("선 라벨은 확장 문자소 스무 개와 ASCII 밖 대문자 퍼센트 인코딩을 쓴다") { t in
    let id = MemoID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
    for glyph in ["👩‍💻", "e\u{301}", "한"] {
        let link = MemoLink(to: id, kind: .flow, label: String(repeating: glyph, count: 21))
        t.expectEqual(link.label, String(repeating: glyph, count: 20))
        var changed = link
        changed.label += glyph
        t.expectEqual(changed.label, link.label)
    }
    let meta = MemoMeta(id: id, links: [.init(to: id, kind: .flow, label: "Az09-_.~ /한")])
    let encoded = FrontmatterCodec.encode(.init(meta: meta, body: ""))
    t.expect(encoded.contains("~Az09%2D%5F%2E%7E%20%2F%ED%95%9C"))
    t.expectEqual(try FrontmatterCodec.decode(fileContents: encoded).meta.links, meta.links)
}

runner.test("알파 숫자 서식과 NaN의 현재 동작") { t in
    let id = MemoID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5FAV")
    for (value, background, foreground) in [(1.0, "1.0", "1.0"), (0.95, "0.95", "0.95"), (0.333333333, "0.333333", "0.333333"), (0.00001, "0.15", "0.3")] {
        let text = FrontmatterCodec.encode(.init(meta: MemoMeta(id: id, backgroundAlpha: value, textAlpha: value), body: ""))
        t.expect(text.contains("bgAlpha: \(background)\ntextAlpha: \(foreground)\n"))
    }
    let meta = MemoMeta(id: id, backgroundAlpha: .nan, textAlpha: .nan)
    t.expect(meta.backgroundAlpha.isNaN && meta.textAlpha.isNaN)
    let text = FrontmatterCodec.encode(.init(meta: meta, body: ""))
    t.expect(text.contains("bgAlpha: nan\ntextAlpha: nan\n"))
    let decoded = try FrontmatterCodec.decode(fileContents: text)
    t.expect(decoded.meta.backgroundAlpha.isNaN && decoded.meta.textAlpha.isNaN)
    t.expectEqual(MemoMeta.clampBackgroundAlpha(-1), 0.15)
    t.expectEqual(MemoMeta.clampTextAlpha(-1), 0.3)
}

runner.test("MemoID는 대문자만 유효하다") { t in
    let raw = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    t.expect(MemoID(rawValue: raw).isValid)
    t.expect(!MemoID(rawValue: raw.lowercased()).isValid)
    for invalid in ["I", "L", "O", "U"] {
        t.expect(!MemoID(rawValue: String(raw.dropLast()) + invalid).isValid)
    }
}

runner.test("JSON 저장 서식의 현재 동작: 보드는 키 정렬하고 그룹 배열 순서는 보존한다") { t in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try makeRepository(root: root, keychain: testKeychain)
    try repo.saveBoardLayout(.init(placements: ["Z/": .init(x: 2, y: 3), "A": .init(x: 1, y: 4)]))
    let board = try String(contentsOf: root.appendingPathComponent("board.json"), encoding: .utf8)
    t.expect(board.hasPrefix("{\n  \"bentoSpans\" : {"))
    t.expect(board.contains("\"Z\\/\" : {"))
    t.expect(board.range(of: "\"A\"")!.lowerBound < board.range(of: "\"Z\\/\"")!.lowerBound)
    try repo.saveGroups(["Z/", "A"])
    t.expectEqual(try String(contentsOf: root.appendingPathComponent("groups.json"), encoding: .utf8), "[\n  \"Z\\/\",\n  \"A\"\n]")
    let file = root.appendingPathComponent("device-state.json")
    let states = DeviceStateStore(fileURL: file)
    states.setState(.init(frame: [1, 2, 300, 200]), for: .init(rawValue: "Z/"))
    states.setState(.init(frame: [1, 2, 300, 200]), for: .init(rawValue: "A"))
    states.flush()
    let data = try Data(contentsOf: file)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    t.expectEqual(data, try encoder.encode(JSONDecoder().decode([String: DeviceMemoState].self, from: data)))
    t.expect(String(decoding: data, as: UTF8.self).contains("\"Z\\/\" : {"))
}

runner.test("저장소 레코드는 모든 메타데이터와 모르는 줄 및 선 꼬리를 보존한다") { t in
    let (repo, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = MemoID.generate()
    var meta = MemoMeta(schemaVersion: 7, id: .generate(), title: "제목 🙂", group: "업무", colorHex: "#123456", backgroundAlpha: 0.45, textAlpha: 0.65, isOpen: false, isPinned: false, created: Date(timeIntervalSinceReferenceDate: 1234), modified: Date(timeIntervalSinceReferenceDate: 5678), conflictOf: target, links: [MemoLink(to: target, kind: .flow, label: "한글 🙂", unknownSuffix: "~future")])
    meta.lockSalt = "c2FsdA=="
    meta.lockIterations = 2_000_000
    meta.lockVersion = 1
    meta.lockFailures = 3
    let doc = MemoDocument(meta: meta, body: "본문\n유지", unknownFrontmatterLines: ["# 주석", "future: 값", "콜론 없는 줄"], unknownLinkTokens: ["future:알수없음"])
    try repo.save(doc)
    t.expectEqual(try repo.load(id: meta.id), doc)
    t.expectEqual(try Data(contentsOf: root.appendingPathComponent("memos/\(meta.id.rawValue)/memo.md")), Data(FrontmatterCodec.encode(doc).utf8))
    let text = FrontmatterCodec.encode(doc).components(separatedBy: "\n").map {
        $0.hasPrefix("links:") ? "links: flow:\(target.rawValue)~%ZZ~future,future:알수없음" : $0
    }.joined(separator: "\n")
    let malformedLabel = try FrontmatterCodec.decode(fileContents: text)
    try repo.save(malformedLabel)
    t.expectEqual(try repo.load(id: meta.id), malformedLabel)
    t.expectEqual(try String(contentsOf: root.appendingPathComponent("memos/\(meta.id.rawValue)/memo.md"), encoding: .utf8), text)

}

runner.test("저장소의 없는 파일은 Cocoa 파일 없음으로 구분된다") { t in
    let (repo, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    do { _ = try repo.load(id: .generate()); t.expect(false) }
    catch { t.expectEqual((error as NSError).domain, NSCocoaErrorDomain); t.expectEqual((error as NSError).code, NSFileReadNoSuchFileError) }
}

runner.test("저장소 조립은 실행 플래그에 따라 구현을 선택한다") { t in
    let (_, root) = try makeTemporaryRepository()
    defer { try? FileManager.default.removeItem(at: root) }
    let repo = try CoreStorage.make(root: root, keychain: testKeychain)
    t.expect(rustStorage ? repo is RustMemoRepository : repo is FileMemoRepository)
}

// 정방향 그림자 장식자 자체의 계약 8개는 Swift 기반으로만 실행한다.
if !rustStorage { registerShadowTests(runner) }

runner.finish()
