import AppKit
import MarkdownEngine
import Observation
import SwiftUI

/// 이미지 글자 읽기 미리보기 시트의 상태.
///
/// 왼쪽에 원본 썸네일, 오른쪽에 인식 결과(고칠 수 있음), 위에 "마크다운 | 텍스트만" 전환.
@MainActor
@Observable
final class ImageTextSheetModel {
    enum Phase { case recognizing, done, empty }

    var phase: Phase = .recognizing
    var isMarkdown = true {
        didSet { if oldValue != isMarkdown { rebuild() } }
    }
    /// 오른쪽에서 고칠 수 있는 결과. 형식을 바꾸면 인식 결과로 다시 만든다.
    var text = ""
    let thumbnail: NSImage?
    let replacesImage: Bool
    @ObservationIgnored private var lines: [OCRLine] = []
    @ObservationIgnored var onInsert: ((_ text: String, _ isPlain: Bool) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    init(thumbnail: NSImage?, replacesImage: Bool) {
        self.thumbnail = thumbnail
        self.replacesImage = replacesImage
    }

    func finish(with lines: [OCRLine]) {
        self.lines = lines
        phase = lines.isEmpty ? .empty : .done
        rebuild()
    }

    private func rebuild() {
        text = OCRMarkdownBuilder.build(lines: lines, mode: isMarkdown ? .markdown : .plain)
    }

    var canInsert: Bool { phase == .done && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct ImageTextSheetView: View {
    @Bindable var model: ImageTextSheetModel
    private let ink = Color(red: 28 / 255, green: 29 / 255, blue: 32 / 255)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack {
                    if let thumbnail = model.thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("원본 이미지")
                    } else {
                        Text("원본 이미지").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 220).padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Picker("형식", selection: $model.isMarkdown) {
                        Text("마크다운").tag(true)
                        Text("텍스트만").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .disabled(model.phase != .done)
                    ZStack {
                        TextEditor(text: $model.text)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ink.opacity(0.12)))
                            .disabled(model.phase != .done)
                            .accessibilityLabel("인식한 글자, 고칠 수 있음")
                        switch model.phase {
                        case .recognizing:
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("글자를 읽는 중") }
                                .foregroundStyle(.secondary)
                        case .empty:
                            Text("글자를 찾지 못했습니다").foregroundStyle(.secondary)
                        case .done:
                            EmptyView()
                        }
                    }
                }
                .padding(16).frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button("취소") { model.onCancel?() }.keyboardShortcut(.cancelAction)
                Button("복사") { model.copyText() }.disabled(!model.canInsert)
                Button("넣기") { model.onInsert?(model.text, !model.isMarkdown) }
                    .keyboardShortcut(.defaultAction).disabled(!model.canInsert)
                    .help(model.replacesImage ? "글을 넣고 이미지를 지웁니다" : "이미지 아래에 글을 넣습니다")
            }.padding(12)
        }
        .frame(width: 640, height: 400)
    }
}
