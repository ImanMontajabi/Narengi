import Foundation

enum ConversionError: LocalizedError, Equatable {
    case unsupported(from: String, to: String)
    case notImplemented(String)
    case decodeFailed(String)
    case encodeFailed(String)
    case toolMissing(String)
    case toolFailed(tool: String, message: String)
    case encoderMissing(String)
    case passwordProtected
    case noText
    case outputUnwritable(String)
    /// A ready-made, user-facing message.
    case custom(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let from, let to):
            return "Converting \(from) to \(to) isn't supported yet."
        case .notImplemented(let what):
            return "\(what) isn't available yet."
        case .decodeFailed(let name):
            return "Couldn't read \(name)."
        case .encodeFailed(let format):
            return "Couldn't write \(format) on this Mac."
        case .toolMissing(let tool) where tool == "ffmpeg":
            return "ffmpeg wasn't found. Install it with `brew install ffmpeg` to convert audio and video."
        case .toolMissing(let tool):
            return "\(tool) wasn't found. Run scripts/setup-vendor.sh or install it with Homebrew."
        case .toolFailed(let tool, let message):
            return "\(tool) failed: \(message)"
        case .encoderMissing(let what):
            return "This ffmpeg build cannot encode \(what)."
        case .passwordProtected:
            return "This PDF is password protected."
        case .noText:
            return "No text could be found in this file."
        case .outputUnwritable(let path):
            return "Couldn't write to \(path)."
        case .custom(let message):
            return message
        }
    }
}
