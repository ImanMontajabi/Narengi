import AppKit
import Combine
import QuickLookUI

/// The grid inside a Float shelf: file icons that can be selected, dragged out to Finder or other apps,
/// and added to by dropping files on it. Layout and interaction follow Satsuma's `float.rs`
/// (MIT, © sonatina-dream); the implementation is Narengi's own.
final class FloatShelfView: NSView, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let cellWidth: CGFloat = 92
    static let cellHeight: CGFloat = 96
    static let padding: CGFloat = 10
    static let iconSize: CGFloat = 52

    let model: FloatShelfModel
    private var cancellables: Set<AnyCancellable> = []
    private var icons: [UUID: NSImage] = [:]
    private var anchor: UUID?
    private var pressed: UUID?
    private var pressPoint: NSPoint = .zero
    private var rubberBand: NSRect?
    private var rubberBase: Set<UUID> = []
    private var dropTarget = false

    init(model: FloatShelfModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 200))
        registerForDraggedTypes([.fileURL])
        autoresizingMask = [.width]
        model.$items.combineLatest(model.$selection).receive(on: DispatchQueue.main).sink { [weak self] _, _ in
            guard let self else { return }
            self.setFrameSize(self.frame.size)
            self.needsDisplay = true
        }.store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Geometry

    static func columns(forWidth width: CGFloat) -> Int {
        max(1, Int(((width - padding * 2) / cellWidth).rounded(.down)))
    }

    static func cellRect(_ index: Int, columns: Int) -> NSRect {
        NSRect(x: padding + CGFloat(index % columns) * cellWidth, y: padding + CGFloat(index / columns) * cellHeight,
               width: cellWidth, height: cellHeight)
    }

    static func iconRect(_ index: Int, columns: Int) -> NSRect {
        let cell = cellRect(index, columns: columns)
        return NSRect(x: cell.minX + (cellWidth - iconSize) / 2, y: cell.minY + 8, width: iconSize, height: iconSize)
    }

    static func contentHeight(count: Int, width: CGFloat) -> CGFloat {
        let rows = (count + columns(forWidth: width) - 1) / columns(forWidth: width)
        return padding * 2 + CGFloat(max(rows, 1)) * cellHeight
    }

    private var columns: Int { Self.columns(forWidth: bounds.width) }

    private func index(at point: NSPoint) -> Int? {
        model.items.indices.first { Self.cellRect($0, columns: columns).contains(point) }
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let clipHeight = enclosingScrollView?.contentSize.height ?? newSize.height
        super.setFrameSize(NSSize(width: newSize.width, height: max(Self.contentHeight(count: model.items.count, width: newSize.width), clipHeight)))
    }

    // MARK: - Drawing

    private func icon(for item: FloatItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[item.id] = image
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        let columns = self.columns
        if model.items.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("Drop files here" as NSString).draw(
                in: NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        }
        if dropTarget {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
            path.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        for (index, item) in model.items.enumerated() {
            let cell = Self.cellRect(index, columns: columns)
            if model.selection.contains(item.id) {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 4, dy: 2), xRadius: 8, yRadius: 8).fill()
            }
            icon(for: item).draw(in: Self.iconRect(index, columns: columns))
            (item.url.lastPathComponent as NSString).draw(
                with: NSRect(x: cell.minX + 4, y: cell.minY + Self.iconSize + 12, width: cell.width - 8, height: 30),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
        if let band = rubberBand {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: band)
            path.fill()
            path.stroke()
        }
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        pressPoint = point
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        if let hit = index(at: point) {
            let item = model.items[hit]
            pressed = item.id
            model.click(item.id, command: command, shift: shift, anchor: &anchor)
            if event.clickCount == 2 { NSWorkspace.shared.open(item.url) }
        } else {
            pressed = nil
            rubberBase = command || shift ? model.selection : []
            if !(command || shift) { model.selection = [] }
            rubberBand = NSRect(origin: point, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = pressed {
            guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 4 else { return }
            pressed = nil
            let items = model.dragItems(startingOn: id)
            let columns = self.columns
            let frames = items.map { item in
                Self.iconRect(model.items.firstIndex(of: item) ?? 0, columns: columns)
            }
            Self.beginDrag(from: self, items: items, frames: frames, event: event, source: self) { self.icon(for: $0) }
            return
        }
        guard rubberBand != nil else { return }
        let band = NSRect(x: min(point.x, pressPoint.x), y: min(point.y, pressPoint.y),
                          width: abs(point.x - pressPoint.x), height: abs(point.y - pressPoint.y))
        rubberBand = band
        let columns = self.columns
        let hits = model.items.enumerated().filter { Self.cellRect($0.offset, columns: columns).intersects(band) }.map(\.element.id)
        model.selection = rubberBase.union(hits)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let id = pressed, event.modifierFlags.intersection([.command, .shift]).isEmpty {
            model.selection = [id]  // a plain click inside a multi-selection narrows it, like Finder
        }
        pressed = nil
        rubberBand = nil
        needsDisplay = true
    }

    /// Starts a drag session carrying `items` as file URLs (used by the grid and by "Drag All").
    static func beginDrag(
        from view: NSView, items: [FloatItem], frames: [NSRect], event: NSEvent,
        source: NSDraggingSource, icon: (FloatItem) -> NSImage
    ) {
        let draggingItems = zip(items, frames).map { item, frame -> NSDraggingItem in
            let dragging = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            dragging.setDraggingFrame(frame, contents: icon(item))
            return dragging
        }
        guard !draggingItems.isEmpty else { return }
        view.beginDraggingSession(with: draggingItems, event: event, source: source)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic, .link]
    }

    // MARK: - Dropping files in

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingSource as AnyObject? === self { return [] }  // reordering isn't a drop
        dropTarget = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropTarget = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTarget = false
        needsDisplay = true
        return model.add(droppedFiles(sender)) > 0
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 51, 117: model.removeSelected()                     // ⌫ ⌦
        case 49: toggleQuickLook()                               // Space
        case 0 where command: model.selectAll()                  // ⌘A
        case 8 where command: copySelection()                    // ⌘C
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = index(at: point) else { return nil }
        let item = model.items[hit]
        if !model.selection.contains(item.id) { model.selection = [item.id] }
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector) {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        add("Open", #selector(openSelection))
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu(for: item.url)
        menu.addItem(openWith)
        add("Quick Look", #selector(quickLookAction))
        add("Show in Finder", #selector(showInFinder))
        menu.addItem(.separator())
        add("Copy", #selector(copyAction))
        add("Duplicate", #selector(duplicateSelection))
        add("Move to Trash", #selector(trashSelection))
        menu.addItem(.separator())
        add("Remove from Float", #selector(removeAction))
        return menu
    }

    private func openWithMenu(for url: URL) -> NSMenu {
        let submenu = NSMenu()
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        for app in apps.prefix(12) {
            let entry = NSMenuItem(title: FileManager.default.displayName(atPath: app.path), action: #selector(openWithApp(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = app
            entry.image = NSWorkspace.shared.icon(forFile: app.path)
            entry.image?.size = NSSize(width: 16, height: 16)
            submenu.addItem(entry)
        }
        return submenu
    }

    @objc private func openSelection() { model.selectedItems.forEach { NSWorkspace.shared.open($0.url) } }
    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(model.selectedItems.map(\.url), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    @objc private func quickLookAction() { toggleQuickLook() }
    @objc private func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting(model.selectedItems.map(\.url)) }
    @objc private func copyAction() { copySelection() }
    @objc private func removeAction() { model.removeSelected() }

    private func copySelection() {
        let urls = model.selectedItems.map(\.url)
        if !urls.isEmpty { ActionRunner.copyToClipboard(urls) }
    }

    @objc private func duplicateSelection() {
        for item in model.selectedItems {
            if let copy = Self.duplicate(item.url) { model.add([copy]) }
        }
    }

    /// `a.txt` → `a copy.txt` → `a copy 2.txt`, beside the original.
    @discardableResult
    static func duplicate(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        let name = url.lastPathComponent
        let base = NamingRules.stem(of: name) + " copy"
        let ext = String(name.dropFirst(NamingRules.stem(of: name).count).drop { $0 == "." })
        let free = NamingRules.firstFree(base: base, ext: ext.isEmpty ? nil : ext) {
            fileManager.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent($0).path)
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(free)
        do { try fileManager.copyItem(at: url, to: target); return target } catch { return nil }
    }

    @objc private func trashSelection() {
        var removed = Set<UUID>()
        for item in model.selectedItems {
            if (try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)) != nil { removed.insert(item.id) }
        }
        model.remove(removed)
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        guard !model.selectedItems.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            window?.makeKey()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { model.selectedItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let items = model.selectedItems
        return items.indices.contains(index) ? items[index].url as NSURL : nil
    }
}

/// "Drag All": a handle that drags every file on the shelf out at once.
final class FloatDragAllHandle: NSView, NSDraggingSource {
    private let model: FloatShelfModel

    init(model: FloatShelfModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 92, height: 24))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        ("Drag All" as NSString).draw(
            in: NSRect(x: 0, y: 4, width: bounds.width, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }

    override func mouseDragged(with event: NSEvent) {
        let items = model.items
        let frames = items.indices.map { NSRect(x: 8 + CGFloat($0 % 5) * 3, y: 4 + CGFloat($0 % 5) * 3, width: 16, height: 16) }
        FloatShelfView.beginDrag(from: self, items: items, frames: frames, event: event, source: self) {
            NSWorkspace.shared.icon(forFile: $0.url.path)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic, .link]
    }
}
