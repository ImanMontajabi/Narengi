import CoreGraphics
import Foundation
import Vision

/// Every Vision request (text recognition, barcode reading) goes through one serial queue at one QoS, so two
/// callers at different priorities never wait on each other (a priority inversion) and Vision's own
/// threads aren't asked to serve two QoS classes at once.
enum VisionQueue {
    private static let queue = DispatchQueue(label: "app.narengi.vision", qos: .userInitiated)

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// On-device text recognition with Vision. Paragraph grouping ported from Satsuma's `ocr.rs`
/// (MIT, © sonatina-dream).
enum OCREngine {
    /// One recognised line; the box is normalised with a top-left origin.
    struct Line: Equatable {
        var text: String
        var x: Double
        var top: Double
        var height: Double
    }

    static func recognize(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ConversionError.toolFailed(tool: "Vision", message: "Text recognition failed: \(error.localizedDescription)")
        }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return Line(text: best.string, x: Double(box.origin.x), top: 1 - Double(box.origin.y + box.size.height),
                        height: Double(box.size.height))
        }
    }

    /// Runs Vision off the Swift-concurrency pool, on the shared Vision queue.
    static func recognizeAsync(_ image: CGImage) async throws -> [Line] {
        try await VisionQueue.run { try recognize(image) }
    }

    static func recognize(url: URL) throws -> [Line] {
        let image = try ImageEngine.decode(url, dpi: 150, flattenOnWhite: true).image
        return try recognize(image)
    }

    /// Orders lines top to bottom and joins them into paragraphs at larger vertical gaps.
    static func paragraphs(_ input: [Line]) -> [String] {
        let lines = input.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { ($0.top, $0.x) < ($1.top, $1.x) }
        let heights = lines.map(\.height).sorted()
        let typical = heights.isEmpty ? 0.02 : heights[heights.count / 2]

        var out: [String] = []
        var previousBottom: Double?
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            let newParagraph = previousBottom.map { line.top - $0 > typical * 0.9 } ?? true
            if newParagraph || out.isEmpty {
                out.append(text)
            } else {
                if out[out.count - 1].hasSuffix("-") {
                    out[out.count - 1].removeLast()
                } else {
                    out[out.count - 1] += " "
                }
                out[out.count - 1] += text
            }
            previousBottom = line.top + line.height
        }
        return out
    }
}
