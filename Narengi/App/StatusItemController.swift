import AppKit

/// The menu-bar item. It is created once, strongly retained, and always has *some* visible content:
/// an SF Symbol, else a drawn template image, else a text title.
@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    var onConvertFiles: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onWelcomeGuide: (() -> Void)?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A stable name lets macOS remember where you ⌘-drag the item to.
        item.autosaveName = "NarengiStatusItem"
        item.isVisible = true
        statusItem = item

        if let button = item.button {
            if let image = Self.icon() {
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.title = "N"
            }
            button.toolTip = "Narengi"
            button.setAccessibilityLabel("Narengi")
        }

        menu.autoenablesItems = false
        addItem("Convert Files…", #selector(convertFiles))
        menu.addItem(.separator())
        addItem("Settings…", #selector(openSettings), key: ",")
        addItem("Welcome Guide…", #selector(welcomeGuide))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Narengi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        Log.app.notice("Status item installed")
    }

    var menuItemTitles: [String] { menu.items.map(\.title) }

    func uninstall() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    /// False when macOS has pushed the item off-screen, e.g. hidden behind the notch.
    var isOnScreen: Bool {
        guard let window = statusItem?.button?.window else { return false }
        let visible = window.occlusionState.contains(.visible)
        let onAScreen = NSScreen.screens.contains { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }
        Log.app.notice("Status item window: frame=\(NSStringFromRect(window.frame), privacy: .public) visible=\(visible) onScreen=\(onAScreen) alpha=\(window.alphaValue)")
        return window.isVisible && visible && onAScreen
    }

    private func addItem(_ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func convertFiles() { onConvertFiles?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func welcomeGuide() { onWelcomeGuide?() }

    // MARK: - Icon

    /// SF Symbol first (guaranteed on macOS 14), then a drawn citrus slice, so the item is never blank.
    static func icon() -> NSImage? {
        if let symbol = NSImage(systemSymbolName: "chart.pie.fill", accessibilityDescription: "Narengi") {
            symbol.isTemplate = true
            return symbol
        }
        return drawnCitrusSlice()
    }

    static func drawnCitrusSlice() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()
            for i in 0..<8 {
                let angle = CGFloat(i) * .pi / 4
                let spoke = NSBezierPath()
                spoke.move(to: center)
                spoke.line(to: NSPoint(x: center.x + 6.5 * cos(angle), y: center.y + 6.5 * sin(angle)))
                spoke.lineWidth = 1.2
                spoke.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
