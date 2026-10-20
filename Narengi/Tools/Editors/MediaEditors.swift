import SwiftUI

// MARK: - Trim Video

struct TrimVideoPanel: View {
    @ObservedObject var model: TrimModel
    @ObservedObject var frames: VideoFrameSource
    let onSave: (Double, Double) -> Void
    let onCancel: () -> Void
    @State private var startText = "0:00.0"
    @State private var endText = ""

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.3)
                if let image = frames.image { Image(nsImage: image).resizable().scaledToFit().padding(16) } else { ProgressView() }
            }
            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 12) {
                TimelineBar(duration: model.duration, ranges: [model.start...model.end], tint: Theme.accent)
                    .frame(height: 22)
                HStack(spacing: 16) {
                    timeField("Start", text: $startText) { if let v = TimeFormat.seconds(from: startText) { model.setStart(v) }; sync() }
                    timeField("End", text: $endText) { if let v = TimeFormat.seconds(from: endText) { model.setEnd(v) }; sync() }
                    Spacer()
                    Text(model.summary).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 14) {
                    Slider(value: Binding(get: { model.start }, set: { model.setStart($0); sync() }), in: 0...model.duration)
                    Slider(value: Binding(get: { model.end }, set: { model.setEnd($0); sync() }), in: 0...model.duration)
                }
            }
            .padding(16)
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Text("The cut is re-encoded, so it starts exactly where you choose.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(GreyButtonStyle())
                Button("Trim") { onSave(model.start, model.end) }.buttonStyle(OrangeButtonStyle())
                    .disabled(model.isFullRange).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .onAppear { sync() }
        .onChange(of: model.previewTime) { _, time in frames.show(at: time) }
    }

    private func sync() {
        startText = TimeFormat.string(model.start)
        endText = TimeFormat.string(model.end)
    }

    private func timeField(_ title: String, text: Binding<String>, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            TextField(title, text: text).textFieldStyle(.roundedBorder).frame(width: 86).onSubmit(commit)
        }
    }
}

/// A thin bar showing which stretches of the media are selected.
struct TimelineBar: View {
    let duration: Double
    let ranges: [ClosedRange<Double>]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(.white.opacity(0.10)))
            for range in ranges {
                let x0 = size.width * range.lowerBound / max(duration, 0.001), x1 = size.width * range.upperBound / max(duration, 0.001)
                context.fill(Path(roundedRect: CGRect(x: x0, y: 0, width: max(x1 - x0, 3), height: size.height), cornerRadius: 6), with: .color(tint))
            }
        }
    }
}

// MARK: - Redact Video

struct RedactVideoPanel: View {
    @ObservedObject var model: VideoRedactModel
    @ObservedObject var frames: VideoFrameSource
    let onSave: (VideoRedactModel) -> Void
    let onCancel: () -> Void

    var body: some View {
        MarkupEditor(
            model: model.markup, pageImage: { _ in frames.image },
            onSave: { _ in onSave(model) }, onCancel: onCancel,
            accessory: AnyView(RedactTimeControls(model: model)),
            saveTitle: "Save Redacted",
            note: "Covered areas are re-encoded into the video, and metadata is removed.")
            .onChange(of: model.previewTime) { _, time in frames.show(at: time) }
    }
}

private struct RedactTimeControls: View {
    @ObservedObject var model: VideoRedactModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Preview").font(.system(size: 13)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.previewTime }, set: { model.setPreview($0) }), in: 0...model.duration)
                Text(TimeFormat.string(model.previewTime)).font(.system(size: 13)).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Toggle("Only between", isOn: $model.limitToRange).toggleStyle(.checkbox)
                Slider(value: Binding(get: { model.start }, set: { model.setStart($0) }), in: 0...model.duration).disabled(!model.limitToRange)
                Slider(value: Binding(get: { model.end }, set: { model.setEnd($0) }), in: 0...model.duration).disabled(!model.limitToRange)
                Text("\(TimeFormat.string(model.start)) – \(TimeFormat.string(model.end))").font(.system(size: 13)).monospacedDigit()
                    .foregroundStyle(model.limitToRange ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

// MARK: - Bleep Audio

struct BleepAudioPanel: View {
    @ObservedObject var model: BleepModel
    let fileName: String
    let onSave: ([BleepInterval]) -> Void
    let onCancel: () -> Void
    @State private var startText = ""
    @State private var endText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fileName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("Length \(TimeFormat.string(model.duration))").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            WaveformView(peaks: model.peaks, duration: model.duration, intervals: model.intervals, selection: $model.selection, isLoading: model.isLoading)
                .frame(height: 150).padding(.horizontal, 20)

            HStack(spacing: 10) {
                Text("From").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("0:00.0", text: $startText).textFieldStyle(.roundedBorder).frame(width: 82)
                Text("to").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("0:01.0", text: $endText).textFieldStyle(.roundedBorder).frame(width: 82)
                Button("Add") { addTyped() }.buttonStyle(GreyButtonStyle())
                    .disabled(TimeFormat.seconds(from: startText) == nil || TimeFormat.seconds(from: endText) == nil)
                Spacer()
                if model.selection != nil { Button("Bleep Selection") { model.addSelection() }.buttonStyle(GreyButtonStyle()) }
            }
            .padding(.horizontal, 20).padding(.top, 12)

            List {
                ForEach(model.intervals) { interval in
                    HStack {
                        Image(systemName: "speaker.slash.fill").foregroundStyle(Theme.accent)
                        Text("\(TimeFormat.string(interval.start)) → \(TimeFormat.string(interval.end))").monospacedDigit()
                        Spacer()
                        Text(String(format: "%.1f s", interval.length)).foregroundStyle(.secondary)
                        Button { model.remove(interval.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
            }
            .scrollContentBackground(.hidden).listStyle(.plain).padding(.horizontal, 12)

            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Text(model.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(GreyButtonStyle())
                Button("Bleep") { onSave(model.intervals) }.buttonStyle(OrangeButtonStyle())
                    .disabled(model.intervals.isEmpty).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }

    private func addTyped() {
        guard let start = TimeFormat.seconds(from: startText), let end = TimeFormat.seconds(from: endText) else { return }
        if model.add(start: start, end: end) { startText = ""; endText = "" }
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let duration: Double
    let intervals: [BleepInterval]
    @Binding var selection: ClosedRange<Double>?
    let isLoading: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06))
                Canvas { context, size in
                    for interval in intervals {
                        let x0 = size.width * interval.start / duration, x1 = size.width * interval.end / duration
                        context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 2), height: size.height)), with: .color(Theme.accent.opacity(0.30)))
                    }
                    if let selection {
                        let x0 = size.width * selection.lowerBound / duration, x1 = size.width * selection.upperBound / duration
                        context.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 2), height: size.height)), with: .color(.white.opacity(0.18)))
                    }
                    guard !peaks.isEmpty else { return }
                    let barWidth = size.width / CGFloat(peaks.count)
                    for (i, peak) in peaks.enumerated() {
                        let h = max(2, CGFloat(peak) * (size.height - 8))
                        let rect = CGRect(x: CGFloat(i) * barWidth + 0.5, y: (size.height - h) / 2, width: max(barWidth - 1, 1), height: h)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.white.opacity(0.75)))
                    }
                }
                if isLoading { ProgressView() }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let a = time(at: value.startLocation.x, width: proxy.size.width), b = time(at: value.location.x, width: proxy.size.width)
                        selection = min(a, b)...max(a, b)
                    })
        }
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double { min(max(Double(x / max(width, 1)) * duration, 0), duration) }
}
