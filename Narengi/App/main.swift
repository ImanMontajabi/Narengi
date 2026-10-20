import AppKit

// A plain AppKit entry point: the status item and delegate are owned by `AppController`,
// which stays alive for the whole run because `NSApplication.delegate` is weak.
let narengiController = MainActor.assumeIsolated { AppController() }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = narengiController
    app.run()
}
