import AppKit
import Combine

/// One Float shelf window: a small always-on-top panel holding files to drag into other apps.
@MainActor
final class FloatShelfController: NSObject, NSWindowDelegate {
    let model = FloatShelfModel()
    let panel: NSPanel
    var onClose: ((FloatShelfController) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private let countLabel = NSTextField(labelWithString: "")

    init(near point: NSPoint) {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView]
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 392, height: 300), styleMask: style, backing: .buffered, defer: false)
        super.init()
        panel.title = "Float"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 200, height: 170)
        panel.delegate = self
        panel.contentView = makeContent()

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: point.x + 40, y: point.y - panel.frame.height / 2)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - panel.frame.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - panel.frame.height)
        panel.setFrameOrigin(origin)

        model.$items.receive(on: DispatchQueue.main).sink { [weak self] items in
            self?.countLabel.stringValue = items.isEmpty ? "" : "\(items.count) item\(items.count == 1 ? "" : "s")"
        }.store(in: &cancellables)
    }

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active

        let shelf = FloatShelfView(model: model)
        let scroll = NSScrollView()
        scroll.documentView = shelf
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearAll))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        [clear, remove].forEach { $0.bezelStyle = .rounded; $0.controlSize = .small }
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let handle = FloatDragAllHandle(model: model)
        let bar = NSStackView(views: [clear, remove, countLabel, NSView(), handle])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(scroll)
        background.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 38),
        ])
        return background
    }

    @objc private func clearAll() { model.clear() }
    @objc private func removeSelected() { model.removeSelected() }

    func add(_ urls: [URL]) {
        model.add(urls)
        panel.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.pruneMissing()
    }
}

/// Keeps track of open shelves and applies the "Float Behaviour" setting.
@MainActor
final class FloatShelfManager {
    private(set) var shelves: [FloatShelfController] = []

    func add(_ urls: [URL], behaviour: FloatBehaviour, near point: NSPoint) {
        let shelf: FloatShelfController
        if behaviour == .addToLast, let last = shelves.last {
            shelf = last
        } else {
            shelf = FloatShelfController(near: point)
            shelf.onClose = { [weak self] closed in self?.shelves.removeAll { $0 === closed } }
            shelves.append(shelf)
        }
        shelf.add(urls)
    }

    /// Adds files to the newest shelf, creating one if none is open.
    func addToNewestOrNew(_ urls: [URL], near point: NSPoint) {
        add(urls, behaviour: .addToLast, near: point)
    }
}
