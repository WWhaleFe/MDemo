import AppKit

/// 글꼴 이름을 실제 `NSFont`로 바꾼다 (TXT-02).
///
/// 기본값은 맑은 고딕이다. 다만 맑은 고딕은 Windows 글꼴이라 macOS에는 없는 경우가 많으므로,
/// 설치돼 있으면 그대로 쓰고 없으면 생김새가 가장 가까운 순서로 대체한다.
/// 사용자가 고른 글꼴이 나중에 삭제되더라도 같은 경로로 안전하게 대체된다.
public enum FontResolver {
    /// 위에서부터 설치된 것을 찾아 쓴다.
    public static let preferredFamilies = [
        "Malgun Gothic",        // 사용자가 지정한 기본 글꼴 (Windows 계열, 설치된 경우에만)
        "맑은 고딕",
        "Apple SD Gothic Neo",  // macOS 한글 시스템 글꼴 — 맑은 고딕과 인상이 가장 가깝다
        "Nanum Gothic",
        "AppleGothic",
    ]

    /// 실제로 쓸 기본 글꼴 가족. 하나도 없으면 nil(시스템 글꼴)을 뜻한다.
    public static func defaultFamily() -> String? {
        preferredFamilies.first { isAvailable($0) }
    }

    public static func isAvailable(_ family: String) -> Bool {
        NSFont(name: family, size: 12) != nil
            || NSFontManager.shared.availableFontFamilies.contains(family)
    }

    /// 지정한 가족으로 글꼴을 만든다. 없으면 대체 목록을 거쳐 시스템 글꼴까지 내려간다.
    public static func font(family: String?, size: CGFloat, traits: NSFontTraitMask = []) -> NSFont {
        let candidates = [family].compactMap { $0 } + preferredFamilies
        for candidate in candidates {
            if let font = NSFont(name: candidate, size: size)
                ?? NSFontManager.shared.font(withFamily: candidate, traits: [], weight: 5, size: size) {
                return traits.isEmpty ? font : NSFontManager.shared.convert(font, toHaveTrait: traits)
            }
        }
        let system = NSFont.systemFont(ofSize: size)
        return traits.isEmpty ? system : NSFontManager.shared.convert(system, toHaveTrait: traits)
    }

    /// 한글을 표시할 수 있는 설치 글꼴 목록. 글꼴 선택 메뉴에 쓴다.
    ///
    /// 글꼴마다 문자 집합을 검사하는 일이 가볍지 않아 한 번만 계산해 둔다.
    public static let koreanCapableFamilies: [String] = {
        let sample = Set("가힣".unicodeScalars)
        return NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            let covered = font.coveredCharacterSet
            return sample.allSatisfy { covered.contains($0) }
        }.sorted()
    }()

    /// 설치된 전체 글꼴 가족.
    public static var allFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.sorted()
    }
}
