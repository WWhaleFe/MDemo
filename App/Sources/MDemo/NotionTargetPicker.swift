import Services
import SwiftUI

/// 노션에 올릴 곳(페이지 또는 데이터베이스)을 고르는 작은 창의 화면.
/// 통합이 접근할 수 있는 항목을 최근 수정 순으로 보여 주고, 검색어를 넣으면 그 이름으로 찾는다.
struct NotionTargetPickerView: View {
    let current: NotionTarget?
    let search: @Sendable (String) async throws -> [NotionSearchItem]
    let onChoose: (NotionTarget) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var items: [NotionSearchItem] = []
    @State private var selection: String?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 12) {
            TextField("페이지나 데이터베이스 이름으로 찾기", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
            if let current {
                Text("지금 올릴 곳: \(current.title) (\(current.kindLabel))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                List(items, selection: $selection) { item in
                    HStack(spacing: 8) {
                        Text(item.type == .page ? "페이지" : "데이터베이스")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 14)).lineLimit(1)
                            if !item.path.isEmpty {
                                Text(item.path).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.tag(item.id)
                }
                if isLoading && items.isEmpty {
                    ProgressView()
                } else if let errorText {
                    Text(errorText).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                } else if items.isEmpty {
                    Text("노션 로그인 때 MDemo가 볼 수 있게 허락한 페이지만 보입니다. 노션에서 페이지 오른쪽 위 ⋯ > 연결에 MDemo를 추가하거나 다시 로그인해 허락할 페이지를 고르세요.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            HStack {
                Spacer()
                Button("취소", action: onCancel).keyboardShortcut(.cancelAction)
                Button("여기에 올리기") {
                    if let chosen = items.first(where: { $0.id == selection }) { onChoose(chosen.target) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 400)
        .task(id: query) {
            // 타자를 칠 때마다 부르지 않게 잠깐 기다린다.
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 350_000_000) }
            if Task.isCancelled { return }
            isLoading = true
            do {
                items = try await search(query)
                errorText = nil
            } catch is CancellationError {
                return
            } catch {
                items = []
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}
