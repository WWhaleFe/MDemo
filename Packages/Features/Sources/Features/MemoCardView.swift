import MemoCore
import SwiftUI

extension MemoSummary {
    var listPreview: String {
        preview.components(separatedBy: "\n").dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }
    func listDate(trash: Bool) -> String {
        let date = trash ? (deletedAt ?? meta.modified) : meta.modified
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "a h:mm" : "M월 d일"
        return formatter.string(from: date)
    }
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
                Text("\(index.title(of: context.flow)) \(context.index + 1)/\(context.flow.memoIDs.count)").lineLimit(1)
            }.font(.system(size: 12)).foregroundStyle(ListTheme.text2)
                .padding(4).background(ListTheme.chipBg, in: RoundedRectangle(cornerRadius: 4))
        } else if let count = index.linkCount[id], count > 0 {
            Text("관련 \(count)").font(.system(size: 12)).foregroundStyle(ListTheme.text2).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ListTheme.related, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
    }
}

struct ChecklistProgress: View {
    let memo: MemoSummary
    var body: some View {
        let tasks = MemoListModel.checklist(memo)
        if !tasks.isEmpty {
            HStack(spacing: 8) {
                GeometryReader { geo in
                    Capsule().fill(ListTheme.chipBg)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ListTheme.ink).frame(width: geo.size.width * CGFloat(tasks.filter(\.checked).count) / CGFloat(tasks.count))
                        }
                }.frame(height: 4)
                Text("\(tasks.filter(\.checked).count)/\(tasks.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(ListTheme.muted)
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
                let tasks = MemoListModel.checklist(memo)
                ForEach(Array(tasks.prefix(6).enumerated()), id: \.offset) { _, task in
                    HStack(spacing: 8) {
                        Image(systemName: task.checked ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(ListTheme.ink)
                        Text(task.text).font(.system(size: 13)).foregroundStyle(ListTheme.text2).lineLimit(1)
                    }
                }
                if tasks.isEmpty { preview }
            } else { preview }
            Spacer(minLength: 0)
            ChecklistProgress(memo: memo)
            if span == .large, let context = index.flowByMemo[memo.id] {
                VStack(alignment: .leading, spacing: 8) {
                    MemoLinkChip(id: memo.id, index: index)
                    FlowChips(flow: context.flow, current: memo.id, index: index, terminals: true, select: select)
                }.padding(12).background(ListTheme.flowBg, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack(spacing: 4) {
                if board {
                    Text("연결 \(index.linkCount[memo.id] ?? 0)")
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
        Text(memo.listPreview).font(.system(size: span == .large ? 14 : 13))
            .foregroundStyle(ListTheme.text2).lineLimit(board || span == .large ? 2 : 3)
    }
}
