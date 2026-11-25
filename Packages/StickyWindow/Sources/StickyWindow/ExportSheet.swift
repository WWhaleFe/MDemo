import AppKit
import EditorKit
import Observation
import SwiftUI

/// 메모를 이미지로 내보내는 시트의 상태.
///
/// 옵션이 바뀔 때마다 1배로 미리보기를 다시 그린다. 저장 · 복사 · 공유는 고른 배율로 새로 그린다.
@MainActor
@Observable
final class ExportSheetModel {
    var options = MemoExportOptions() {
        didSet { if oldValue != options { refresh() } }
    }
    private(set) var preview: NSImage?
    private(set) var sizeText = ""
    private(set) var isTooLarge = false
    let hasFlow: Bool

    /// 옵션으로 결과 크기를 계산한다 (화면 그리기 없이).
    @ObservationIgnored let layoutProvider: (MemoExportOptions) -> MemoExportOptions.Layout
    /// 옵션으로 그림을 그린다. 실패하면 nil.
    @ObservationIgnored let renderer: (MemoExportOptions) -> NSBitmapImageRep?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var onSave: (() -> Void)?
    @ObservationIgnored var onCopy: (() -> Void)?
    @ObservationIgnored var onShare: (() -> Void)?
    /// 공유 목록을 띄울 기준 뷰.
    @ObservationIgnored weak var shareAnchor: NSView?
    private(set) var notice: String?

    init(
        hasFlow: Bool,
        layoutProvider: @escaping (MemoExportOptions) -> MemoExportOptions.Layout,
        renderer: @escaping (MemoExportOptions) -> NSBitmapImageRep?
    ) {
        self.hasFlow = hasFlow
        self.layoutProvider = layoutProvider
        self.renderer = renderer
        refresh()
    }

    func refresh() {
        let layout = layoutProvider(options)
        sizeText = layout.sizeText
        isTooLarge = layout.isTooLarge
        var preview = options
        preview.scale = 1
        if let rep = renderer(preview) {
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            self.preview = image
        } else {
            self.preview = nil
        }
    }

    func show(notice: String?) { self.notice = notice }
}

struct ExportSheetView: View {
    @Bindable var model: ExportSheetModel
    private let ink = Color(red: 28 / 255, green: 29 / 255, blue: 32 / 255)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    if let image = model.preview {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                            .accessibilityLabel("내보낼 이미지 미리보기")
                    } else {
                        Text("미리보기를 만들지 못했습니다").foregroundStyle(.secondary).padding(20)
                    }
                }
                .frame(width: 300)
                .background(Color.black.opacity(0.05))
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("메모 색 배경", isOn: $model.options.usesMemoColor)
                    Toggle("아래에 날짜와 MDemo 표시", isOn: $model.options.showsFooter)
                    Toggle("흐름 줄 포함", isOn: $model.options.includesFlowStrip).disabled(!model.hasFlow)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("크기").font(.system(size: 12)).foregroundStyle(.secondary)
                        Picker("크기", selection: $model.options.scale) {
                            ForEach(MemoExportOptions.scales, id: \.self) { Text("\($0)배").tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Text(model.isTooLarge ? "너무 커서 만들 수 없습니다 (\(model.sizeText)). 배율을 낮춰 주세요" : "예상 크기 \(model.sizeText)")
                        .font(.system(size: 12)).foregroundStyle(model.isTooLarge ? Color.red : Color.secondary)
                    if let notice = model.notice {
                        Text(notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16).frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Button("닫기") { model.onClose?() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("복사") { model.onCopy?() }.disabled(model.isTooLarge)
                Button("공유") { model.onShare?() }
                    .disabled(model.isTooLarge)
                    .background(ShareAnchor(model: model))
                Button("PNG로 저장…") { model.onSave?() }
                    .keyboardShortcut(.defaultAction).disabled(model.isTooLarge)
            }.padding(12)
        }
        .frame(width: 640, height: 440)
    }
}

/// 공유 목록(`NSSharingServicePicker`)을 띄울 기준 뷰를 모델에 알려 준다.
private struct ShareAnchor: NSViewRepresentable {
    let model: ExportSheetModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { model.shareAnchor = view }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        model.shareAnchor = view
    }
}
