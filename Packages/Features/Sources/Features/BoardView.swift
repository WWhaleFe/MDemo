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
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?
    @State private var hovered: MemoID?
    @State private var moving: [MemoID: BoardLayout.Placement] = [:]
    @State private var dragOrigins: [MemoID: BoardLayout.Placement] = [:]
    @State private var linkStart: MemoID?
    @State private var linkPort = CGPoint.zero
    @State private var linkPointer: CGPoint?
    @State private var selectedEdge: MemoEdge?
    @State private var kind = MemoLinkKind.flow
    @FocusState private var focused: Bool

    private func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height) }
    private func world(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom) }
    private func rect(_ placement: BoardLayout.Placement) -> CGRect { CGRect(x: placement.x, y: placement.y, width: 200, height: 120) }
    private func placements() -> [MemoID: BoardLayout.Placement] { model.boardPlacements(for: memos).merging(moving) { _, new in new } }

    var body: some View {
        GeometryReader { geo in
            let positions = placements()
            let viewport = CGRect(origin: world(.zero), size: CGSize(width: geo.size.width / zoom, height: geo.size.height / zoom))
            let pipes = index.edges.compactMap { edge -> PipeGeometry? in
                guard let a = positions[edge.from], let b = positions[edge.to] else { return nil }
                return PipeGeometry(edge: edge, a: rect(a), b: rect(b))
            }
            ZStack(alignment: .topLeading) {
                ListTheme.boardBg
                background(size: geo.size, pipes: pipes)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        focused = true
                        if panOrigin == nil { panOrigin = pan }
                        if let origin = panOrigin, value.translation.width * value.translation.width + value.translation.height * value.translation.height > 9 {
                            pan = CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height)
                        }
                    }.onEnded { value in
                        if abs(value.translation.width) + abs(value.translation.height) < 4 {
                            selectedEdge = pipes.reversed().first { $0.distance(to: world(value.location)) * zoom <= 6 }?.edge
                            if selectedEdge == nil { model.selection = [] }
                        }
                        panOrigin = nil
                    })
                if memos.isEmpty {
                    VStack(spacing: 12) {
                        Text(model.query.isEmpty ? "메모가 없습니다" : "찾는 메모가 없습니다").foregroundStyle(ListTheme.muted)
                        Button("새 메모 만들기", action: onCreate).buttonStyle(.plain)
                    }.frame(width: geo.size.width, height: geo.size.height)
                }
                ForEach(memos.filter { memo in positions[memo.id].map { rect($0).intersects(viewport.insetBy(dx: -240, dy: -160)) } ?? false }) { memo in
                    if let placement = positions[memo.id] {
                        boardCard(memo, placement: placement, positions: positions, pipes: pipes)
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
                if let selectedEdge, let pipe = pipes.first(where: { $0.edge == selectedEdge }) {
                    Button("연결 끊기") { model.unlink(selectedEdge.from, selectedEdge.to); self.selectedEdge = nil }
                        .buttonStyle(.plain).font(.system(size: 12)).padding(8).background(ListTheme.card, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ListTheme.hairline))
                        .position(screen(pipe.midpoint))
                }
                VStack {
                    flowStrip
                    Spacer()
                    HStack(alignment: .bottom) {
                        Spacer(minLength: 0)
                        boardToolbar(size: geo.size, positions: positions)
                        Spacer(minLength: 0)
                    }.padding(.bottom, 16)
                }.padding(16).allowsHitTesting(true)
                VStack {
                    Spacer()
                    HStack { Spacer(); minimap(viewport: viewport, positions: positions, size: geo.size) }
                }.padding(16).padding(.bottom, 60).allowsHitTesting(true)
            }
            .background(ListKeyboardCommands(selectAll: { model.selectAllVisible() }, delete: deleteSelection,
                                             open: { for id in model.orderedSelection { onOpen(id) } },
                                             paste: { paste(at: geo.size) }, fit: { fit(size: geo.size, positions: positions) }))
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
                model.pasteMemo(text, at: .init(x: center.x - 100, y: center.y - 60)); return .handled
            }
            .onChange(of: target) { _, id in if let id { center(on: id, size: geo.size, positions: positions) } }
            .onAppear { if let target { center(on: target, size: geo.size, positions: positions) } }
        }
    }

    private func deleteSelection() {
        if let selectedEdge { model.unlink(selectedEdge.from, selectedEdge.to); self.selectedEdge = nil }
        else { model.moveSelectionToTrash() }
    }
    private func paste(at size: CGSize) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let center = world(CGPoint(x: size.width / 2, y: size.height / 2))
        model.pasteMemo(text, at: .init(x: center.x - 100, y: center.y - 60))
    }

    private func background(size: CGSize, pipes: [PipeGeometry]) -> some View {
        Canvas { context, canvasSize in
            let step = 20 * zoom
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
                let flow = pipe.edge.kind == .flow
                context.stroke(pipe.path, with: .color(flow ? ListTheme.ink : ListTheme.related),
                               style: StrokeStyle(lineWidth: flow ? 4 : 3, lineCap: .round, lineJoin: .round, dash: flow ? [] : [6, 6]))
                if flow { context.stroke(pipe.arrow, with: .color(ListTheme.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)) }
            }
            if linkStart != nil, let pointer = linkPointer {
                var line = Path(); line.move(to: linkPort); line.addLine(to: world(pointer))
                context.stroke(line, with: .color(ListTheme.ink.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            }
        }
    }

    private func boardCard(_ memo: MemoSummary, placement: BoardLayout.Placement, positions: [MemoID: BoardLayout.Placement], pipes: [PipeGeometry]) -> some View {
        let bounds = rect(placement)
        let endpoints = pipes.flatMap { pipe -> [CGPoint] in
            if pipe.edge.from == memo.id { return [pipe.points.first!] }
            if pipe.edge.to == memo.id { return [pipe.points.last!] }
            return []
        }
        return MemoCardView(memo: memo, index: index, visible: model.windowActions.isVisible(memo.id), board: true, select: { model.selection = [$0] })
            .frame(width: 200, height: 120)
            .modifier(CardSurface(selected: model.selection.contains(memo.id)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture(count: 2) { onOpen(memo.id) }
            .onTapGesture { select(memo.id); focused = true }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("메모보드"))
                .onChanged { value in
                    focused = true
                    if dragOrigins.isEmpty {
                        if !model.selection.contains(memo.id) { select(memo.id) }
                        for id in model.selection { dragOrigins[id] = positions[id] }
                    }
                    for (id, origin) in dragOrigins {
                        moving[id] = .init(x: origin.x + value.translation.width / zoom, y: origin.y + value.translation.height / zoom)
                    }
                }.onEnded { _ in
                    model.moveCards(moving)
                    moving = [:]; dragOrigins = [:]
                })
            .contextMenu { menu(memo.id) }
            .overlay {
                ZStack {
                    ForEach(0..<4, id: \.self) { side in
                        let point = port(side, bounds: bounds)
                        let connected = endpoints.contains { hypot($0.x - point.x, $0.y - point.y) < 1 }
                        if hovered == memo.id || connected || linkStart == memo.id {
                            LimeDot(size: 10).opacity(connected ? 1 : 0.55)
                                .frame(width: 20, height: 20).contentShape(Circle())
                                .position(x: point.x - bounds.minX, y: point.y - bounds.minY)
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("메모보드"))
                                    .onChanged { value in linkStart = memo.id; linkPort = point; linkPointer = value.location; focused = true }
                                    .onEnded { value in
                                        if let other = hitCard(at: world(value.location), positions: positions, excluding: memo.id) { model.link(from: memo.id, to: other, kind: kind) }
                                        linkStart = nil; linkPointer = nil
                                    })
                        }
                    }
                }
            }
            .onHover { inside in if inside { hovered = memo.id } else if hovered == memo.id { hovered = nil } }
            .scaleEffect(zoom)
            .position(screen(CGPoint(x: bounds.midX, y: bounds.midY)))
    }
    private func port(_ side: Int, bounds: CGRect) -> CGPoint {
        switch side {
        case 0: CGPoint(x: bounds.minX, y: bounds.midY)
        case 1: CGPoint(x: bounds.maxX, y: bounds.midY)
        case 2: CGPoint(x: bounds.midX, y: bounds.minY)
        default: CGPoint(x: bounds.midX, y: bounds.maxY)
        }
    }
    private func hitCard(at point: CGPoint, positions: [MemoID: BoardLayout.Placement], excluding id: MemoID) -> MemoID? {
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
            ForEach(MemoLinkKind.allCases, id: \.self) { item in
                Button { kind = item } label: {
                    HStack(spacing: 4) {
                        PipeSample(dashed: item == .related).stroke(ListTheme.ink, style: StrokeStyle(lineWidth: 2, dash: item == .related ? [4, 3] : [])).frame(width: 20, height: 8)
                        Text(item == .flow ? "흐름" : "관련")
                    }.padding(4).background(kind == item ? ListTheme.chipBg : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Divider().frame(height: 20)
            Button("자동 정리") { withAnimation(.easeOut(duration: 0.25)) { model.autoArrange(memos) } }
            Button("전체 보기") { fit(size: size, positions: positions) }
            Button { changeZoom(zoom / 1.2, size: size) } label: { Image(systemName: "minus") }.help("축소")
            Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 40)
            Button { changeZoom(zoom * 1.2, size: size) } label: { Image(systemName: "plus") }.help("확대")
        }.buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 12).frame(height: 44)
            .background(ListTheme.card, in: RoundedRectangle(cornerRadius: 12)).shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }
    private func changeZoom(_ value: CGFloat, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let before = world(center)
        zoom = min(2, max(0.4, value))
        pan = CGSize(width: center.x - before.x * zoom, height: center.y - before.y * zoom)
    }
    private func fit(size: CGSize, positions: [MemoID: BoardLayout.Placement]) {
        guard let bounds = allBounds(positions) else { return }
        zoom = min(2, max(0.4, min((size.width - 80) / bounds.width, (size.height - 160) / bounds.height)))
        pan = CGSize(width: size.width / 2 - bounds.midX * zoom, height: size.height / 2 - bounds.midY * zoom)
    }
    private func center(on id: MemoID, size: CGSize, positions: [MemoID: BoardLayout.Placement]) {
        guard let placement = positions[id] else { return }
        pan = CGSize(width: size.width / 2 - (placement.x + 100) * zoom, height: size.height / 2 - (placement.y + 60) * zoom)
    }
    private func allBounds(_ positions: [MemoID: BoardLayout.Placement]) -> CGRect? {
        positions.values.map { rect($0) }.reduce(nil) { result, rect in result.map { $0.union(rect) } ?? rect }
    }
    private func minimap(viewport: CGRect, positions: [MemoID: BoardLayout.Placement], size: CGSize) -> some View {
        let bounds = (allBounds(positions) ?? viewport).union(viewport).insetBy(dx: -40, dy: -40)
        let scale = min(132 / bounds.width, 80 / bounds.height)
        return Canvas { context, _ in
            context.translateBy(x: 4, y: 4)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            for (id, placement) in positions {
                context.fill(Path(roundedRect: rect(placement), cornerRadius: 12), with: .color(model.selection.contains(id) ? ListTheme.ink : ListTheme.muted.opacity(0.4)))
            }
            context.stroke(Path(viewport), with: .color(ListTheme.ink), lineWidth: 1.5 / scale)
        }.frame(width: 140, height: 88).background(ListTheme.card, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .gesture(SpatialTapGesture().onEnded { value in
                let point = CGPoint(x: bounds.minX + (value.location.x - 4) / scale, y: bounds.minY + (value.location.y - 4) / scale)
                pan = CGSize(width: size.width / 2 - point.x * zoom, height: size.height / 2 - point.y * zoom)
            })
    }
}

private struct PipeSample: Shape {
    var dashed: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: CGPoint(x: rect.minX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); return path
    }
}

/// 직각 파이프의 도형과 클릭 판정을 같은 점열에서 만든다
struct PipeGeometry {
    let edge: MemoEdge
    let points: [CGPoint]
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
    var midpoint: CGPoint { CGPoint(x: (points[1].x + points[2].x) / 2, y: (points[1].y + points[2].y) / 2) }
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
    var arrow: Path {
        let end = points.last!
        let previous = points.dropLast().last(where: { $0 != end }) ?? points[0]
        let angle = atan2(end.y - previous.y, end.x - previous.x)
        var path = Path()
        path.move(to: CGPoint(x: end.x - 12 * cos(angle) + 5 * sin(angle), y: end.y - 12 * sin(angle) - 5 * cos(angle)))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - 12 * cos(angle) - 5 * sin(angle), y: end.y - 12 * sin(angle) + 5 * cos(angle)))
        return path
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
