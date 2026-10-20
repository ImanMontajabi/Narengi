import AppKit
import SwiftUI

/// The practice file as a card the user can drag out of the window. It is a real AppKit drag source, and it
/// tells the drag monitor when the drag starts: global event monitors never see drags that begin inside
/// Narengi's own windows.
struct SampleCardView: NSViewRepresentable {
    let url: URL
    let onDragStart: ([URL]) -> Void

    func makeNSView(context: Context) -> SampleCardNSView {
        let view = SampleCardNSView(url: url)
        view.onDragStart = onDragStart
        return view
    }

    func updateNSView(_ view: SampleCardNSView, context: Context) { view.onDragStart = onDragStart }
}

final class SampleCardNSView: NSView, NSDraggingSource {
    let url: URL
    var onDragStart: (([URL]) -> Void)?
    private let thumbnail: NSImage
    private var pressPoint: NSPoint = .zero
    private var dragging = false

    init(url: URL) {
        self.url = url
        thumbnail = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 190))
        setAccessibilityLabel("Practice file. Drag it to try the wheels.")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 230, height: 190) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 6, dy: 6)
        NSColor(white: 1, alpha: 0.07).setFill()
        NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16).fill()
        NSColor(white: 1, alpha: 0.16).setStroke()
        let border = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        border.lineWidth = 1
        border.setLineDash([6, 4], count: 2, phase: 0)
        border.stroke()

        let picture = NSRect(x: card.minX + 20, y: card.minY + 52, width: card.width - 40, height: card.height - 72)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: picture, xRadius: 10, yRadius: 10).addClip()
        thumbnail.draw(in: picture, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        (url.lastPathComponent as NSString).draw(
            in: NSRect(x: card.minX, y: card.minY + 14, width: card.width, height: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: style])
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !dragging, hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 4 else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let frame = NSRect(x: point.x - 40, y: point.y - 30, width: 80, height: 60)
        item.setDraggingFrame(frame, contents: thumbnail)
        beginDraggingSession(with: [item], event: event, source: self)
        onDragStart?([url])
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
