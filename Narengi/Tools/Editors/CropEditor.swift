import SwiftUI

struct CropEditor: View {
    @ObservedObject var model: CropModel
    let image: EditorImage
    let onCrop: (CropSpec) -> Void
    let onCancel: () -> Void
    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let fit = fittedRect(image: model.imageSize, in: CGSize(width: proxy.size.width - 40, height: proxy.size.height - 40))
                let scale = fit.width / max(model.imageSize.width, 1)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image.preview, scale: 1).resizable().frame(width: fit.width, height: fit.height)
                    CropOverlay(rect: model.rect, imageSize: model.imageSize, scale: scale).frame(width: fit.width, height: fit.height)
                }
                .frame(width: fit.width, height: fit.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if value.translation == .zero {
                                model.beginDrag(at: CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale), tolerance: 18 / scale)
                            }
                            model.drag(dx: value.translation.width / scale, dy: value.translation.height / scale)
                            syncFields()
                        }
                        .onEnded { _ in model.endDrag() })
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 14) {
                Picker("Aspect", selection: Binding(get: { model.aspectIndex }, set: { model.selectAspect($0); syncFields() })) {
                    ForEach(CropGeometry.aspects.indices, id: \.self) { Text(CropGeometry.aspects[$0].name).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                TextField("W", text: $widthText).frame(width: 62).onSubmit { model.setSize(width: Double(widthText), height: nil); syncFields() }
                Text("×").foregroundStyle(.secondary)
                TextField("H", text: $heightText).frame(width: 62).onSubmit { model.setSize(width: nil, height: Double(heightText)); syncFields() }
                Button("Cancel", action: onCancel).buttonStyle(GreyButtonStyle())
                Button(model.imageCount > 1 ? "Crop \(model.imageCount) Images" : "Crop") { onCrop(model.spec) }
                    .buttonStyle(OrangeButtonStyle()).disabled(model.isFullImage).keyboardShortcut(.defaultAction)
            }
            .textFieldStyle(.roundedBorder)
            .padding(14)
        }
        .onAppear(perform: syncFields)
    }

    private func syncFields() {
        widthText = String(Int(model.rect.width.rounded()))
        heightText = String(Int(model.rect.height.rounded()))
    }
}

private struct CropOverlay: View {
    let rect: CGRect
    let imageSize: CGSize
    let scale: Double

    var body: some View {
        Canvas { context, size in
            let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            var dim = Path(CGRect(origin: .zero, size: size))
            dim.addRect(r)
            context.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            context.stroke(Path(r), with: .color(.white), lineWidth: 1.5)
            for i in 1...2 {  // rule-of-thirds guides
                var guide = Path()
                let x = r.minX + r.width * Double(i) / 3, y = r.minY + r.height * Double(i) / 3
                guide.move(to: CGPoint(x: x, y: r.minY)); guide.addLine(to: CGPoint(x: x, y: r.maxY))
                guide.move(to: CGPoint(x: r.minX, y: y)); guide.addLine(to: CGPoint(x: r.maxX, y: y))
                context.stroke(guide, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
            }
            for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                      CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)] {
                let dot = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                context.fill(Path(roundedRect: dot, cornerRadius: 2), with: .color(.white))
                context.stroke(Path(roundedRect: dot, cornerRadius: 2), with: .color(.black.opacity(0.4)), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}
