import Foundation

/// 슬래시 명령 (SL-01 ~ SL-05).
///
/// 줄 시작에서 `/`를 치면 목록이 뜨고, 이어 입력하면 좁혀지고, 고르면 그 블록으로 바뀐다.
/// 팝업을 그리는 일은 EditorKit이 하고, 여기서는 무엇이 있고 무엇이 걸리는지만 정한다.
public struct SlashCommand: Hashable, Sendable, Identifiable {
    public var id: String
    /// 메뉴에 보이는 이름.
    public var title: String
    /// 무엇을 하는지 한 줄 설명.
    public var subtitle: String
    /// 검색어. 한글과 영어를 모두 넣어 어느 쪽으로 쳐도 걸리게 한다 (SL-05).
    public var keywords: [String]
    /// 같은 결과를 내는 마크다운 입력. 목록에 함께 보여 주면 자연스럽게 익히게 된다.
    public var shortcut: String
    /// 고르면 적용될 블록.
    public var block: BlockStyle

    public init(
        id: String,
        title: String,
        subtitle: String,
        keywords: [String],
        shortcut: String = "",
        block: BlockStyle
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.shortcut = shortcut
        self.block = block
    }
}

public enum SlashCommandCatalog {
    /// 기본 명령 세트 (SL-04). 표·이미지·코드 블록은 해당 기능이 들어올 때 함께 추가한다.
    ///
    /// 배치 순서는 글의 구조를 따라간다 — 본문에서 제목으로, 목록으로, 마지막에 구분·인용.
    /// 목록에서 위아래로 훑을 때 이 순서가 눈에 익으면 화살표 횟수가 줄어든다.
    public static let standard: [SlashCommand] = [
        SlashCommand(
            id: "paragraph", title: "본문", subtitle: "서식을 없애고 보통 문단으로",
            keywords: ["본문", "문단", "text", "paragraph", "normal"],
            block: .paragraph
        ),
        SlashCommand(
            id: "heading1", title: "제목 1", subtitle: "가장 큰 제목",
            keywords: ["제목1", "제목", "heading1", "h1", "title"],
            shortcut: "# ",
            block: .heading(level: 1)
        ),
        SlashCommand(
            id: "heading2", title: "제목 2", subtitle: "중간 크기 제목",
            keywords: ["제목2", "제목", "heading2", "h2"],
            shortcut: "## ",
            block: .heading(level: 2)
        ),
        SlashCommand(
            id: "heading3", title: "제목 3", subtitle: "작은 제목",
            keywords: ["제목3", "제목", "heading3", "h3"],
            shortcut: "### ",
            block: .heading(level: 3)
        ),
        SlashCommand(
            id: "ordered", title: "번호 목록", subtitle: "1, 2, 3으로 이어지는 목록",
            keywords: ["번호", "숫자", "목록", "ordered", "number"],
            shortcut: "1. ",
            block: .ordered(indent: 0, number: 1)
        ),
        SlashCommand(
            id: "bullet", title: "글머리 목록", subtitle: "점으로 시작하는 목록",
            keywords: ["글머리", "목록", "리스트", "bullet", "list"],
            shortcut: "- ",
            block: .bullet(indent: 0)
        ),
        SlashCommand(
            id: "checkbox", title: "체크박스", subtitle: "클릭해서 체크하는 할 일 목록",
            keywords: ["체크박스", "할일", "todo", "checkbox", "check"],
            shortcut: "[] ",
            block: .checkbox(indent: 0, checked: false)
        ),
        SlashCommand(
            id: "divider", title: "구분선", subtitle: "가로줄로 구역을 나눕니다",
            keywords: ["구분선", "구분", "선", "divider", "line", "hr"],
            shortcut: "---",
            block: .divider
        ),
        SlashCommand(
            id: "quote", title: "인용", subtitle: "인용문으로 표시",
            keywords: ["인용", "따옴", "quote"],
            shortcut: "> ",
            block: .quote
        ),
    ]

    /// 글자 서식은 블록이 아니라 감싸는 기호로 넣는다. 팝업 아래쪽에 안내로만 보여 준다.
    public static let inlineHints: [(label: String, shortcut: String)] = [
        ("굵게", "**글자**"),
        ("기울임", "*글자*"),
        ("취소선", "~~글자~~"),
        ("형광", "==글자=="),
        ("코드", "`글자`"),
    ]

    /// 입력한 글자로 목록을 좁힌다 (SL-02).
    ///
    /// 앞에서부터 일치하는 것을 먼저 보여준다 — "제"를 쳤을 때 "제목"이 위로 오는 편이 자연스럽다.
    public static func filter(_ query: String, in commands: [SlashCommand] = standard) -> [SlashCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return commands }

        var prefixMatches: [SlashCommand] = []
        var containsMatches: [SlashCommand] = []

        for command in commands {
            let haystacks = ([command.title] + command.keywords).map { $0.lowercased() }
            if haystacks.contains(where: { $0.hasPrefix(needle) }) {
                prefixMatches.append(command)
            } else if haystacks.contains(where: { $0.contains(needle) }) {
                containsMatches.append(command)
            }
        }
        return prefixMatches + containsMatches
    }
}
