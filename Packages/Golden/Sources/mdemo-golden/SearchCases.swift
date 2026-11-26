import Foundation
import MemoCore

// 본문 검색 일치 비교 (P3 후속). (본문, 검색어) 쌍마다 실제 판정을 그대로 호출한다.
//  - 앞: MemoSearch.matches (제목 · 미리보기 · 그룹, 본문 전체를 미리보기로 넣는다)
//  - 뒤: FileMemoRepository.searchBodies (파일에 저장한 뒤 본문만 찾는다)
// 출력은 [[앞, 뒤], ...] 한 줄 JSON이다.
func searchResults(input: URL, root: URL, keychain: any MemoKeychain) throws -> Data {
    struct Case: Decodable { var body: String; var query: String }
    struct Cases: Decodable { var cases: [Case] }
    let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: input)).cases
    let repo = try FileMemoRepository(rootDirectory: root, keychain: keychain)
    let id = MemoID(rawValue: "01ARZ3NDEKTSV4RRFFQ69G5F00")
    let date = Date(timeIntervalSinceReferenceDate: 123.25)
    var rows: [String] = []
    for item in cases {
        let meta = MemoMeta(id: id, created: date, modified: date)
        let summary = MemoSummary(meta: meta, preview: item.body)
        let viaSummary = MemoSearch.matches(summary, query: item.query)
        try repo.save(MemoDocument(meta: meta, body: item.body))
        let viaBody = try repo.searchBodies(matching: item.query, in: [id]).contains(id)
        rows.append("[\(viaSummary),\(viaBody)]")
    }
    return Data(("[" + rows.joined(separator: ",") + "]\n").utf8)
}
