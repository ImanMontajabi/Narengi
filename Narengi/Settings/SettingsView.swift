import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Text("General") }
            FormatsTab()
                .tabItem { Text("Formats") }
            CompatibilityTab()
                .tabItem { Text("Compatibility") }
            FoldersTab()
                .tabItem { Text("Folders") }
            AboutTab()
                .tabItem { Text("About") }
        }
        .tint(Theme.accent)
        .frame(minWidth: 520, idealWidth: 540, minHeight: 560, idealHeight: 640)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Style", selection: $store.style) {
                    ForEach(AppearanceStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            Section("General") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                Toggle("Sound and haptic feedback", isOn: $store.feedbackEnabled)
                Toggle("Reveal results in Finder when done", isOn: $store.revealInFinder)
            }

            Section("Drag Modifiers") {
                modifierPicker("Conversion wheel", selection: $store.conversionModifier)
                modifierPicker("Tools wheel", selection: $store.toolsModifier)
                modifierPicker("Actions wheel", selection: $store.actionsModifier)
                if let conflict = store.modifierConflict {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Tap the chosen modifier combination while dragging files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Float Behaviour", selection: $store.floatBehaviour) {
                    ForEach(FloatBehaviour.allCases) { Text($0.title).tag($0) }
                }
                Picker("Terminal app", selection: $store.terminalApp) {
                    ForEach(TerminalApp.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modifierPicker(_ title: String, selection: Binding<ModifierChoice>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierChoice.allCases) { Text($0.title).tag($0) }
        }
    }
}

// MARK: - Formats

private struct FormatsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var search = ""
    @State private var selection = "JPG"

    private var filtered: [(category: FormatCategory, formats: [String])] {
        FormatCatalog.categories.compactMap { category in
            let formats = category.formats.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
            return formats.isEmpty ? nil : (category, formats)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(selection: $selection) {
                    ForEach(filtered, id: \.category.id) { group in
                        Section(group.category.name) {
                            ForEach(group.formats, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)

            FormatDetail(format: selection)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct FormatDetail: View {
    let format: String
    @ObservedObject private var store = SettingsStore.shared

    private var options: Binding<FormatOptions> {
        Binding(get: { store.options(for: format) }, set: { store.setOptions($0, for: format) })
    }

    private var isImage: Bool { FormatCatalog.category(of: format)?.id == "images" }
    /// Formats whose pages/shapes are rendered to pixels when converting to an image.
    private var rasterizesWhenInput: Bool { format == "PDF" || format == "SVG" }

    private var summary: String {
        let outs = FormatCatalog.outputs(from: format)
        let isOutput = FormatCatalog.routes.values.contains { $0.contains(format) }
        let role = !outs.isEmpty && isOutput ? "Input and output format."
            : !outs.isEmpty ? "Input only." : "Output only."
        guard !outs.isEmpty else { return role }
        return "\(role) Converts to \(outs.joined(separator: ", "))."
    }

    var body: some View {
        Form {
            Section {
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Section("Conversion Settings") {
                Picker("Quality", selection: options.quality) {
                    ForEach(QualityLevel.allCases) { Text($0.title).tag($0) }
                }
                if isImage {
                    Toggle("Preserve metadata", isOn: options.preserveMetadata)
                }
                if rasterizesWhenInput {
                    Picker("Render resolution", selection: options.dpi) {
                        ForEach(FormatOptions.dpiChoices, id: \.self) { Text("\($0) DPI").tag($0) }
                    }
                }
                Button("Restore Defaults") { store.resetOptions(for: format) }
            }
            if isImage {
                Section("Image Compression") {
                    Picker("Compression", selection: options.compression) {
                        ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Image size", selection: options.imageSize) {
                        ForEach(ImageSizeOption.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("\(format) Settings")
        .overlay(alignment: .topLeading) {
            // Title row matching the reference layout.
            EmptyView()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Text("\(format) Settings")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Compatibility

private struct CompatibilityTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Format Compatibility", systemImage: "tablecells")
                    .font(.headline)
                ForEach(FormatCatalog.categories) { category in
                    CompatibilityCard(category: category)
                }
            }
            .padding(20)
        }
    }
}

private struct CompatibilityCard: View {
    let category: FormatCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(category.name, systemImage: category.symbol)
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Image(systemName: "arrow.turn.right.up")
                            .foregroundStyle(.secondary)
                            .frame(width: 64, height: 30)
                        ForEach(category.outputs, id: \.self) { output in
                            Text(output)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 52, height: 30)
                        }
                    }
                    ForEach(category.inputs, id: \.self) { input in
                        GridRow {
                            Text(input)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, height: 28)
                            ForEach(category.outputs, id: \.self) { output in
                                cell(input: input, output: output)
                            }
                        }
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
    }

    @ViewBuilder
    private func cell(input: String, output: String) -> some View {
        Group {
            if input == output {
                Text("–").foregroundStyle(.tertiary)
            } else if FormatCatalog.canConvert(input, to: output) {
                Image(systemName: "checkmark").foregroundStyle(.primary)
            } else {
                Text("–").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .frame(width: 52, height: 28)
    }
}

// MARK: - Folders

private struct FoldersTab: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        Form {
            Section("Output Location") {
                Picker("Save results", selection: $store.outputLocation) {
                    ForEach(OutputLocation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)

                if store.outputLocation == .customFolder {
                    HStack {
                        Text(store.customOutputFolder?.path ?? "No folder chosen")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Narengi isn't sandboxed, so it can write next to your files in any folder without asking for each one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { store.customOutputFolder = panel.url }
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.bottom, 6)
            Text("Narengi").font(.title.weight(.semibold))
            Text(version).foregroundStyle(.secondary)
            Text("Convert and tweak files right where you drag them.\nEverything runs on your Mac. No limits, no uploads.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Button("Welcome Guide…") { NotificationCenter.default.post(name: .narengiShowWelcome, object: nil) }
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
