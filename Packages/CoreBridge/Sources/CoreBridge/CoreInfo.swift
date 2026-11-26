// 생성된 UniFFI 함수는 이 계층의 공개 API로 감싼다.
public enum CoreInfo {
    public static var version: String { coreVersion() }
    public static func ping(_ v: UInt32) -> UInt32 { CoreBridge.ping(value: v) }
}
