import AppKit
import SwiftUI

enum TimeFormat {
    /// `1:05.3` (minutes:seconds.tenths), or `1:02:05.3` past an hour.
    static func string(_ seconds: Double) -> String {
        let total = max(seconds, 0)
        let hours = Int(total) / 3600, minutes = Int(total) / 60 % 60
        let secs = total - Double(Int(total) / 60 * 60)
        return hours > 0 ? String(format: "%d:%02d:%04.1f", hours, minutes, secs) : String(format: "%d:%04.1f", minutes, secs)
    }

    /// Accepts `12`, `12.5`, `1:05`, `1:05.5` and `1:02:05`.
    static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part.replacingOccurrences(of: ",", with: ".")), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

/// Loads preview frames of a video, keeping only the newest request so scrubbing stays smooth.
@MainActor
final class VideoFrameSource: ObservableObject {
    let url: URL
    let engine: MediaEngine
    @Published private(set) var image: NSImage?
    private var task: Task<Void, Never>?

    init(url: URL, engine: MediaEngine) {
        self.url = url
        self.engine = engine
    }

    func show(at seconds: Double) {
        task?.cancel()
        task = Task { [url, engine] in
            try? await Task.sleep(nanoseconds: 60_000_000)  // coalesce rapid slider moves
            guard !Task.isCancelled, let frame = try? await engine.frame(of: url, at: seconds) else { return }
            if !Task.isCancelled { image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)) }
        }
    }
}

@MainActor
final class TrimModel: ObservableObject {
    static let minimumLength = 0.1

    let duration: Double
    @Published private(set) var start = 0.0
    @Published private(set) var end: Double
    /// The handle moved last; the preview shows that moment.
    @Published private(set) var previewTime = 0.0

    init(duration: Double) {
        self.duration = max(duration, Self.minimumLength)
        end = self.duration
    }

    func setStart(_ value: Double) {
        start = min(max(value, 0), end - Self.minimumLength)
        previewTime = start
    }

    func setEnd(_ value: Double) {
        end = max(min(value, duration), start + Self.minimumLength)
        previewTime = max(end - 0.05, 0)
    }

    var keptLength: Double { end - start }
    var isFullRange: Bool { start <= 0.001 && end >= duration - 0.001 }
    var summary: String { "Keeping \(TimeFormat.string(keptLength)) of \(TimeFormat.string(duration))" }
}

@MainActor
final class BleepModel: ObservableObject {
    let duration: Double
    @Published private(set) var peaks: [Float] = []
    @Published private(set) var isLoading = true
    @Published private(set) var intervals: [BleepInterval] = []
    /// A stretch being dragged out on the waveform.
    @Published var selection: ClosedRange<Double>?

    init(duration: Double) {
        self.duration = max(duration, 0.1)
    }

    func setPeaks(_ peaks: [Float]) {
        self.peaks = peaks
        isLoading = false
    }

    /// Adds a stretch; overlapping ones merge. Returns false for an empty or out-of-range stretch.
    @discardableResult
    func add(start: Double, end: Double) -> Bool {
        let merged = MediaEngine.normalized(intervals + [BleepInterval(start: start, end: end)], duration: duration)
        guard merged.count != intervals.count || merged != intervals else { return false }
        intervals = merged
        return true
    }

    func addSelection() {
        guard let selection else { return }
        add(start: selection.lowerBound, end: selection.upperBound)
        self.selection = nil
    }

    func remove(_ id: UUID) { intervals.removeAll { $0.id == id } }
    func clear() { intervals = [] }

    var totalBleeped: Double { intervals.reduce(0) { $0 + $1.length } }
    var summary: String {
        intervals.isEmpty ? "Drag across the waveform to choose what to bleep."
            : "\(intervals.count) stretch\(intervals.count == 1 ? "" : "es") · \(TimeFormat.string(totalBleeped)) bleeped"
    }
}

/// Redact Video's marks and time range, reusing the markup model for drawing.
@MainActor
final class VideoRedactModel: ObservableObject {
    let markup = MarkupModel(mode: .redact, pageCount: 1)
    let duration: Double
    @Published var limitToRange = false
    @Published private(set) var start = 0.0
    @Published private(set) var end: Double
    @Published private(set) var previewTime = 0.0

    init(duration: Double) {
        self.duration = max(duration, 0.1)
        end = self.duration
    }

    func setStart(_ value: Double) { start = min(max(value, 0), end - 0.1); previewTime = start }
    func setEnd(_ value: Double) { end = max(min(value, duration), start + 0.1); previewTime = max(end - 0.05, 0) }
    func setPreview(_ value: Double) { previewTime = min(max(value, 0), duration) }

    var redactions: [VideoRedaction] {
        markup.items.map { VideoRedaction(rect: $0.box, style: $0.kind == .blur ? .blur : $0.kind == .pixelate ? .pixelate : .blackout) }
    }

    var range: (start: Double?, end: Double?) {
        guard limitToRange else { return (nil, nil) }
        return (start <= 0.001 ? nil : start, end >= duration - 0.001 ? nil : end)
    }
}
