import AppKit

enum WheelAction: Equatable {
    case convert(to: String)
    case tool(ToolID)
    case action(ActionID)
}

struct WheelItem: Identifiable, Equatable {
    let id: String
    /// Text on the petal.
    let title: String
    /// Long name for the hub and progress ("Convert to PNG").
    let name: String
    /// SF Symbol above the label (tools and actions only).
    let symbol: String?
    let action: WheelAction

    static func convert(_ format: String) -> WheelItem {
        WheelItem(id: "convert.\(format)", title: format, name: "Convert to \(format)", symbol: nil, action: .convert(to: format))
    }

    static func tool(_ tool: ToolID) -> WheelItem {
        let info = tool.info
        return WheelItem(id: "tool.\(info.id)", title: info.title, name: info.name, symbol: info.symbol, action: .tool(tool))
    }

    static func action(_ action: ActionID) -> WheelItem {
        WheelItem(id: "action.\(action.rawValue)", title: action.title, name: action.name, symbol: action.symbol, action: .action(action))
    }
}

/// The files being dragged, with the facts the wheels need.
struct DraggedFiles {
    let urls: [URL]
    /// Format of each item; nil for plain folders and unknown files.
    let formats: [String?]

    init(urls: [URL]) {
        self.urls = urls
        self.formats = urls.map(FormatCatalog.detect)
    }

    /// Total size of the files; nil when the selection holds only folders.
    var totalBytes: UInt64? {
        var total: UInt64 = 0
        var sawFile = false
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.totalFileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true, FormatCatalog.detect(url) == nil { continue }
            sawFile = true
            total += UInt64(values?.totalFileSize ?? 0)
        }
        return sawFile ? total : nil
    }

    var captionLines: [String] {
        WheelCaption.lines(count: urls.count, totalBytes: totalBytes)
    }
}

enum WheelItems {
    /// Petals for a wheel, in order, keeping only what `available` allows.
    static func items(for kind: WheelKind, formats: [String?], available: (WheelItem) -> Bool) -> [WheelItem] {
        let items: [WheelItem]
        switch kind {
        case .actions:
            items = ActionID.allCases.map(WheelItem.action)
        case .conversion, .tools:
            let known = formats.compactMap { $0 }
            guard !known.isEmpty, known.count == formats.count else { return [] }
            items = kind == .conversion
                ? FormatCatalog.targets(forSelection: known).map(WheelItem.convert)
                : ToolID.tools(forSelection: known).map(WheelItem.tool)
        }
        return items.filter(available)
    }

    /// The wheel to open in keyboard mode: conversions, or actions when there are none.
    static func initialKeyboardKind(hasConversions: Bool) -> WheelKind {
        hasConversions ? .conversion : .actions
    }

    /// Shown under the ring when a wheel has no petals. Uses the user's own modifier names.
    @MainActor
    static func emptyMessage(for kind: WheelKind, settings: SettingsStore) -> String {
        let actions = settings.modifier(for: .actions).shortName
        let convert = settings.modifier(for: .conversion).shortName
        switch kind {
        case .conversion: return "No conversions for this format. Tap \(actions) for file actions."
        case .tools: return "No tools for this format. Tap \(convert) to convert or \(actions) for file actions."
        case .actions: return ""
        }
    }
}

@MainActor
final class WheelModel: ObservableObject {
    @Published var kind: WheelKind = .conversion
    @Published var items: [WheelItem] = []
    @Published var hovered: Int?
    @Published var isPresented = false
    /// Menu-opened mode: the wheel takes keyboard and click input instead of a drag.
    @Published var keyboard = false
    @Published var captionLines: [String] = []
    @Published var emptyMessage = ""

    var hoveredItem: WheelItem? {
        guard let hovered, items.indices.contains(hovered) else { return nil }
        return items[hovered]
    }
}
