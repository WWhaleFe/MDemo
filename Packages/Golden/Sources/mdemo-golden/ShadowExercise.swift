import Foundation
import MemoCore

// 빠른 그림자 검사 (P7). 실제 데이터 폴더의 복제본에서 MemoStore로 실제 앱과 같은 연산을 무작위로 돌리고,
// ShadowMemoRepository가 매 연산을 Rust로 재생해 비교하게 한다. 키체인은 빈 가짜라 잠긴 메모는 건너뛴다.
// 사용법: mdemo-golden shadow-exercise <데이터 폴더 복제본> <그림자 기록 폴더> <연산 수> <시드>
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
func runShadowExercise(dataDir: URL, shadowDir: URL, steps: Int, seed: UInt64, rust: Bool = false) throws {
    let real = FileMemoRepository.defaultRootDirectory().standardizedFileURL.resolvingSymlinksInPath().path
    guard dataDir.standardizedFileURL.resolvingSymlinksInPath().path != real else {
        throw NSError(domain: "그림자 검사", code: 1, userInfo: [NSLocalizedDescriptionKey: "실제 데이터 폴더에는 실행하지 않습니다. 복제본을 주세요."])
    }
    let keychain = EmptyKeychain()
    let shadow: ShadowMemoRepository
    if rust { shadow = try ShadowMemoRepository(RustMemoRepository(rootDirectory: dataDir, keychain: keychain), shadowDirectory: shadowDir) }
    else { shadow = try ShadowMemoRepository(FileMemoRepository(rootDirectory: dataDir, keychain: keychain), shadowDirectory: shadowDir) }
    let store = MemoStore(repository: shadow, keychain: keychain)
    // 진단용: MDEMO_SHADOW_KEEP=<폴더>이면 앞 회차 몇 개의 before(=Rust 결과) · after(=Swift 결과)를 남긴다.
    if let keep = ProcessInfo.processInfo.environment["MDEMO_SHADOW_KEEP"] {
        let counter = Counter()
        shadow.afterShadowApply = { before in
            let n = counter.next()
            guard n < 5000 else { return }
            let target = URL(fileURLWithPath: keep).appendingPathComponent("\(n)")
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: before, to: target.appendingPathComponent(rust ? "swift" : "rust"))
            try? FileManager.default.copyItem(at: before.deletingLastPathComponent().appendingPathComponent("after"), to: target.appendingPathComponent(rust ? "rust" : "swift"))
        }
    }
    var rng = SeededRandom(state: seed)
    let words = ["오늘", "할 일", "회의", "메모", "🙂", "e\u{301}", "- [ ] 항목", "**굵게**", "| 표 | 칸 |", "\t탭", "줄\r\n바꿈", "#제목"]
    func plain() -> [MemoSummary] { store.summaries.filter { !$0.meta.isLocked } }
    for step in 0..<steps {
        let memos = plain()
        let pick = memos.randomElement(using: &rng)
        switch Int.random(in: 0..<16, using: &rng) {
        case 0, 1, 2, 3:
            if let pick, let doc = store.loadDocument(id: pick.id) {
                let extra = (0..<Int.random(in: 1...4, using: &rng)).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
                _ = store.saveBody(id: pick.id, body: doc.body + "\n" + extra)
            }
        case 4:
            if let pick { _ = store.saveBody(id: pick.id, body: store.loadDocument(id: pick.id)?.body ?? "") }
        case 5:
            if let pick { store.updateMeta(id: pick.id) { $0.title = Bool.random(using: &rng) ? nil : "검사 \(step)" } }
        case 6:
            let meta = store.createMemo()
            _ = store.saveBody(id: meta.id, body: "새 메모 \(step) " + words.randomElement(using: &rng)!)
        case 7:
            if let pick { _ = store.duplicate([pick.id]) }
        case 8:
            if let a = memos.randomElement(using: &rng), let b = memos.randomElement(using: &rng), a.id != b.id {
                store.link(from: a.id, to: b.id, kind: MemoLinkKind.allCases.randomElement(using: &rng)!)
            }
        case 9:
            if let a = memos.randomElement(using: &rng), let b = memos.randomElement(using: &rng), a.id != b.id { store.unlink(a.id, b.id) }
        case 10:
            if let pick { store.moveToTrash(id: pick.id) }
        case 11:
            store.reloadTrash()
            if let item = store.trashed.filter({ !$0.meta.isLocked }).randomElement(using: &rng) { store.restoreFromTrash(id: item.id) }
        case 12:
            store.reloadTrash()
            // 원래 휴지통 항목을 다 지우지 않도록 검사 중 만든 복제 · 새 메모 위주로 지운다(복제본이라 실제 데이터는 상관없다).
            if let item = store.trashed.filter({ !$0.meta.isLocked }).randomElement(using: &rng) { store.permanentlyDelete(id: item.id) }
        case 13:
            let name = "검사그룹\(Int.random(in: 0..<4, using: &rng))"
            store.createGroup(named: name)
            if let pick { store.assignGroup(name, to: pick.id) }
        case 14:
            if let pick {
                store.setBoardPlacement(.init(x: Double(Int.random(in: 0..<60, using: &rng) * 20), y: Double(Int.random(in: 0..<40, using: &rng) * 20)), for: pick.id)
            }
        default:
            if Int.random(in: 0..<10, using: &rng) == 0 { store.emptyTrash(olderThan: 30) }
            else if let pick { store.setOpen(id: pick.id, isOpen: Bool.random(using: &rng)) }
        }
        if step % 50 == 0 { store.reloadSummaries() }
        // 실제 사용보다 훨씬 빠르게 연산하므로 비교 대기열이 밀려 건너뛰지 않게 자주 기다린다.
        if step % 20 == 0 { shadow.waitForShadow() }
    }
    shadow.waitForShadow()
}

final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value - 1 }
}
