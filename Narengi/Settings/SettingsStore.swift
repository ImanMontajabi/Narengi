import AppKit
import ServiceManagement

enum AppearanceStyle: String, CaseIterable, Identifiable {
    case glass, solid
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum WheelKind: String, CaseIterable, Identifiable {
    case conversion, tools, actions
    var id: String { rawValue }

    var name: String {
        switch self {
        case .conversion: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }
}

/// A modifier combination that can be tapped while dragging to open a wheel.
enum ModifierChoice: String, CaseIterable, Identifiable {
    case shift, command, option, control, shiftOption, shiftCommand, commandOption

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return [.shift]
        case .command: return [.command]
        case .option: return [.option]
        case .control: return [.control]
        case .shiftOption: return [.shift, .option]
        case .shiftCommand: return [.shift, .command]
        case .commandOption: return [.command, .option]
        }
    }

    var title: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shiftOption: return "⇧⌥ Shift + Option"
        case .shiftCommand: return "⇧⌘ Shift + Command"
        case .commandOption: return "⌘⌥ Command + Option"
        }
    }
}

extension ModifierChoice {
    /// Plain name for sentences: "Shift", "Control", "Shift+Option".
    var shortName: String {
        switch self {
        case .shift: return "Shift"
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shiftOption: return "Shift+Option"
        case .shiftCommand: return "Shift+Command"
        case .commandOption: return "Command+Option"
        }
    }
}

enum FloatBehaviour: String, CaseIterable, Identifiable {
    case createNew, addToLast
    var id: String { rawValue }
    var title: String {
        switch self {
        case .createNew: return "Create a New Float"
        case .addToLast: return "Add to Last Float"
        }
    }
}

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty, warp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        }
    }
    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        }
    }
}

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal, customFolder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .besideOriginal: return "Beside the original file"
        case .customFolder: return "A folder I choose"
        }
    }
}

enum QualityLevel: String, Codable, CaseIterable, Identifiable {
    case low, balanced, high
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CompressionLevel: String, Codable, CaseIterable, Identifiable {
    case balanced, strong
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ImageSizeOption: String, Codable, CaseIterable, Identifiable {
    case original, percent75, percent50, percent25, max4096, max2048, max1080
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Keep original dimensions"
        case .percent75: return "75% of original"
        case .percent50: return "50% of original"
        case .percent25: return "25% of original"
        case .max4096: return "Fit within 4096 px"
        case .max2048: return "Fit within 2048 px"
        case .max1080: return "Fit within 1080 px"
        }
    }
}

struct FormatOptions: Codable, Equatable {
    static let dpiChoices = [72, 96, 150, 200, 300, 600]

    var quality: QualityLevel = .balanced
    var preserveMetadata = true
    var compression: CompressionLevel = .balanced
    var imageSize: ImageSizeOption = .original
    /// Resolution for rasterizing this format when it is the input (PDF pages, SVG).
    var dpi = 150

    init() {}

    // Tolerant decoding so options saved by older builds keep working when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quality = try c.decodeIfPresent(QualityLevel.self, forKey: .quality) ?? .balanced
        preserveMetadata = try c.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? true
        compression = try c.decodeIfPresent(CompressionLevel.self, forKey: .compression) ?? .balanced
        imageSize = try c.decodeIfPresent(ImageSizeOption.self, forKey: .imageSize) ?? .original
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi) ?? 150
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var style: AppearanceStyle {
        didSet { defaults.set(style.rawValue, forKey: "style") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }
    @Published var feedbackEnabled: Bool {
        didSet { defaults.set(feedbackEnabled, forKey: "feedbackEnabled") }
    }
    @Published var revealInFinder: Bool {
        didSet { defaults.set(revealInFinder, forKey: "revealInFinder") }
    }
    @Published var conversionModifier: ModifierChoice {
        didSet { defaults.set(conversionModifier.rawValue, forKey: "conversionModifier") }
    }
    @Published var toolsModifier: ModifierChoice {
        didSet { defaults.set(toolsModifier.rawValue, forKey: "toolsModifier") }
    }
    @Published var actionsModifier: ModifierChoice {
        didSet { defaults.set(actionsModifier.rawValue, forKey: "actionsModifier") }
    }
    @Published var floatBehaviour: FloatBehaviour {
        didSet { defaults.set(floatBehaviour.rawValue, forKey: "floatBehaviour") }
    }
    @Published var terminalApp: TerminalApp {
        didSet { defaults.set(terminalApp.rawValue, forKey: "terminalApp") }
    }
    @Published var outputLocation: OutputLocation {
        didSet { defaults.set(outputLocation.rawValue, forKey: "outputLocation") }
    }
    @Published var customOutputFolder: URL? {
        didSet { defaults.set(customOutputFolder?.path, forKey: "customOutputFolder") }
    }
    @Published private(set) var formatOptions: [String: FormatOptions] {
        didSet {
            if let data = try? JSONEncoder().encode(formatOptions) {
                defaults.set(data, forKey: "formatOptions")
            }
        }
    }

    private init() {
        func raw<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        style = raw("style", .glass)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        feedbackEnabled = defaults.object(forKey: "feedbackEnabled") as? Bool ?? true
        revealInFinder = defaults.object(forKey: "revealInFinder") as? Bool ?? true
        conversionModifier = raw("conversionModifier", .shift)
        toolsModifier = raw("toolsModifier", .command)
        actionsModifier = raw("actionsModifier", .control)
        floatBehaviour = raw("floatBehaviour", .createNew)
        terminalApp = raw("terminalApp", .terminal)
        outputLocation = raw("outputLocation", .besideOriginal)
        customOutputFolder = defaults.string(forKey: "customOutputFolder").map { URL(fileURLWithPath: $0) }
        formatOptions = defaults.data(forKey: "formatOptions")
            .flatMap { try? JSONDecoder().decode([String: FormatOptions].self, from: $0) } ?? [:]
    }

    var outputPolicy: OutputPolicy {
        OutputPolicy(location: outputLocation, customFolder: customOutputFolder)
    }

    func modifier(for kind: WheelKind) -> ModifierChoice {
        switch kind {
        case .conversion: return conversionModifier
        case .tools: return toolsModifier
        case .actions: return actionsModifier
        }
    }

    /// Non-nil when two wheels share the same modifier combination, which makes one unreachable.
    var modifierConflict: String? {
        let all = WheelKind.allCases.map { modifier(for: $0) }
        return Set(all).count == all.count ? nil : "Two wheels use the same modifier; only one will open."
    }

    func options(for format: String) -> FormatOptions {
        formatOptions[format] ?? FormatOptions()
    }

    func setOptions(_ options: FormatOptions, for format: String) {
        formatOptions[format] = options
    }

    func resetOptions(for format: String) {
        formatOptions[format] = nil
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.settings.error("Launch at login change failed: \(error.localizedDescription)")
        }
    }
}
