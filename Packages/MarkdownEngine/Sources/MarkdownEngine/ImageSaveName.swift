import Foundation

/// 이미지를 "다른 이름으로 저장"할 때 처음 보여 줄 파일 이름.
///
/// 첨부 파일의 실제 이름은 무작위 글자(a1b2c3d4)라 사람이 알아볼 수 없다.
/// 설명(alt)이 있으면 그것을, 없으면 "<메모 제목> 이미지 N"을 쓴다. 순수 함수라 화면 없이 시험한다.
public enum ImageSaveName {
    /// 파일 이름에 쓸 수 없는 글자(`/` `:` 줄바꿈 등)를 `-`로 바꾸고 앞뒤 공백과 점을 뗀다.
    public static func sanitized(_ text: String) -> String {
        let forbidden: Set<Character> = ["/", ":", "\\", "\u{0}"]
        let replaced = String(text.map { character -> Character in
            forbidden.contains(character) || character.isNewline ? "-" : character
        })
        return replaced.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// - Parameters:
    ///   - alt: 이미지 설명. 비었으면 제목과 번호로 이름을 만든다.
    ///   - memoTitle: 메모 제목. 없으면 "메모"로 쓴다.
    ///   - ordinal: 그 메모 안에서 몇 번째 이미지인가 (1부터).
    ///   - fileExtension: 점 없는 확장자. 비면 확장자를 붙이지 않는다.
    public static func defaultName(alt: String, memoTitle: String?, ordinal: Int, fileExtension: String) -> String {
        var base = sanitized(alt)
        if base.isEmpty {
            let title = sanitized(memoTitle ?? "")
            base = "\(title.isEmpty ? "메모" : title) 이미지 \(max(1, ordinal))"
        }
        return fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
    }
}
