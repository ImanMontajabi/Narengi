import AppKit
import Combine
import SwiftUI

/// Compact floating panel (top-right of the screen the cursor is on) listing the queue's jobs.
@MainActor
final class ProgressHUDController {
    private let queue: JobQueue
    private let settings: SettingsStore
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private var cancellables = Set<AnyCancellable>()
    private var hideTask: Task<Void, Never>?

    init(queue: JobQueue, settings: SettingsStore? = nil) {
        let settings = settings ?? .shared
        self.queue = queue
        self.settings = settings

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: ProgressHUDMetrics.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow

        host = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = host

        queue.onJobAdded = { [weak self] _ in self?.jobAdded() }
        // The list changes shape only when jobs are added/removed; progress ticks update rows in place.
        queue.$jobs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// Called when a batch has fully finished: hide the HUD later if everything went fine.
    func batchFinished(_ result: BatchResult) {
        hideTask?.cancel()
        guard result.failedCount == 0 else { return }  // keep errors on screen until dismissed
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.hideIfIdle()
        }
    }

    func dismissAll() {
        queue.clearFinished()
    }

    // MARK: -

    private func jobAdded() {
        hideTask?.cancel()
        refresh()
    }

    private func hideIfIdle() {
        guard queue.isIdle else { return }
        queue.clearFinished()
    }

    private func refresh() {
        let jobs = queue.jobs
        guard !jobs.isEmpty else {
            panel.orderOut(nil)
            return
        }
        // Show active jobs first, then the most recent results.
        let ordered = jobs.filter { !$0.state.isTerminal } + jobs.filter { $0.state.isTerminal }.reversed()
        let visible = Array(ordered.prefix(ProgressHUDMetrics.maxRows))
        let hidden = jobs.count - visible.count

        host.rootView = AnyView(ProgressHUDView(
            queue: queue, settings: settings, visibleJobs: visible, hiddenCount: hidden,
            onDismissAll: { [weak self] in self?.dismissAll() }))

        let size = NSSize(width: ProgressHUDMetrics.width,
                          height: ProgressHUDMetrics.height(rows: visible.count, hidden: hidden))
        panel.setFrame(frame(size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func frame(size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Keep the top-right corner pinned while the panel grows downward.
        return NSRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 12,
                      width: size.width, height: size.height)
    }
}
