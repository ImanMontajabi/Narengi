import AppKit

/// Borderless, non-activating panel that floats above everything (including Finder's drag preview)
/// without ever taking focus from the app the drag started in. In keyboard mode it may become key
/// so it can receive arrow keys and clicks.
final class WheelPanel: NSPanel {
    var keyboardMode = false {
        didSet { acceptsMouseMovedEvents = keyboardMode }
    }

    init(size: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isFloatingPanel = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { keyboardMode }
    override var canBecomeMain: Bool { false }
}

enum WheelKeyCommand {
    case navigate(WheelNavKey)
    case apply
    case cancel
}

/// Content view of the wheel panel. During a drag it only accepts the file drop (what the drop means
/// depends on the petal under the cursor, so Finder's drag session is never owned or cancelled by us).
/// In keyboard mode it also handles keys, modifier switches, hover and clicks.
final class WheelDropView: NSView {
    var onDrop: (() -> Bool)?
    var onKey: ((WheelKeyCommand) -> Void)?
    var onFlagsChanged: ((NSEvent.ModifierFlags) -> Void)?
    /// Screen-coordinate pointer events (keyboard mode).
    var onMouseMoved: ((NSPoint) -> Void)?
    var onClick: ((NSPoint) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?() ?? false }

    // MARK: Keyboard mode

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 124, 125: onKey?(.navigate(.next))      // → ↓
        case 123, 126: onKey?(.navigate(.previous))  // ← ↑
        case 115: onKey?(.navigate(.first))          // Home
        case 119: onKey?(.navigate(.last))           // End
        case 36, 76, 49: onKey?(.apply)              // Return, Enter, Space
        case 53, 48: onKey?(.cancel)                 // Escape, Tab
        default: break
        }
    }

    override func flagsChanged(with event: NSEvent) {
        onFlagsChanged?(event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(NSEvent.mouseLocation)
    }
}
