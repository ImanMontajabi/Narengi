import AppKit

/// The six file actions of the Actions wheel. Behaviour follows Satsuma's `actions.rs` (MIT, © sonatina-dream);
/// the AppKit calls are Narengi's own.
@MainActor
final class ActionRunner {
    private let settings: SettingsStore
    private let queue: JobQueue
    let float: FloatShelfManager
    private let pasteboard: NSPasteboard

    init(settings: SettingsStore, queue: JobQueue, float: FloatShelfManager, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.settings = settings
        self.queue = queue
        self.float = float
    }

    func perform(_ action: ActionID, on urls: [URL], near point: NSPoint = NSEvent.mouseLocation) {
        guard !urls.isEmpty else { return }
        Log.job.notice("Action \(action.rawValue, privacy: .public) on \(urls.count) item(s)")
        switch action {
        case .airDrop: airDrop(urls)
        case .float: float.add(urls, behaviour: settings.floatBehaviour, near: point)
        case .copy: Self.copyToClipboard(urls, pasteboard: pasteboard)
        case .copyPath: Self.copyPaths(urls, pasteboard: pasteboard)
        case .terminal: openTerminal(urls)
        case .move:
            // The drag has just ended; let it finish before a modal panel appears.
            DispatchQueue.main.async { [weak self] in self?.chooseFolderAndMove(urls) }
        }
        if action != .move, action != .float, settings.feedbackEnabled {
            NSSound(named: NSSound.Name("Tink"))?.play()
        }
    }

    // MARK: - Copy, Copy Path

    @discardableResult
    static func copyToClipboard(_ urls: [URL], pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    @discardableResult
    static func copyPaths(_ urls: [URL], pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(ActionID.pathsAsText(urls), forType: .string)
    }

    // MARK: - AirDrop

    private func airDrop(_ urls: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            queue.enqueue(title: "AirDrop", work: { _ in throw ConversionError.custom("AirDrop isn't available on this Mac.") })
            return
        }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    // MARK: - Terminal

    /// Folders to open: each folder itself, each file's parent, without repeats.
    static func terminalDirectories(for urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let directory = ActionID.terminalDirectory(for: url, isDirectory: isDirectory.boolValue)
            return seen.insert(directory.standardizedFileURL.path).inserted ? directory : nil
        }
    }

    private func openTerminal(_ urls: [URL]) {
        let directories = Self.terminalDirectories(for: urls)
        let workspace = NSWorkspace.shared
        let app = workspace.urlForApplication(withBundleIdentifier: settings.terminalApp.bundleIdentifier)
            ?? workspace.urlForApplication(withBundleIdentifier: TerminalApp.terminal.bundleIdentifier)
        guard let app else { return }
        if app.lastPathComponent != "Terminal.app", settings.terminalApp != .terminal,
           workspace.urlForApplication(withBundleIdentifier: settings.terminalApp.bundleIdentifier) == nil {
            Log.job.notice("Terminal app \(self.settings.terminalApp.title, privacy: .public) is not installed; using Terminal")
        }
        workspace.open(directories, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Move

    private func chooseFolderAndMove(_ urls: [URL]) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = "Choose a folder to move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        queue.enqueue(
            title: "Move to \(folder.lastPathComponent)",
            sourceName: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items",
            work: Self.moveWork(urls, to: folder))
    }

    static func moveWork(_ urls: [URL], to folder: URL) -> Job.Work {
        { context in
            var moved: [URL] = []
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                moved.append(try move(url, into: folder))
                context.reportProgress(Double(index + 1) / Double(urls.count))
            }
            return moved
        }
    }

    /// Moves `url` into `folder` under a free name (`a.txt`, `a 2.txt`, …). Never overwrites.
    @discardableResult
    nonisolated static func move(_ url: URL, into folder: URL) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let name = url.lastPathComponent
        let base = isDirectory.boolValue && url.pathExtension.isEmpty ? name : NamingRules.stem(of: name)
        let ext = name.dropFirst(base.count).drop { $0 == "." }
        for _ in 0..<1000 {
            let free = NamingRules.firstFree(base: base, ext: ext.isEmpty ? nil : String(ext)) {
                fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            let target = folder.appendingPathComponent(free)
            do {
                try fileManager.moveItem(at: url, to: target)
                return target
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue  // name appeared meanwhile; pick the next one
            } catch {
                throw ConversionError.outputUnwritable(folder.path)
            }
        }
        throw ConversionError.outputUnwritable(folder.path)
    }
}
