import AppKit
import CoreImage
import SwiftUI

extension Notification.Name {
    /// Posted by anything that wants the Welcome Guide opened (the About tab's button).
    static let narengiShowWelcome = Notification.Name("app.narengi.showWelcome")
}

enum OnboardingDefaults {
    static let completedKey = "hasCompletedOnboarding"
}

enum OnboardingStep: Int, CaseIterable {
    case how, practice, setup, done

    var title: String {
        switch self {
        case .how: return "How it works"
        case .practice: return "Try it"
        case .setup: return "Quick setup"
        case .done: return "You're all set"
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .how
    @Published private(set) var wheelsSeen: Set<WheelKind> = []
    let sampleURL: URL?

    init(sampleURL: URL? = OnboardingSample.makeFile()) {
        self.sampleURL = sampleURL
    }

    var isFirst: Bool { step == .how }
    var isLast: Bool { step == .done }
    var progress: Double { Double(step.rawValue + 1) / Double(OnboardingStep.allCases.count) }

    func next() { if let n = OnboardingStep(rawValue: step.rawValue + 1) { step = n } }
    func back() { if let p = OnboardingStep(rawValue: step.rawValue - 1) { step = p } }
    func go(to step: OnboardingStep) { self.step = step }

    func noteWheel(_ kind: WheelKind) { wheelsSeen.insert(kind) }
    var allWheelsTried: Bool { wheelsSeen.count == WheelKind.allCases.count }
}

/// The practice file: a picture that every wheel has something to do with (convert, tools, actions),
/// carrying a QR code so Read QR has something to find.
enum OnboardingSample {
    static let qrText = "Hello from Narengi!"
    static let fileName = "Narengi Sample.png"

    static func makeFile() -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Narengi Practice", isDirectory: true)
        let url = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let image = makeImage(), let data = ImageEngine.pngData(image) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch { return nil }
    }

    static func makeImage() -> CGImage? {
        let size = CGSize(width: 900, height: 600)
        guard let context = try? ImageOps.makeContext(width: Int(size.width), height: Int(size.height)) else { return nil }
        let colors = [RGB(255, 140, 66).cgColor, RGB(242, 101, 34).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: ImageOps.sRGB, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        // The wordmark.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Narengi" as NSString).draw(at: CGPoint(x: 60, y: 330), withAttributes: [
            .font: NSFont.systemFont(ofSize: 110, weight: .bold), .foregroundColor: NSColor.white])
        ("Drag me onto a slice" as NSString).draw(at: CGPoint(x: 64, y: 270), withAttributes: [
            .font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
        NSGraphicsContext.restoreGraphicsState()
        // The QR code on a white card.
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(Data(qrText.utf8), forKey: "inputMessage")
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
               let qr = CIContext().createCGImage(output, from: output.extent) {
                let card = CGRect(x: 60, y: 50, width: 190, height: 190)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.addPath(CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil))
                context.fillPath()
                context.interpolationQuality = .none
                context.draw(qr, in: card.insetBy(dx: 16, dy: 16))
            }
        }
        return context.makeImage()
    }
}
