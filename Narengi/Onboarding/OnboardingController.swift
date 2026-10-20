import AppKit
import SwiftUI

/// Owns the Welcome Guide window. Closing it, any way, counts as having seen it.
@MainActor
final class OnboardingController {
    let model: OnboardingModel
    private let settings: SettingsStore
    private let defaults: UserDefaults
    private var controller: ToolWindowController?
    /// Tells the drag monitor a drag began in our own window (global monitors can't see those).
    var onSampleDragStart: (([URL]) -> Void)?
    var onOpenSettings: (() -> Void)?

    init(settings: SettingsStore, defaults: UserDefaults = .standard, model: OnboardingModel? = nil) {
        self.settings = settings
        self.defaults = defaults
        self.model = model ?? OnboardingModel()
    }

    var hasCompleted: Bool { defaults.bool(forKey: OnboardingDefaults.completedKey) }
    var isShowing: Bool { controller?.window.isVisible ?? false }
    var window: NSWindow? { controller?.window }

    func showIfFirstLaunch() {
        if !hasCompleted { show() }
    }

    func show() {
        if let controller {
            NSApp.activate()
            controller.window.makeKeyAndOrderFront(nil)
            return
        }
        model.go(to: .how)
        let controller = ToolWindowController(title: "Welcome to Narengi", size: NSSize(width: 720, height: 560)) { [model, settings] controller in
            OnboardingView(
                model: model, settings: settings,
                onSampleDragStart: { [weak self] urls in self?.onSampleDragStart?(urls) },
                onOpenSettings: { [weak self] in self?.onOpenSettings?() },
                onFinish: { [weak controller] in controller?.close() })
        }
        controller.onClose = { [weak self] in
            self?.defaults.set(true, forKey: OnboardingDefaults.completedKey)
            self?.controller = nil
        }
        self.controller = controller
        controller.show()
        Log.app.notice("Welcome guide shown")
    }
}
