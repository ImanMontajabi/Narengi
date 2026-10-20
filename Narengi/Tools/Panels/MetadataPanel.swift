import SwiftUI

/// State of the Metadata window: what was read, what the user removed or edited.
@MainActor
final class MetadataModel: ObservableObject {
    let fileName: String
    let format: String
    let canEdit: Bool
    @Published private(set) var groups: [MetadataGroup] = []
    @Published private(set) var isLoading = true
    @Published var search = ""
    @Published private(set) var removed: Set<String> = []
    @Published private(set) var edited: [String: String] = [:]
    @Published private(set) var loadError: String?

    init(fileName: String, format: String, canEdit: Bool) {
        self.fileName = fileName
        self.format = format
        self.canEdit = canEdit
    }

    func load(url: URL, engine: MetadataEngine) async {
        do { groups = try await engine.read(url, format: format) } catch { loadError = error.localizedDescription }
        isLoading = false
    }

    func setGroups(_ groups: [MetadataGroup]) {
        self.groups = groups
        isLoading = false
    }

    func remove(_ id: String) { removed.insert(id); edited[id] = nil }
    func restore(_ id: String) { removed.remove(id) }

    func setValue(_ value: String, for entry: MetadataEntry) {
        guard !removed.contains(entry.id) else { return }
        if value == entry.value { edited[entry.id] = nil } else { edited[entry.id] = value }
    }

    func value(for entry: MetadataEntry) -> String { edited[entry.id] ?? entry.value }

    /// Groups with only the rows matching the search box.
    var visibleGroups: [MetadataGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let entries = group.entries.filter { $0.label.lowercased().contains(query) || $0.value.lowercased().contains(query) }
            return entries.isEmpty ? nil : MetadataGroup(name: group.name, entries: entries)
        }
    }

    var hasChanges: Bool { !removed.isEmpty || !edited.isEmpty }

    /// Tag → new value (nil removes), for `MetadataEngine.save`.
    var changes: [String: String?] {
        var result: [String: String?] = [:]
        for id in removed { result[id] = .some(nil) }
        for (id, value) in edited { result[id] = .some(value) }
        return result
    }
}

struct MetadataPanel: View {
    @ObservedObject var model: MetadataModel
    let onRemoveAll: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.fileName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                TextField("Search metadata", text: $model.search)
                    .textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7).frame(width: 190)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let error = model.loadError {
                        Text(error).foregroundStyle(.secondary).padding(20)
                    } else if model.visibleGroups.isEmpty {
                        Text(model.groups.isEmpty ? "No metadata found" : "No matches")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    ForEach(model.visibleGroups) { group in
                        Text(group.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                        ForEach(group.entries) { entry in MetadataRow(model: model, entry: entry) }
                    }
                }
                .padding(.bottom, 12)
            }

            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 10) {
                Text("For photos, Remove All also clears hidden camera and processing data. HDR and portrait effects may change.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.canEdit {
                    Text("Editing individual values needs ExifTool; Remove All always works.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Remove All", action: onRemoveAll).buttonStyle(GreyButtonStyle())
                    Button("Save", action: onSave).buttonStyle(OrangeButtonStyle())
                        .disabled(!model.hasChanges || !model.canEdit).keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
    }
}

private struct MetadataRow: View {
    @ObservedObject var model: MetadataModel
    let entry: MetadataEntry

    var body: some View {
        let isRemoved = model.removed.contains(entry.id)
        HStack(alignment: .top, spacing: 12) {
            Text(entry.label + ":").font(.system(size: 14)).multilineTextAlignment(.trailing)
                .frame(width: 130, alignment: .trailing).padding(.top, 8)
            Group {
                if entry.isEditable, model.canEdit, !isRemoved {
                    TextField("", text: Binding(get: { model.value(for: entry) }, set: { model.setValue($0, for: entry) }), axis: .vertical)
                        .textFieldStyle(.plain).padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                } else {
                    Text(entry.value).padding(.vertical, 8).strikethrough(isRemoved)
                }
            }
            .font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).opacity(isRemoved ? 0.4 : 1)
            Button {
                if isRemoved { model.restore(entry.id) } else { model.remove(entry.id) }
            } label: {
                Image(systemName: isRemoved ? "arrow.uturn.backward.circle" : "minus.circle").font(.system(size: 17))
            }
            .buttonStyle(.plain).padding(.top, 8).disabled(!model.canEdit)
            .help(isRemoved ? "Keep this value" : "Remove this value")
        }
        .padding(.horizontal, 20)
    }
}
