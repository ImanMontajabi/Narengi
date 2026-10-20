import CoreGraphics
import Foundation
import PDFKit
import Vision

struct QRResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    let payload: String
    /// Symbology such as QR, EAN-13, Code 128.
    let kind: String
    /// Page the code was found on (PDFs), starting at 1.
    let page: Int?

    var url: URL? {
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) else { return nil }
        return url
    }
}

/// Reads QR codes and barcodes with Vision.
enum QREngine {
    static func scan(_ image: CGImage, page: Int? = nil) throws -> [QRResult] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            return QRResult(payload: payload, kind: kindName(observation.symbology), page: page)
        }
    }

    static func kindName(_ symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: return "QR"
        case .ean13: return "EAN-13"
        case .ean8: return "EAN-8"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .upce: return "UPC-E"
        case .pdf417: return "PDF417"
        case .dataMatrix: return "Data Matrix"
        case .aztec: return "Aztec"
        default: return symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
        }
    }

    /// `scan(file:format:)` on the shared Vision queue (for callers inside Swift concurrency).
    static func scanAsync(file url: URL, format: String, dpi: Int = 200) async throws -> [QRResult] {
        try await VisionQueue.run { try scan(file: url, format: format, dpi: dpi) }
    }

    /// Codes in an image file or in every page of a PDF, without repeats.
    static func scan(file url: URL, format: String, dpi: Int = 200) throws -> [QRResult] {
        var results: [QRResult] = []
        if format == "PDF" {
            let document = try PDFEngine.open(url)
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                results += try scan(try PDFEngine.render(page, dpi: dpi), page: index + 1)
            }
        } else {
            results = try scan(try ImageEngine.decode(url, dpi: dpi, flattenOnWhite: true).image)
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0.payload).inserted }
    }
}
