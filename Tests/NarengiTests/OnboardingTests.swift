import AppKit
import XCTest
@testable import Narengi

@MainActor
final class OnboardingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "app.narengi.tests.onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Model

    func testStepsAdvanceAndStayInRange() {
        let model = OnboardingModel(sampleURL: nil)
        XCTAssertEqual(model.step, .how)
        XCTAssertTrue(model.isFirst)
        model.back()
        XCTAssertEqual(model.step, .how)
        for expected in [OnboardingStep.practice, .setup, .done] {
            model.next()
            XCTAssertEqual(model.step, expected)
        }
        XCTAssertTrue(model.isLast)
        model.next()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.progress, 1)
        model.go(to: .setup)
        XCTAssertEqual(model.step, .setup)
        XCTAssertEqual(OnboardingStep.allCases.count, 4)
    }

    func testWheelsSeenTracksEachWheelOnce() {
        let model = OnboardingModel(sampleURL: nil)
        XCTAssertFalse(model.allWheelsTried)
        model.noteWheel(.conversion)
        model.noteWheel(.conversion)
        model.noteWheel(.tools)
        XCTAssertEqual(model.wheelsSeen, [.conversion, .tools])
        XCTAssertFalse(model.allWheelsTried)
        model.noteWheel(.actions)
        XCTAssertTrue(model.allWheelsTried)
    }

    func testThePracticeFileIsAReadablePictureWithAQRCode() throws {
        let url = try XCTUnwrap(OnboardingSample.makeFile())
        XCTAssertEqual(url.lastPathComponent, "Narengi Sample.png")
        let info = try XCTUnwrap(TestSupport.info(url))
        XCTAssertEqual(info.width, 900)
        XCTAssertEqual(info.height, 600)
        XCTAssertEqual(FormatCatalog.detect(url), "PNG", "every wheel recognises it")
        let results = try QREngine.scan(file: url, format: "PNG")
        XCTAssertEqual(results.map(\.payload), [OnboardingSample.qrText], "Read QR has something to find")
        // Every wheel has something to offer for it.
        XCTAssertFalse(FormatCatalog.targets(forSelection: ["PNG"]).isEmpty)
        XCTAssertFalse(ToolID.tools(for: "PNG", count: 1).isEmpty)
        XCTAssertEqual(OnboardingSample.makeFile(), url, "creating it twice reuses the file")
    }

    // MARK: - Triggers

    func testShowsOnFirstLaunchOnlyAndRemembersCompletion() throws {
        let controller = OnboardingController(settings: .shared, defaults: defaults, model: OnboardingModel(sampleURL: nil))
        defer { controller.window?.close() }
        XCTAssertFalse(controller.hasCompleted)
        controller.showIfFirstLaunch()
        XCTAssertTrue(controller.isShowing, "first launch opens the guide")
        XCTAssertFalse(defaults.bool(forKey: OnboardingDefaults.completedKey), "not done until it is closed")
        controller.window?.close()
        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(defaults.bool(forKey: "hasCompletedOnboarding"), "closing, any way, records it")

        controller.showIfFirstLaunch()
        XCTAssertFalse(controller.isShowing, "later launches stay quiet")
        controller.show()
        XCTAssertTrue(controller.isShowing, "the menu item and the About button reopen it any time")
        // The test host is the real app, which may show its own guide too; compare before and after.
        let visibleGuides = { NSApp.windows.filter { $0.title == "Welcome to Narengi" && $0.isVisible }.count }
        let before = visibleGuides()
        controller.show()  // a second request reuses the window
        XCTAssertEqual(visibleGuides(), before)
    }

    func testReopeningStartsAtTheFirstStep() {
        let model = OnboardingModel(sampleURL: nil)
        let controller = OnboardingController(settings: .shared, defaults: defaults, model: model)
        defer { controller.window?.close() }
        model.go(to: .done)
        controller.show()
        XCTAssertEqual(model.step, .how)
    }

    func testStatusMenuOffersTheWelcomeGuide() {
        let item = StatusItemController()
        item.install()
        defer { item.uninstall() }
        XCTAssertEqual(item.menuItemTitles.filter { !$0.isEmpty }, ["Convert Files…", "Settings…", "Welcome Guide…", "Quit Narengi"])
    }

    // MARK: - Practice drag hand-off

    func testADragStartedInTheWindowReachesTheDragMonitor() async throws {
        let url = try XCTUnwrap(OnboardingSample.makeFile())
        let monitor = DragGestureMonitor(settings: .shared)
        var began: [[URL]] = []
        var ended = 0
        monitor.onDragBegan = { began.append($0) }
        monitor.onDragEnded = { ended += 1 }
        monitor.beginManualDrag([])
        XCTAssertTrue(began.isEmpty, "nothing to drag")
        monitor.beginManualDrag([url])
        monitor.beginManualDrag([url])  // a second request while tracking is ignored
        XCTAssertEqual(began.count, 1)
        XCTAssertEqual(began.first?.first?.lastPathComponent, "Narengi Sample.png")
        // No mouse button is held in the test, so the 60 Hz poll sees the release and ends the drag.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ended, 1)
    }

    func testSampleCardDragSourceOffersTheFile() throws {
        let url = try XCTUnwrap(OnboardingSample.makeFile())
        let card = SampleCardNSView(url: url)
        XCTAssertEqual(card.intrinsicContentSize, NSSize(width: 230, height: 190))
        XCTAssertTrue(card.acceptsFirstMouse(for: nil))
        XCTAssertEqual(card.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .outsideApplication), .copy)
    }

    // MARK: - Windows

    private func snapshot(_ window: NSWindow, name: String) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["NARENGI_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func hasContent(_ rep: NSBitmapImageRep) -> Bool {
        var colors = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 9) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 9) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return colors.count > 8
    }

    func testEveryOnboardingStepRenders() async throws {
        let controller = OnboardingController(settings: .shared, defaults: defaults)
        defer { controller.window?.close() }
        controller.show()
        controller.model.noteWheel(.conversion)
        for (step, name) in [(OnboardingStep.how, "onboarding-1-how"), (.practice, "onboarding-2-practice"), (.setup, "onboarding-3-setup"), (.done, "onboarding-4-done")] {
            controller.model.go(to: step)
            try await Task.sleep(nanoseconds: 450_000_000)
            let window = try XCTUnwrap(controller.window)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(hasContent(try snapshot(window, name: name)), "\(step) isn't blank")
        }
    }
}
