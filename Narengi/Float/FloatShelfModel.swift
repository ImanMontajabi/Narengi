import Foundation

struct FloatItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// What a Float shelf holds: the files, which are selected, and the operations on them.
@MainActor
final class FloatShelfModel: ObservableObject {
    @Published private(set) var items: [FloatItem] = []
    @Published var selection: Set<UUID> = []

    /// Adds files that exist and aren't already on the shelf; returns how many were new.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let resolved = (url as NSURL).filePathURL ?? url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: resolved.path),
                  !items.contains(where: { $0.url.standardizedFileURL.path == resolved.path }) else { continue }
            items.append(FloatItem(url: resolved))
            added += 1
        }
        return added
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func removeSelected() { remove(selection) }

    func clear() {
        items = []
        selection = []
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    var selectedItems: [FloatItem] { items.filter { selection.contains($0.id) } }

    /// Items a drag starting on `id` carries: the whole selection if `id` is part of it, else just `id`.
    func dragItems(startingOn id: UUID) -> [FloatItem] {
        if selection.contains(id) { return selectedItems }
        return items.filter { $0.id == id }
    }

    /// Click selection: plain click selects one, ⌘ toggles, ⇧ extends from the last-clicked item.
    func click(_ id: UUID, command: Bool, shift: Bool, anchor: inout UUID?) {
        if shift, let anchorID = anchor,
           let a = items.firstIndex(where: { $0.id == anchorID }), let b = items.firstIndex(where: { $0.id == id }) {
            selection = Set(items[min(a, b)...max(a, b)].map(\.id))
        } else if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            if !selection.contains(id) { selection = [id] }
            anchor = id
        }
    }

    /// Prunes items whose files have disappeared.
    func pruneMissing() {
        let gone = Set(items.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map(\.id))
        if !gone.isEmpty { remove(gone) }
    }
}
