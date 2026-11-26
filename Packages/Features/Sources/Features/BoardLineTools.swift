import AppKit
import MemoCore
import SwiftUI

struct LineSample: View {
    let kind: MemoLinkKind
    @MainActor static func menuIcon(_ kind: MemoLinkKind) -> Image {
        let renderer = ImageRenderer(content: LineSample(kind: kind).frame(width: 40, height: 24))
        renderer.scale = 2
        return Image(nsImage: renderer.nsImage ?? NSImage(size: NSSize(width: 40, height: 24)))
    }
    var body: some View {
        Canvas { context, size in
            let pipe = PipeGeometry(edge: MemoEdge(from: .init(rawValue: ""), to: .init(rawValue: ""), kind: kind),
                                    points: [CGPoint(x: 7, y: size.height / 2), CGPoint(x: size.width - 4, y: size.height / 2)])
            pipe.draw(in: &context, sample: true)
        }.accessibilityHidden(true)
    }
}

struct BoardLineTools: View {
    let selected: MemoLinkKind
    let availableWidth: CGFloat
    let choose: (MemoLinkKind) -> Void
    @AppStorage("board.lineButtonStyle", store: AppSettings.defaults) private var style = "A"
    @AppStorage("board.showPipeLabels", store: AppSettings.defaults) private var labels = true
    @State private var visibleNames = AppSettings.defaults.stringArray(forKey: "board.visibleLineKinds") ?? MemoLinkKind.basic.map(\.rawValue)
    @State private var legend = false
    @State private var visibility = false
    private var visible: [MemoLinkKind] {
        let values = MemoLinkKind.allCases.filter { visibleNames.contains($0.rawValue) }
        return values.isEmpty ? MemoLinkKind.basic : values
    }
    private var shown: [MemoLinkKind] {
        {
        // 실제 칸 크기로 계산한다: 선 단추 56(견본만 44) + 간격 2, 묶음 구분선 8, 오른쪽 더 보기 · 뜻 · 이름표 세 칸과 여백.
        let cell: CGFloat = style == "A" ? 52 : 42
        let tools: CGFloat = (style == "A" ? 44 : 32) * 3 + 40
        let groups = Set(visible.map(\.group)).count
        let room = availableWidth - tools - CGFloat(max(0, groups - 1)) * 8
        return Array(visible.prefix(max(0, Int(room / cell))))
    }()
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.element) { offset, kind in
                if offset > 0 && shown[offset - 1].group != kind.group { Divider().frame(height: 22).padding(.horizontal, 2) }
                Button { choose(kind) } label: {
                    VStack(spacing: 1) {
                        // 화살표 · 원 크기가 고정이라 작은 칸에 바로 그리면 뭉개진다. 원래 크기(44×24)로 그린 뒤 통째로 줄인다.
                        LineSample(kind: kind).frame(width: 44, height: 24).scaleEffect(style == "A" ? 0.74 : 0.7)
                            .frame(width: style == "A" ? 34 : 30, height: style == "A" ? 14 : 16)
                        if style == "A" { Text(kind.displayName).font(.system(size: 10, weight: selected == kind ? .semibold : .regular)) }
                    }.frame(width: style == "A" ? 50 : 40, height: style == "A" ? 34 : 28)
                        .background(selected == kind ? ListTheme.chipBg : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected == kind ? ListTheme.ink : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }.help(kind.help).accessibilityLabel(kind.help)
            }
            if !shown.isEmpty { Divider().frame(height: 22) }
            Menu {
                ForEach(MemoLinkKind.allCases.filter { !shown.contains($0) }, id: \.self) { kind in
                    Button { choose(kind) } label: { Label { Text(kind.displayName) } icon: { LineSample.menuIcon(kind) } }
                        .help(kind.help).accessibilityLabel(kind.help)
                }
                Divider()
                Button("도구 막대에 보일 선…") { visibility = true }
                Menu("단추 모양") {
                    Picker("단추 모양", selection: $style) { Text("이름 함께 (기본, 높이 40)").tag("A"); Text("견본만 (높이 34)").tag("C") }
                }
            } label: {
                toolCell(Image(systemName: "ellipsis"), title: "더 보기", active: false)
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("더 보기")
                .popover(isPresented: $visibility) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("도구 막대에 보일 선").font(.headline)
                        ForEach(MemoLinkKind.allCases, id: \.self) { kind in
                            Toggle(isOn: Binding(get: { visible.contains(kind) }, set: { on in
                                var values = visible
                                if on { values.append(kind) } else { values.removeAll { $0 == kind } }
                                save(values)
                            })) { HStack { LineSample(kind: kind).frame(width: 40, height: 24); Text(kind.displayName) } }
                                .disabled(visible.count == 1 && visible.contains(kind))
                        }
                        HStack { Button("모두 보이기") { save(MemoLinkKind.allCases) }; Button("기본 6개로") { save(MemoLinkKind.basic) } }
                    }.padding(16)
                }
            Button { legend = true } label: { toolCell(Image(systemName: "info.circle"), title: "뜻", active: legend) }.help("선 이름과 뜻")
                .popover(isPresented: $legend) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(MemoLinkKind.allCases, id: \.self) { kind in
                            if kind == .contain { Divider(); Text("더 보기").foregroundStyle(.secondary) }
                            HStack(spacing: 10) {
                                LineSample(kind: kind).frame(width: 40, height: 24)
                                VStack(alignment: .leading, spacing: 3) { Text(kind.displayName).bold(); Text(kind.meaning).font(.system(size: 12)) }
                            }
                        }
                    }.padding(16).frame(width: 430)
                }
            Button { labels.toggle() } label: {
                toolCell(Image(systemName: "tag"), title: "이름표", active: labels)
            }.help("보드 선 이름표 보이기").accessibilityValue(labels ? "켬" : "끔")
        }.buttonStyle(.plain)
    }
    /// 선 단추와 같은 칸: 위에 그림, 아래에 이름(A 모양일 때). 선 단추와 같은 높이(A 34, 견본만 28)로 맞춰 막대 안에서 가운데 정렬된다.
    private func toolCell(_ image: Image, title: String, active: Bool) -> some View {
        VStack(spacing: 0) {
            image.font(.system(size: style == "A" ? 12 : 14, weight: .regular)).frame(width: 30, height: style == "A" ? 14 : 16)
            if style == "A" { Text(title).font(.system(size: 10, weight: active ? .semibold : .regular)) }
        }
        .frame(width: style == "A" ? 44 : 32, height: style == "A" ? 34 : 28)
        .background(active ? ListTheme.ink.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(ListTheme.ink)
        .contentShape(Rectangle())
    }

    private func save(_ values: [MemoLinkKind]) {
        guard !values.isEmpty else { return }
        visibleNames = MemoLinkKind.allCases.filter { values.contains($0) }.map(\.rawValue)
        AppSettings.defaults.set(visibleNames, forKey: "board.visibleLineKinds")
    }
}

struct PipeLabelEditor: View {
    let edge: MemoEdge
    let confirm: (String) -> Void
    let cancel: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool
    init(edge: MemoEdge, confirm: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.edge = edge; self.confirm = confirm; self.cancel = cancel
        _text = State(initialValue: edge.label)
    }
    var body: some View {
        HStack(spacing: 6) {
            Text(edge.kind.displayName).font(.system(size: 11)).padding(5).background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 5))
            TextField("이름 (최대 20자)", text: $text).textFieldStyle(.plain).frame(width: 150).focused($focused)
                .onSubmit { confirm(text) }.onExitCommand(perform: cancel)
                .onChange(of: text) { _, value in text = MemoLink.normalizedLabel(value) }
                .onChange(of: focused) { _, value in if !value { confirm(text) } }
        }.padding(6).foregroundStyle(ListTheme.ink).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ListTheme.ink, lineWidth: 1.5))
            .background(PipeEditorOutsideClick { confirm(text) })
            .onAppear { focused = true }
    }
}

private struct PipeEditorOutsideClick: NSViewRepresentable {
    let confirm: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(confirm: confirm) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak coordinator = context.coordinator] event in
            if let coordinator, let view = coordinator.view, let window = view.window, event.window === window,
               !view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { coordinator.confirm() }
            return event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.confirm = confirm }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) } }
    @MainActor final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var confirm: () -> Void
        init(confirm: @escaping () -> Void) { self.confirm = confirm }
    }
}
