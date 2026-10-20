import Foundation

enum ExternalTool: String, CaseIterable, Sendable {
    case ffmpeg, cwebp, exiftool

    var displayName: String { rawValue }
}

/// Finds helper executables: the app bundle's `Resources/Vendor` first, then Homebrew for local development.
struct BundledToolLocator: Sendable {
    var vendorDirectory: URL?
    var fallbackDirectories: [String]

    static let shared = BundledToolLocator()

    init(
        vendorDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Vendor", isDirectory: true),
        fallbackDirectories: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) {
        self.vendorDirectory = vendorDirectory
        self.fallbackDirectories = fallbackDirectories
    }

    func locate(_ tool: ExternalTool) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let vendorDirectory {
            candidates.append(vendorDirectory.appendingPathComponent(tool.rawValue))
            candidates.append(vendorDirectory.appendingPathComponent(tool.rawValue).appendingPathComponent(tool.rawValue))
            candidates.append(vendorDirectory.appendingPathComponent("bin").appendingPathComponent(tool.rawValue))
        }
        candidates += fallbackDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent(tool.rawValue) }

        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && fileManager.isExecutableFile(atPath: url.path)
        }
    }

    /// Like `locate`, but throws a user-facing error when the tool is missing.
    func require(_ tool: ExternalTool) throws -> URL {
        guard let url = locate(tool) else { throw ConversionError.toolMissing(tool.displayName) }
        return url
    }
}
