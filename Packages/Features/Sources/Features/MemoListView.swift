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

    /// 한꺼번에 띄우기 전 확인. 창 하나마다 본문이 메모리에 올라온다 (§4-5).
    @State private var isConfirmingBulkOpen = false

    /// 영구 삭제 전 확인. 되돌릴 수 없으므로 개수와 함께 한 번 묻는다.
    @State private var pendingPermanentDelete: [MemoID] = []

    public var body: some View {
        VStack(spacing: 0) {
            // 버튼 줄은 창 전체 폭에 둔다. 왼쪽 목록에도 함께 걸리는 동작(모두 띄우기 등)이라
            // 오른쪽 목록 위에만 두면 어디에 걸리는 동작인지 헷갈린다.
            commandBar
            Divider()

            NavigationSplitView {
                sidebar
            } detail: {
                memoList
            }
        }
        .navigationTitle("메모 목록")
        .onAppear { model.refresh() }
        .confirmationDialog(
            "메모 \(model.visibleMemos.count)개를 모두 띄울까요?",
            isPresented: $isConfirmingBulkOpen,
            titleVisibility: .visible
        ) {
            Button("모두 띄우기") { model.showAll() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("창 하나마다 본문이 메모리에 올라옵니다. 화면이 가득 찰 수 있습니다.")
        }
        .confirmationDialog(
            "메모 \(pendingPermanentDelete.count)개를 영구 삭제할까요?",
            isPresented: Binding(
                get: { !pendingPermanentDelete.isEmpty },
                set: { if !$0 { pendingPermanentDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("영구 삭제", role: .destructive) {
                model.deletePermanently(pendingPermanentDelete)
                pendingPermanentDelete = []
            }
            Button("취소", role: .cancel) { pendingPermanentDelete = [] }
        } message: {
            Text("첨부 이미지까지 함께 지워지며 되돌릴 수 없습니다.")
        }
    }

    // MARK: - 위: 버튼 줄 (LST-06, LST-09 ~ LST-11)

    private var commandBar: some View {
        HStack(spacing: 8) {
            Button(action: onCreateMemo) {
                Label("새 메모", systemImage: "square.and.pencil")
            }
            .help("새 메모 (어디서든 ⌘⇧N)")

            Divider().frame(height: 16)

            Button {
                if model.needsBulkOpenConfirmation {
                    isConfirmingBulkOpen = true
                } else {
                    model.showAll()
                }
            } label: {
                Label("모두 띄우기", systemImage: "rectangle.stack")
            }
            .disabled(model.isShowingTrash || model.visibleMemos.isEmpty)
            .help("지금 목록에 있는 메모를 모두 화면에 띄웁니다")

            Button {
                model.hideAll()
            } label: {
                Label("모두 숨기기", systemImage: "eye.slash")
            }
            .help("화면에서만 내립니다. 메모는 그대로 남습니다")

            Button {
                model.showSelection()
            } label: {
                Label("선택 띄우기", systemImage: "rectangle.badge.checkmark")
            }
            .disabled(model.isShowingTrash || model.selection.isEmpty)
            .help("고른 메모만 화면에 띄웁니다")

            Divider().frame(height: 16)

            sortControls

            Divider().frame(height: 16)

            Button {
                model.arrangeWindows(byGroup: false)
            } label: {
                Label("창 나열", systemImage: "square.grid.2x2")
            }
            .help("떠 있는 창을 화면에 격자로 늘어놓습니다")

            Button {
                model.arrangeWindows(byGroup: true)
            } label: {
                Label("그룹 나열", systemImage: "square.grid.3x1.below.line.grid.1x2")
            }
            .help("그룹마다 줄을 나눠 늘어놓습니다")

            Spacer(minLength: 8)

            searchField
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("검색어를 입력하세요", text: $model.query)
                .textFieldStyle(.plain)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .frame(minWidth: 160, idealWidth: 240)
    }

    private var sortControls: some View {
        HStack(spacing: 4) {
            Picker("정렬", selection: $model.sortOrder.key) {
                ForEach(MemoSortKey.allCases, id: \.self) { key in
                    Text(key.label).tag(key)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 96)

            Button {
                model.sortOrder.ascending.toggle()
            } label: {
                Image(systemName: model.sortOrder.ascending ? "arrow.up" : "arrow.down")
            }
            .help(model.sortOrder.ascending ? "오름차순" : "내림차순")
        }
    }

    // MARK: - 왼쪽: 그룹 (LST-02, LST-03)

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("보기") {
                rows(model.viewSidebarItems)
            }
            Section("그룹") {
                rows(model.groupSidebarItems)
            }
            Section {
                sidebarRow(scope: .trash, count: model.store.trashed.count)
                    .tag(MemoListModel.Scope.trash)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        .safeAreaInset(edge: .bottom) {
            GroupEditor(store: model.store)
                .padding(8)
        }
    }

    private func rows(_ items: [(scope: MemoListModel.Scope, count: Int)]) -> some View {
        ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            sidebarRow(scope: item.scope, count: item.count)
                .tag(item.scope)
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
        case .visible: return "eye"
        case .hidden: return "eye.slash"
        case .group: return "folder"
        case .ungrouped: return "tray"
        case .trash: return "trash"
        }
    }

    // MARK: - 오른쪽: 목록 (LST-01, SRC-*)

    /// 여러 개 고르기 (LST-05).
    ///
    /// ⌘ 클릭으로 하나씩 더하고 빼고, ⇧ 클릭으로 사이를 한꺼번에 고른다. ⌘A는 전체.
    /// ⌃ 클릭도 ⌘ 클릭처럼 하나씩 고른다 (MemoListWindowController 참고).
    /// 줄마다 탭 동작을 걸면 이 클릭들을 가로채므로, 두 번 누르기와 우클릭 메뉴는
    /// 목록 전체에 한 번만 건다.
    private var memoList: some View {
        VStack(spacing: 0) {
            if model.visibleMemos.isEmpty {
                emptyState
            } else {
                List(model.visibleMemos, selection: $model.selection) { memo in
                    MemoRow(
                        memo: memo,
                        showsDeletedDate: model.isShowingTrash,
                        isOnScreen: model.isShowingTrash ? nil : model.windowActions.isVisible(memo.id),
                        onToggleOnScreen: { model.toggleVisibility(of: memo.id) }
                    )
                        .tag(memo.id)
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: MemoID.self) { ids in
                    rowMenu(for: model.targets(for: ids))
                } primaryAction: { ids in
                    // 두 번 누르거나 엔터: 고른 메모를 모두 연다. 휴지통에서는 열 수 없다.
                    guard !model.isShowingTrash else { return }
                    openMemos(model.targets(for: ids))
                }
                .onDeleteCommand {
                    // Delete 키: 목록에서는 휴지통으로, 휴지통에서는 영구 삭제(확인 후).
                    let ids = model.orderedSelection
                    guard !ids.isEmpty else { return }
                    if model.isShowingTrash {
                        pendingPermanentDelete = ids
                    } else {
                        model.moveToTrash(ids)
                    }
                }
            }
            selectionBar
        }
    }

    /// 아래 줄: 몇 개를 골랐는지, 고른 것에 바로 할 수 있는 일.
    /// 버튼 줄까지 눈을 옮기지 않고 고른 자리 가까이에서 처리하게 한다.
    @ViewBuilder
    private var selectionBar: some View {
        let ids = model.orderedSelection
        let note = trashNote
        if !ids.isEmpty || note != nil {
            Divider()
            HStack(spacing: 8) {
                if ids.isEmpty {
                    if let note {
                        Label(note, systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(ids.count)개 선택됨")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("선택 해제") { model.selection = [] }
                        .buttonStyle(.link)
                }
                Spacer()
                if !ids.isEmpty {
                    if model.isShowingTrash {
                        Button {
                            model.restore(ids)
                        } label: {
                            Label("복원", systemImage: "arrow.uturn.backward")
                        }
                        Button(role: .destructive) {
                            pendingPermanentDelete = ids
                        } label: {
                            Label("영구 삭제", systemImage: "trash.slash")
                        }
                    } else {
                        Button {
                            openMemos(ids)
                        } label: {
                            Label("열기", systemImage: "macwindow")
                        }
                        Button(role: .destructive) {
                            model.moveToTrash(ids)
                        } label: {
                            Label("휴지통으로", systemImage: "trash")
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// 휴지통에서만 보이는 안내. 자동 비우기가 꺼져 있으면 그렇다고 알린다.
    private var trashNote: String? {
        guard model.isShowingTrash else { return nil }
        if let days = model.trashRetentionDays() {
            return "휴지통에 들어간 지 \(days)일이 지나면 자동으로 지워집니다"
        }
        return "자동 비우기가 꺼져 있습니다. 직접 비울 때까지 남습니다"
    }

    /// 하나면 그 창을 앞으로 가져오고, 여럿이면 모두 띄운다.
    private func openMemos(_ ids: [MemoID]) {
        if ids.count == 1, let id = ids.first {
            onOpenMemo(id)
            model.noteWindowStateChanged()
        } else {
            model.open(ids)
        }
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

    /// 우클릭 메뉴. 여러 개를 골라 두었으면 그 전부에 적용된다.
    @ViewBuilder
    private func rowMenu(for ids: [MemoID]) -> some View {
        let suffix = ids.count > 1 ? " (\(ids.count)개)" : ""
        if ids.isEmpty {
            EmptyView()
        } else if model.isShowingTrash {
            Button("복원" + suffix) {
                model.restore(ids)
            }
            Button("영구 삭제" + suffix + "…", role: .destructive) {
                pendingPermanentDelete = ids
            }
        } else {
            Button("열기" + suffix) { openMemos(ids) }
            Divider()
            Menu("그룹으로 이동" + suffix) {
                Button("그룹 없음") { model.assign(ids, to: nil) }
                ForEach(model.store.groups, id: \.self) { group in
                    Button(group) { model.assign(ids, to: group) }
                }
            }
            Divider()
            Button("휴지통으로 이동" + suffix, role: .destructive) {
                model.moveToTrash(ids)
            }
        }
    }
}

/// 목록 한 줄 (LST-01).
private struct MemoRow: View {
    let memo: MemoSummary
    let showsDeletedDate: Bool
    /// 창이 화면에 떠 있는가. 휴지통에서는 뜻이 없으므로 nil.
    let isOnScreen: Bool?
    let onToggleOnScreen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let isOnScreen {
                // 한 줄에서 바로 띄우고 내릴 수 있어야 목록과 화면을 오가지 않는다 (LST-10).
                Button(action: onToggleOnScreen) {
                    Image(systemName: isOnScreen ? "eye" : "eye.slash")
                        .foregroundStyle(isOnScreen ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .frame(width: 18)
                .help(isOnScreen ? "화면에서 내리기" : "화면에 띄우기")
            }

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
