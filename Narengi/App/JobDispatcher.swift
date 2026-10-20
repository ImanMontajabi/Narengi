import Foundation

/// Opens the window for tools that need one (Compress, Metadata, Read QR, Organize, the editors).
@MainActor
protocol ToolPanelPresenting: AnyObject {
    func present(_ tool: ToolID, files: [URL], formats: [String], policy: OutputPolicy)
}

/// Turns a chosen petal and its files into queued jobs or windows: one job per file for conversions and
/// single-file tools, one job for tools that combine files, a window for tools that need one.
@MainActor
struct JobDispatcher {
    let queue: JobQueue
    let settings: SettingsStore
    /// Runs the Actions wheel; without it (tests) actions only queue a placeholder job.
    var actions: ActionRunner?
    /// Shows tool windows; without it (tests) every tool runs with its quick defaults.
    var panels: ToolPanelPresenting?
    var availability: Availability = .shared

    @discardableResult
    func handle(_ item: WheelItem, files: [URL], policy: OutputPolicy) -> [Job] {
        switch item.action {
        case .convert(let target):
            return files.compactMap { url in
                guard let source = FormatCatalog.detect(url), source != target else { return nil }
                let options = ConversionOptions.make(source: source, target: target, settings: settings)
                return queue.enqueue(
                    title: "\(url.lastPathComponent) → \(target)",
                    sourceName: url.lastPathComponent,
                    work: ConversionService.work(source: url, options: options, policy: policy, availability: availability))
            }
        case .tool(let tool):
            return handle(tool, files: files, policy: policy)
        case .action(let action) where actions != nil:
            actions?.perform(action, on: files)
            return []
        case .action(let action):
            return [queue.enqueue(title: action.name, work: ConversionService.notImplemented(action.name))]
        }
    }

    @discardableResult
    func handle(_ tool: ToolID, files: [URL], policy: OutputPolicy) -> [Job] {
        let known = files.compactMap { url in FormatCatalog.detect(url).map { (url, $0) } }
        guard !known.isEmpty else { return [] }
        let urls = known.map(\.0), formats = known.map(\.1)

        if tool.opensPanel(forCount: urls.count), let panels {
            panels.present(tool, files: urls, formats: formats, policy: policy)
            return []
        }
        if tool.combinesInputs {
            return [queue.enqueue(
                title: tool.info.name, sourceName: "\(urls.count) files",
                work: ToolService.work(.plain(tool), sources: urls, formats: formats, policy: policy, availability: availability))]
        }
        return known.map { url, format in
            var options = ToolOptions()
            options.compression = CompressionSpec.fromSettings(format: format, settings: settings)
            return queue.enqueue(
                title: tool.info.name, sourceName: url.lastPathComponent,
                work: ToolService.work(.plain(tool, options), sources: [url], formats: [format], policy: policy, availability: availability))
        }
    }

    /// Queues a tool that a window has configured.
    @discardableResult
    func run(_ operation: ToolOperation, files: [URL], formats: [String], policy: OutputPolicy) -> Job {
        queue.enqueue(
            title: operation.tool.info.name,
            sourceName: files.count == 1 ? files[0].lastPathComponent : "\(files.count) files",
            work: ToolService.work(operation, sources: files, formats: formats, policy: policy, availability: availability))
    }
}
