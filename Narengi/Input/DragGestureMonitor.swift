import AppKit

/// Detects a file drag that started in any app and watches the modifier keys while it lasts.
///
/// - A global `NSEvent` monitor sees mouse-down/drag/up and `flagsChanged` from other apps.
/// - A drag is "a file drag" when the drag pasteboard's `changeCount` moves after the mouse went
///   down and it holds file URLs.
/// - While dragging, a 60 Hz timer is the source of truth for the cursor, the modifier flags and the
///   mouse button, because a drag session can swallow the matching mouse-up event.
@MainActor
final class DragGestureMonitor {
    private enum State {
        case idle
        case tracking(pasteboardCount: Int)
        case dragging
    }

    var onDragBegan: (([URL]) -> Void)?
    var onWheelRequested: ((WheelKind) -> Void)?
    var onTick: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private let settings: SettingsStore
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var state: State = .idle
    private var globalMonitor: Any?
    private var timer: Timer?
    private var lastRelevantFlags: NSEvent.ModifierFlags = []

    private static let relevant: NSEvent.ModifierFlags = [.shift, .command, .option, .control]

    init(settings: SettingsStore? = nil) {
        self.settings = settings ?? .shared
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        ) { [weak self] event in
            let type = event.type
            let flags = event.modifierFlags
            MainActor.assumeIsolated { self?.handle(type: type, flags: flags) }
        }
        Log.drag.notice("Drag shortcut monitor started")
    }

    /// Starts tracking a drag that began inside Narengi's own windows, which global event monitors never see.
    func beginManualDrag(_ urls: [URL]) {
        guard case .idle = state, !urls.isEmpty else { return }
        beginDragging(urls)
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        globalMonitor = nil
        endDragging()
    }

    private func handle(type: NSEvent.EventType, flags: NSEvent.ModifierFlags) {
        switch type {
        case .leftMouseDown:
            if case .dragging = state { return }
            state = .tracking(pasteboardCount: dragPasteboard.changeCount)

        case .leftMouseDragged:
            guard case .tracking(let before) = state, dragPasteboard.changeCount != before else { return }
            let urls = fileURLs()
            if urls.isEmpty {
                state = .idle
            } else {
                beginDragging(urls)
            }

        case .leftMouseUp:
            if case .dragging = state { endDragging() } else { state = .idle }

        case .flagsChanged:
            if case .dragging = state { evaluateModifiers(flags) }

        default:
            break
        }
    }

    private func fileURLs() -> [URL] {
        let objects = dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
        var seen = Set<String>()
        return ((objects as? [URL]) ?? []).compactMap { url in
            // Finder may publish `file:///.file/id=…` reference URLs; resolve them to real paths.
            let resolved = (url as NSURL).filePathURL ?? url.standardizedFileURL
            return seen.insert(resolved.path).inserted ? resolved : nil
        }
    }

    private func beginDragging(_ urls: [URL]) {
        state = .dragging
        lastRelevantFlags = []
        Log.drag.notice("File drag began with \(urls.count) item(s)")
        onDragBegan?(urls)
        // The modifier may already be held when the drag starts.
        evaluateModifiers(NSEvent.modifierFlags)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard case .dragging = state else { return }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            endDragging()
            return
        }
        evaluateModifiers(NSEvent.modifierFlags)
        onTick?(NSEvent.mouseLocation)
    }

    /// A wheel opens when the held modifiers become exactly the combination assigned to it.
    /// Releasing keys does not close the wheel; it stays until the drop or the end of the drag.
    private func evaluateModifiers(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection(Self.relevant)
        guard held != lastRelevantFlags else { return }
        lastRelevantFlags = held
        guard !held.isEmpty else { return }
        if let kind = WheelKind.allCases.first(where: { settings.modifier(for: $0).flags == held }) {
            onWheelRequested?(kind)
        }
    }

    private func endDragging() {
        timer?.invalidate()
        timer = nil
        let wasDragging: Bool
        if case .dragging = state { wasDragging = true } else { wasDragging = false }
        state = .idle
        lastRelevantFlags = []
        if wasDragging {
            Log.drag.notice("File drag ended")
            onDragEnded?()
        }
    }
}
