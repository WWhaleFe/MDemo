import AppKit
import MemoCore
import SwiftUI

/// 모든 파이프를 한 캔버스에 그리며 카드만 화면 근처에서 만든다
struct BoardView: View {
    @AppStorage("board.lineButtonStyle", store: AppSettings.defaults) private var lineButtonStyle = "A"
    @Bindable var model: MemoListModel
    let memos: [MemoSummary]
    let index: MemoListModel.LinkIndex
    @Binding var target: MemoID?
    let onOpen: (MemoID) -> Void
    let onCreate: () -> Void
    let menu: (MemoID) -> AnyView
    @Environment(\.undoManager) private var undoManager
    @State private var showsExport = false
    @AppStorage("board.showPipeLabels", store: AppSettings.defaults) private var showLabels = true
    @State private var hoveredEdge: MemoEdge?
    @State private var editingEdge: MemoEdge?
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var minimapDrag: MinimapDrag?
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?
    @State private var moving: [MemoID: BoardLayout.Placement] = [:]
    @State private var dragOrigins: [MemoID: BoardLayout.Placement] = [:]
    @State private var linkStart: MemoID?
    @State private var linkPort = CGPoint.zero
    @State private var linkPointer: CGPoint?
    @State private var selectedEdge: MemoEdge?
    @State private var kind = MemoLinkKind.flow
    @FocusState private var focused: Bool

    /// 이 비율보다 작게 보면 카드를 SwiftUI 뷰로 만들지 않고 캔버스에 직접 그린다.
    /// 이보다 작게 축소하면 카드를 간단한 그림으로 그린다. 너무 높으면 조금만 축소해도 카드 모양이 바뀌어 배치가 달라진 것처럼 보인다.
    static let flatZoom: CGFloat = 0.35
    private var flat: Bool { zoom < Self.flatZoom }
    private var highlightedEdge: MemoEdge? { selectedEdge ?? hoveredEdge }
    private func cardOpacity(_ id: MemoID) -> Double {
        guard let edge = highlightedEdge else { return 1 }
        return edge.from == id || edge.to == id ? 1 : 0.45
    }

    private func dragPipes(positions: [MemoID: BoardLayout.Placement]) -> [PipeGeometry] {
        let fixed = model.boardPipes(for: memos, edges: index.edges)
            .filter { moving[$0.edge.from] == nil && moving[$0.edge.to] == nil }
        let touching = index.edges.filter { moving[$0.from] != nil || moving[$0.to] != nil }
        return fixed + PipeGeometry.make(edges: touching, positions: positions, avoiding: fixed)
    }
    private func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height) }
    private func world(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom) }
    private func rect(_ placement: BoardLayout.Placement) -> CGRect { CGRect(x: placement.x, y: placement.y, width: 200, height: 120) }
    private func placements() -> [MemoID: BoardLayout.Placement] {
        let base = model.boardPlacements(for: memos)
        return moving.isEmpty ? base : base.merging(moving) { _, new in new }
    }

    var body: some View {
        GeometryReader { geo in
            let positions = placements()
            let viewport = CGRect(origin: world(.zero), size: CGSize(width: geo.size.width / zoom, height: geo.size.height / zoom))
            // 드래그 중이 아니면 모델이 계산해 둔 파이프를 쓴다.
            // 끄는 중에는 옮기는 카드에 붙은 선만 새 길을 찾고, 나머지는 저장된 길을 피해 가게 한다. 놓으면 전체를 다시 계산한다.
            let pipes = moving.isEmpty ? model.boardPipes(for: memos, edges: index.edges) : dragPipes(positions: positions)
            let endpoints = moving.isEmpty ? model.boardEndpoints(for: memos, edges: index.edges) : PipeGeometry.endpoints(of: pipes)
            ZStack(alignment: .topLeading) {
                ListTheme.boardBg
                background(size: geo.size, pipes: pipes, positions: positions, viewport: viewport)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        focused = true
                        if panOrigin == nil { panOrigin = pan }
                        if let origin = panOrigin, value.translation.width * value.translation.width + value.translation.height * value.translation.height > 9 {
                            pan = CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height)
                        }
                    }.onEnded { value in
                        if abs(value.translation.width) + abs(value.translation.height) < 4 {
                            if flat, let id = hitCard(at: world(value.location), positions: positions, excluding: nil) {
                                select(id); focused = true; panOrigin = nil; return
                            }
                            selectedEdge = pipes.reversed().first { $0.distance(to: world(value.location)) * zoom <= 6 }?.edge
                            if selectedEdge == nil { model.selection = [] }
                        }
                        panOrigin = nil
                    })
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                        if flat, let id = hitCard(at: world(value.location), positions: positions, excluding: nil) { onOpen(id) }
                        else if !flat, let edge = pipes.reversed().first(where: { $0.distance(to: world(value.location)) * zoom <= 8 })?.edge {
                            selectedEdge = edge; editingEdge = edge
                        }
                    })
                if !flat {
                    ForEach(Array(pipes.enumerated()), id: \.offset) { _, pipe in
                        if showLabels || hoveredEdge == pipe.edge || selectedEdge == pipe.edge || editingEdge == pipe.edge {
                            pipeLabel(pipe, positions: positions)
                                .opacity(highlightedEdge == nil || highlightedEdge == pipe.edge ? 1 : 0.18)
                        }
                    }
                }
                if memos.isEmpty {
                    VStack(spacing: 12) {
                        Text(model.appliedQuery.isEmpty ? "메모가 없습니다" : "찾는 메모가 없습니다").foregroundStyle(ListTheme.muted)
                        Button("새 메모 만들기", action: onCreate).buttonStyle(.plain)
                    }.frame(width: geo.size.width, height: geo.size.height)
                }
                if !flat {
                    ForEach(memos.filter { memo in positions[memo.id].map { rect($0).intersects(viewport.insetBy(dx: -240, dy: -160)) } ?? false }) { memo in
                        if let placement = positions[memo.id] {
                            boardCard(memo, placement: placement, positions: positions, endpoints: endpoints[memo.id] ?? []).opacity(cardOpacity(memo.id))
                        }
                    }
                }
                if let start = linkStart, let pointer = linkPointer {
                    let drop = hitCard(at: world(pointer), positions: positions, excluding: start)
                    if let drop, let placement = positions[drop] {
                        PlaceholderSurface().overlay(Text("여기에 놓아 연결").font(.system(size: 12)).padding(4).background(ListTheme.card))
                            .frame(width: 200 * zoom, height: 120 * zoom)
                            .position(screen(CGPoint(x: placement.x + 100, y: placement.y + 60))).allowsHitTesting(false)
                    }
                }
                if flat, let edge = selectedEdge, let pipe = pipes.first(where: { $0.edge == edge }) {
                    Button("연결 끊기") { model.unlink(edge.from, edge.to, undoManager: undoManager); selectedEdge = nil }
                        .buttonStyle(.plain).font(.system(size: 12)).padding(8)
                        .background(ListTheme.card, in: RoundedRectangle(cornerRadius: 6)).position(screen(pipe.midpoint))
                }
                VStack(spacing: 10) {
                    // 선 도구는 보드 위쪽 막대로 따로 둔다. 아래 막대는 배치 · 확대 · 내보내기만.
                    HStack { Spacer(minLength: 0); lineToolbar(size: geo.size); Spacer(minLength: 0) }
                    flowStrip
                    Spacer()
                    ScrollView(.horizontal) {
                        HStack {
                            Spacer(minLength: 0)
                            boardToolbar(size: geo.size, positions: positions)
                            Spacer(minLength: 0)
                        }.frame(minWidth: max(0, geo.size.width - 32))
                    }.scrollIndicators(.hidden).frame(height: 52).padding(.bottom, 16)
                }.padding(16).allowsHitTesting(true)
                VStack {
                    Spacer()
                    HStack { Spacer(); minimap(viewport: viewport, positions: positions, size: geo.size) }
                }.padding(16).padding(.bottom, 60).allowsHitTesting(true)
            }
            .background(ListKeyboardCommands(selectAll: { model.selectAllVisible() }, delete: deleteSelection,
                                             open: { for id in model.orderedSelection { onOpen(id) } },
                                             paste: { paste(at: geo.size) }, fit: { fit(size: geo.size, positions: positions) },
                                             undo: { undoManager?.undo() }, redo: { undoManager?.redo() }))
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    hoveredEdge = hitCard(at: world(location), positions: positions, excluding: nil) == nil
                        ? pipes.reversed().first { $0.distance(to: world(location)) * zoom <= 6 }?.edge : nil
                } else { hoveredEdge = nil }
            }
            .clipped().coordinateSpace(name: "메모보드")
            .focusable().focused($focused).focusEffectDisabled()
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if zoomOrigin == nil { zoomOrigin = zoom }
                changeZoom((zoomOrigin ?? zoom) * value.magnification, size: geo.size)
            }.onEnded { _ in zoomOrigin = nil })
            .onDeleteCommand(perform: deleteSelection)
            .onKeyPress(.return) {
                for id in model.orderedSelection { onOpen(id) }; return .handled
            }
            .onKeyPress("a", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.selectAllVisible(); return .handled
            }
            .onKeyPress("0", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                fit(size: geo.size, positions: positions); return .handled
            }
            .onKeyPress("v", phases: .down) { press in
                guard press.modifiers.contains(.command), let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return .ignored }
                let center = world(CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
                model.pasteMemo(text, at: .init(x: center.x - 100, y: center.y - 60), undoManager: undoManager); return .handled
            }
            .sheet(isPresented: $showsExport) {
                BoardExportSheet(model: model, memos: memos, index: index)
            }
            .onChange(of: index.edges) { _, edges in
                if let selectedEdge {
                    self.selectedEdge = edges.first {
                        ($0.from == selectedEdge.from && $0.to == selectedEdge.to) ||
                        ($0.from == selectedEdge.to && $0.to == selectedEdge.from)
                    }
                }
            }
            .onChange(of: target) { _, id in if let id { center(on: id, size: geo.size, positions: positions) } }
            .onAppear {
                // 보기를 바꾸는 애니메이션이 줌과 이동에 번지지 않게 한다.
                withTransaction(Transaction(animation: nil)) { initialFit(size: geo.size, positions: positions) }
            }
            .onChange(of: model.scope) { _, _ in initialFit(size: geo.size, positions: positions) }
        }
    }

    private func deleteSelection() {
        if let selectedEdge { model.unlink(selectedEdge.from, selectedEdge.to, undoManager: undoManager); self.selectedEdge = nil }
        else { model.moveSelectionToTrash() }
    }
    private func paste(at size: CGSize) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let center = world(CGPoint(x: size.width / 2, y: size.height / 2))
        model.pasteMemo(text, at: .init(x: center.x - 100, y: center.y - 60), undoManager: undoManager)
    }

    private func background(size: CGSize, pipes: [PipeGeometry], positions: [MemoID: BoardLayout.Placement], viewport: CGRect) -> some View {
        Canvas { context, canvasSize in
            // 멀리서 볼 때 점 간격이 좁아지면 점이 수십만 개가 되어 그리기와 메모리가 크게 늘어난다.
            // 화면에서 16pt보다 좁아지면 격자를 두 배씩 성기게 한다.
            var step = 20 * zoom
            while step < 16 { step *= 2 }
            let x0 = pan.width.truncatingRemainder(dividingBy: step)
            let y0 = pan.height.truncatingRemainder(dividingBy: step)
            var dots = Path()
            for x in stride(from: x0, through: canvasSize.width, by: step) {
                for y in stride(from: y0, through: canvasSize.height, by: step) {
                    dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(ListTheme.boardDot))
            context.translateBy(x: pan.width, y: pan.height)
            context.scaleBy(x: zoom, y: zoom)
            PipeGeometry.drawAll(pipes, in: &context, background: ListTheme.boardBg,
                                 highlighted: highlightedEdge, dimOthers: highlightedEdge != nil)
            if flat {
                drawFlatCards(context: &context, positions: positions, viewport: viewport, endpoints: PipeGeometry.endpoints(of: pipes))
            }
            if linkStart != nil, let pointer = linkPointer {
                var line = Path(); line.move(to: linkPort); line.addLine(to: world(pointer))
                context.stroke(line, with: .color(ListTheme.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            }
        }
    }

    /// 멀리서 볼 때 카드를 캔버스에 직접 그린다. 보이는 영역 근처 카드만 그린다.
    private func drawFlatCards(context: inout GraphicsContext, positions: [MemoID: BoardLayout.Placement], viewport: CGRect, endpoints: [MemoID: [CGPoint]]) {
        let near = viewport.insetBy(dx: -40, dy: -40)
        for memo in memos {
            var context = context
            context.opacity *= cardOpacity(memo.id)
            guard let placement = positions[memo.id] else { continue }
            let bounds = rect(placement)
            guard bounds.intersects(near) else { continue }
            let shape = Path(roundedRect: bounds, cornerRadius: 14)
            let selected = model.selection.contains(memo.id)
            context.fill(shape, with: .color(ListTheme.card))
            context.stroke(shape, with: .color(selected ? ListTheme.ink : ListTheme.hairline), lineWidth: selected ? 2 / zoom : 1 / zoom)
            let rgb = MemoColor.components(fromHex: memo.meta.colorHex)
            let chip = CGRect(x: bounds.minX + 14, y: bounds.minY + 14, width: 10, height: 10)
            context.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(Color(red: rgb?.red ?? 0.5, green: rgb?.green ?? 0.5, blue: rgb?.blue ?? 0.5)))
            let shown = model.windowActions.isVisible(memo.id)
            let textRect = CGRect(x: chip.maxX + 8, y: bounds.minY + 8, width: bounds.maxX - chip.maxX - (shown ? 36 : 22), height: 22)
            context.drawLayer { layer in
                layer.clip(to: Path(textRect))
                layer.draw(Text(memo.title).font(.system(size: 14, weight: .semibold)).foregroundColor(ListTheme.ink),
                           at: CGPoint(x: textRect.minX, y: textRect.midY), anchor: .leading)
            }
            if shown {
                context.fill(Path(ellipseIn: CGRect(x: bounds.maxX - 22, y: bounds.minY + 15, width: 8, height: 8)), with: .color(ListTheme.lime))
            }
            for point in endpoints[memo.id] ?? [] {
                let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(ListTheme.lime))
                context.stroke(dot, with: .color(ListTheme.ink), lineWidth: 1)
            }
        }
    }

    private func boardCard(_ memo: MemoSummary, placement: BoardLayout.Placement, positions: [MemoID: BoardLayout.Placement], endpoints: [CGPoint]) -> some View {
        let id = memo.id
        let bounds = rect(placement)
        return BoardCardView(
            memo: memo, info: model.cardInfo(for: memo), index: index, visible: model.windowActions.isVisible(id),
            selected: model.selection.contains(id), linking: linkStart == id, bounds: bounds, endpoints: endpoints, zoom: zoom,
            center: screen(CGPoint(x: bounds.midX, y: bounds.midY)), menu: menu(id),
            onSelectOnly: { model.selection = [$0] },
            onTap: { select(id); focused = true },
            onOpen: { onOpen(id) },
            onDragChanged: { translation in
                focused = true
                if dragOrigins.isEmpty {
                    if !model.selection.contains(id) { select(id) }
                    for sel in model.selection { dragOrigins[sel] = positions[sel] }
                }
                for (sel, origin) in dragOrigins {
                    // 선 길찾기가 20pt 격자 위에서 하므로 끄는 동안에도 격자에 맞춘다(놓을 때와 같은 반올림).
                    moving[sel] = .init(x: ((origin.x + translation.width / zoom) / 20).rounded() * 20,
                                        y: ((origin.y + translation.height / zoom) / 20).rounded() * 20)
                }
            },
            onDragEnded: {
                model.moveCards(moving, freezing: memos, undoManager: undoManager)
                moving = [:]; dragOrigins = [:]
            },
            onPortChanged: { point, location in linkStart = id; linkPort = point; linkPointer = location; focused = true },
            onPortEnded: { location in
                if let other = hitCard(at: world(location), positions: positions, excluding: id) { model.link(from: id, to: other, kind: kind, undoManager: undoManager) }
                linkStart = nil; linkPointer = nil
            })
    }
    private func hitCard(at point: CGPoint, positions: [MemoID: BoardLayout.Placement], excluding id: MemoID?) -> MemoID? {
        memos.reversed().first { $0.id != id && positions[$0.id].map { rect($0).contains(point) } == true }?.id
    }
    private func select(_ id: MemoID) {
        selectedEdge = nil
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) || flags.contains(.control) {
            if !model.selection.insert(id).inserted { model.selection.remove(id) }
        } else { model.selection = [id] }
    }
    @ViewBuilder private var flowStrip: some View {
        if let id = model.selection.first, let context = index.flowByMemo[id] {
            HStack(spacing: 12) {
                FlowSymbol().stroke(ListTheme.ink, lineWidth: 1.5).frame(width: 16, height: 16)
                Text(index.title(of: context.flow)).fontWeight(.semibold).lineLimit(1)
                Text("메모 \(context.flow.memoIDs.count)개").foregroundStyle(ListTheme.muted)
                Divider().frame(height: 16)
                Button("모두 띄우기") { model.openFlow(context.flow) }
                Button("순서대로 놓기") { model.arrangeFlow(context.flow) }
            }.buttonStyle(.plain).padding(.horizontal, 12).frame(height: 40).background(ListTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    /// 위쪽 막대: 선 종류 단추 · 더 보기 · 뜻 · 이름표.
    private func lineToolbar(size: CGSize) -> some View {
        BoardLineTools(selected: selectedEdge?.kind ?? kind, availableWidth: max(200, size.width - 52)) { item in
            kind = item
            if let edge = selectedEdge {
                model.changeLink(edge, kind: item, undoManager: undoManager)
                selectedEdge = MemoEdge(from: edge.from, to: edge.to, kind: item, label: edge.label)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: lineButtonStyle == "A" ? 40 : 34)
        .background(ListTheme.card, in: RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }
    private func boardToolbar(size: CGSize, positions: [MemoID: BoardLayout.Placement]) -> some View {
        HStack(spacing: 12) {
            Button("재정렬") { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.autoArrange(memos, undoManager: undoManager) } }.help("이어진 메모끼리 모아 다시 놓습니다")
            Button("전체 보기") { fit(size: size, positions: positions) }
            // 기호만 눌리던 것을 단추 칸 전체가 눌리게 한다. 가운데 비율을 누르면 100%로 돌아간다.
            Button { changeZoom(zoom / 1.25, size: size) } label: {
                Image(systemName: "minus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                    .background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ListTheme.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }.help("축소 (⌘-)").keyboardShortcut("-", modifiers: .command)
            Button { changeZoom(1, size: size) } label: {
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 44, height: 28).contentShape(Rectangle())
            }.help("100%로")
            Button { changeZoom(zoom * 1.25, size: size) } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                    .background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ListTheme.hairline))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }.help("확대 (⌘+)").keyboardShortcut("=", modifiers: .command)
            Divider().frame(height: 20)
            Button { showsExport = true } label: {
                ExportImageGlyph().frame(width: 28, height: 28).contentShape(Rectangle())
            }.help("보드를 이미지로 내보내기")
        }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 12).frame(height: 52)
            .background(ListTheme.card, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }
    @ViewBuilder private func pipeLabel(_ pipe: PipeGeometry, positions: [MemoID: BoardLayout.Placement]) -> some View {
        let point = screen(pipe.labelPoint(avoiding: positions.values.map { rect($0) }, scale: zoom, extraWidth: selectedEdge == pipe.edge ? 85 : 0))
        Group {
            if editingEdge == pipe.edge {
                PipeLabelEditor(edge: pipe.edge, confirm: { value in
                    guard editingEdge != nil else { return }
                    editingEdge = nil
                    model.renameLink(pipe.edge, label: value, undoManager: undoManager)
                }, cancel: { editingEdge = nil })
            } else {
                HStack(spacing: 6) {
                    Text(pipe.edge.displayLabel).font(.system(size: pipe.edge.label.isEmpty ? 12 : 11))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(ListTheme.card, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ListTheme.hairline))
                        .onTapGesture(count: 2) { selectedEdge = pipe.edge; editingEdge = pipe.edge }
                        .onTapGesture { selectedEdge = pipe.edge }
                    if selectedEdge == pipe.edge {
                        Button("연결 끊기") { model.unlink(pipe.edge.from, pipe.edge.to, undoManager: undoManager); selectedEdge = nil }
                            .buttonStyle(.plain).font(.system(size: 12)).padding(6).background(ListTheme.card, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }.fixedSize().position(point)
    }
    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 2
    private func changeZoom(_ value: CGFloat, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let before = world(center)
        // "전체 보기"가 내려갈 수 있는 비율과 같은 범위를 쓴다. 범위가 다르면 작게 축소된 보드에서
        // 축소 단추가 오히려 확대(아래 한계로 튐)되는 일이 생긴다.
        zoom = min(Self.maxZoom, max(Self.minZoom, value))
        pan = CGSize(width: center.x - before.x * zoom, height: center.y - before.y * zoom)
    }
    private func initialFit(size: CGSize, positions: [MemoID: BoardLayout.Placement]) {
        zoom = 1
        pan = .zero
        if let bounds = allBounds(positions), !CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 80).contains(bounds) {
            fit(size: size, positions: positions)
        }
        if let target { center(on: target, size: size, positions: positions) }
    }
    private func fit(size: CGSize, positions: [MemoID: BoardLayout.Placement]) {
        guard let bounds = allBounds(positions) else { return }
        zoom = min(1, max(Self.minZoom, min((size.width - 80) / bounds.width, (size.height - 160) / bounds.height)))
        pan = CGSize(width: size.width / 2 - bounds.midX * zoom, height: size.height / 2 - bounds.midY * zoom)
    }
    private func center(on id: MemoID, size: CGSize, positions: [MemoID: BoardLayout.Placement]) {
        guard let placement = positions[id] else { return }
        pan = CGSize(width: size.width / 2 - (placement.x + 100) * zoom, height: size.height / 2 - (placement.y + 60) * zoom)
    }
    private func allBounds(_ positions: [MemoID: BoardLayout.Placement]) -> CGRect? {
        positions.values.map { rect($0) }.reduce(nil) { result, rect in result.map { $0.union(rect) } ?? rect }
    }
    /// 미니맵을 끄는 동안의 고정 값. 보이는 범위가 움직이면 미니맵 축척도 바뀌어 손잡이가 출렁이므로, 끌기 시작할 때 값을 굳혀 둔다.
    private struct MinimapDrag {
        var bounds: CGRect
        var scale: CGFloat
        /// 사각형 안을 잡았을 때, 잡은 점과 사각형 가운데의 거리(보드 좌표). 바깥을 누르면 0이라 그 점으로 바로 옮긴다.
        var grab: CGSize
    }

    private func minimap(viewport: CGRect, positions: [MemoID: BoardLayout.Placement], size: CGSize) -> some View {
        let live = (allBounds(positions) ?? viewport).union(viewport).insetBy(dx: -40, dy: -40)
        let bounds = minimapDrag?.bounds ?? live
        let scale = minimapDrag?.scale ?? min(132 / live.width, 80 / live.height)
        func world(_ location: CGPoint, _ b: CGRect, _ k: CGFloat) -> CGPoint {
            CGPoint(x: b.minX + (location.x - 4) / k, y: b.minY + (location.y - 4) / k)
        }
        return Canvas { context, _ in
            context.translateBy(x: 4, y: 4)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            for pipe in PipeGeometry.make(edges: index.edges, positions: positions) { pipe.draw(in: &context) }
            for (id, placement) in positions {
                context.fill(Path(roundedRect: rect(placement), cornerRadius: 12), with: .color(model.selection.contains(id) ? ListTheme.ink : ListTheme.muted.opacity(0.4)))
            }
            // 보이는 범위: 끌 수 있다는 것이 보이도록 옅게 채우고 테두리를 둔다.
            context.fill(Path(viewport), with: .color(ListTheme.ink.opacity(minimapDrag == nil ? 0.06 : 0.12)))
            context.stroke(Path(viewport), with: .color(ListTheme.ink), lineWidth: 1.5 / scale)
        }.frame(width: 140, height: 88).background(ListTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
            // 사각형을 잡고 끌면 보는 위치가 따라 움직이고, 빈 곳을 누르거나 끌면 그 점이 가운데로 온다.
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let drag = minimapDrag ?? {
                    let k = min(132 / live.width, 80 / live.height)
                    let start = world(value.startLocation, live, k)
                    let grab = viewport.contains(start)
                        ? CGSize(width: start.x - viewport.midX, height: start.y - viewport.midY) : .zero
                    return MinimapDrag(bounds: live, scale: k, grab: grab)
                }()
                if minimapDrag == nil { minimapDrag = drag; NSCursor.closedHand.push() }
                let point = world(value.location, drag.bounds, drag.scale)
                let center = CGPoint(x: point.x - drag.grab.width, y: point.y - drag.grab.height)
                pan = CGSize(width: size.width / 2 - center.x * zoom, height: size.height / 2 - center.y * zoom)
            }.onEnded { _ in
                if minimapDrag != nil { NSCursor.pop() }
                minimapDrag = nil
            })
            .help("사각형을 끌어 보는 위치를 옮깁니다. 빈 곳을 누르면 그 자리로 갑니다")
            .accessibilityLabel("보드 미니맵")
    }
}

/// 보드 카드 한 장. 마우스 올림 상태를 여기에 두어 보드 전체가 다시 그려지지 않게 한다.
private struct BoardCardView: View {
    let memo: MemoSummary
    let info: MemoListModel.CardInfo
    let index: MemoListModel.LinkIndex
    let visible: Bool
    let selected: Bool
    let linking: Bool
    let bounds: CGRect
    let endpoints: [CGPoint]
    let zoom: CGFloat
    let center: CGPoint
    let menu: AnyView
    let onSelectOnly: (MemoID) -> Void
    let onTap: () -> Void
    let onOpen: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onPortChanged: (CGPoint, CGPoint) -> Void
    let onPortEnded: (CGPoint) -> Void
    @State private var hovered = false

    private func port(_ side: Int) -> CGPoint {
        switch side {
        case 0: CGPoint(x: bounds.minX, y: bounds.midY)
        case 1: CGPoint(x: bounds.maxX, y: bounds.midY)
        case 2: CGPoint(x: bounds.midX, y: bounds.minY)
        default: CGPoint(x: bounds.midX, y: bounds.maxY)
        }
    }

    var body: some View {
        MemoCardView(memo: memo, info: info, index: index, visible: visible, board: true, select: onSelectOnly)
            .frame(width: 200, height: 120)
            .modifier(CardSurface(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture(perform: onTap)
            .simultaneousGesture(TapGesture(count: 2).onEnded(onOpen))
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("메모보드"))
                .onChanged { onDragChanged($0.translation) }
                .onEnded { _ in onDragEnded() })
            .contextMenu { menu }
            .overlay {
                ZStack {
                    ForEach(Array(endpoints.enumerated()), id: \.offset) { _, point in
                        LimeDot(size: 10)
                            .position(x: point.x - bounds.minX, y: point.y - bounds.minY)
                            .allowsHitTesting(false)
                    }
                    ForEach(0..<4, id: \.self) { side in
                        let point = port(side)
                        let connected = endpoints.contains { hypot($0.x - point.x, $0.y - point.y) < 1 }
                        if hovered || linking {
                            LimeDot(size: 10).opacity(connected ? 1 : 0.55)
                                .frame(width: 20, height: 20).contentShape(Circle())
                                .position(x: point.x - bounds.minX, y: point.y - bounds.minY)
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("메모보드"))
                                    .onChanged { onPortChanged(point, $0.location) }
                                    .onEnded { onPortEnded($0.location) })
                        }
                    }
                }
            }
            .onHover { hovered = $0 }
            .scaleEffect(zoom)
            .position(center)
    }
}

/// 직각 파이프의 도형과 클릭 판정을 같은 점열에서 만든다
struct PipeGeometry {
    let edge: MemoEdge
    let points: [CGPoint]
    static func make(edges: [MemoEdge], positions: [MemoID: BoardLayout.Placement], avoiding: [PipeGeometry] = []) -> [PipeGeometry] {
        let valid = edges.filter { positions[$0.from] != nil && positions[$0.to] != nil }
        guard !valid.isEmpty else { return [] }
        // 뒷단이 설치돼 있으면 길찾기를 맡기고, 점열만 받아 기존 도형 타입으로 감싼다.
        if let backend = BoardEngineBackend.current {
            let paths = backend.route(edges: valid, positions: positions, avoiding: avoiding.map(\.points))
            if paths.count == valid.count { return zip(valid, paths).map { PipeGeometry(edge: $0, points: $1) } }
        }
        let router = Router(edges: valid, positions: positions)
        router.markUsed(avoiding)
        return router.route()
    }

    /// 격자와 탐색 버퍼는 한 보드의 모든 선이 함께 쓴다.
    private final class Router {
        struct Route {
            var edge: MemoEdge
            var side: Int
            var a = CGPoint.zero
            var b = CGPoint.zero
        }
        struct PortKey: Hashable { var id: MemoID; var side: Int }
        struct Port { var route: Int; var start: Bool; var coordinate: Double }
        struct Cell {
            var blocked = false
            var usedH = false
            var usedV = false
            var nodeH = false
            var nodeV = false
            var owner = -1
        }
        struct State {
            var cost = 0
            var priority = 0
            var previous = -1
            var stamp = 0
            var queuePrevious = -1
            var queueNext = -1
            var queued = false
        }
        let directions = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        let positions: [MemoID: BoardLayout.Placement]
        let x0: Double, y0: Double
        let width: Int, height: Int
        var routes: [Route]
        let cells: UnsafeMutableBufferPointer<Cell>
        let states: UnsafeMutableBufferPointer<State>
        let queue: UnsafeMutableBufferPointer<Int>
        var generation = 0

        init(edges: [MemoEdge], positions: [MemoID: BoardLayout.Placement]) {
            self.positions = positions
            let xs = positions.values.map(\.x), ys = positions.values.map(\.y)
            x0 = floor((xs.min()! - 100) / 20) * 20
            y0 = floor((ys.min()! - 100) / 20) * 20
            width = Int((ceil((xs.max()! + 300) / 20) * 20 - x0) / 20) + 1
            height = Int((ceil((ys.max()! + 220) / 20) * 20 - y0) / 20) + 1
            let count = width * height
            cells = .allocate(capacity: count)
            cells.initialize(repeating: Cell())
            states = .allocate(capacity: count * 4)
            states.initialize(repeating: State())
            queue = .allocate(capacity: 64)
            queue.initialize(repeating: -1)
            routes = edges.map { edge in
                let a = positions[edge.from]!, b = positions[edge.to]!
                let dx = (b.x - a.x) / 280, dy = (b.y - a.y) / 200
                return Route(edge: edge, side: abs(dx) >= abs(dy) ? (dx >= 0 ? 0 : 2) : (dy >= 0 ? 1 : 3))
            }
            // 카드 둘레의 막힌 점만 채워 큰 보드에서도 카드 수 곱하기 전체 격자 순회를 피한다.
            for p in positions.values {
                let left = max(0, Int(floor((p.x - 10 - x0) / 20)) + 1)
                let right = min(width - 1, Int(ceil((p.x + 210 - x0) / 20)) - 1)
                let top = max(0, Int(floor((p.y - 10 - y0) / 20)) + 1)
                let bottom = min(height - 1, Int(ceil((p.y + 130 - y0) / 20)) - 1)
                if left <= right && top <= bottom {
                    for y in top...bottom { for x in left...right { cells[y * width + x].blocked = true } }
                }
            }
            var ports: [PortKey: [Port]] = [:]
            for (i, r) in routes.enumerated() {
                for start in [true, false] {
                    let side = start ? r.side : (r.side + 2) % 4
                    let other = positions[start ? r.edge.to : r.edge.from]!
                    ports[PortKey(id: start ? r.edge.from : r.edge.to, side: side), default: []]
                        .append(Port(route: i, start: start, coordinate: side % 2 == 0 ? other.y + 60 : other.x + 100))
                }
            }
            for (key, list) in ports {
                let sorted = list.sorted { $0.coordinate == $1.coordinate ? $0.route < $1.route : $0.coordinate < $1.coordinate }
                let p = positions[key.id]!
                let slots = Self.slots(for: sorted.map { $0.coordinate - (key.side % 2 == 0 ? p.y : p.x) }, length: key.side % 2 == 0 ? 120 : 200)
                for (i, port) in sorted.enumerated() {
                    let offset = Double(slots[min(i, slots.count - 1)])
                    let point: CGPoint
                    switch key.side {
                    case 0: point = CGPoint(x: p.x + 200, y: p.y + offset)
                    case 1: point = CGPoint(x: p.x + offset, y: p.y + 120)
                    case 2: point = CGPoint(x: p.x, y: p.y + offset)
                    default: point = CGPoint(x: p.x + offset, y: p.y)
                    }
                    if port.start { routes[port.route].a = point } else { routes[port.route].b = point }
                }
            }
            for (i, r) in routes.enumerated() {
                for (point, side) in [(r.a, r.side), (r.b, (r.side + 2) % 4)] {
                    let node = index(stub(point, side))
                    let owner = cells[node].owner
                    cells[node].owner = owner == -1 || owner == i ? i : -2
                }
            }
        }
        /// 한 변에 나갈 선들의 자리를 20pt 간격 후보 중에서 순서를 지키며 고른다.
        /// 상대 카드 중심(이 카드 기준 좌표)에 가장 가까운 자리를 골라, 나란한 두 카드 사이 선이 꺾이지 않고 곧게 가게 한다.
        /// 선이 하나면 상대가 어디 있든 가운데, 후보보다 많으면 가운데부터 고르게 나눈다.
        static func slots(for wanted: [Double], length: Int) -> [Int] {
            let candidates = Array(stride(from: 20, through: length - 20, by: 20))
            let n = wanted.count
            guard n > 1 else { return [length / 2] }
            guard n <= candidates.count else { return candidates }
            // cost[i][j]: 앞의 i개 선을 후보 j개 안에서 배치한 최소 비용
            let m = candidates.count
            var cost = Array(repeating: Array(repeating: Double.infinity, count: m + 1), count: n + 1)
            var take = Array(repeating: Array(repeating: false, count: m + 1), count: n + 1)
            for j in 0...m { cost[0][j] = 0 }
            for i in 1...n {
                for j in i...m {
                    let skip = cost[i][j - 1]
                    let use = cost[i - 1][j - 1] + abs(Double(candidates[j - 1]) - wanted[i - 1])
                    if use <= skip { cost[i][j] = use; take[i][j] = true } else { cost[i][j] = skip }
                }
            }
            var result: [Int] = [], i = n, j = m
            while i > 0 {
                if take[i][j] { result.append(candidates[j - 1]); i -= 1 }
                j -= 1
            }
            return result.reversed()
        }
        deinit {
            cells.deinitialize(); cells.deallocate()
            states.deinitialize(); states.deallocate()
            queue.deinitialize(); queue.deallocate()
        }
        func stub(_ p: CGPoint, _ side: Int) -> CGPoint {
            CGPoint(x: p.x + Double(directions[side].0 * 20), y: p.y + Double(directions[side].1 * 20))
        }
        func index(_ p: CGPoint) -> Int {
            Int(((p.y - y0) / 20).rounded()) * width + Int(((p.x - x0) / 20).rounded())
        }
        func point(_ node: Int) -> CGPoint { CGPoint(x: x0 + Double(node % width * 20), y: y0 + Double(node / width * 20)) }

        func search(_ start: CGPoint, _ sd: Int, _ goal: CGPoint, _ gd: Int, _ owner: Int, local: Bool) -> [CGPoint]? {
            generation += 1
            // 지역 포인터로 읽어 매 칸마다 참조 계수와 배열 복사 여부를 검사하지 않는다.
            let cells = cells.baseAddress!, states = states.baseAddress!, queue = queue.baseAddress!
            let width = width, height = height, stamp = generation
            // 한 칸의 예상 비용 증가는 최대 37이다. 64칸 순환 큐로 정수 우선순위를 관리한다.
            for i in 0..<64 { queue[i] = -1 }
            let si = index(start), gi = index(goal), gx = gi % width, gy = gi / width
            let sx = si % width, sy = si / width
            let left = local ? max(0, min(sx, gx) - 20) : 0
            let right = local ? min(width - 1, max(sx, gx) + 20) : width - 1
            let top = local ? max(0, min(sy, gy) - 20) : 0
            let bottom = local ? min(height - 1, max(sy, gy) + 20) : height - 1
            let initial = si * 4 + sd
            var priority = abs(sx - gx) + abs(sy - gy)
            states[initial] = State(cost: 0, priority: priority, previous: -1, stamp: stamp, queued: true)
            queue[priority % 64] = initial
            var queueCount = 1, best = Int.max, bestState = -1
            while queueCount > 0 {
                while queue[priority % 64] < 0 { priority += 1 }
                if priority >= best { break }
                let current = queue[priority % 64], nextInQueue = states[current].queueNext
                queue[priority % 64] = nextInQueue
                if nextInQueue >= 0 { states[nextInQueue].queuePrevious = -1 }
                states[current].queued = false
                queueCount -= 1
                let node = current / 4, direction = current % 4, cost = states[current].cost
                if node == gi {
                    let total = cost + (direction == gd ? 0 : 6)
                    if total < best { best = total; bestState = current }
                    continue
                }
                let x = node % width, y = node / width
                for nd in 0..<4 {
                    if nd == (direction + 2) % 4 { continue }
                    let nx = x + (nd == 0 ? 1 : (nd == 2 ? -1 : 0))
                    let ny = y + (nd == 1 ? 1 : (nd == 3 ? -1 : 0))
                    if nx < left || nx > right || ny < top || ny > bottom { continue }
                    let next = ny * width + nx, cell = cells[next]
                    if next != gi && (cell.blocked || (cell.owner != -1 && cell.owner != owner)) { continue }
                    let horizontal = nd % 2 == 0, segment = cells[min(node, next)]
                    let extra = (horizontal ? segment.usedH : segment.usedV) ? 30 : 0
                    let crossing = (horizontal ? cell.nodeV : cell.nodeH) ? 2 : 0
                    let total = cost + 1 + (nd == direction ? 0 : 3) + extra + crossing
                    let state = next * 4 + nd, old = states[state]
                    if old.stamp == stamp && total >= old.cost { continue }
                    let estimate = total + abs(nx - gx) + abs(ny - gy)
                    if old.stamp == stamp && old.queued {
                        if old.queuePrevious < 0 { queue[old.priority % 64] = old.queueNext }
                        else { states[old.queuePrevious].queueNext = old.queueNext }
                        if old.queueNext >= 0 { states[old.queueNext].queuePrevious = old.queuePrevious }
                    } else { queueCount += 1 }
                    let bucket = estimate % 64, head = queue[bucket]
                    states[state] = State(cost: total, priority: estimate, previous: current, stamp: stamp, queueNext: head, queued: true)
                    if head >= 0 { states[head].queuePrevious = state }
                    queue[bucket] = state
                }
            }
            guard bestState >= 0 else { return nil }
            var result: [CGPoint] = [], state = bestState
            while state >= 0 { result.append(point(state / 4)); state = states[state].previous }
            return result.reversed()
        }

        /// 이미 그려 둔 선이 지나는 격자 구간을 '쓴 길'로 표시해 새 선이 그 위에 포개지지 않게 한다.
        func markUsed(_ pipes: [PipeGeometry]) {
            for pipe in pipes {
                for (a, b) in zip(pipe.points, pipe.points.dropFirst()) {
                    let horizontal = abs(a.y - b.y) < 0.5
                    let steps = Int((max(abs(b.x - a.x), abs(b.y - a.y)) / 20).rounded())
                    guard steps > 0 else { continue }
                    for k in 0..<steps {
                        let t0 = Double(k) / Double(steps), t1 = Double(k + 1) / Double(steps)
                        let p = CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
                        let q = CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
                        let maxX = x0 + Double((width - 1) * 20), maxY = y0 + Double((height - 1) * 20)
                        guard [p, q].allSatisfy({ $0.x >= x0 && $0.x <= maxX && $0.y >= y0 && $0.y <= maxY }) else { continue }
                        let ip = index(p), iq = index(q)
                        if horizontal { cells[min(ip, iq)].usedH = true; cells[ip].nodeH = true; cells[iq].nodeH = true }
                        else { cells[min(ip, iq)].usedV = true; cells[ip].nodeV = true; cells[iq].nodeV = true }
                    }
                }
            }
        }

        func route() -> [PipeGeometry] {
            func length(_ r: Route) -> CGFloat { abs(r.a.x - r.b.x) + abs(r.a.y - r.b.y) }
            let order = routes.indices.sorted { length(routes[$0]) == length(routes[$1]) ? $0 < $1 : length(routes[$0]) < length(routes[$1]) }
            var result: [Int: PipeGeometry] = [:]
            for i in order {
                let r = routes[i], opposite = (r.side + 2) % 4
                let start = stub(r.a, r.side), goal = stub(r.b, opposite)
                guard let path = search(start, r.side, goal, r.side, i, local: true)
                    ?? search(start, r.side, goal, r.side, i, local: false) else {
                    let a = positions[r.edge.from]!, b = positions[r.edge.to]!
                    result[i] = PipeGeometry(edge: r.edge, a: CGRect(x: a.x, y: a.y, width: 200, height: 120), b: CGRect(x: b.x, y: b.y, width: 200, height: 120))
                    continue
                }
                for (a, b) in zip(path, path.dropFirst()) {
                    let ia = index(a), ib = index(b)
                    if a.y == b.y { cells[min(ia, ib)].usedH = true; cells[ia].nodeH = true; cells[ib].nodeH = true }
                    else { cells[min(ia, ib)].usedV = true; cells[ia].nodeV = true; cells[ib].nodeV = true }
                }
                result[i] = PipeGeometry(edge: r.edge, points: PipeGeometry.simplified([r.a] + path + [r.b]))
            }
            return routes.indices.compactMap { result[$0] }
        }
    }

    static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for p in points {
            if let last = result.last, hypot(last.x - p.x, last.y - p.y) < 0.5 { continue }
            result.append(p)
            while result.count >= 3 {
                let a = result[result.count - 3], b = result[result.count - 2], c = result[result.count - 1]
                if (abs(a.x - b.x) < 0.5 && abs(b.x - c.x) < 0.5) || (abs(a.y - b.y) < 0.5 && abs(b.y - c.y) < 0.5) {
                    result.remove(at: result.count - 2)
                } else { break }
            }
        }
        return result
    }
    init(edge: MemoEdge, points: [CGPoint]) {
        self.edge = edge
        self.points = points
    }
    init(edge: MemoEdge, a: CGRect, b: CGRect) {
        self.edge = edge
        if abs(a.midX - b.midX) > abs(a.midY - b.midY) {
            let p = CGPoint(x: a.midX < b.midX ? a.maxX : a.minX, y: a.midY)
            let q = CGPoint(x: a.midX < b.midX ? b.minX : b.maxX, y: b.midY)
            points = [p, CGPoint(x: (p.x + q.x) / 2, y: p.y), CGPoint(x: (p.x + q.x) / 2, y: q.y), q]
        } else {
            let p = CGPoint(x: a.midX, y: a.midY < b.midY ? a.maxY : a.minY)
            let q = CGPoint(x: b.midX, y: a.midY < b.midY ? b.minY : b.maxY)
            points = [p, CGPoint(x: p.x, y: (p.y + q.y) / 2), CGPoint(x: q.x, y: (p.y + q.y) / 2), q]
        }
    }
    /// 메모마다 파이프가 닿는 점. 시작 메모는 첫 점, 끝 메모는 마지막 점.
    static func endpoints(of pipes: [PipeGeometry]) -> [MemoID: [CGPoint]] {
        var result: [MemoID: [CGPoint]] = [:]
        for pipe in pipes {
            result[pipe.edge.from, default: []].append(pipe.points.first!)
            result[pipe.edge.to, default: []].append(pipe.points.last!)
        }
        return result
    }
    var midpoint: CGPoint {
        guard let first = points.first else { return .zero }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) / 2
        for (i, length) in lengths.enumerated() {
            if remaining <= length && length > 0 {
                let a = points[i], b = points[i + 1], t = remaining / length
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= length
        }
        return first
    }
    func labelPoint(avoiding cards: [CGRect], scale: CGFloat = 1, extraWidth: CGFloat = 0) -> CGPoint {
        let width = (CGFloat(edge.displayLabel.count) * 12 + 24 + extraWidth) / scale
        let height: CGFloat = 30 / scale
        var point = midpoint
        // 카드와 닿으면 위로 옮기며 카드 바깥의 빈 자리를 찾는다.
        for _ in 0..<1000 {
            let bounds = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            let overlaps = cards.filter { $0.insetBy(dx: -4 / scale, dy: -4 / scale).intersects(bounds) }
            guard let top = overlaps.map(\.minY).min() else { break }
            point.y = top - height / 2 - 8 / scale
        }
        return point
    }
    func drawLabel(in context: inout GraphicsContext, avoiding cards: [CGRect]) {
        let text = context.resolve(Text(edge.displayLabel).font(.system(size: 11)).foregroundColor(ListTheme.ink))
        let size = text.measure(in: CGSize(width: 500, height: 30))
        let point = labelPoint(avoiding: cards)
        let bounds = CGRect(x: point.x - size.width / 2 - 8, y: point.y - size.height / 2 - 4, width: size.width + 16, height: size.height + 8)
        let shape = Path(roundedRect: bounds, cornerRadius: 6)
        context.fill(shape, with: .color(ListTheme.card))
        context.stroke(shape, with: .color(ListTheme.hairline), lineWidth: 1)
        context.draw(text, at: point)
    }
    struct Crossing: Equatable {
        var point: CGPoint
        var horizontalPipe: Int
        var segment: Int
    }
    static func crossings(in pipes: [PipeGeometry]) -> [Crossing] {
        if let backend = BoardEngineBackend.current {
            return backend.crossings(paths: pipes.map(\.points)).map { Crossing(point: $0.point, horizontalPipe: $0.horizontalPipe, segment: $0.segment) }
        }
        var result: [Crossing] = []
        for p in pipes.indices {
            for q in pipes.indices where q > p {
                for i in pipes[p].points.indices.dropLast() {
                    let a = pipes[p].points[i], b = pipes[p].points[i + 1]
                    for j in pipes[q].points.indices.dropLast() {
                        let c = pipes[q].points[j], d = pipes[q].points[j + 1]
                        let ph = abs(a.y - b.y) < 0.5, qh = abs(c.y - d.y) < 0.5
                        guard ph != qh else { continue }
                        let h0 = ph ? a : c, h1 = ph ? b : d, v0 = ph ? c : a, v1 = ph ? d : b
                        guard abs(v0.x - v1.x) < 0.5,
                              v0.x > min(h0.x, h1.x) + 0.5, v0.x < max(h0.x, h1.x) - 0.5,
                              h0.y > min(v0.y, v1.y) + 0.5, h0.y < max(v0.y, v1.y) - 0.5 else { continue }
                        let crossing = Crossing(point: CGPoint(x: v0.x, y: h0.y), horizontalPipe: ph ? p : q, segment: ph ? i : j)
                        if !result.contains(crossing) { result.append(crossing) }
                    }
                }
            }
        }
        return result
    }
    private func bridgeFits(_ crossing: Crossing) -> Bool {
        guard edge.kind != .same && edge.kind != .oppose else { return false }
        let i = crossing.segment, a = points[i], b = points[i + 1]
        let startRadius = i == 0 ? 0 : cornerRadius(i)
        let endRadius = i + 1 == points.count - 1 ? 0 : cornerRadius(i + 1)
        let start = toward(a, b, startRadius), end = toward(b, a, endRadius)
        return crossing.point.x > min(start.x, end.x) + 8 && crossing.point.x < max(start.x, end.x) - 8
    }
    private func cornerRadius(_ i: Int) -> CGFloat {
        min(8, hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) / 2,
            hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y) / 2)
    }
    private func toward(_ a: CGPoint, _ b: CGPoint, _ distance: CGFloat) -> CGPoint {
        let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
        return CGPoint(x: a.x + (b.x - a.x) * distance / length, y: a.y + (b.y - a.y) * distance / length)
    }
    private static func bridge(_ path: inout Path, at p: CGPoint, rightward: Bool) {
        let sign: CGFloat = rightward ? 1 : -1
        path.addLine(to: CGPoint(x: p.x - sign * 6, y: p.y))
        // 위쪽 반원을 두 곡선으로 이어 진행 방향과 관계없이 위로 넘긴다.
        let k: CGFloat = 6 * 0.5522847498307936
        path.addCurve(to: CGPoint(x: p.x, y: p.y - 6),
                      control1: CGPoint(x: p.x - sign * 6, y: p.y - k),
                      control2: CGPoint(x: p.x - sign * k, y: p.y - 6))
        path.addCurve(to: CGPoint(x: p.x + sign * 6, y: p.y),
                      control1: CGPoint(x: p.x + sign * k, y: p.y - 6),
                      control2: CGPoint(x: p.x + sign * 6, y: p.y - k))
    }
    private func path(hops: [Crossing]) -> Path {
        guard let first = points.first, points.count >= 2 else { return Path() }
        var path = Path(); path.move(to: first)
        for i in points.indices.dropLast() {
            let a = points[i], b = points[i + 1]
            let end = i + 1 == points.count - 1 ? b : toward(b, a, cornerRadius(i + 1))
            let crossings = hops.filter { $0.segment == i && bridgeFits($0) }
                .sorted { a.x < b.x ? $0.point.x < $1.point.x : $0.point.x > $1.point.x }
            for crossing in crossings { Self.bridge(&path, at: crossing.point, rightward: b.x > a.x) }
            path.addLine(to: end)
            if i + 1 < points.count - 1 {
                path.addQuadCurve(to: toward(b, points[i + 2], cornerRadius(i + 1)), control: b)
            }
        }
        return path
    }
    static func drawAll(_ pipes: [PipeGeometry], in context: inout GraphicsContext, background: Color, highlighted: MemoEdge?, dimOthers: Bool) {
        let crossings = crossings(in: pipes).filter { pipes[$0.horizontalPipe].bridgeFits($0) }
        let grouped = Dictionary(grouping: crossings, by: \.horizontalPipe)
        for (i, pipe) in pipes.enumerated() {
            var layer = context
            layer.opacity *= dimOthers && pipe.edge != highlighted ? 0.18 : 1
            let path = pipe.path(hops: grouped[i] ?? [])
            if pipe.edge == highlighted {
                layer.stroke(path, with: .color(ListTheme.lime), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
            }
            pipe.draw(in: &layer, routedPath: path, background: background)
        }
        // 모든 선을 그린 뒤 다리 조각을 덧그려 가로선이 항상 위에 오도록 한다.
        for crossing in crossings {
            let pipe = pipes[crossing.horizontalPipe], p = crossing.point
            var layer = context
            layer.opacity *= dimOthers && pipe.edge != highlighted ? 0.18 : 1
            var fragment = Path()
            fragment.move(to: CGPoint(x: p.x - 9, y: p.y))
            bridge(&fragment, at: p, rightward: true)
            fragment.addLine(to: CGPoint(x: p.x + 9, y: p.y))
            let dashed = pipe.edge.kind.lineStyle == .dashed
            let width: CGFloat = dashed ? 3 : 4
            layer.stroke(fragment, with: .color(background), style: StrokeStyle(lineWidth: width + 7, lineCap: .butt, lineJoin: .round))
            layer.stroke(fragment, with: .color(dashed ? ListTheme.related : ListTheme.ink), style: StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .round))
        }
    }
    var path: Path { path(hops: []) }
    /// 삼각형 꼭짓점을 카드 가장자리에 맞추고 안쪽으로 길이 10, 폭 9를 채운다.
    var arrow: Path {
        var path = Path()
        func triangle(_ end: CGPoint, _ previous: CGPoint) {
            let length = hypot(end.x - previous.x, end.y - previous.y)
            guard length > 0 else { return }
            let dx = (end.x - previous.x) / length, dy = (end.y - previous.y) / length
            path.move(to: end)
            path.addLine(to: CGPoint(x: end.x - 10 * dx + 4.5 * dy, y: end.y - 10 * dy - 4.5 * dx))
            path.addLine(to: CGPoint(x: end.x - 10 * dx - 4.5 * dy, y: end.y - 10 * dy + 4.5 * dx))
            path.closeSubpath()
        }
        if edge.kind.arrows != .none, let end = points.last {
            triangle(end, points.dropLast().last(where: { $0 != end }) ?? points[0])
        }
        if edge.kind.arrows == .both, let start = points.first {
            triangle(start, points.dropFirst().first(where: { $0 != start }) ?? points.last!)
        }
        return path
    }
    func draw(in context: inout GraphicsContext, sample: Bool = false, routedPath: Path? = nil, background: Color? = nil) {
        let dashed = edge.kind.lineStyle == .dashed
        let color = sample || !dashed ? ListTheme.ink : ListTheme.related
        let width: CGFloat = sample ? 2 : (dashed ? 3 : 4)
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed ? (sample ? [4, 3] : [6, 6]) : [])
        func halo(_ path: Path, in layer: inout GraphicsContext) {
            if let background {
                layer.stroke(path, with: .color(background), style: StrokeStyle(lineWidth: width + 7, lineCap: .round, lineJoin: .round))
            }
        }
        if edge.kind == .same {
            // 코너에서도 같은 간격을 유지하도록 각 직선 구간의 법선으로 옮긴다.
            var shiftedPaths: [Path] = []
            for side: CGFloat in [-3, 3] {
                var shifted = Path()
                for i in points.indices {
                    let point = points[i]
                    let previous = points[..<i].last(where: { $0 != point })
                    let next = points.dropFirst(i + 1).first(where: { $0 != point })
                    func normal(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                        let length = max(1, hypot(b.x - a.x, b.y - a.y))
                        return CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
                    }
                    let incoming = previous.map { normal($0, point) }
                    let outgoing = next.map { normal(point, $0) }
                    let n = incoming ?? outgoing ?? .zero
                    let m = outgoing ?? incoming ?? .zero
                    let divisor = max(0.01, 1 + n.x * m.x + n.y * m.y)
                    let p = CGPoint(x: point.x + (n.x + m.x) * side / divisor, y: point.y + (n.y + m.y) * side / divisor)
                    if i == 0 { shifted.move(to: p) } else { shifted.addLine(to: p) }
                }
                shiftedPaths.append(shifted)
            }
            for shifted in shiftedPaths { halo(shifted, in: &context) }
            for shifted in shiftedPaths { context.stroke(shifted, with: .color(color), style: style) }
        } else if edge.kind == .oppose {
            var wave = Path(); var traveled: CGFloat = 0
            for (a, b) in zip(points, points.dropFirst()) {
                let length = hypot(b.x - a.x, b.y - a.y)
                guard length > 0 else { continue }
                let steps = max(1, Int(ceil(length / 2)))
                for step in 0...steps {
                    let d = length * CGFloat(step) / CGFloat(steps)
                    let offset = 4 * sin((traveled + d) * .pi / 8)
                    let p = CGPoint(x: a.x + (b.x - a.x) * d / length - (b.y - a.y) / length * offset,
                                    y: a.y + (b.y - a.y) * d / length + (b.x - a.x) / length * offset)
                    if traveled == 0 && step == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
                }
                traveled += length
            }
            halo(wave, in: &context)
            context.stroke(wave, with: .color(color), style: style)
            let circle = Path(ellipseIn: CGRect(x: midpoint.x - 7, y: midpoint.y - 7, width: 14, height: 14))
            context.fill(circle, with: .color(.white)); context.stroke(circle, with: .color(color), lineWidth: 1.5)
            var cross = Path()
            for sign: CGFloat in [-1, 1] { cross.move(to: CGPoint(x: midpoint.x - 3, y: midpoint.y - 3 * sign)); cross.addLine(to: CGPoint(x: midpoint.x + 3, y: midpoint.y + 3 * sign)) }
            context.stroke(cross, with: .color(color), lineWidth: 1.5)
        } else {
            let shape = routedPath ?? path
            halo(shape, in: &context)
            context.stroke(shape, with: .color(color), style: style)
        }
        context.fill(arrow, with: .color(color))
        if edge.kind == .contain || edge.kind == .block, let end = points.last,
           let previous = points.dropLast().last(where: { $0 != end }) {
            let length = hypot(end.x - previous.x, end.y - previous.y)
            let dx = (end.x - previous.x) / length, dy = (end.y - previous.y) / length
            var mark = Path()
            if edge.kind == .contain {
                let start = points[0]
                context.fill(Path(ellipseIn: CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12)), with: .color(color))
                for spread: CGFloat in [-10, 0, 10] {
                    mark.move(to: CGPoint(x: end.x - 16 * dx, y: end.y - 16 * dy))
                    mark.addLine(to: CGPoint(x: end.x - dy * spread, y: end.y + dx * spread))
                }
            } else {
                mark.move(to: CGPoint(x: end.x - dy * 7, y: end.y + dx * 7))
                mark.addLine(to: CGPoint(x: end.x + dy * 7, y: end.y - dx * 7))
            }
            context.stroke(mark, with: .color(color), style: StrokeStyle(lineWidth: edge.kind == .block ? 2.5 : width, lineCap: .round))
        }
    }

    func distance(to point: CGPoint) -> CGFloat {
        zip(points, points.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length == 0 ? 0 : min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
            return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
        }.min() ?? .infinity
    }
}
