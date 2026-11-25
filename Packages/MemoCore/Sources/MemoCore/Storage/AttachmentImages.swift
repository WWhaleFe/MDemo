import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 저장된 첨부 이미지 한 장의 정보.
public struct SavedAttachment: Equatable, Sendable {
    /// 첨부 폴더 안의 파일 이름 (예: `a1b2c3d4.png`).
    public let fileName: String
    /// 방향(EXIF)을 반영한 화면상 픽셀 크기.
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// 본문에 적을 상대 경로.
    public var relativePath: String { "\(AttachmentImages.folderName)/\(fileName)" }
}

/// 본문 이미지 파일을 첨부 폴더에 저장하고 정리한다 (IMG-06, IMG-07).
///
/// 이미지는 마크다운에 인라인으로 넣지 않고 파일로 둔다. UI 프레임워크는 쓰지 않는다(ImageIO만).
public enum AttachmentImages {
    public static let folderName = "attachments"
    /// 긴 변이 이 값을 넘으면 줄여서 저장한다 (IMG-06).
    public static let maxLongSide = 2400
    /// JPEG 저장 품질.
    public static let jpegQuality = 0.85

    public enum SaveError: Error {
        case unreadableImage
        case writeFailed
    }

    /// 이미지 데이터를 읽어 첨부 폴더에 저장한다.
    ///
    /// - 원본이 PNG면 PNG로, 그 밖(JPEG·HEIC 등)은 JPEG(품질 0.85)로 저장한다.
    /// - 긴 변이 `maxLongSide` 이하인 PNG·JPEG는 다시 인코딩하지 않고 원본 바이트를 그대로 둔다.
    public static func save(imageData: Data, into directory: URL, maxLongSide: Int = maxLongSide) throws -> SavedAttachment {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let size = displaySize(of: source)
        else { throw SaveError.unreadableImage }

        let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
        let isPNG = type?.conforms(to: .png) == true
        let isJPEG = type?.conforms(to: .jpeg) == true
        let fileExtension = isPNG ? "png" : "jpg"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = uniqueFileName(in: directory, fileExtension: fileExtension)
        let destinationURL = directory.appendingPathComponent(fileName)

        let longSide = max(size.width, size.height)
        if longSide <= maxLongSide, isPNG || isJPEG {
            try imageData.write(to: destinationURL, options: .atomic)
            return SavedAttachment(fileName: fileName, pixelWidth: size.width, pixelHeight: size.height)
        }

        // 줄이거나 형식을 바꿔야 한다. 방향 정보는 픽셀에 반영해 둔다.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longSide, maxLongSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SaveError.unreadableImage
        }
        let outputType: UTType = isPNG ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, outputType.identifier as CFString, 1, nil
        ) else { throw SaveError.writeFailed }
        let properties: [CFString: Any] = isPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SaveError.writeFailed }
        return SavedAttachment(fileName: fileName, pixelWidth: image.width, pixelHeight: image.height)
    }

    /// 파일에서 읽어 저장한다 (Finder 파일 붙여넣기, 끌어 놓기, 파일 선택).
    public static func save(imageFileAt url: URL, into directory: URL, maxLongSide: Int = maxLongSide) throws -> SavedAttachment {
        try save(imageData: Data(contentsOf: url), into: directory, maxLongSide: maxLongSide)
    }

    /// 디코딩 없이 헤더만 읽어 화면상 픽셀 크기를 얻는다.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return displaySize(of: source).map { ($0.width, $0.height) }
    }

    private static func displaySize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        // EXIF 방향 5~8은 가로세로가 뒤바뀐다.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// 짧고 겹치지 않는 파일 이름.
    private static func uniqueFileName(in directory: URL, fileExtension: String) -> String {
        while true {
            let stem = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            let name = "\(stem).\(fileExtension)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                return name
            }
        }
    }

    // MARK: - 내보내기 (다른 이름으로 저장)

    public enum ExportFormat: Sendable, Equatable {
        /// 원본 바이트를 그대로 복사한다.
        case original
        case png
        case jpeg

        /// 형식이 정해진 경우의 확장자. 원본이면 nil(원본 확장자를 따른다).
        public var fileExtension: String? {
            switch self {
            case .original: return nil
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    /// JPEG로 내보낼 때의 품질.
    public static let exportJPEGQuality = 0.9

    /// 첨부 이미지를 `destination`에 저장한다. 이미 있는 파일은 덮어쓴다(덮어쓰기 확인은 저장 창이 한다).
    /// PNG·JPEG는 방향(EXIF)을 픽셀에 반영해 다시 인코딩한다.
    public static func export(from source: URL, to destination: URL, format: ExportFormat) throws {
        switch format {
        case .original:
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        case .png, .jpeg:
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) > 0,
                  let size = displaySize(of: imageSource)
            else { throw SaveError.unreadableImage }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
            ]
            guard var image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
                throw SaveError.unreadableImage
            }
            if format == .jpeg { image = flattenedOnWhite(image) ?? image }
            let type: UTType = format == .png ? .png : .jpeg
            guard let target = CGImageDestinationCreateWithURL(destination as CFURL, type.identifier as CFString, 1, nil) else {
                throw SaveError.writeFailed
            }
            let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: exportJPEGQuality] : [:]
            CGImageDestinationAddImage(target, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(target) else { throw SaveError.writeFailed }
        }
    }

    /// 투명한 부분을 흰색으로 채운다. JPEG는 투명을 저장하지 못해 그대로 두면 검게 나온다.
    private static func flattenedOnWhite(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    // MARK: - 정리

    /// 본문 어디에서도 쓰지 않는 첨부 파일 가운데 `date`보다 오래된 것을 지운다. 지운 개수를 돌려준다.
    ///
    /// 본문에서 이미지 줄을 지워도 파일은 바로 지우지 않는다(되돌리기 대비).
    /// 그래서 수정한 지 오래된 것만 지운다. 수정 시각을 읽지 못하면 남긴다.
    @discardableResult
    public static func pruneUnused(in directory: URL, body: String, olderThan date: Date) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true,
                  let modified = values?.contentModificationDate, modified < date
            else { continue }
            if body.contains(entry.lastPathComponent) { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}
