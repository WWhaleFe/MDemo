import Foundation

/// 메모 식별자. ULID 형식으로 생성 시각순 정렬이 가능하고 기기 간 충돌이 없다.
/// 폴더명 · 프론트매터 · 커밋 메시지에 같은 값을 사용한다.
public struct MemoID: Hashable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Crockford Base32 (I, L, O, U 제외 — 사람이 읽을 때 혼동을 막는다)
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 48비트 타임스탬프(밀리초) + 80비트 난수로 구성된 26자 ULID를 만든다.
    public static func generate(date: Date = Date()) -> MemoID {
        var characters = [Character]()
        characters.reserveCapacity(26)

        var timestamp = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var timeChars = [Character]()
        for _ in 0..<10 {
            timeChars.append(alphabet[Int(timestamp % 32)])
            timestamp /= 32
        }
        characters.append(contentsOf: timeChars.reversed())

        for _ in 0..<16 {
            characters.append(alphabet[Int.random(in: 0..<32)])
        }
        return MemoID(rawValue: String(characters))
    }

    /// 파일 경로로 쓰이므로 형식을 벗어난 값은 거부한다.
    public var isValid: Bool {
        rawValue.count == 26 && rawValue.allSatisfy { MemoID.alphabet.contains($0) }
    }
}
