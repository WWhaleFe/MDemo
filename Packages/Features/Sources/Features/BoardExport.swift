import AppKit
import MemoCore
import SwiftUI
import UniformTypeIdentifiers

/// 현재 범위에서 잠긴 카드와 그 연결을 제거한 내보내기 자료.
struct BoardExportContent {
    let memos: [MemoSummary]
    let positions: [MemoID: BoardLayout.Placement]
    let edges: [MemoEdge]
    let excludedCount: Int
    let bounds: CGRect
    var index: MemoListModel.LinkIndex

    init(memos: [MemoSummary], positions: [MemoID: BoardLayout.Placement], index: MemoListModel.LinkIndex) {
        self.memos = memos.filter { !$0.meta.isLocked }
        excludedCount = memos.count - self.memos.count
        let ids = Set(self.memos.map(\.id))
        self.positions = positions.filter { ids.contains($0.key) }
        edges = index.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        bounds = self.positions.values.map { CGRect(x: $0.x, y: $0.y, width: 200, height: 120) }
            .reduce(nil as CGRect?) { result, rect in result.map { $0.union(rect) } ?? rect } ?? CGRect(x: 0, y: 0, width: 200, height: 120)
        var safe = MemoListModel.LinkIndex()
        safe.edges = edges
        safe.summaries = Dictionary(uniqueKeysWithValues: self.memos.map { ($0.id, $0) })
        for edge in edges {
            safe.linkCount[edge.from, default: 0] += 1
            safe.linkCount[edge.to, default: 0] += 1
            safe.countsByKind[edge.from, default: [:]][edge.kind, default: 0] += 1
            safe.countsByKind[edge.to, default: [:]][edge.kind, default: 0] += 1
        }
        // 잠긴 메모를 사이에 둔 흐름은 나누어 제목이나 순서에 흔적을 남기지 않는다.
        for flow in index.flows {
            var remaining = Set(flow.memoIDs).intersection(ids)
            for seed in flow.memoIDs where remaining.contains(seed) {
                var pending = [seed], members = Set<MemoID>()
                while let id = pending.popLast() {
                    guard members.insert(id).inserted else { continue }
                    for edge in edges where edge.kind == .flow && (edge.from == id || edge.to == id) {
                        pending.append(edge.from == id ? edge.to : edge.from)
                    }
                }
                remaining.subtract(members)
                let ordered = flow.memoIDs.filter { members.contains($0) }
                guard ordered.count > 1 else { continue }
                let part = MemoFlow(id: ordered[0], memoIDs: ordered)
                safe.flows.append(part)
                for (offset, id) in ordered.enumerated() { safe.flowByMemo[id] = (part, offset) }
            }
        }
        self.index = safe
    }

    func size(footer: Bool, scale: Int = 1) -> CGSize {
        CGSize(width: ceil(bounds.width + 80) * CGFloat(scale), height: ceil(bounds.height + 80 + (footer ? 28 : 0)) * CGFloat(scale))
    }
    func isTooLarge(footer: Bool, scale: Int) -> Bool {
        let size = size(footer: footer, scale: scale)
        return size.width > 16384 || size.height > 16384
    }
}

private struct BoardExportOptions: Equatable {
    var grid = true
    var pipes = true
    var labels = UserDefaults.standard.object(forKey: "board.showPipeLabels") as? Bool ?? true
    var footer = true
    var scale = 2
}

private struct BoardExportImage: View {
    let model: MemoListModel
    let content: BoardExportContent
    let options: BoardExportOptions
    let date: Date
    let pixelScale: CGFloat

    var body: some View {
        let size = content.size(footer: options.footer)
        ZStack(alignment: .topLeading) {
            ListTheme.boardBg
            Canvas { context, _ in
                if options.grid {
                    var dots = Path()
                    var step: CGFloat = 20
                    while step * pixelScale < 4 { step *= 2 }
                    for x in stride(from: 0.0, through: size.width, by: step) {
                        for y in stride(from: 0.0, through: size.height, by: step) {
                            dots.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                        }
                    }
                    context.fill(dots, with: .color(ListTheme.boardDot))
                }
                context.translateBy(x: 40 - content.bounds.minX, y: 40 - content.bounds.minY)
                if options.pipes {
                    for pipe in PipeGeometry.make(edges: content.edges, positions: content.positions) {
                        pipe.draw(in: &context)
                        if options.labels { pipe.drawLabel(in: &context, avoiding: content.positions.values.map { CGRect(x: $0.x, y: $0.y, width: 200, height: 120) }) }
                    }
                }
            }
            ForEach(content.memos) { memo in
                if let placement = content.positions[memo.id] {
                    MemoCardView(memo: memo, info: model.cardInfo(for: memo), index: content.index,
                                 visible: model.windowActions.isVisible(memo.id), board: true, select: { _ in })
                        .frame(width: 200, height: 120).modifier(CardSurface())
                        .position(x: placement.x - content.bounds.minX + 140, y: placement.y - content.bounds.minY + 100)
                }
            }
            if options.footer {
                HStack(spacing: 6) {
                    LimeDot(size: 6)
                    Text("MDemo 보드 · \(date.formatted(.dateTime.year().month().day().locale(Locale(identifier: "ko_KR"))))")
                        .font(.system(size: 11)).foregroundStyle(ListTheme.muted)
                }.position(x: size.width / 2, y: size.height - 20)
            }
        }.frame(width: size.width, height: size.height)
    }
}

struct BoardExportSheet: View {
    let model: MemoListModel
    let memos: [MemoSummary]
    let index: MemoListModel.LinkIndex
    @Environment(\.dismiss) private var dismiss
    @State private var options = BoardExportOptions()
    @State private var preview: NSImage?
    @State private var notice: String?
    @State private var shareAnchor: NSView?
    @State private var picker: NSSharingServicePicker?
    @State private var temporaryFolders: [URL] = []
    @State private var date = Date()

    private var content: BoardExportContent {
        BoardExportContent(memos: memos, positions: model.boardPlacements(for: memos), index: index)
    }
    private var tooLarge: Bool { content.isTooLarge(footer: options.footer, scale: options.scale) }
    var body: some View {
        VStack(spacing: 0) {
            Text("보드를 이미지로 내보내기").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    Color.black.opacity(0.05)
                    if let preview {
                        Image(nsImage: preview).resizable().scaledToFit().padding(16).accessibilityLabel("내보낼 보드 미리보기")
                    } else { Text("미리보기를 만들지 못했습니다").foregroundStyle(.secondary) }
                }.frame(width: 360)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("점 격자 배경", isOn: $options.grid)
                    Toggle("파이프", isOn: $options.pipes)
                    Toggle("선 이름표", isOn: $options.labels).padding(.leading, 16).disabled(!options.pipes)
                    Toggle("아래에 날짜와 MDemo 표시", isOn: $options.footer)
                    Text("크기").font(.caption).foregroundStyle(.secondary)
                    Picker("크기", selection: $options.scale) {
                        Text("1배").tag(1)
                        if !content.isTooLarge(footer: options.footer, scale: 2) { Text("2배").tag(2) }
                    }.pickerStyle(.segmented).labelsHidden()
                    let size = content.size(footer: options.footer, scale: options.scale)
                    Text("예상 크기 \(Int(size.width)) × \(Int(size.height))").font(.caption).foregroundStyle(.secondary)
                    if tooLarge { Text("너무 커서 만들 수 없습니다").font(.caption).foregroundStyle(.red) }
                    if content.excludedCount > 0 {
                        Text("잠긴 메모 \(content.excludedCount)개와 그 파이프는 넣지 않았습니다").font(.caption).foregroundStyle(.secondary)
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }.padding(16).frame(width: 280)
            }
            Divider()
            HStack(spacing: 8) {
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("공유") { share() }.background(BoardShareAnchor(anchor: $shareAnchor)).disabled(tooLarge)
                Button("복사") {
                    guard let data = png() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(data, forType: .png)
                    notice = "클립보드에 복사했습니다"
                }.disabled(tooLarge)
                Button("PNG로 저장…") { save() }.keyboardShortcut(.defaultAction).disabled(tooLarge)
            }.padding(12)
        }.frame(width: 641, height: 440)
            .onAppear { refresh() }
            .onDisappear {
                for folder in temporaryFolders { try? FileManager.default.removeItem(at: folder) }
                temporaryFolders = []
            }
            .onChange(of: options) { _, _ in refresh() }
            .onChange(of: memos) { _, _ in refresh() }
            .onChange(of: index.edges) { _, _ in refresh() }
            .onChange(of: model.store.boardLayout) { _, _ in refresh() }
    }

    private func render(scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: BoardExportImage(model: model, content: content, options: options, date: date, pixelScale: scale))
        renderer.scale = scale
        return renderer.cgImage
    }
    private func refresh() {
        if options.scale == 2, content.isTooLarge(footer: options.footer, scale: 2) { options.scale = 1 }
        let size = content.size(footer: options.footer)
        // 미리보기는 큰 보드도 작은 비트맵으로 만들어 메모리를 아낀다.
        preview = render(scale: min(1, 640 / max(size.width, size.height))).map { NSImage(cgImage: $0, size: size) }
    }
    private func png() -> Data? {
        guard !tooLarge, let image = render(scale: CGFloat(options.scale)),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            notice = "이미지를 만들지 못했습니다"; return nil
        }
        return data
    }
    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "보드.png"
        guard let window = shareAnchor?.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { if let data = png() { try data.write(to: url, options: .atomic); notice = "저장했습니다" } }
            catch { notice = "이미지를 저장하지 못했습니다: \(error.localizedDescription)" }
        }
    }
    private func share() {
        guard let anchor = shareAnchor, let data = png() else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mdemo-board-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("보드.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            temporaryFolders.append(folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            notice = "공유할 파일을 만들지 못했습니다"; return
        }
        let picker = NSSharingServicePicker(items: [file])
        self.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}

private struct BoardShareAnchor: NSViewRepresentable {
    @Binding var anchor: NSView?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { anchor = view }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
