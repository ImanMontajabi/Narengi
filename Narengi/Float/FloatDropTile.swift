import AppKit
import SwiftUI

/// The "Drop files here" tile that appears at the top-right of the screen while a wheel is open.
/// Releasing the drag over it puts the files on a Float shelf. The drag monitor does the hit test
/// (the tile ignores the mouse), so Finder's drag session is never disturbed.
@MainActor
final class FloatDropTile {
    static let size = NSSize(width: 200, height: 206)

    private final class State: ObservableObject {
        @Published var highlighted = false
    }

    private let state = State()
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: TileView(state: state))
    }

    /// Frame on the screen that holds `point`, tucked under the menu bar at the right edge.
    static func frame(on screenFrame: NSRect) -> NSRect {
        NSRect(x: screenFrame.maxX - size.width - 12, y: screenFrame.maxY - size.height - 12, width: size.width, height: size.height)
    }

    var frame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    func show(near point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        panel.setFrame(Self.frame(on: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)), display: false)
        state.highlighted = false
        panel.orderFrontRegardless()
    }

    func hide() {
        state.highlighted = false
        panel.orderOut(nil)
    }

    func contains(_ point: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(point) }

    func updateHover(_ point: NSPoint) {
        let inside = contains(point)
        if state.highlighted != inside { state.highlighted = inside }
    }

    private struct TileView: View {
        @ObservedObject var state: State

        var body: some View {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(state.highlighted ? Theme.accent : Color.white.opacity(0.12), lineWidth: state.highlighted ? 3 : 1))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "pin.fill").font(.system(size: 20)).foregroundStyle(.secondary)
                        Text("Drop files here").font(.system(size: 15)).foregroundStyle(.secondary)
                    })
                .scaleEffect(state.highlighted ? 1.02 : 1)
                .animation(.easeOut(duration: 0.12), value: state.highlighted)
        }
    }
}
