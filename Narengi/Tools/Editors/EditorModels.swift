import AppKit
import CoreGraphics
import SwiftUI

/// A picture loaded for an editor: the full-resolution size (what specs are expressed against) and a
/// screen-sized preview (what the sliders and gestures work on).
struct EditorImage {
    let url: URL
    let fullSize: CGSize
    let preview: CGImage

    static func load(_ url: URL, previewEdge: Int = 1400) throws -> EditorImage {
        let decoded = try ImageEngine.decode(url, dpi: 150, flattenOnWhite: false)
        let size = CGSize(width: decoded.image.width, height: decoded.image.height)
        return EditorImage(url: url, fullSize: size, preview: try ImageOps.resize(decoded.image, maxEdge: previewEdge))
    }

    var nsImage: NSImage { NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)) }
}

/// Fits an image of `image` size into `container`, centred.
func fittedRect(image: CGSize, in container: CGSize) -> CGRect {
    guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
    let scale = min(container.width / image.width, container.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
}

// MARK: - Crop

@MainActor
final class CropModel: ObservableObject {
    let imageSize: CGSize
    let imageCount: Int
    @Published var rect: CGRect
    @Published var aspectIndex = 0
    private var dragStart: (rect: CGRect, handle: CropGeometry.Handle)?

    init(imageSize: CGSize, imageCount: Int) {
        self.imageSize = imageSize
        self.imageCount = imageCount
        rect = CGRect(origin: .zero, size: imageSize)
    }

    var aspect: Double? { CropGeometry.aspects[aspectIndex].ratio.map(CropGeometry.ratioValue) }

    func selectAspect(_ index: Int) {
        aspectIndex = index
        if let aspect { rect = CropGeometry.fitAspect(rect, aspect: aspect, bounds: imageSize) }
    }

    func setSize(width: Double?, height: Double?) {
        var w = width ?? Double(rect.width), h = height ?? Double(rect.height)
        if let aspect {  // a typed side drives the other one
            if width != nil { h = w / aspect } else { w = h * aspect }
        }
        rect = CropGeometry.setSize(rect, width: w, height: h, bounds: imageSize)
    }

    func beginDrag(at point: CGPoint, tolerance: Double) {
        guard let handle = CropGeometry.hitHandle(rect, at: point, tolerance: tolerance) else { dragStart = nil; return }
        dragStart = (rect, handle)
    }

    func drag(dx: Double, dy: Double) {
        guard let dragStart else { return }
        rect = CropGeometry.drag(dragStart.rect, handle: dragStart.handle, dx: dx, dy: dy, aspect: aspect, bounds: imageSize, min: 20)
    }

    func endDrag() { dragStart = nil }

    var spec: CropSpec { CropSpec.fromPixels(rect, image: imageSize) }
    var isFullImage: Bool { rect.integral == CGRect(origin: .zero, size: imageSize) }
}

// MARK: - Markup (Annotate and Redact)

@MainActor
final class MarkupModel: ObservableObject {
    enum Mode { case annotate, redact }

    let mode: Mode
    let pageCount: Int
    @Published var currentPage = 0
    @Published private(set) var itemsByPage: [Int: [MarkupItem]] = [:]
    @Published var kind: MarkupItem.Kind
    @Published var color = RGB(255, 59, 48)
    @Published var width = 0.006
    @Published private(set) var draft: MarkupItem?
    /// Where a text mark is being typed, if any.
    @Published var pendingText: CGPoint?

    init(mode: Mode, pageCount: Int) {
        self.mode = mode
        self.pageCount = pageCount
        kind = mode == .redact ? .blackout : .rectangle
    }

    var tools: [MarkupItem.Kind] {
        mode == .redact ? [.blackout, .blur, .pixelate] : [.rectangle, .ellipse, .arrow, .pen, .text]
    }

    var items: [MarkupItem] { itemsByPage[currentPage] ?? [] }
    var totalItems: Int { itemsByPage.values.reduce(0) { $0 + $1.count } }
    var hasItems: Bool { totalItems > 0 }
    var redactedPageCount: Int { itemsByPage.filter { $0.value.contains(where: \.isRedaction) }.count }

    func begin(at p: CGPoint) {
        let point = clamp(p)
        switch kind {
        case .text: pendingText = point
        case .pen: draft = make(.pen, [point])
        default: draft = make(kind, [point, point])
        }
    }

    func update(to p: CGPoint) {
        guard var draft else { return }
        let point = clamp(p)
        if draft.kind == .pen { draft.points.append(point) } else { draft.points[1] = point }
        self.draft = draft
    }

    func end() {
        guard let draft else { return }
        self.draft = nil
        // Ignore stray clicks: a shape needs some size, a pen stroke some length.
        let tiny: Bool
        switch draft.kind {
        case .pen: tiny = draft.points.count < 2
        default: tiny = hypot(draft.points[0].x - draft.points[1].x, draft.points[0].y - draft.points[1].y) < 0.005
        }
        if !tiny { itemsByPage[currentPage, default: []].append(draft) }
    }

    func addText(_ text: String) {
        defer { pendingText = nil }
        guard let point = pendingText, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var item = make(.text, [point])
        item.text = text
        itemsByPage[currentPage, default: []].append(item)
    }

    func undo() {
        guard var list = itemsByPage[currentPage], !list.isEmpty else { return }
        list.removeLast()
        itemsByPage[currentPage] = list.isEmpty ? nil : list
    }

    func clearPage() { itemsByPage[currentPage] = nil }

    private func make(_ kind: MarkupItem.Kind, _ points: [CGPoint]) -> MarkupItem {
        var item = MarkupItem(kind: kind, points: points)
        item.color = color
        item.width = kind == .pen ? max(width, 0.004) : width
        return item
    }

    private func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) }
}
