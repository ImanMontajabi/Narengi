import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// State of the Organize PDF window: the page order, per-page turns and deletions.
@MainActor
final class OrganizeModel: ObservableObject {
    let pageCount: Int
    @Published private(set) var pages: [PDFPageEdit]
    @Published var sameWidth = false

    init(pageCount: Int) {
        self.pageCount = pageCount
        pages = (0..<pageCount).map { PDFPageEdit(index: $0) }
    }

    /// Moves the page at `from` so it ends up at `to` (positions in the current order).
    func move(from: Int, to: Int) {
        guard pages.indices.contains(from), pages.indices.contains(to), from != to else { return }
        pages.insert(pages.remove(at: from), at: to)
    }

    func rotate(at position: Int) {
        guard pages.indices.contains(position) else { return }
        pages[position].rotation = (pages[position].rotation + 90) % 360
    }

    func delete(at position: Int) {
        guard pages.indices.contains(position), pages.count > 1 else { return }
        pages.remove(at: position)
    }

    func reset() { pages = (0..<pageCount).map { PDFPageEdit(index: $0) } }

    var isUnchanged: Bool { pages == (0..<pageCount).map { PDFPageEdit(index: $0) } && !sameWidth }
}

struct OrganizePanel: View {
    @ObservedObject var model: OrganizeModel
    let document: PDFDocument
    let onSave: () -> Void
    @State private var thumbnails: [Int: NSImage] = [:]
    @State private var dragging: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.index) { position, edit in
                        PageTile(
                            number: position + 1, image: thumbnail(edit.index), rotation: edit.rotation,
                            onRotate: { model.rotate(at: position) },
                            onDelete: { model.delete(at: position) })
                            .onDrag {
                                dragging = position
                                return NSItemProvider(object: "\(position)" as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: PageDropDelegate(position: position, model: model, dragging: $dragging))
                    }
                }
                .padding(18)
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Button("Reset Order") { model.reset() }.buttonStyle(GreyButtonStyle()).disabled(model.isUnchanged)
                Toggle("Make all pages the same width", isOn: $model.sameWidth).toggleStyle(.checkbox)
                Spacer()
                Button("Save Organized PDF", action: onSave).buttonStyle(OrangeButtonStyle())
                    .disabled(model.isUnchanged).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
    }

    private func thumbnail(_ index: Int) -> NSImage? {
        if let cached = thumbnails[index] { return cached }
        guard let page = document.page(at: index) else { return nil }
        let image = page.thumbnail(of: NSSize(width: 200, height: 260), for: .cropBox)
        DispatchQueue.main.async { thumbnails[index] = image }
        return image
    }
}

private struct PageDropDelegate: DropDelegate {
    let position: Int
    let model: OrganizeModel
    @Binding var dragging: Int?

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != position else { return }
        withAnimation(.easeOut(duration: 0.15)) { model.move(from: from, to: position) }
        dragging = position
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

private struct PageTile: View {
    let number: Int
    let image: NSImage?
    let rotation: Int
    let onRotate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
            Group {
                if let image { Image(nsImage: image).resizable().scaledToFit().rotationEffect(.degrees(Double(rotation))) }
                else { ProgressView() }
            }
            .padding(8)
            Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(minWidth: 22, minHeight: 22).background(Circle().fill(Theme.accent)).padding(6)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Button(action: onRotate) { Image(systemName: "rotate.right") }.help("Rotate")
                        Button(action: onDelete) { Image(systemName: "trash") }.help("Delete page")
                    }
                    .buttonStyle(.plain).font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundStyle(.white)
                }
                .padding(6)
            }
        }
        .aspectRatio(0.77, contentMode: .fit)
    }
}
