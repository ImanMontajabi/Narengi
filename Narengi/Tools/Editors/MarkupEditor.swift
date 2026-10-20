import SwiftUI

/// Annotate and Redact for photos and PDFs: draw on a page, move between pages, save.
struct MarkupEditor: View {
    @ObservedObject var model: MarkupModel
    /// The page picture to draw on (nil while loading).
    let pageImage: (Int) -> NSImage?
    let onSave: ([Int: [MarkupItem]]) -> Void
    let onCancel: () -> Void
    /// Extra controls above the footer (Redact Video's time range).
    var accessory: AnyView?
    var saveTitle: String?
    var note: String?
    @State private var typed = ""

    private static let colors: [RGB] = [RGB(255, 59, 48), RGB(255, 149, 0), RGB(255, 204, 0), RGB(52, 199, 89), RGB(10, 132, 255), RGB(0, 0, 0), RGB(255, 255, 255)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color.white.opacity(0.08))
            GeometryReader { proxy in
                if let image = pageImage(model.currentPage) {
                    let fit = fittedRect(image: image.size, in: CGSize(width: proxy.size.width - 32, height: proxy.size.height - 32))
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: image).resizable().frame(width: fit.width, height: fit.height)
                        MarkupCanvas(items: model.items, draft: model.draft).frame(width: fit.width, height: fit.height)
                        if let anchor = model.pendingText {
                            TextField("Type text", text: $typed).textFieldStyle(.roundedBorder).frame(width: 200)
                                .offset(x: anchor.x * fit.width, y: anchor.y * fit.height)
                                .onSubmit { model.addText(typed); typed = "" }
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let point = CGPoint(x: value.location.x / fit.width, y: value.location.y / fit.height)
                                if value.translation == .zero { model.begin(at: CGPoint(x: value.startLocation.x / fit.width, y: value.startLocation.y / fit.height)) }
                                model.update(to: point)
                            }
                            .onEnded { _ in model.end() })
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let accessory {
                Divider().overlay(Color.white.opacity(0.08))
                accessory
            }
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(model.tools, id: \.self) { kind in
                Button { model.kind = kind } label: {
                    Image(systemName: Self.symbol(kind)).frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.kind == kind ? Theme.accent : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain).help(Self.title(kind))
            }
            if model.mode == .annotate {
                Divider().frame(height: 18)
                ForEach(Array(Self.colors.enumerated()), id: \.offset) { _, color in
                    Button { model.color = color } label: {
                        Circle().fill(Color(red: color.r, green: color.g, blue: color.b)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(model.color == color ? Color.white : Color.white.opacity(0.25), lineWidth: model.color == color ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                }
                Slider(value: $model.width, in: 0.003...0.03).frame(width: 90).help("Line width")
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(.plain)
                .disabled(model.items.isEmpty).keyboardShortcut("z", modifiers: .command).help("Undo")
            Button("Clear Page") { model.clearPage() }.buttonStyle(GreyButtonStyle()).disabled(model.items.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.pageCount > 1 {
                Button { model.currentPage = max(model.currentPage - 1, 0) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(model.currentPage == 0)
                Text("Page \(model.currentPage + 1) of \(model.pageCount)").font(.system(size: 13)).monospacedDigit()
                Button { model.currentPage = min(model.currentPage + 1, model.pageCount - 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).disabled(model.currentPage == model.pageCount - 1)
            }
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if model.mode == .redact {
                Text(model.pageCount > 1 && model.redactedPageCount > 0
                     ? "Redacted pages are flattened to pictures, so their text can't be recovered."
                     : "Covered areas are burned into the saved file and can't be recovered.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onCancel).buttonStyle(GreyButtonStyle())
            Button(saveTitle ?? (model.mode == .redact ? "Save Redacted" : "Save")) { onSave(model.itemsByPage) }
                .buttonStyle(OrangeButtonStyle()).disabled(!model.hasItems).keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    static func symbol(_ kind: MarkupItem.Kind) -> String {
        switch kind {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .blackout: return "rectangle.fill"
        case .blur: return "drop.halffull"
        case .pixelate: return "squareshape.split.3x3"
        }
    }

    static func title(_ kind: MarkupItem.Kind) -> String {
        switch kind {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .pen: return "Pen"
        case .text: return "Text"
        case .blackout: return "Blackout"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        }
    }
}

/// Draws the marks over the page picture, in view coordinates.
struct MarkupCanvas: View {
    let items: [MarkupItem]
    let draft: MarkupItem?

    var body: some View {
        Canvas { context, size in
            let short = min(size.width, size.height)
            func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
            for item in items + (draft.map { [$0] } ?? []) {
                let color = Color(red: item.color.r, green: item.color.g, blue: item.color.b)
                let style = StrokeStyle(lineWidth: max(1, item.width * short), lineCap: .round, lineJoin: .round)
                switch item.kind {
                case .rectangle, .ellipse:
                    let b = item.box
                    let r = CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height)
                    context.stroke(item.kind == .rectangle ? Path(r) : Path(ellipseIn: r), with: .color(color), style: style)
                case .arrow:
                    guard item.points.count >= 2 else { continue }
                    let tail = point(item.points[0]), head = point(item.points[1])
                    let angle = atan2(head.y - tail.y, head.x - tail.x)
                    let length = max(12, item.width * short * 5)
                    var path = Path()
                    path.move(to: tail); path.addLine(to: head)
                    for side in [-1.0, 1.0] {
                        path.move(to: head)
                        path.addLine(to: CGPoint(x: head.x - length * cos(angle + side * .pi / 7), y: head.y - length * sin(angle + side * .pi / 7)))
                    }
                    context.stroke(path, with: .color(color), style: style)
                case .pen:
                    var path = Path()
                    for (i, p) in item.points.enumerated() { i == 0 ? path.move(to: point(p)) : path.addLine(to: point(p)) }
                    context.stroke(path, with: .color(color), style: style)
                case .text:
                    guard let anchor = item.points.first else { continue }
                    context.draw(Text(item.text).font(.system(size: max(8, item.fontSize * short), weight: .bold)).foregroundColor(color),
                                 at: point(anchor), anchor: .topLeading)
                case .blackout, .blur, .pixelate:
                    let b = item.box
                    let r = CGRect(x: b.minX * size.width, y: b.minY * size.height, width: b.width * size.width, height: b.height * size.height)
                    context.fill(Path(r), with: .color(item.kind == .blackout ? .black : Color.black.opacity(0.55)))
                    if item.kind != .blackout {
                        context.stroke(Path(r), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
