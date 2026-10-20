import SwiftUI

/// What the Compress window edits: a mode and, for "Percentage", how much to cut.
@MainActor
final class CompressModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case percentage = "Percentage", balanced = "Balanced", strong = "Strong"
        var id: String { rawValue }
    }

    let fileName: String
    let originalBytes: Int
    @Published var mode: Mode = .percentage
    @Published var reduceBy: Double = 50

    init(fileName: String, originalBytes: Int) {
        self.fileName = fileName
        self.originalBytes = originalBytes
    }

    /// The caption under the slider.
    var estimate: String {
        switch mode {
        case .percentage:
            let cap = Int(Double(originalBytes) * (1 - reduceBy / 100))
            return "Output will be at most \(ByteFormat.string(cap))."
        case .balanced: return "A good balance of size and quality."
        case .strong: return "The smallest result; quality drops more."
        }
    }

    var spec: CompressionSpec {
        switch mode {
        case .percentage: return CompressionSpec(mode: .percentage(reduceBy))
        case .balanced: return CompressionSpec(mode: .preset(strong: false))
        case .strong: return CompressionSpec(mode: .preset(strong: true))
        }
    }
}

struct CompressPanel: View {
    @ObservedObject var model: CompressModel
    let onCompress: (CompressionSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.fileName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Original size: \(ByteFormat.string(model.originalBytes))").font(.system(size: 17, weight: .semibold))
            }
            .padding(20)
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Text("Mode").foregroundStyle(.secondary)
                Spacer()
                Picker("Mode", selection: $model.mode) {
                    ForEach(CompressModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 8) {
                if model.mode == .percentage {
                    HStack(spacing: 12) {
                        Text("Reduce by").font(.system(size: 15, weight: .medium))
                        Slider(value: $model.reduceBy, in: 0...95, step: 1)
                        Text("\(Int(model.reduceBy))%").font(.system(size: 15, weight: .medium)).monospacedDigit().frame(width: 46, alignment: .trailing)
                    }
                }
                Text(model.estimate).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(20)
            Spacer(minLength: 0)
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Spacer()
                Button("Compress") { onCompress(model.spec) }
                    .buttonStyle(OrangeButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }
}
