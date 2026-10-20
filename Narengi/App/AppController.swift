import AppKit
import SwiftUI

/// Owns the long-lived pieces: status item, drag monitor, wheel overlay, job queue, HUD, settings window.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let settings = SettingsStore.shared
    let queue = JobQueue()
    private let monitor: DragGestureMonitor
    private let wheel: WheelController
    private let hud: ProgressHUDController
    private let statusItem = StatusItemController()
    private let dispatcher: JobDispatcher
    private let toolPanels: ToolPanels
    private let float = FloatShelfManager()
    private let dropTile = FloatDropTile()
    private let onboarding: OnboardingController
    private var welcomeObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?

    override init() {
        monitor = DragGestureMonitor(settings: SettingsStore.shared)
        wheel = WheelController(settings: SettingsStore.shared)
        hud = ProgressHUDController(queue: queue)
        let actions = ActionRunner(settings: SettingsStore.shared, queue: queue, float: float)
        toolPanels = ToolPanels(queue: queue, settings: SettingsStore.shared)
        dispatcher = JobDispatcher(queue: queue, settings: SettingsStore.shared, actions: actions, panels: toolPanels)
        onboarding = OnboardingController(settings: SettingsStore.shared)
        super.init()
        wire()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("Narengi launched")
        statusItem.install()
        monitor.start()

        // ffmpeg's encoder list takes a moment to read; do it off the main thread before the first drag.
        // User-initiated, not utility: the first drag may need the result, and waiting on a lower-priority thread is a priority inversion.
        Task.detached(priority: .userInitiated) { _ = Availability.shared }

        // First launch: the Welcome Guide. Afterwards it is one click away in the menu and in Settings → About.
        // (Not while the unit tests host the app: they exercise the guide themselves.)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { onboarding.showIfFirstLaunch() }
        // On notched screens macOS can hide overflowing status items; make sure the app stays reachable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.statusItem.isOnScreen else { return }
            Log.app.notice("Status item is not visible; opening Settings so Narengi stays reachable")
            if !self.onboarding.isShowing { self.showSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    /// Re-launching from Finder, Spotlight or Xcode opens Settings (the menu-bar item may be hidden).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.app.notice("Reopen requested; showing Settings")
        showSettings()
        return true
    }

    // MARK: - Wiring

    private func wire() {
        statusItem.onConvertFiles = { [weak self] in self?.convertFiles() }
        statusItem.onOpenSettings = { [weak self] in self?.showSettings() }
        statusItem.onWelcomeGuide = { [weak self] in self?.onboarding.show() }
        onboarding.onSampleDragStart = { [weak self] urls in self?.monitor.beginManualDrag(urls) }
        onboarding.onOpenSettings = { [weak self] in self?.showSettings() }
        welcomeObserver = NotificationCenter.default.addObserver(forName: .narengiShowWelcome, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onboarding.show() }
        }

        wheel.isAvailable = { item, formats in Availability.shared.item(item, formats: formats) }
        wheel.onSelect = { [weak self] item, urls in self?.handle(item, files: urls) }

        monitor.onDragBegan = { [weak self] urls in
            guard let self, !self.wheel.isKeyboardMode else { return }
            self.wheel.prepare(files: urls)
        }
        monitor.onWheelRequested = { [weak self] kind in
            guard let self, !self.wheel.isKeyboardMode else { return }
            self.wheel.present(kind)
            self.onboarding.model.noteWheel(kind)
            if !self.dropTile.isVisible { self.dropTile.show(near: NSEvent.mouseLocation) }
        }
        monitor.onTick = { [weak self] mouse in
            self?.wheel.updateHover(mouse: mouse)
            self?.dropTile.updateHover(mouse)
        }
        // Mouse-up applies the petal under the pointer (the panel's own drop callback is not reliable).
        monitor.onDragEnded = { [weak self] in
            guard let self, !self.wheel.isKeyboardMode else { return }
            let mouse = NSEvent.mouseLocation
            defer { self.dropTile.hide() }
            if self.dropTile.contains(mouse) {
                // Released over the "Drop files here" tile: put the files on a Float shelf.
                let urls = self.wheel.draggedURLs
                self.wheel.dismiss(after: 0.3)
                self.float.add(urls, behaviour: self.settings.floatBehaviour, near: mouse)
                return
            }
            self.wheel.finishDrag(at: mouse)
        }

        queue.onBatchFinished = { [weak self] result in self?.batchFinished(result) }
    }

    // MARK: - Keyboard mode

    /// "Convert Files…": choose files, then pick a petal with the keyboard or the mouse.
    private func convertFiles() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose files to convert, edit or act on."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        wheel.presentKeyboard(files: panel.urls)
    }

    // MARK: - Jobs

    private func handle(_ item: WheelItem, files: [URL]) {
        dispatcher.handle(item, files: files, policy: settings.outputPolicy)
    }

    private func batchFinished(_ result: BatchResult) {
        Log.job.notice("Batch finished: \(result.outputs.count) output(s), \(result.failedCount) failed, \(result.cancelledCount) cancelled")
        hud.batchFinished(result)
        guard !result.outputs.isEmpty else { return }
        if settings.revealInFinder {
            NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
        }
        if settings.feedbackEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }

    // MARK: - Settings window

    func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: controller)
            window.title = "Narengi Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 540, height: 640))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
