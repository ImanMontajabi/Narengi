import AppKit
import SwiftUI

@MainActor
final class WheelController {
    /// Called when a petal is chosen (drop or keyboard/click).
    var onSelect: ((WheelItem, [URL]) -> Void)?
    /// Whether a petal works for these files on this Mac; unavailable petals are hidden.
    var isAvailable: (WheelItem, [String?]) -> Bool = { _, _ in true }

    private let settings: SettingsStore
    private let geometry = WheelGeometry()
    private let model = WheelModel()
    private let panel: WheelPanel
    private let dropView: WheelDropView
    private var files = DraggedFiles(urls: [])
    private var generation = 0
    /// Set once the current drag has produced its job, so a drop *and* a mouse-up never run it twice.
    private var dragCommitted = false
    private var resignObserver: NSObjectProtocol?

    init(settings: SettingsStore? = nil) {
        let settings = settings ?? .shared
        self.settings = settings
        let size = WheelGeometry.viewSize
        panel = WheelPanel(size: size)

        dropView = WheelDropView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let host = NSHostingView(rootView: WheelView(model: model, settings: settings, geometry: geometry))
        host.frame = dropView.bounds
        host.autoresizingMask = [.width, .height]
        dropView.addSubview(host)
        panel.contentView = dropView

        dropView.onDrop = { [weak self] in self?.commit() ?? false }
        dropView.onKey = { [weak self] in self?.handle(key: $0) }
        dropView.onFlagsChanged = { [weak self] in self?.handle(flags: $0) }
        dropView.onMouseMoved = { [weak self] in self?.pointerMoved(to: $0) }
        dropView.onClick = { [weak self] in self?.clicked(at: $0) }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.model.keyboard == true { self?.dismiss() }
            }
        }
    }

    var isVisible: Bool { panel.isVisible && model.isPresented }
    var isKeyboardMode: Bool { model.keyboard }
    var selectedItem: WheelItem? { model.hoveredItem }
    var currentItems: [WheelItem] { model.items }
    /// The wheel's content, for rendering documentation images.
    var contentViewForSnapshot: NSView? { panel.contentView }
    var draggedURLs: [URL] { files.urls }
    var panelCenter: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }

    /// A screen point inside petal `index` (used by tests and diagnostics).
    func pointInside(petal index: Int) -> NSPoint? {
        let count = model.items.count
        for dx in stride(from: -geometry.outer, through: geometry.outer, by: 2) {
            for dy in stride(from: -geometry.outer, through: geometry.outer, by: 2) where geometry.hitTest(dx: dx, dy: dy, count: count) == index {
                return NSPoint(x: panelCenter.x + dx, y: panelCenter.y + dy)
            }
        }
        return nil
    }

    // MARK: - Drag mode

    func prepare(files urls: [URL]) {
        files = DraggedFiles(urls: urls)
        dragCommitted = false
        model.captionLines = files.captionLines
    }

    /// Opens the wheel at the pointer, or switches the open wheel to another kind (keeping its position).
    func present(_ kind: WheelKind) {
        generation += 1
        model.kind = kind
        rebuild()
        model.hovered = nil

        if !panel.isVisible {
            panel.setFrame(frame(anchoredAt: NSEvent.mouseLocation), display: false)
            model.isPresented = false
            panel.orderFrontRegardless()
        }
        model.isPresented = true
        feedback(sound: "Pop")
        Log.wheel.notice("Wheel opened: \(kind.rawValue, privacy: .public), \(self.model.items.count) petals")
    }

    func updateHover(mouse: NSPoint) {
        guard panel.isVisible, !model.keyboard else { return }
        setHovered(hitIndex(at: mouse))
    }

    /// The drag monitor saw the mouse button go up. Drop delivery to a panel that appeared mid-drag is not
    /// reliable, so the petal under the pointer is applied here; `commit()` ignores a second delivery.
    @discardableResult
    func finishDrag(at mouse: NSPoint) -> Bool {
        guard !model.keyboard else { return false }
        guard panel.isVisible, model.isPresented, !dragCommitted else {
            dismiss(after: 0.3)
            return false
        }
        setHovered(hitIndex(at: mouse))
        if commit() { return true }
        dismiss(after: 0.3)
        return false
    }

    func dismiss(after delay: TimeInterval = 0) {
        generation += 1
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token else { return }
            self.model.isPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.generation == token else { return }
                self.panel.orderOut(nil)
                self.panel.keyboardMode = false
                self.model.keyboard = false
                self.model.hovered = nil
                self.model.items = []
            }
        }
    }

    // MARK: - Keyboard / click mode ("Convert Files…")

    func presentKeyboard(files urls: [URL]) {
        guard !urls.isEmpty else { return }
        prepare(files: urls)
        let hasConversions = !WheelItems.items(for: .conversion, formats: files.formats, available: { isAvailable($0, files.formats) }).isEmpty
        let kind = WheelItems.initialKeyboardKind(hasConversions: hasConversions)

        model.keyboard = true
        panel.keyboardMode = true
        generation += 1
        model.kind = kind
        rebuild()
        model.hovered = WheelNavigation.navigate(selected: nil, count: model.items.count, key: .first)

        panel.setFrame(frame(anchoredAt: NSEvent.mouseLocation), display: false)
        model.isPresented = false
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(dropView)
        model.isPresented = true
        Log.wheel.notice("Keyboard wheel opened: \(kind.rawValue, privacy: .public), \(self.model.items.count) petals")
    }

    private func handle(key: WheelKeyCommand) {
        guard model.keyboard else { return }
        switch key {
        case .navigate(let navKey):
            setHovered(WheelNavigation.navigate(selected: model.hovered, count: model.items.count, key: navKey), feedback: true)
        case .apply:
            if model.hoveredItem != nil { _ = commit() }
        case .cancel:
            dismiss()
        }
    }

    /// Shift/Command/Control switch wheels, like in drag mode.
    private func handle(flags: NSEvent.ModifierFlags) {
        guard model.keyboard else { return }
        let held = flags.intersection([.shift, .command, .option, .control])
        guard let kind = WheelKind.allCases.first(where: { settings.modifier(for: $0).flags == held }), kind != model.kind else { return }
        model.kind = kind
        rebuild()
        model.hovered = WheelNavigation.navigate(selected: nil, count: model.items.count, key: .first)
    }

    private func pointerMoved(to screenPoint: NSPoint) {
        guard model.keyboard, let index = hitIndex(at: screenPoint) else { return }
        setHovered(index)
    }

    private func clicked(at screenPoint: NSPoint) {
        guard model.keyboard else { return }
        if let index = hitIndex(at: screenPoint) {
            setHovered(index)
            _ = commit()
        } else {
            dismiss()
        }
    }

    // MARK: - Shared

    private func rebuild() {
        let formats = files.formats
        model.items = WheelItems.items(for: model.kind, formats: formats) { [isAvailable] in isAvailable($0, formats) }
        model.emptyMessage = model.items.isEmpty ? WheelItems.emptyMessage(for: model.kind, settings: settings) : ""
    }

    private func hitIndex(at screenPoint: NSPoint) -> Int? {
        geometry.hitTest(
            dx: screenPoint.x - panel.frame.midX, dy: screenPoint.y - panel.frame.midY, count: model.items.count)
    }

    private func setHovered(_ index: Int?, feedback shouldGiveFeedback: Bool = false) {
        guard index != model.hovered else { return }
        model.hovered = index
        if index != nil { feedback(sound: "Tink") }
    }

    private func commit() -> Bool {
        guard let item = model.hoveredItem else { return false }
        if !model.keyboard {
            guard !dragCommitted else { return true }
            dragCommitted = true
        }
        let urls = files.urls
        dismiss()
        Log.wheel.notice("Petal chosen: \(item.id, privacy: .public) for \(urls.count) item(s)")
        onSelect?(item, urls)
        return true
    }

    /// Panel frame centred on `point`, moved so the whole wheel stays on the screen's visible area.
    private func frame(anchoredAt point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = geometry.clampAnchor(point, in: bounds)
        let size = WheelGeometry.viewSize
        return NSRect(x: anchor.x - size / 2, y: anchor.y - size / 2, width: size, height: size)
    }

    private func feedback(sound name: String) {
        guard settings.feedbackEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.volume = 0.3
            sound.stop()
            sound.play()
        }
    }
}
