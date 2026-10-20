import AppKit
import PDFKit
import SwiftUI

/// Opens the window each tool needs and queues the configured operation when the user confirms.
@MainActor
final class ToolPanels: ToolPanelPresenting {
    private let settings: SettingsStore
    private let dispatcher: JobDispatcher
    private let availability: Availability
    private var controllers: [ToolWindowController] = []

    init(queue: JobQueue, settings: SettingsStore, availability: Availability = .shared) {
        self.settings = settings
        self.availability = availability
        dispatcher = JobDispatcher(queue: queue, settings: settings, actions: nil, panels: nil, availability: availability)
    }

    var openWindowCount: Int { controllers.count }
    var windows: [NSWindow] { controllers.map(\.window) }

    func closeAll() { controllers.forEach { $0.close() } }

    func present(_ tool: ToolID, files: [URL], formats: [String], policy: OutputPolicy) {
        guard let url = files.first, let format = formats.first else { return }
        Log.job.notice("Opening \(tool.info.id, privacy: .public) window")
        switch tool {
        case .compress: presentCompress(url, format: format, files: files, formats: formats, policy: policy)
        case .removeMetadata: presentMetadata(url, format: format, files: files, formats: formats, policy: policy)
        case .readQR: presentQR(url, format: format)
        case .organizePDF: presentOrganize(url, files: files, formats: formats, policy: policy)
        default:
            if !presentEditor(tool, files: files, formats: formats, policy: policy) {
                dispatcher.queue.enqueue(title: tool.info.name, work: ConversionService.notImplemented(tool.info.name))
            }
        }
    }

    // MARK: - Helpers

    func open(_ controller: ToolWindowController) {
        controllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let controller else { return }
            self?.controllers.removeAll { $0 === controller }
        }
        controller.show()
    }

    func run(_ operation: ToolOperation, files: [URL], formats: [String], policy: OutputPolicy) {
        dispatcher.run(operation, files: files, formats: formats, policy: policy)
    }

    // MARK: - Windows

    private func presentCompress(_ url: URL, format: String, files: [URL], formats: [String], policy: OutputPolicy) {
        let model = CompressModel(fileName: url.lastPathComponent, originalBytes: ImageOps.fileSize(url))
        // The slider's Percentage mode needs a format that can hit a size; the others only have presets.
        let controller = ToolWindowController(title: "Compress", size: NSSize(width: 420, height: 400)) { controller in
            CompressPanel(model: model) { [weak self, weak controller] spec in
                var options = ToolOptions()
                options.compression = spec
                let settingsSpec = CompressionSpec.fromSettings(format: format, settings: self?.settings)
                options.compression.maxEdge = settingsSpec.maxEdge
                options.compression.scale = settingsSpec.scale
                self?.run(.compress(options.compression), files: [url], formats: [format], policy: policy)
                controller?.close()
            }
        }
        open(controller)
    }

    private func presentMetadata(_ url: URL, format: String, files: [URL], formats: [String], policy: OutputPolicy) {
        let engine = MetadataEngine(tools: availability.tools, media: availability.media)
        let model = MetadataModel(fileName: url.lastPathComponent, format: format, canEdit: engine.canEdit || format == "PDF")
        let controller = ToolWindowController(title: "Metadata", size: NSSize(width: 520, height: 660), resizable: true) { controller in
            MetadataPanel(
                model: model,
                onRemoveAll: { [weak self, weak controller] in
                    self?.run(.plain(.removeMetadata), files: [url], formats: [format], policy: policy)
                    controller?.close()
                },
                onSave: { [weak self, weak controller] in
                    self?.run(.metadata(model.changes), files: [url], formats: [format], policy: policy)
                    controller?.close()
                })
        }
        open(controller)
        Task { await model.load(url: url, engine: engine) }
    }

    @MainActor
    final class QRState: ObservableObject {
        @Published var results: [QRResult] = []
        @Published var error: String?
        @Published var isScanning = true
    }

    private func presentQR(_ url: URL, format: String) {
        let state = QRState()
        let controller = ToolWindowController(title: "QR Results", size: NSSize(width: 460, height: 380)) { _ in
            QRResultsHost(state: state, fileName: url.lastPathComponent)
        }
        open(controller)
        Task {
            do { state.results = try await QREngine.scanAsync(file: url, format: format) }
            catch { state.error = error.localizedDescription }
            state.isScanning = false
        }
    }

    private struct QRResultsHost: View {
        @ObservedObject var state: QRState
        let fileName: String
        var body: some View {
            QRResultsPanel(fileName: fileName, results: state.results, error: state.error, isScanning: state.isScanning)
        }
    }

    private func presentOrganize(_ url: URL, files: [URL], formats: [String], policy: OutputPolicy) {
        guard let document = try? PDFEngine.open(url) else {
            dispatcher.queue.enqueue(title: "Organize PDF", work: { _ in throw ConversionError.decodeFailed(url.lastPathComponent) })
            return
        }
        let model = OrganizeModel(pageCount: document.pageCount)
        let controller = ToolWindowController(title: "Organize PDF", size: NSSize(width: 700, height: 700), resizable: true) { controller in
            OrganizePanel(model: model, document: document) { [weak self, weak controller] in
                self?.run(.organize(model.pages, sameWidth: model.sameWidth), files: [url], formats: ["PDF"], policy: policy)
                controller?.close()
            }
        }
        open(controller)
    }

    // MARK: - Editors

    /// Opens the editor for `tool`; false if it has none.
    private func presentEditor(_ tool: ToolID, files: [URL], formats: [String], policy: OutputPolicy) -> Bool {
        guard let url = files.first, let format = formats.first else { return false }
        let size = NSSize(width: 920, height: 680)
        func fail(_ error: Error) {
            dispatcher.queue.enqueue(title: tool.info.name, sourceName: url.lastPathComponent, work: { _ in throw error })
        }
        switch tool {
        case .cropImage:
            guard let image = try? EditorImage.load(url) else { fail(ConversionError.decodeFailed(url.lastPathComponent)); return true }
            let model = CropModel(imageSize: image.fullSize, imageCount: files.count)
            open(ToolWindowController(title: "Crop", size: size, resizable: true) { controller in
                CropEditor(model: model, image: image, onCrop: { [weak self, weak controller] spec in
                    self?.run(.crop(spec), files: files, formats: formats, policy: policy)
                    controller?.close()
                }, onCancel: { [weak controller] in controller?.close() })
            })
        case .frameImage:
            guard let image = try? EditorImage.load(url) else { fail(ConversionError.decodeFailed(url.lastPathComponent)); return true }
            let model = FrameModel(image: image)
            open(ToolWindowController(title: "Add Background", size: size, resizable: true) { controller in
                FrameEditor(model: model, onSave: { [weak self, weak controller] spec in
                    self?.run(.frame(spec), files: [url], formats: [format], policy: policy)
                    controller?.close()
                }, onCancel: { [weak controller] in controller?.close() })
            })
        case .editImage:
            guard let image = try? EditorImage.load(url, previewEdge: 1100) else { fail(ConversionError.decodeFailed(url.lastPathComponent)); return true }
            let model = AdjustModel(image: image)
            open(ToolWindowController(title: "Edit Photo", size: size, resizable: true) { controller in
                AdjustEditor(model: model, onSave: { [weak self, weak controller] adjustments in
                    self?.run(.adjust(adjustments), files: [url], formats: [format], policy: policy)
                    controller?.close()
                }, onCancel: { [weak controller] in controller?.close() })
            })
        case .annotateImage, .redactImage, .annotatePDF, .redactPDF:
            presentMarkup(tool, url: url, format: format, policy: policy)
        case .trimVideo, .cropVideo, .redactVideo, .redactAudio:
            presentMedia(tool, url: url, format: format, policy: policy)
        default:
            return false
        }
        return true
    }

    // MARK: - Video and audio editors

    private func presentMedia(_ tool: ToolID, url: URL, format: String, policy: OutputPolicy) {
        let engine = MediaEngine(env: availability.media)
        Task {
            let info = await engine.probe(url)
            guard let duration = info.duration, duration > 0 else {
                dispatcher.queue.enqueue(title: tool.info.name, sourceName: url.lastPathComponent, work: { _ in throw ConversionError.decodeFailed(url.lastPathComponent) })
                return
            }
            switch tool {
            case .trimVideo: openTrim(url, format: format, duration: duration, engine: engine, policy: policy)
            case .cropVideo: await openCropVideo(url, format: format, video: info.video, duration: duration, engine: engine, policy: policy)
            case .redactVideo: openRedactVideo(url, format: format, duration: duration, engine: engine, policy: policy)
            default: openBleep(url, format: format, duration: duration, engine: engine, policy: policy)
            }
        }
    }

    private func openTrim(_ url: URL, format: String, duration: Double, engine: MediaEngine, policy: OutputPolicy) {
        let model = TrimModel(duration: duration)
        let frames = VideoFrameSource(url: url, engine: engine)
        open(ToolWindowController(title: "Trim Video", size: NSSize(width: 760, height: 640), resizable: true) { controller in
            TrimVideoPanel(model: model, frames: frames, onSave: { [weak self, weak controller] start, end in
                self?.run(.trimVideo(start: start, end: end), files: [url], formats: [format], policy: policy)
                controller?.close()
            }, onCancel: { [weak controller] in controller?.close() })
        })
        frames.show(at: 0)
    }

    private func openCropVideo(
        _ url: URL, format: String, video: (width: Int, height: Int)?, duration: Double, engine: MediaEngine, policy: OutputPolicy
    ) async {
        guard let video, let frame = try? await engine.frame(of: url, at: duration / 2) else {
            dispatcher.queue.enqueue(title: "Crop Video", sourceName: url.lastPathComponent, work: { _ in throw ConversionError.decodeFailed(url.lastPathComponent) })
            return
        }
        let image = EditorImage(url: url, fullSize: CGSize(width: video.width, height: video.height), preview: frame)
        let model = CropModel(imageSize: image.fullSize, imageCount: 1)
        open(ToolWindowController(title: "Crop Video", size: NSSize(width: 920, height: 680), resizable: true) { controller in
            CropEditor(model: model, image: image, onCrop: { [weak self, weak controller] spec in
                self?.run(.cropVideo(spec), files: [url], formats: [format], policy: policy)
                controller?.close()
            }, onCancel: { [weak controller] in controller?.close() })
        })
    }

    private func openRedactVideo(_ url: URL, format: String, duration: Double, engine: MediaEngine, policy: OutputPolicy) {
        let model = VideoRedactModel(duration: duration)
        let frames = VideoFrameSource(url: url, engine: engine)
        open(ToolWindowController(title: "Redact Video", size: NSSize(width: 960, height: 760), resizable: true) { controller in
            RedactVideoPanel(model: model, frames: frames, onSave: { [weak self, weak controller] model in
                let range = model.range
                self?.run(.redactVideo(model.redactions, start: range.start, end: range.end), files: [url], formats: [format], policy: policy)
                controller?.close()
            }, onCancel: { [weak controller] in controller?.close() })
        })
        frames.show(at: duration / 2)
    }

    private func openBleep(_ url: URL, format: String, duration: Double, engine: MediaEngine, policy: OutputPolicy) {
        let model = BleepModel(duration: duration)
        open(ToolWindowController(title: "Bleep Audio", size: NSSize(width: 720, height: 600), resizable: true) { controller in
            BleepAudioPanel(model: model, fileName: url.lastPathComponent, onSave: { [weak self, weak controller] intervals in
                self?.run(.bleep(intervals), files: [url], formats: [format], policy: policy)
                controller?.close()
            }, onCancel: { [weak controller] in controller?.close() })
        })
        Task { model.setPeaks((try? await engine.waveform(of: url)) ?? []) }
    }

    private func presentMarkup(_ tool: ToolID, url: URL, format: String, policy: OutputPolicy) {
        let mode: MarkupModel.Mode = (tool == .redactImage || tool == .redactPDF) ? .redact : .annotate
        let document: PDFDocument? = format == "PDF" ? try? PDFEngine.open(url) : nil
        let photo = format == "PDF" ? nil : try? EditorImage.load(url)
        guard document != nil || photo != nil else {
            dispatcher.queue.enqueue(title: tool.info.name, work: { _ in throw ConversionError.decodeFailed(url.lastPathComponent) })
            return
        }
        let model = MarkupModel(mode: mode, pageCount: document?.pageCount ?? 1)
        let pages = PageImageCache(document: document, photo: photo)
        let title = tool.info.name
        open(ToolWindowController(title: title, size: NSSize(width: 940, height: 720), resizable: true) { controller in
            MarkupEditorHost(model: model, pages: pages, onSave: { [weak self, weak controller] items in
                self?.run(.markup(tool, items), files: [url], formats: [format], policy: policy)
                controller?.close()
            }, onCancel: { [weak controller] in controller?.close() })
        })
    }

    /// Page pictures for the markup window, rendered on demand.
    @MainActor
    final class PageImageCache: ObservableObject {
        private let document: PDFDocument?
        private let photo: EditorImage?
        private var cache: [Int: NSImage] = [:]

        init(document: PDFDocument?, photo: EditorImage?) {
            self.document = document
            self.photo = photo
        }

        func image(_ index: Int) -> NSImage? {
            if let cached = cache[index] { return cached }
            let image: NSImage?
            if let photo { image = photo.nsImage }
            else if let page = document?.page(at: index), let cg = try? PDFEngine.render(page, dpi: 110) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else { image = nil }
            cache[index] = image
            return image
        }
    }

    private struct MarkupEditorHost: View {
        @ObservedObject var model: MarkupModel
        let pages: PageImageCache
        let onSave: ([Int: [MarkupItem]]) -> Void
        let onCancel: () -> Void

        var body: some View {
            MarkupEditor(model: model, pageImage: { pages.image($0) }, onSave: onSave, onCancel: onCancel)
        }
    }
}
