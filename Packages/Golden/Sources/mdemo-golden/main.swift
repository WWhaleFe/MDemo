import Foundation
import MemoCore
@testable import Services
@testable import Features
import StickyWindow

// 디버그 전용 도구. 앱을 실행하지 않고 기존 저장기와 계산기를 직접 호출한다.
final class EmptyKeychain: MemoKeychain, @unchecked Sendable {
    func read(id: MemoID) throws -> Data? { nil }
    func write(_ value: Data, id: MemoID) throws {}
    func delete(id: MemoID) throws {}
    func readFailures(id: MemoID) throws -> Int { 0 }
    func writeFailures(_ count: Int, id: MemoID) throws {}
}

// 상태 파일 왕복에서는 API를 호출할 수 없다. 잘못 연결되면 즉시 실패한다.
struct OfflineDrive: DriveAPI {
    struct UnexpectedCall: Error {}
    func list() async throws -> [DriveFile] { throw UnexpectedCall() }
    func download(id: String) async throws -> Data { throw UnexpectedCall() }
    func upload(name: String, parentID: String?, data: Data) async throws -> DriveFile { throw UnexpectedCall() }
    func update(id: String, data: Data) async throws -> DriveFile { throw UnexpectedCall() }
    func createFolder(name: String, parentID: String?) async throws -> DriveFile { throw UnexpectedCall() }
    func delete(id: String) async throws { throw UnexpectedCall() }
}

struct Scenario: Decodable {
    struct Edge: Decodable {
        var from: String
        var to: String
        var kind: MemoLinkKind
        var value: MemoEdge { .init(from: .init(rawValue: from), to: .init(rawValue: to), kind: kind) }
    }
    struct RoutingCase: Decodable {
        var name: String
        var edges: [Edge]
        var positions: [String: BoardLayout.Placement]
    }
    var routingCases: [RoutingCase]
    struct CrossingPath: Decodable { var points: [[Double]] }
    var ids: [String]
    var edges: [Edge]
    var positions: [String: BoardLayout.Placement]
    var crossingPaths: [CrossingPath]
}

// 계산 결과만 숫자를 여섯 자리로 고정한다. 문자열과 불리언은 JSON 값 그대로 쓴다.
indirect enum ResultJSON {
    case string(String), number(Double), bool(Bool), array([ResultJSON]), object([String: ResultJSON])
    var text: String {
        switch self {
        case .string(let value): String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
        case .number(let value): String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        case .bool(let value): value ? "true" : "false"
        case .array(let values): "[" + values.map(\.text).joined(separator: ",") + "]"
        case .object(let values): "{" + values.keys.sorted().map { ResultJSON.string($0).text + ":" + values[$0]!.text }.joined(separator: ",") + "}"
        }
    }
    static func point(_ p: CGPoint) -> Self { .array([.number(p.x), .number(p.y)]) }
}

@MainActor
func generate(input: URL, output: URL) throws {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("mdemo-golden-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: work) }
    let keychain = EmptyKeychain()
    let repo = try FileMemoRepository(rootDirectory: work, keychain: keychain)
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    func read(_ name: String) throws -> Data { try Data(contentsOf: input.appendingPathComponent(name)) }
    func emit(_ name: String, _ data: Data) throws {
        let url = output.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func copyResult(_ name: String) throws { try emit(name, Data(contentsOf: work.appendingPathComponent(name))) }
    for url in try fm.contentsOfDirectory(at: input.appendingPathComponent("memos"), includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "md" {
        let document = try FrontmatterCodec.decode(fileContents: String(contentsOf: url, encoding: .utf8))
        try emit("memos/" + url.lastPathComponent, Data(FrontmatterCodec.encode(document).utf8))
    }
    try repo.saveBoardLayout(JSONDecoder().decode(BoardLayout.self, from: read("board.json")))
    try copyResult("board.json")
    try repo.saveGroups(JSONDecoder().decode([String].self, from: read("groups.json")))
    try copyResult("groups.json")
    for name in ["destroyed", "local-only"] {
        try read(name + ".json").write(to: work.appendingPathComponent(name + ".json"))
        try MemoPrivacyLedger.write(MemoPrivacyLedger.read(name, root: work), name: name, root: work)
        try copyResult(name + ".json")
    }
    let deviceURL = work.appendingPathComponent("device-state.json")
    try read("device-state.json").write(to: deviceURL)
    DeviceStateStore(fileURL: deviceURL).flush()
    try copyResult("device-state.json")
    let stateURL = work.appendingPathComponent("sync-state-google.json")
    let hashesURL = work.appendingPathComponent("sync-state-google.hashes.json")
    try read("sync-state-google.json").write(to: stateURL)
    try read("sync-state-google.hashes.json").write(to: hashesURL)
    let sync = SyncService(localRoot: work, remoteRoot: work, stateURL: stateURL, keychain: keychain)
    sync.saveState(sync.loadState())
    for name in ["sync-state-google.json", "sync-state-google.hashes.json"] {
        // 저장기의 사전 순서는 비결정적이다. 골든에서는 압축 JSON으로 키를 정렬한다.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: work.appendingPathComponent(name)))
        try emit(name, JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]))
    }
    let driveURL = work.appendingPathComponent("drive-state.json")
    try read("drive-state.json").write(to: driveURL)
    let drive = DriveMirrorSync(localRoot: work, mirrorRoot: work, driveStateURL: driveURL, engineStateURL: stateURL, api: OfflineDrive(), keychain: keychain)
    drive.saveState(drive.loadState())
    try copyResult("drive-state.json")

    // 검색 일치는 따로 둔 저장소 폴더에서 한다(보드 계산용 메모와 섞이지 않게).
    if fm.fileExists(atPath: input.appendingPathComponent("search-cases.json").path) {
        let searchRoot = work.appendingPathComponent("search-root")
        try emit("search-results.json", searchResults(input: input.appendingPathComponent("search-cases.json"), root: searchRoot, keychain: keychain))
    }

    // 마크다운 엔진 고정 사례(P5). 입력에 markdown-cases.json이 있을 때만 만든다.
    if fm.fileExists(atPath: input.appendingPathComponent("markdown-cases.json").path) {
        try emit("markdown-results.json", markdownResults(input: input.appendingPathComponent("markdown-cases.json")))
    }

    let scenario = try JSONDecoder().decode(Scenario.self, from: read("board-calculations.json"))
    let ids = scenario.ids.map { MemoID(rawValue: $0) }
    let edges = scenario.edges.map(\.value)
    let date = Date(timeIntervalSinceReferenceDate: 123.25)
    for id in ids {
        let links = edges.filter { $0.from == id }.map { MemoLink(to: $0.to, kind: $0.kind) }
        try repo.save(.init(meta: MemoMeta(id: id, created: date, modified: date, links: links), body: "가짜 메모"))
    }
    let store = MemoStore(repository: repo, keychain: keychain)
    let model = MemoListModel(store: store)
    let summaries = ids.compactMap { id in store.summaries.first { $0.id == id } }
    let arranged = model.autoArrangedPlacements(for: summaries)
    let positions = Dictionary(uniqueKeysWithValues: scenario.positions.map { (MemoID(rawValue: $0.key), $0.value) })
    let pipes = PipeGeometry.make(edges: edges, positions: positions)
    let crossingPipes = scenario.crossingPaths.map { path in PipeGeometry(edge: edges[0], points: path.points.map { CGPoint(x: $0[0], y: $0[1]) }) }
    let crossings = PipeGeometry.crossings(in: crossingPipes)
    let routing: [ResultJSON] = scenario.routingCases.map { item in
        let positions = Dictionary(uniqueKeysWithValues: item.positions.map { (MemoID(rawValue: $0.key), $0.value) })
        let paths = PipeGeometry.make(edges: item.edges.map(\.value), positions: positions)
        return .object(["name": .string(item.name), "points": .array(paths.map { .array($0.points.map(ResultJSON.point)) })])
    }
    let result: ResultJSON = .object([
        "routingCases": .array(routing),
        "arranged": .object(Dictionary(uniqueKeysWithValues: arranged.map { ($0.key.rawValue, .array([.number($0.value.x), .number($0.value.y)])) })),
        "pipes": .array(pipes.map { .object(["from": .string($0.edge.from.rawValue), "to": .string($0.edge.to.rawValue), "points": .array($0.points.map(ResultJSON.point))]) }),
        "crossings": .array(crossings.map { .object(["point": .point($0.point), "horizontalPipe": .number(Double($0.horizontalPipe)), "segment": .number(Double($0.segment))]) })
    ])
    try emit("board-calculations.json", Data((result.text + "\n").utf8))
    var relations: [String: ResultJSON] = [:]
    for (name, depth, enabled) in [("direct", 1, true), ("twoSteps", 2, true), ("disabled", 2, false)] {
        let value = MemoStripRelations.calculate(current: ids[0], flow: nil, edges: edges, depth: depth, showRelations: enabled)
        relations[name] = .object([
            "direct": .array(value.direct.map { .object(["other": .string($0.other.rawValue), "kind": .string($0.kind.rawValue), "outgoing": .bool($0.outgoing)]) }),
            "indirect": .array(value.indirect.map { .object(["other": .string($0.other.rawValue), "via": .string($0.via.rawValue), "kind": .string($0.kind.rawValue), "outgoing": .bool($0.outgoing)]) })
        ])
    }
    try emit("relations.json", Data((ResultJSON.object(relations).text + "\n").utf8))
}

do {
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "sync-step" {
        try await runSyncStep(file: URL(fileURLWithPath: CommandLine.arguments[2]), root: URL(fileURLWithPath: CommandLine.arguments[3]))
        exit(0)
    }
    if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "scenario" {
        try await MainActor.run {
            try runScenario(file: URL(fileURLWithPath: CommandLine.arguments[2]), dataDir: URL(fileURLWithPath: CommandLine.arguments[3]))
        }
        exit(0)
    }
    // lock <시나리오.json> <데이터 폴더> [--phase N]: 암호 메모 시나리오 (P4)
    if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "lock" {
        var phase: Int?
        if CommandLine.arguments.count == 6, CommandLine.arguments[4] == "--phase" { phase = Int(CommandLine.arguments[5]) }
        else if CommandLine.arguments.count != 4 { throw NSError(domain: "인자", code: 1, userInfo: [NSLocalizedDescriptionKey: "사용법: mdemo-golden lock <시나리오.json> <데이터 폴더> [--phase N]"]) }
        try await runLockScenario(file: URL(fileURLWithPath: CommandLine.arguments[2]), dataDir: URL(fileURLWithPath: CommandLine.arguments[3]), phase: phase)
        exit(0)
    }
    guard CommandLine.arguments.count == 3 else {
        throw NSError(domain: "인자", code: 1, userInfo: [NSLocalizedDescriptionKey: "사용법: mdemo-golden <입력 폴더> <출력 폴더> | mdemo-golden scenario <시나리오.json> <데이터 폴더> | mdemo-golden lock <시나리오.json> <데이터 폴더> [--phase N]"])
    }
    try await MainActor.run {
        try generate(input: URL(fileURLWithPath: CommandLine.arguments[1]), output: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
} catch {
    FileHandle.standardError.write(Data("골든 생성 실패: \(error)\n".utf8))
    exit(1)
}
