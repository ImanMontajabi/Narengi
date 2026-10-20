import Foundation

/// Runs a helper executable, killing it if the surrounding task is cancelled.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// Runs to completion and throws `ConversionError.toolFailed` on a non-zero exit.
    /// `onOutputLine` sees each stdout line as it arrives (ffmpeg `-progress pipe:1`).
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        tool: String,
        environment: [String: String]? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let output = try await launch(
            executable, arguments: arguments, tool: tool, environment: environment, onOutputLine: onOutputLine)
        guard output.status == 0 else {
            throw ConversionError.toolFailed(tool: tool, message: failureDetail(output))
        }
        return output
    }

    /// Runs to completion and returns whatever happened, whatever the exit status
    /// (`ffmpeg -i file` exits non-zero by design when only probing).
    static func capture(_ executable: URL, arguments: [String], environment: [String: String]? = nil) async throws -> Output {
        try await launch(executable, arguments: arguments, tool: executable.lastPathComponent,
                         environment: environment, onOutputLine: nil)
    }

    /// The last few meaningful stderr lines, which is where tools put the actual reason.
    static func failureDetail(_ output: Output) -> String {
        let lines = output.standardError.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let detail = lines.suffix(3).joined(separator: " ")
        return detail.isEmpty ? "exit code \(output.status)" : String(detail.suffix(400))
    }

    // MARK: -

    private static func launch(
        _ executable: URL,
        arguments: [String],
        tool: String,
        environment: [String: String]?,
        onOutputLine: (@Sendable (String) -> Void)?
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes continuously so a chatty tool can't fill them and stall.
        let outCollector = LineCollector(onLine: onOutputLine)
        let errCollector = LineCollector(onLine: nil)
        outPipe.fileHandleForReading.readabilityHandler = { outCollector.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errCollector.append($0.availableData) }
        let cancelled = CancelFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, Error>) in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outCollector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    errCollector.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    outCollector.finish()
                    if cancelled.isSet {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: Output(
                            status: finished.terminationStatus,
                            standardOutput: outCollector.text,
                            standardError: errCollector.text))
                    }
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ConversionError.toolFailed(tool: tool, message: error.localizedDescription))
                }
            }
        } onCancel: {
            cancelled.set()
            if process.isRunning { process.terminate() }
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Accumulates output, reports complete lines, and keeps the text (capped) for later.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var pending = Data()
        private let onLine: (@Sendable (String) -> Void)?

        init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            var lines: [String] = []
            lock.lock()
            if storage.count < 4_000_000 { storage.append(data) }
            if onLine != nil {
                pending.append(data)
                while let newline = pending.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                    pending = Data(pending[pending.index(after: newline)...])
                }
            }
            lock.unlock()
            lines.forEach { onLine?($0) }
        }

        func finish() {
            lock.lock()
            let rest = pending
            pending = Data()
            lock.unlock()
            if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
        }

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: storage, as: UTF8.self)
        }
    }
}
