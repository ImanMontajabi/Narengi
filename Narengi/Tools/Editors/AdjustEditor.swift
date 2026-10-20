import SwiftUI

@MainActor
final class AdjustModel: ObservableObject {
    let image: EditorImage
    @Published var adjustments = Adjustments() { didSet { render() } }
    @Published var showOriginal = false
    @Published private(set) var preview: CGImage

    init(image: EditorImage) {
        self.image = image
        preview = image.preview
    }

    private func render() {
        preview = (try? PhotoAdjuster.apply(adjustments, to: image.preview)) ?? image.preview
    }

    func reset() { adjustments = Adjustments() }
}

struct AdjustEditor: View {
    @ObservedObject var model: AdjustModel
    let onSave: (Adjustments) -> Void
    let onCancel: () -> Void

    var body: some View {
        HSplitView {
            ZStack {
                Color.black.opacity(0.25)
                Image(decorative: model.showOriginal ? model.image.preview : model.preview, scale: 1).resizable().scaledToFit().padding(24)
                VStack {
                    Spacer()
                    Text("Hold to compare").font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .onLongPressGesture(minimumDuration: .infinity, perform: {}, onPressingChanged: { model.showOriginal = $0 })
                        .padding(.bottom, 14)
                }
            }
            .frame(minWidth: 380)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(["Light", "Colour", "Detail", "Effects"], id: \.self) { group in
                            Text(group).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(Adjustments.Key.allCases.filter { $0.group == group }) { key in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(key.title)
                                        Spacer()
                                        Text("\(Int(model.adjustments[key]))").monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 13))
                                    Slider(value: Binding(get: { model.adjustments[key] }, set: { model.adjustments[key] = $0 }), in: key.range)
                                }
                            }
                        }
                    }
                    .padding(18)
                }
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    Button("Reset") { model.reset() }.buttonStyle(GreyButtonStyle()).disabled(model.adjustments.isIdentity)
                    Spacer()
                    Button("Cancel", action: onCancel).buttonStyle(GreyButtonStyle())
                    Button("Save") { onSave(model.adjustments) }.buttonStyle(OrangeButtonStyle())
                        .disabled(model.adjustments.isIdentity).keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            .frame(width: 290)
        }
    }
}
