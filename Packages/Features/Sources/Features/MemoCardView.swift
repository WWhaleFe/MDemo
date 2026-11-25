import MemoCore
import SwiftUI

extension MemoSummary {
    func listDate(trash: Bool) -> String {
        let date = trash ? (deletedAt ?? meta.modified) : meta.modified
        let formatter = Calendar.current.isDateInToday(date) ? ListDateFormat.today : ListDateFormat.other
        return formatter.string(from: date)
    }
}

/// 날짜 포매터는 만드는 값이 비싸서 한 번만 만든다. 메모 내용은 담지 않는다.
private enum ListDateFormat {
    static let today = make("a h:mm")
    static let other = make("M월 d일")
    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = format
        return formatter
    }
}

/// 줄 앞의 목록 · 인용 · 제목 기호. 한 번만 컴파일한다.
private let previewPrefixPattern = try! NSRegularExpression(
    pattern: #"^(?:[-*+]\s+\[[ xX]\]\s*|[-*+]\s+|\d+\.\s+|>\s*|#+\s*)"#)

/// 줄 전체가 이미지 문법으로 시작하는가 (`![설명](경로`).
func isImagePreviewLine(_ text: String) -> Bool {
    text.hasPrefix("![") && text.contains("](")
}

/// 목록과 카드에서 같은 규칙으로 마크다운 기호를 걷어 낸다.
func cleanedMemoPreview(_ preview: String, singleLine: Bool = false, excludingTitle: Bool = true) -> String {
    var sourceLines = preview.components(separatedBy: "\n")
    // 제목 줄은 뺀다. 이미지 줄은 제목이 아니므로(MemoSummary.title 참고) 그 앞의 이미지 줄은 남기고 첫 글 줄을 뺀다.
    if excludingTitle,
       let titleIndex = sourceLines.firstIndex(where: { !isImagePreviewLine($0.trimmingCharacters(in: .whitespaces)) }) {
        sourceLines.remove(at: titleIndex)
    }
    return sourceLines.compactMap { line -> String? in
        var text = line.trimmingCharacters(in: .whitespaces)
        guard !text.hasPrefix("```") else { return nil }
        // 이미지 줄(`![설명](attachments/...)`)은 원문 대신 "[이미지]"로 보인다.
        // 미리보기는 200자에서 잘리므로 닫는 괄호가 없어도 이미지 줄로 본다.
        if isImagePreviewLine(text) { return "[이미지]" }
        while true {
            let whole = NSRange(location: 0, length: (text as NSString).length)
            guard let match = previewPrefixPattern.firstMatch(in: text, range: whole), match.range.length > 0 else { break }
            text = (text as NSString).substring(from: match.range.length)
        }
        for marker in ["**", "__", "~~", "`", "*", "_"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.isEmpty ? nil : text
    }.joined(separator: singleLine ? " · " : "\n")
}

struct MemoColorChip: View {
    let memo: MemoSummary
    var body: some View {
        let rgb = MemoColor.components(fromHex: memo.meta.colorHex)
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(red: rgb?.red ?? 0.5, green: rgb?.green ?? 0.5, blue: rgb?.blue ?? 0.5))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(ListTheme.ink.opacity(0.14)))
            .frame(width: 10, height: 10)
    }
}

struct ConflictChip: View {
    var body: some View {
        Text("충돌 사본").font(.system(size: 12)).foregroundStyle(ListTheme.text2)
            .padding(.horizontal, 4).padding(.vertical, 2).background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 4))
            .help("다른 기기에서 같은 메모를 함께 고쳐 사본이 만들어졌습니다")
    }
}

struct MemoLinkChip: View {
    let id: MemoID
    let index: MemoListModel.LinkIndex
    var body: some View {
        if let context = index.flowByMemo[id] {
            HStack(spacing: 4) {
                FlowSymbol().stroke(ListTheme.text2, lineWidth: 1.5).frame(width: 16, height: 12)
                Text(index.title(of: context.flow)).lineLimit(1).truncationMode(.tail)
                Text("\(context.index + 1)/\(context.flow.memoIDs.count)").monospacedDigit().fixedSize()
            }.font(.system(size: 12)).foregroundStyle(ListTheme.text2)
                .padding(4).background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 4))
        } else if let count = index.linkCount[id], count > 0 {
            Text("관련 \(count)").font(.system(size: 12)).foregroundStyle(ListTheme.text2).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ListTheme.related, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
    }
}

struct ChecklistProgress: View {
    let info: MemoListModel.CardInfo
    var body: some View {
        if info.total > 0 {
            HStack(spacing: 8) {
                Capsule().fill(ListTheme.chipBg).frame(maxWidth: .infinity).frame(height: 4)
                    .overlay {
                        Capsule().fill(ListTheme.ink)
                            .scaleEffect(x: CGFloat(info.done) / CGFloat(info.total), anchor: .leading)
                    }
                Text("\(info.done)/\(info.total)").font(.system(size: 12).monospacedDigit()).foregroundStyle(ListTheme.muted)
            }
        }
    }
}

struct FlowChips: View {
    let flow: MemoFlow
    let current: MemoID
    let index: MemoListModel.LinkIndex
    var terminals = false
    let select: (MemoID) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if terminals { LimeDot() }
                ForEach(Array(flow.memoIDs.enumerated()), id: \.element) { offset, id in
                    if offset > 0 { Rectangle().fill(ListTheme.ink).frame(width: 16, height: terminals ? 3 : 2) }
                    Button { select(id) } label: {
                        Text(index.summaries[id]?.title ?? "메모").lineLimit(1)
                            .font(.system(size: 12, weight: current == id ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(current == id ? ListTheme.ink : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
                if terminals { LimeDot() }
            }.padding(2)
        }.frame(height: 32)
    }
}

struct MemoCardView: View {
    let memo: MemoSummary
    let info: MemoListModel.CardInfo
    let index: MemoListModel.LinkIndex
    let visible: Bool
    var trash = false
    var span: BoardLayout.BentoSpan = .small
    var board = false
    let select: (MemoID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: board ? 4 : (span == .large ? 6 : 8)) {
            if span == .large {
                HStack {
                    Text(memo.meta.group ?? "미분류").font(.system(size: 12)).foregroundStyle(ListTheme.muted)
                    Spacer()
                    if visible { LimeDot() }
                }
            }
            HStack(spacing: 8) {
                MemoColorChip(memo: memo)
                Text(memo.title).font(.system(size: span == .large ? 22 : 14, weight: span == .large ? .bold : .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if visible && span != .large { LimeDot() }
            }
            if memo.meta.conflictOf != nil { ConflictChip() }
            if span == .tall {
                let tasks = info.tasks
                ForEach(Array(tasks.prefix(6).enumerated()), id: \.offset) { _, task in
                    HStack(spacing: 8) {
                        Image(systemName: task.checked ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(ListTheme.ink)
                        Text(task.text).font(.system(size: 13)).foregroundStyle(ListTheme.text2).lineLimit(1)
                    }
                }
                if tasks.isEmpty { preview }
            } else { preview }
            Spacer(minLength: 0)
            ChecklistProgress(info: info)
            if span == .large, let context = index.flowByMemo[memo.id] {
                VStack(alignment: .leading, spacing: 8) {
                    MemoLinkChip(id: memo.id, index: index)
                    FlowChips(flow: context.flow, current: memo.id, index: index, terminals: true, select: select)
                }.padding(12).background(ListTheme.flowBg, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 4) {
                if board {
                    MemoLinkChip(id: memo.id, index: index)
                } else if span != .large || index.flowByMemo[memo.id] == nil { MemoLinkChip(id: memo.id, index: index) }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(memo.listDate(trash: trash)).monospacedDigit()
                    if !board, span != .large, let group = memo.meta.group { Text(group).lineLimit(1) }
                }
            }.font(.system(size: 12)).foregroundStyle(ListTheme.muted)
        }
        .padding(.horizontal, span == .large ? 20 : 16)
        .padding(.vertical, span == .large ? 20 : (board ? 14 : 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(ListTheme.ink)
        .clipped()
    }
    private var preview: some View {
        Text(info.preview).font(.system(size: span == .large ? 14 : 13))
            .foregroundStyle(ListTheme.text2).lineLimit(board || span == .large ? 2 : 3)
    }
}
