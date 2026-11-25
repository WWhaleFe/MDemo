import Foundation
import MarkdownEngine
import Vision

/// 이미지 속 글자 읽기 (Vision, 맥 안에서만 돈다).
///
/// 네트워크로 보내지 않는다(NFR-07). 인식은 백그라운드 큐에서 하고 결과만 돌려준다.
public enum OCRService {
    /// 이미지 파일의 글자를 읽는다. 읽을 수 없거나 글자가 없으면 빈 배열.
    public static func recognize(imageAt url: URL) async -> [OCRLine] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: recognizeSynchronously(imageAt: url))
            }
        }
    }

    static func recognizeSynchronously(imageAt url: URL) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = true

        // 이 핸들러는 파일의 방향(EXIF) 정보를 읽어 반영한다.
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRLine(
                text: candidate.string,
                x: Double(box.minX), y: Double(box.minY),
                width: Double(box.width), height: Double(box.height),
                confidence: Double(candidate.confidence)
            )
        }
    }
}
