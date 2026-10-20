import AppKit
import SwiftUI

@MainActor
final class FrameModel: ObservableObject {
    let image: EditorImage
    let limits: (padding: Double, corners: Double, shadow: Double)
    @Published var spec: FrameSpec
    @Published private(set) var preview: CGImage?
    private var backgroundPreview: CGImage?

    init(image: EditorImage) {
        self.image = image
        limits = FrameSpec.limits(for: image.fullSize)
        spec = FrameSpec.defaults(for: image.fullSize)
        render()
    }

    /// Full-resolution values mapped onto the preview picture.
    private var previewScale: Double { Double(image.preview.width) / max(Double(image.fullSize.width), 1) }

    func chooseBackgroundImage(_ url: URL) {
        guard let loaded = try? ImageEngine.decode(url, dpi: 72, flattenOnWhite: true).image else { return }
        backgroundPreview = try? ImageOps.resize(loaded, maxEdge: 1200)
        spec.background = .image(url)
        render()
    }

    func render() {
        var scaled = spec
        scaled.padding *= previewScale
        scaled.corners *= previewScale
        scaled.shadow *= previewScale
        preview = try? FrameRenderer.render(image.preview, spec: scaled, backgroundImage: backgroundPreview)
    }
}

struct FrameEditor: View {
    @ObservedObject var model: FrameModel
    let onSave: (FrameSpec) -> Void
    let onCancel: () -> Void

    var body: some View {
        HSplitView {
            ZStack {
                Color.black.opacity(0.25)
                if let preview = model.preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit().padding(24)
                }
            }
            .frame(minWidth: 360)
            VStack(alignment: .leading, spacing: 14) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Background").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        let swatches = swatchList()
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(stride(from: 0, to: swatches.count, by: 6)), id: \.self) { start in
                                HStack(spacing: 8) {
                                    ForEach(swatches[start..<min(start + 6, swatches.count)], id: \.id) { swatch in
                                        Swatch(selected: model.spec.background == swatch.background) {
                                            swatch.fill
                                        } action: { model.spec.background = swatch.background; model.render() }
                                            .help(swatch.name)
                                    }
                                }
                            }
                        }
                        Button("Use a Picture…") { chooseImage() }.buttonStyle(GreyButtonStyle())

                        slider("Padding", $model.spec.padding, model.limits.padding)
                        slider("Corners", $model.spec.corners, model.limits.corners)
                        slider("Shadow", $model.spec.shadow, model.limits.shadow)

                        Text("Canvas").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        Picker("Canvas", selection: Binding(
                            get: { FrameSpec.ratios.firstIndex { $0.ratio?.0 == model.spec.ratio?.0 && $0.ratio?.1 == model.spec.ratio?.1 } ?? 0 },
                            set: { model.spec.ratio = FrameSpec.ratios[$0].ratio; model.render() })) {
                            ForEach(FrameSpec.ratios.indices, id: \.self) { Text(FrameSpec.ratios[$0].name).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    .padding(18)
                }
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel).buttonStyle(GreyButtonStyle())
                    Button("Save") { onSave(model.spec) }.buttonStyle(OrangeButtonStyle()).keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            .frame(width: 300)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ maximum: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary) }.font(.system(size: 13))
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; model.render() }), in: 0...max(maximum, 1))
        }
    }

    private struct SwatchItem {
        let id: String
        let name: String
        let background: FrameBackground
        let fill: AnyView
    }

    private func swatchList() -> [SwatchItem] {
        let gradients = FrameSpec.gradients.indices.map { index -> SwatchItem in
            let preset = FrameSpec.gradients[index]
            return SwatchItem(id: "g\(index)", name: preset.name, background: .gradient(index), fill: AnyView(
                LinearGradient(colors: preset.stops.map { Color(red: $0.r, green: $0.g, blue: $0.b) }, startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        let solids = FrameSpec.solids.map { solid in
            SwatchItem(id: "s\(solid.name)", name: solid.name, background: .solid(solid.color), fill: AnyView(Color(red: solid.color.r, green: solid.color.g, blue: solid.color.b)))
        }
        return gradients + solids
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.chooseBackgroundImage(url) }
    }
}

private struct Swatch<Fill: View>: View {
    let selected: Bool
    @ViewBuilder var fill: Fill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            fill.frame(width: 34, height: 34).clipShape(Circle())
                .overlay(Circle().strokeBorder(selected ? Color.white : Color.white.opacity(0.15), lineWidth: selected ? 2.5 : 1))
        }
        .buttonStyle(.plain)
    }
}
