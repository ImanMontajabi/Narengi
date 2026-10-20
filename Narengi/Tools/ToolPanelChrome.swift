import AppKit
import SwiftUI

/// A borderless, rounded, draggable window that can take keyboard focus: the shell of every tool window
/// (Compress, Metadata, Read QR, Organize and the editors).
final class ToolWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns one tool window and closes it when the tool is done.
@MainActor
final class ToolWindowController: NSObject, NSWindowDelegate {
    let window: ToolWindow
    var onClose: (() -> Void)?

    init<Content: View>(title: String, size: NSSize, resizable: Bool = false, @ViewBuilder content: (ToolWindowController) -> Content) {
        var style: NSWindow.StyleMask = [.borderless]
        if resizable { style.insert(.resizable) }
        window = ToolWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self
        window.minSize = resizable ? NSSize(width: size.width * 0.7, height: size.height * 0.6) : size
        let host = NSHostingView(rootView: ToolPanelChrome(title: title, close: { [weak self] in self?.close() }) { content(self) })
        host.sizingOptions = []  // the window keeps the size we chose; the content scrolls
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2 + 30))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Title bar (round ✕ at the left, centred title), a divider, then the content, on a dark rounded card.
struct ToolPanelChrome<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 17, weight: .semibold))
                HStack {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                    Spacer()
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(Color.white.opacity(0.08))
            content
        }
        .foregroundStyle(Color.white.opacity(0.92))
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.135)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

struct OrangeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1)))
            .foregroundStyle(.white)
            .opacity(enabled ? 1 : 0.4)
    }
}

struct GreyButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10)))
            .opacity(enabled ? 1 : 0.4)
    }
}

enum ByteFormat {
    /// "3.3 MB", decimal like Finder.
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
