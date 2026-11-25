import AppKit
import ImageIO
import MemoCore
import MarkdownEngine

/// 메모 창 하나가 쓰는 이미지 읽기 도구 (IMG-01).
///
/// 메인 스레드에서만 쓴다(그리기와 편집이 모두 메인 스레드다).
/// 메모리 원칙(§4-5): 원본을 통째로 디코딩해 들고 있지 않는다.
/// 표시 크기에 맞춘 썸네일만 만들어 작은 캐시에 두고, 창이 닫혀 이 객체가 풀리면 함께 사라진다.
public final class MemoImageStore: @unchecked Sendable {
    /// 이 메모의 첨부 폴더 (`<메모 폴더>/attachments`).
    public let directory: URL
    public let lockSession: MemoLockSession?

    private let thumbnails = NSCache<NSString, NSImage>()
    /// 파일 이름 → 화면상 픽셀 크기. 헤더만 읽은 값이라 작다.
    private var sizes: [String: NSSize] = [:]

    /// 캐시 한도. 이미지가 많은 메모를 열어도 창마다 이 정도를 넘지 않는다.
    private static let cacheByteLimit = 32 * 1024 * 1024
    /// 썸네일 폭을 이 단위로 올려 잡는다. 크기를 끌어 바꾸는 동안 매번 새로 디코딩하지 않기 위해서다.
    private static let widthBucket = 128

    public init(directory: URL, lockSession: MemoLockSession? = nil) {
        self.directory = directory
        self.lockSession = lockSession
        thumbnails.totalCostLimit = Self.cacheByteLimit
        thumbnails.countLimit = 24
    }

    public func fileURL(for fileName: String) -> URL? {
        guard lockSession == nil, MarkdownImage.isValidFileName(fileName) else { return nil }
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = parent.appendingPathComponent(fileName).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.deletingLastPathComponent() == parent,
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { return nil }
        return candidate
    }

    public func fileExists(_ fileName: String) -> Bool {
        if lockSession != nil { return (try? read(fileName)) != nil }
        guard let url = fileURL(for: fileName) else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// 원본의 화면상 픽셀 크기. 파일이 없거나 이미지가 아니면 nil.
    public func naturalSize(of fileName: String) -> NSSize? {
        if let cached = sizes[fileName] { return cached }
        guard let source = imageSource(fileName),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let value = (5...8).contains(orientation) ? NSSize(width: height.doubleValue, height: width.doubleValue) : NSSize(width: width.doubleValue, height: height.doubleValue)
        sizes[fileName] = value
        return value
    }

    /// 표시 폭(포인트)에 맞춘 썸네일. 이미지의 `size`는 `displayWidth`에 비례하는 포인트 크기다.
    public func thumbnail(of fileName: String, displayWidth: CGFloat, scale: CGFloat) -> NSImage? {
        guard let natural = naturalSize(of: fileName) else { return nil }
        // 정수 변환 전에 상한을 제한한다. 무한폭 컨테이너와 손상된 너비도 넘치지 않는다.
        let requested = displayWidth * scale
        let wanted = Int(min(16_384, natural.width, max(1, requested.isNaN ? 1 : requested)).rounded(.up))
        let bucketed = ((max(1, wanted) + Self.widthBucket - 1) / Self.widthBucket) * Self.widthBucket
        // 원본보다 크게 디코딩할 이유가 없다.
        let widthPixels = min(CGFloat(bucketed), natural.width)
        let maxPixel = Int(min(16_384, max(natural.width, natural.height) * widthPixels / natural.width).rounded(.up))

        let key = "\(fileName)@\(maxPixel)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }

        guard let source = imageSource(fileName) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: key, cost: cgImage.width * cgImage.height * 4)
        return image
    }

    public func read(_ name: String) throws -> Data {
        guard MarkdownImage.isValidFileName(name) else { throw MemoLockError.damaged }
        if let session = lockSession {
            let file = directory.appendingPathComponent(name + ".enc")
            guard (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw MemoLockError.damaged }
            return try session.open(Data(contentsOf: file), name: name)
        }
        guard let url = fileURL(for: name) else { throw MemoLockError.damaged }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws -> SavedAttachment {
        try AttachmentImages.save(imageData: data, into: directory, encryptedWith: lockSession)
    }

    private func imageSource(_ name: String) -> CGImageSource? {
        if lockSession == nil, let url = fileURL(for: name) { return CGImageSourceCreateWithURL(url as CFURL, nil) }
        guard var data = try? read(name) else { return nil }
        defer { data.resetBytes(in: 0..<data.count) }
        return CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// 캐시를 비운다. 메모리 경고나 창 숨김에서 쓸 수 있다.
    public func purge() {
        thumbnails.removeAllObjects()
    }
}
