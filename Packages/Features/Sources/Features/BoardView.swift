import AppKit
import MemoCore
import SwiftUI

/// 모든 파이프를 한 캔버스에 그리며 카드만 화면 근처에서 만든다
struct BoardView: View {
    @Bindable var model: MemoListModel
    let memos: [MemoSummary]
    let index: MemoListModel.LinkIndex
    @Binding var target: MemoID?
    let onOpen: (MemoID) -> Void
    let onCreate: () -> Void
    let menu: (MemoID) -> AnyView
    @Environment(\.undoManager) private var undoManager
    @State private var showsExport = false
    @AppStorage("board.showPipeLabels") private var showLabels = true
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
            let pipes = moving.isEmpty ? model.boardPipes(for: memos, edges: index.edges) : PipeGeometry.make(edges: index.edges, positions: positions)
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
                            boardCard(memo, placement: placement, positions: positions, endpoints: endpoints[memo.id] ?? [])
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
                VStack {
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
                        ? pipes.reversed().first { $0.distance(to: world(location)) * zoom <= 8 }?.edge : nil
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
            for pipe in pipes {
                if selectedEdge == pipe.edge {
                    context.stroke(pipe.path, with: .color(ListTheme.lime), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                }
                pipe.draw(in: &context)
            }
            if flat {
                drawFlatCards(context: &context, positions: positions, viewport: viewport)
            }
            if linkStart != nil, let pointer = linkPointer {
                var line = Path(); line.move(to: linkPort); line.addLine(to: world(pointer))
                context.stroke(line, with: .color(ListTheme.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            }
        }
    }

    /// 멀리서 볼 때 카드를 캔버스에 직접 그린다. 보이는 영역 근처 카드만 그린다.
    private func drawFlatCards(context: inout GraphicsContext, positions: [MemoID: BoardLayout.Placement], viewport: CGRect) {
        let near = viewport.insetBy(dx: -40, dy: -40)
        for memo in memos {
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
                    moving[sel] = .init(x: origin.x + translation.width / zoom, y: origin.y + translation.height / zoom)
                }
            },
            onDragEnded: {
                model.moveCards(moving, undoManager: undoManager)
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
    private func boardToolbar(size: CGSize, positions: [MemoID: BoardLayout.Placement]) -> some View {
        HStack(spacing: 12) {
            BoardLineTools(selected: selectedEdge?.kind ?? kind, availableWidth: max(160, size.width - 400)) { item in
                kind = item
                if let edge = selectedEdge {
                    model.changeLink(edge, kind: item, undoManager: undoManager)
                    selectedEdge = MemoEdge(from: edge.from, to: edge.to, kind: item, label: edge.label)
                }
            }
            Divider().frame(height: 20)
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
                    ForEach(0..<4, id: \.self) { side in
                        let point = port(side)
                        let connected = endpoints.contains { hypot($0.x - point.x, $0.y - point.y) < 1 }
                        if hovered || connected || linking {
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
    static func make(edges: [MemoEdge], positions: [MemoID: BoardLayout.Placement]) -> [PipeGeometry] {
        func rect(_ placement: BoardLayout.Placement) -> CGRect { CGRect(x: placement.x, y: placement.y, width: 200, height: 120) }
        return edges.compactMap { edge -> PipeGeometry? in
            guard let a = positions[edge.from], let b = positions[edge.to] else { return nil }
            return PipeGeometry(edge: edge, a: rect(a), b: rect(b))
        }
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
        guard points.count > 2 else { return CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2) }
        return CGPoint(x: (points[1].x + points[2].x) / 2, y: (points[1].y + points[2].y) / 2)
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
    var path: Path {
        var path = Path(); path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            let previous = points[i - 1], corner = points[i], next = points[i + 1]
            let before = hypot(corner.x - previous.x, corner.y - previous.y)
            let after = hypot(next.x - corner.x, next.y - corner.y)
            let radius = min(8, before / 2, after / 2)
            if radius > 0 {
                let entry = CGPoint(x: corner.x + (previous.x - corner.x) * radius / before, y: corner.y + (previous.y - corner.y) * radius / before)
                let exit = CGPoint(x: corner.x + (next.x - corner.x) * radius / after, y: corner.y + (next.y - corner.y) * radius / after)
                path.addLine(to: entry); path.addQuadCurve(to: exit, control: corner)
            } else { path.addLine(to: corner) }
        }
        path.addLine(to: points.last!); return path
    }
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
    func draw(in context: inout GraphicsContext, sample: Bool = false) {
        let dashed = edge.kind.lineStyle == .dashed
        let color = sample || !dashed ? ListTheme.ink : ListTheme.related
        let width: CGFloat = sample ? 2 : (dashed ? 3 : 4)
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed ? (sample ? [4, 3] : [6, 6]) : [])
        if edge.kind == .same {
            // 코너에서도 같은 간격을 유지하도록 각 직선 구간의 법선으로 옮긴다.
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
                context.stroke(shifted, with: .color(color), style: style)
            }
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
            context.stroke(wave, with: .color(color), style: style)
            let circle = Path(ellipseIn: CGRect(x: midpoint.x - 7, y: midpoint.y - 7, width: 14, height: 14))
            context.fill(circle, with: .color(.white)); context.stroke(circle, with: .color(color), lineWidth: 1.5)
            var cross = Path()
            for sign: CGFloat in [-1, 1] { cross.move(to: CGPoint(x: midpoint.x - 3, y: midpoint.y - 3 * sign)); cross.addLine(to: CGPoint(x: midpoint.x + 3, y: midpoint.y + 3 * sign)) }
            context.stroke(cross, with: .color(color), lineWidth: 1.5)
        } else { context.stroke(path, with: .color(color), style: style) }
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
