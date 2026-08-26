import MemoCore
import SwiftUI

/// 모든 메모를 한눈에 보는 관리 창 (LST-01).
///
/// 왼쪽에 그룹, 오른쪽에 목록. 위에 검색과 정렬.
/// 메모를 두 번 누르면 그 메모 창이 화면에 뜬다 (LST-04).
public struct MemoListView: View {
    @Bindable private var model: MemoListModel

    /// 메모를 열어 달라는 요청. 창을 다루는 일은 이 계층 밖에서 한다.
    private let onOpenMemo: (MemoID) -> Void
    private let onCreateMemo: () -> Void

    public init(
        model: MemoListModel,
        onOpenMemo: @escaping (MemoID) -> Void,
        onCreateMemo: @escaping () -> Void
    ) {
        self._model = Bindable(model)
        self.onOpenMemo = onOpenMemo
        self.onCreateMemo = onCreateMemo
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            memoList
        }
        .navigationTitle("메모 목록")
        .onAppear { model.refresh() }
    }

    // MARK: - 왼쪽: 그룹 (LST-02, LST-03)

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("그룹") {
                ForEach(model.sidebarItems.indices, id: \.self) { index in
                    let item = model.sidebarItems[index]
                    sidebarRow(scope: item.scope, count: item.count)
                        .tag(item.scope)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        .safeAreaInset(edge: .bottom) {
            GroupEditor(store: model.store)
                .padding(8)
        }
    }

    private var sidebarSelection: Binding<MemoListModel.Scope?> {
        Binding(
            get: { model.scope },
            set: { newValue in
                guard let newValue else { return }
                model.prepare(for: newValue)
            }
        )
    }

    private func sidebarRow(scope: MemoListModel.Scope, count: Int) -> some View {
        HStack {
            Image(systemName: iconName(for: scope))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(scope.title)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .contextMenu {
            if case .group(let name) = scope {
                Button("그룹 삭제", role: .destructive) {
                    model.store.deleteGroup(name)
                    if model.scope == scope { model.prepare(for: .all) }
                }
            }
            if case .trash = scope, !model.store.trashed.isEmpty {
                Button("휴지통 비우기", role: .destructive) {
                    model.store.emptyTrash()
                }
            }
        }
    }

    private func iconName(for scope: MemoListModel.Scope) -> String {
        switch scope {
        case .all: return "tray.full"
        case .group: return "folder"
        case .ungrouped: return "tray"
        case .trash: return "trash"
        }
    }

    // MARK: - 오른쪽: 목록 (LST-01, SRC-*)

    private var memoList: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if model.visibleMemos.isEmpty {
                emptyState
            } else {
                List(model.visibleMemos, selection: $model.selection) { memo in
                    MemoRow(memo: memo, showsDeletedDate: model.isShowingTrash)
                        .tag(memo.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard !model.isShowingTrash else { return }
                            onOpenMemo(memo.id)
                        }
                        .contextMenu { rowMenu(for: memo) }
                }
                .listStyle(.inset)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("검색", text: $model.query)
                .textFieldStyle(.plain)

            Divider().frame(height: 16)

            Picker("정렬", selection: $model.sortOrder.key) {
                ForEach(MemoSortKey.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)

            Button {
                model.sortOrder.ascending.toggle()
            } label: {
                Image(systemName: model.sortOrder.ascending ? "arrow.up" : "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(model.sortOrder.ascending ? "오름차순" : "내림차순")

            Button(action: onCreateMemo) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("새 메모")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(model.query.isEmpty ? "메모가 없습니다" : "찾는 메모가 없습니다")
                .foregroundStyle(.secondary)
            if model.query.isEmpty, !model.isShowingTrash {
                Button("새 메모 만들기", action: onCreateMemo)
                    .buttonStyle(.link)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func rowMenu(for memo: MemoSummary) -> some View {
        if model.isShowingTrash {
            Button("복원") {
                model.store.restoreFromTrash(id: memo.id)
            }
            Button("영구 삭제", role: .destructive) {
                model.store.permanentlyDelete(id: memo.id)
            }
        } else {
            Button("열기") { onOpenMemo(memo.id) }
            Divider()
            Menu("그룹으로 이동") {
                Button("그룹 없음") { model.store.assignGroup(nil, to: memo.id) }
                ForEach(model.store.groups, id: \.self) { group in
                    Button(group) { model.store.assignGroup(group, to: memo.id) }
                }
            }
            Divider()
            Button("휴지통으로 이동", role: .destructive) {
                model.store.moveToTrash(id: memo.id)
            }
        }
    }
}

/// 목록 한 줄 (LST-01).
private struct MemoRow: View {
    let memo: MemoSummary
    let showsDeletedDate: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(memo.title)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    // 두 기기에서 동시에 고쳐 갈라져 나온 사본 (SYNC-06).
                    // 어느 쪽도 버리지 않았다는 표시이자, 정리해 달라는 신호다.
                    if memo.meta.conflictOf != nil {
                        Text("충돌 사본")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.22), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("다른 기기에서 같은 메모를 함께 고쳐 사본이 만들어졌습니다")
                    }
                }

                if !previewText.isEmpty {
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let group = memo.meta.group {
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// 제목으로 쓴 첫 줄은 미리보기에서 뺀다. 같은 글자가 두 번 보이면 지저분하다.
    private var previewText: String {
        memo.preview
            .components(separatedBy: "\n")
            .dropFirst()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    private var dateText: String {
        let date = showsDeletedDate ? (memo.deletedAt ?? memo.meta.modified) : memo.meta.modified
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M월 d일"
        return formatter.string(from: date)
    }

    private var color: Color {
        guard let rgb = MemoColor.components(fromHex: memo.meta.colorHex) else { return .gray }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

/// 그룹 추가 (LST-02).
private struct GroupEditor: View {
    let store: MemoStore
    @State private var newGroupName = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("새 그룹", text: $newGroupName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addGroup)
            Button(action: addGroup) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addGroup() {
        store.createGroup(named: newGroupName)
        newGroupName = ""
    }
}
