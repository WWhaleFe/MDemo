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
    @AppStorage("board.lineButtonStyle") private var style = "A"
    @AppStorage("board.showPipeLabels") private var labels = true
    @State private var visibleNames = UserDefaults.standard.stringArray(forKey: "board.visibleLineKinds") ?? MemoLinkKind.basic.map(\.rawValue)
    @State private var legend = false
    @State private var visibility = false
    private var visible: [MemoLinkKind] {
        let values = MemoLinkKind.allCases.filter { visibleNames.contains($0.rawValue) }
        return values.isEmpty ? MemoLinkKind.basic : values
    }
    private var shown: [MemoLinkKind] {
        Array(visible.prefix(max(0, Int((availableWidth - 160) / (style == "A" ? 60 : 48)))))
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.element) { offset, kind in
                if offset > 0 && shown[offset - 1].group != kind.group { Divider().frame(height: 30).padding(.horizontal, 2) }
                Button { choose(kind) } label: {
                    VStack(spacing: 0) {
                        LineSample(kind: kind).frame(width: 40, height: 24)
                        if style == "A" { Text(kind.displayName).font(.system(size: 11, weight: selected == kind ? .semibold : .regular)) }
                    }.frame(width: style == "A" ? 56 : 44, height: 44)
                        .background(selected == kind ? ListTheme.chipBg : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected == kind ? ListTheme.ink : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }.help(kind.help).accessibilityLabel(kind.help)
            }
            if !shown.isEmpty { Divider().frame(height: 30) }
            Menu {
                ForEach(MemoLinkKind.allCases.filter { !shown.contains($0) }, id: \.self) { kind in
                    Button { choose(kind) } label: { Label { Text(kind.displayName) } icon: { LineSample.menuIcon(kind) } }
                        .help(kind.help).accessibilityLabel(kind.help)
                }
                Divider()
                Button("도구 막대에 보일 선…") { visibility = true }
                Menu("단추 모양") {
                    Picker("단추 모양", selection: $style) { Text("이름 함께(A, 기본)").tag("A"); Text("견본만(C)").tag("C") }
                }
            } label: {
                VStack(spacing: 0) { Text("⋯").font(.system(size: 20)); if style == "A" { Text("더 보기").font(.system(size: 11)) } }.frame(width: 48, height: 44)
            }.menuStyle(.borderlessButton).fixedSize().help("더 보기")
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
            Button { legend = true } label: { Image(systemName: "info.circle").frame(width: 24, height: 30) }.help("선 이름과 뜻")
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
                Label("이름표", systemImage: "tag").padding(6).background(labels ? ListTheme.chipBg : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.help("보드 선 이름표 보이기").accessibilityValue(labels ? "켬" : "끔")
        }.buttonStyle(.plain)
    }
    private func save(_ values: [MemoLinkKind]) {
        guard !values.isEmpty else { return }
        visibleNames = MemoLinkKind.allCases.filter { values.contains($0) }.map(\.rawValue)
        UserDefaults.standard.set(visibleNames, forKey: "board.visibleLineKinds")
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
