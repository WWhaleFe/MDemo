import AppKit
import MemoCore
import SwiftUI

public struct MemoListView: View {
    @Bindable private var model: MemoListModel
    private let onOpenMemo: (MemoID) -> Void
    private let onCreateMemo: () -> Void
    @AppStorage("memoList.viewMode") private var savedMode = MemoListModel.ViewMode.list.rawValue
    @State private var isConfirmingBulkOpen = false
    @State private var pendingPermanentDelete: [MemoID] = []
    @State private var addingGroup = false
    @State private var groupName = ""
    @State private var anchor: MemoID?
    @State private var boardTarget: MemoID?
    @FocusState private var searchFocused: Bool
    @FocusState private var cardsFocused: Bool

    public init(model: MemoListModel, onOpenMemo: @escaping (MemoID) -> Void, onCreateMemo: @escaping () -> Void) {
        self._model = Bindable(model)
        self.onOpenMemo = onOpenMemo
        self.onCreateMemo = onCreateMemo
    }
    private var mode: MemoListModel.ViewMode { MemoListModel.ViewMode(rawValue: savedMode) ?? .list }

    public var body: some View {
        let memos = model.visibleMemos
        let index = model.linkIndex
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(ListTheme.hairline).frame(height: 1)
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(ListTheme.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    if mode == .board && !model.isShowingTrash {
                        BoardView(model: model, memos: memos, index: index, target: $boardTarget,
                                  onOpen: { openMemos([$0]) }, onCreate: onCreateMemo, menu: { id in AnyView(rowMenu(for: menuTargets(id), index: index)) })
                    } else {
                        contentHeader(count: memos.count)
                        if memos.isEmpty { emptyState }
                        else if mode == .list || model.isShowingTrash && mode == .board { rows(memos, index: index) }
                        else { cards(memos, index: index) }
                    }
                    selectionBar(index: index)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 13)).foregroundStyle(ListTheme.ink).tint(ListTheme.ink).background(ListTheme.windowBg)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { model.refresh() }
        .onChange(of: model.scope) { _, _ in anchor = nil }
        .background {
            Button("검색") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
        .confirmationDialog("메모 \(model.visibleMemos.count)개를 모두 띄울까요?", isPresented: $isConfirmingBulkOpen, titleVisibility: .visible) {
            Button("모두 띄우기") { model.showAll() }
            Button("취소", role: .cancel) {}
        } message: { Text("창 하나마다 본문이 메모리에 올라옵니다. 화면이 가득 찰 수 있습니다") }
        .confirmationDialog("메모 \(pendingPermanentDelete.count)개를 영구 삭제할까요?", isPresented: Binding(
            get: { !pendingPermanentDelete.isEmpty }, set: { if !$0 { pendingPermanentDelete = [] } }), titleVisibility: .visible) {
                Button("영구 삭제", role: .destructive) { model.deletePermanently(pendingPermanentDelete); pendingPermanentDelete = [] }
                Button("취소", role: .cancel) { pendingPermanentDelete = [] }
            } message: { Text("첨부 이미지까지 함께 지워지며 되돌릴 수 없습니다") }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Color.clear.frame(minWidth: 72, idealWidth: 208, maxWidth: 208).layoutPriority(-2)
            HStack(spacing: 0) {
                ForEach(MemoListModel.ViewMode.allCases, id: \.self) { item in
                    Button { savedMode = item.rawValue } label: {
                        HStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 16))
                            Text(item.label).font(.system(size: 13, weight: mode == item ? .semibold : .regular))
                        }.padding(.horizontal, 8).frame(height: 28)
                            .background(mode == item ? ListTheme.card : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .shadow(color: mode == item ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
                    }.buttonStyle(.plain)
                }
            }.padding(3).background(ListTheme.track, in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 0)
            Menu {
                Button("지금 목록 모두 띄우기") {
                    if model.needsBulkOpenConfirmation { isConfirmingBulkOpen = true } else { model.showAll() }
                }.disabled(model.isShowingTrash || model.visibleMemos.isEmpty)
                Button("모두 내리기") { model.hideAll() }
                Button("고른 메모 띄우기") { model.showSelection() }.disabled(model.isShowingTrash || model.selection.isEmpty)
                Divider()
                Button("창 나열") { model.arrangeWindows(byGroup: false) }
                Button("그룹별로 나열") { model.arrangeWindows(byGroup: true) }
            } label: { Label("창", systemImage: "macwindow.on.rectangle") }.fixedSize().menuStyle(.borderlessButton)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(ListTheme.muted)
                TextField("검색", text: $model.query).textFieldStyle(.plain).focused($searchFocused)
                if model.query.isEmpty {
                    Text("⌘F").font(.system(size: 12)).foregroundStyle(ListTheme.muted).padding(2).background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 4))
                } else {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(ListTheme.muted)
                }
            }.padding(.horizontal, 8).frame(width: 220, height: 32)
                .background(ListTheme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ListTheme.hairline))
                .layoutPriority(-1)
            Button(action: onCreateMemo) {
                Label("새 메모", systemImage: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(ListTheme.card)
                    .padding(.horizontal, 12).frame(height: 32).background(ListTheme.ink, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).fixedSize().help("새 메모 (어디서든 ⌘⇧N)")
        }.padding(.horizontal, 12).frame(height: 52)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.viewSidebarItems, id: \.scope) { item in sidebarRow(item.scope, title: item.scope.title, count: item.count) }
                    HStack {
                        Text("모음").font(.system(size: 12, weight: .medium)).foregroundStyle(ListTheme.muted)
                        Spacer()
                        Button { addingGroup.toggle() } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                            .popover(isPresented: $addingGroup) {
                                HStack {
                                    TextField("새 그룹", text: $groupName).onSubmit(addGroup)
                                    Button("추가", action: addGroup).disabled(groupName.trimmingCharacters(in: .whitespaces).isEmpty)
                                }.padding(16).frame(width: 260)
                            }
                    }.padding(.top, 20).padding(.bottom, 6).padding(.horizontal, 8)
                    ForEach(model.groupSidebarItems, id: \.scope) { item in sidebarRow(item.scope, title: item.scope.title, count: item.count) }
                    Text("흐름").font(.system(size: 12, weight: .medium)).foregroundStyle(ListTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 6)
                    ForEach(model.flowSidebarItems, id: \.scope) { item in sidebarRow(item.scope, title: item.title, count: item.count) }
                    if model.flowSidebarItems.isEmpty {
                        Text("보드에서 메모를 이어 보세요").font(.system(size: 12)).foregroundStyle(ListTheme.muted).padding(.horizontal, 8)
                    }
                }
            }
            sidebarRow(.trash, title: "휴지통", count: model.store.trashed.count)
        }.padding(12).frame(width: 232).background(ListTheme.sidebarBg)
    }

    private func sidebarRow(_ scope: MemoListModel.Scope, title: String, count: Int) -> some View {
        SidebarButton(selected: model.scope == scope, action: { model.prepare(for: scope) }) {
            HStack(spacing: 8) {
                Group {
                    if scope == .visible { LimeDot() }
                    else if case .flow = scope { FlowSymbol().stroke(ListTheme.ink, lineWidth: 1.5).frame(height: 12) }
                    else { Image(systemName: sidebarIcon(scope)) }
                }.frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(ListTheme.muted)
            }
        }.contextMenu {
            if case .group(let name) = scope {
                Button("그룹 삭제", role: .destructive) {
                    model.store.deleteGroup(name)
                    if model.scope == scope { model.prepare(for: .all) }
                }
            }
            if scope == .trash { Button("휴지통 비우기", role: .destructive) { model.store.emptyTrash() }.disabled(model.store.trashed.isEmpty) }
        }
    }
    private func sidebarIcon(_ scope: MemoListModel.Scope) -> String {
        switch scope {
        case .all: "tray.full"
        case .visible: "circle.fill"
        case .hidden: "rectangle.on.rectangle.slash"
        case .group: "folder"
        case .ungrouped: "tray"
        case .trash: "trash"
        case .flow: "line.diagonal"
        }
    }
    private func addGroup() {
        let name = groupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.store.createGroup(named: name); groupName = ""; addingGroup = false
    }

    private func contentHeader(count: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(model.scopeTitle).font(.system(size: 20, weight: .bold)).lineLimit(1)
            Text("\(count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(ListTheme.muted)
            Spacer()
            if mode == .bento { Text("연결이 많고 최근에 고친 메모일수록 크게").font(.system(size: 12)).foregroundStyle(ListTheme.muted) }
            Menu {
                Picker("정렬", selection: $model.sortOrder.key) {
                    ForEach(MemoSortKey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button(model.sortOrder.ascending ? "내림차순" : "오름차순") { model.sortOrder.ascending.toggle() }
            } label: {
                Text(model.sortOrder.key == .modified ? "최근 수정 순" : model.sortOrder.key.label + " 순")
            }.menuStyle(.borderlessButton).fixedSize()
        }.padding(.horizontal, 32).padding(.vertical, 24)
    }

    private func sections(_ memos: [MemoSummary]) -> [(String, [MemoSummary])] {
        if case .flow = model.scope { return [("", memos)] }
        if model.sortOrder.key != .modified { return [("", memos)] }
        let calendar = Calendar.current
        let now = Date()
        func bucket(_ memo: MemoSummary) -> String {
            let date = model.isShowingTrash ? memo.deletedAt ?? memo.meta.modified : memo.meta.modified
            if calendar.isDateInToday(date) { return "오늘" }
            if calendar.isDateInYesterday(date) { return "어제" }
            if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "이번 주" }
            if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "이번 달" }
            return "이전"
        }
        let groups = Dictionary(grouping: memos, by: bucket)
        let names = model.sortOrder.ascending ? ["이전", "이번 달", "이번 주", "어제", "오늘"] : ["오늘", "어제", "이번 주", "이번 달", "이전"]
        return names.compactMap { name in groups[name].map { (name, $0) } }
    }

    private func rows(_ memos: [MemoSummary], index: MemoListModel.LinkIndex) -> some View {
        List(selection: $model.selection) {
            ForEach(sections(memos), id: \.0) { title, items in
                Section {
                    ForEach(items) { memo in
                        HStack(spacing: 12) {
                            MemoColorChip(memo: memo)
                            HStack(spacing: 4) {
                                Text(memo.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                if memo.meta.conflictOf != nil { ConflictChip() }
                            }.frame(maxWidth: 240, alignment: .leading)
                            Text(memo.cleanedPreview(singleLine: true)).foregroundStyle(ListTheme.text2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            MemoLinkChip(id: memo.id, index: index).frame(width: 136, alignment: .leading)
                            Group { if !model.isShowingTrash && model.windowActions.isVisible(memo.id) { LimeDot() } else { Color.clear } }.frame(width: 8, height: 8)
                            VStack(alignment: .trailing, spacing: 0) {
                                Text(memo.listDate(trash: model.isShowingTrash)).lineLimit(1).fixedSize(horizontal: false, vertical: true)
                                if let group = memo.meta.group { Text(group).lineLimit(1) }
                            }.font(.system(size: 12).monospacedDigit()).foregroundStyle(ListTheme.muted).frame(width: 72, alignment: .trailing)
                        }.frame(height: 48).tag(memo.id).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparatorTint(ListTheme.hairline)
                    }
                } header: {
                    if !title.isEmpty { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ListTheme.muted) }
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: MemoID.self) { ids in rowMenu(for: model.targets(for: ids), index: index) } primaryAction: { ids in
                if !model.isShowingTrash { openMemos(model.targets(for: ids)) }
            }
            .onDeleteCommand(perform: deleteSelected)
    }

    private func cards(_ memos: [MemoSummary], index: MemoListModel.LinkIndex) -> some View {
        let spans = model.bentoSpans(for: memos)
        return ScrollView {
            Group {
                if mode == .bento {
                    BentoLayout {
                        ForEach(memos.enumerated().sorted { a, b in
                            let order: [BoardLayout.BentoSpan] = [.large, .wide, .tall, .small]
                            let x = order.firstIndex(of: spans[a.element.id] ?? .small)!
                            let y = order.firstIndex(of: spans[b.element.id] ?? .small)!
                            return x == y ? a.offset < b.offset : x < y
                        }.map(\.element)) { memo in card(memo, index: index, span: spans[memo.id] ?? .small).bentoSpan(spans[memo.id] ?? .small) }
                        if canCreateTile { newTile.bentoSpan(.small) }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                        ForEach(memos) { memo in card(memo, index: index, span: .small).frame(height: 176) }
                        if canCreateTile { newTile.frame(height: 176) }
                    }
                }
            }.padding(.horizontal, 32).padding(.bottom, 32)
        }.focusable().focused($cardsFocused).focusEffectDisabled()
            .background(ListKeyboardCommands(selectAll: { model.selectAllVisible() }, delete: deleteSelected,
                                             open: { if !model.isShowingTrash { openMemos(model.orderedSelection) } }))
            .onDeleteCommand(perform: deleteSelected)
            .onKeyPress(.return) { if !model.isShowingTrash { openMemos(model.orderedSelection) }; return .handled }
            .onKeyPress("a", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAllVisible(); return .handled
            }
    }
    private func card(_ memo: MemoSummary, index: MemoListModel.LinkIndex, span: BoardLayout.BentoSpan) -> some View {
        MemoCardView(memo: memo, index: index, visible: !model.isShowingTrash && model.windowActions.isVisible(memo.id), trash: model.isShowingTrash, span: span, select: { model.selection = [$0] })
            .modifier(CardSurface(selected: model.selection.contains(memo.id)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture(count: 2) { if !model.isShowingTrash { openMemos([memo.id]) } }
            .onTapGesture { select(memo.id) }
            .contextMenu {
                rowMenu(for: menuTargets(memo.id), index: index)
                if mode == .bento {
                    Divider()
                    Menu("크기") {
                        Button("자동") { model.setBentoSpan(nil, for: memo.id) }
                        ForEach(BoardLayout.BentoSpan.allCases, id: \.self) { span in
                            Button(spanLabel(span)) { model.setBentoSpan(span, for: memo.id) }
                        }
                    }
                }
            }
    }
    private var canCreateTile: Bool { !model.isShowingTrash && model.query.isEmpty }
    private var newTile: some View {
        Button(action: onCreateMemo) { Label("새 메모", systemImage: "plus").frame(maxWidth: .infinity, maxHeight: .infinity) }
            .buttonStyle(.plain).foregroundStyle(ListTheme.muted).background(PlaceholderSurface())
    }
    private func spanLabel(_ span: BoardLayout.BentoSpan) -> String {
        switch span { case .small: "작게"; case .wide: "가로로 길게"; case .tall: "세로로 길게"; case .large: "크게" }
    }
    private func select(_ id: MemoID) {
        cardsFocused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let ids = model.visibleMemos.map(\.id)
        if flags.contains(.shift), let anchor, let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: id) {
            model.selection.formUnion(ids[min(start, end)...max(start, end)])
        } else if flags.contains(.command) || flags.contains(.control) {
            if !model.selection.insert(id).inserted { model.selection.remove(id) }
            anchor = id
        } else { model.selection = [id]; anchor = id }
    }
    private func menuTargets(_ id: MemoID) -> [MemoID] { model.selection.contains(id) ? model.orderedSelection : [id] }

    @ViewBuilder private func selectionBar(index: MemoListModel.LinkIndex) -> some View {
        let ids = model.orderedSelection
        if !ids.isEmpty || model.isShowingTrash {
            VStack(spacing: 8) {
                // 보드에서는 왼쪽 위 흐름 띠가 같은 일을 하므로 아래 흐름 줄을 두지 않는다.
                if savedMode != "board", ids.count == 1, let id = ids.first, let context = index.flowByMemo[id] {
                    HStack {
                        FlowChips(flow: context.flow, current: id, index: index, select: { model.selection = [$0] })
                        Button("보드에서 보기") { savedMode = "board"; boardTarget = id }
                    }
                }
                HStack(spacing: 8) {
                    if !ids.isEmpty {
                        Text("\(ids.count)개 선택됨").monospacedDigit().foregroundStyle(ListTheme.muted)
                        Button("선택 해제") { model.selection = [] }
                    }
                    Spacer()
                    if !ids.isEmpty {
                        if model.isShowingTrash {
                            Button("복원") { model.restore(ids) }
                            Button("영구 삭제", role: .destructive) { pendingPermanentDelete = ids }
                        } else {
                            Button("열기") { openMemos(ids) }
                            Button("휴지통으로", role: .destructive) { model.moveToTrash(ids) }
                        }
                    }
                }
                if model.isShowingTrash {
                    Text(model.trashRetentionDays().map { "휴지통에 들어간 지 \($0)일이 지나면 자동으로 지워집니다" } ?? "자동 비우기가 꺼져 있습니다. 직접 비울 때까지 남습니다")
                        .font(.system(size: 12)).foregroundStyle(ListTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.bordered).padding(12).background(ListTheme.windowBg)
                .overlay(alignment: .top) { Rectangle().fill(ListTheme.hairline).frame(height: 1) }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(model.query.isEmpty ? "메모가 없습니다" : "찾는 메모가 없습니다").foregroundStyle(ListTheme.muted)
            if !model.isShowingTrash { Button("새 메모 만들기", action: onCreateMemo).buttonStyle(.link).tint(ListTheme.ink) }
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private func deleteSelected() {
        let ids = model.orderedSelection
        guard !ids.isEmpty else { return }
        if model.isShowingTrash { pendingPermanentDelete = ids } else { model.moveToTrash(ids) }
    }
    private func openMemos(_ ids: [MemoID]) {
        if ids.count == 1, let id = ids.first { onOpenMemo(id); model.noteWindowStateChanged() }
        else { model.open(ids) }
    }
    @ViewBuilder private func rowMenu(for ids: [MemoID], index: MemoListModel.LinkIndex) -> some View {
        if !ids.isEmpty {
            if model.isShowingTrash {
                Button("복원") { model.restore(ids) }
                Button("영구 삭제…", role: .destructive) { pendingPermanentDelete = ids }
            } else {
                Button("열기") { openMemos(ids) }
                Button("화면에 띄우기") { model.open(ids) }
                Button("화면에서 내리기") { model.windowActions.hide(ids); model.noteWindowStateChanged() }
                Menu("그룹으로 이동") {
                    Button("미분류") { model.assign(ids, to: nil) }
                    ForEach(model.store.groups, id: \.self) { group in Button(group) { model.assign(ids, to: group) } }
                }
                if ids.count == 1, let id = ids.first {
                    let edges = index.edges.filter { $0.from == id || $0.to == id }
                    if !edges.isEmpty {
                        Menu("연결") {
                            ForEach(edges, id: \.self) { edge in
                                Button("\(index.summaries[edge.from == id ? edge.to : edge.from]?.title ?? "메모")와 연결 끊기") { model.unlink(edge.from, edge.to) }
                            }
                        }
                    }
                }
                Divider()
                Button("휴지통으로 이동", role: .destructive) { model.moveToTrash(ids) }
            }
        }
    }
}

private struct SidebarButton<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            content().font(.system(size: 13, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8).frame(height: 32)
                .background(selected ? ListTheme.card : hovered ? ListTheme.ink.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: selected ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}
