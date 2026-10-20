import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: SettingsStore
    let onSampleDragStart: ([URL]) -> Void
    let onOpenSettings: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(current: model.step, onSelect: { model.go(to: $0) })
                .padding(.top, 14)
            Group {
                switch model.step {
                case .how: HowItWorks(settings: settings)
                case .practice: Practice(model: model, settings: settings, onSampleDragStart: onSampleDragStart)
                case .setup: QuickSetup(settings: settings)
                case .done: AllSet(settings: settings, onOpenSettings: onOpenSettings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Button("Back") { withAnimation(.easeOut(duration: 0.15)) { model.back() } }
                    .buttonStyle(GreyButtonStyle()).opacity(model.isFirst ? 0 : 1).disabled(model.isFirst)
                Spacer()
                if model.isLast {
                    Button("Start Using Narengi", action: onFinish).buttonStyle(OrangeButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    if model.step == .practice {
                        Button("Skip") { withAnimation(.easeOut(duration: 0.15)) { model.next() } }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 8)
                    }
                    Button("Next") { withAnimation(.easeOut(duration: 0.15)) { model.next() } }
                        .buttonStyle(OrangeButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }
}

private struct ProgressDots: View {
    let current: OnboardingStep
    let onSelect: (OnboardingStep) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Button { onSelect(step) } label: {
                    Capsule().fill(step == current ? Theme.accent : Color.white.opacity(0.18)).frame(width: step == current ? 26 : 8, height: 8)
                }
                .buttonStyle(.plain).help(step.title)
            }
        }
        .animation(.easeOut(duration: 0.15), value: current)
    }
}

// MARK: - Steps

private struct WheelCard: View {
    let keyName: String
    let title: String
    let symbol: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Theme.accent)
                Spacer()
                Text(keyName).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 160, maxHeight: 210, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

private struct HowItWorks: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Drag a file. Tap a key. Pick a slice.").font(.system(size: 24, weight: .bold))
                Text("Start dragging any file in Finder, tap a modifier key, and a wheel opens under your pointer.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 14)
            HStack(spacing: 14) {
                WheelCard(keyName: settings.conversionModifier.title, title: "Convert", symbol: "arrow.triangle.2.circlepath",
                          text: "Turn it into any compatible format: images, documents, audio, video, spreadsheets and more.")
                WheelCard(keyName: settings.toolsModifier.title, title: "Tools", symbol: "slider.horizontal.3",
                          text: "Compress, crop, trim, redact, merge, split, read QR codes and edit photos.")
                WheelCard(keyName: settings.actionsModifier.title, title: "Actions", symbol: "bolt.fill",
                          text: "AirDrop, Float shelf, Copy, Move, Copy Path and Open in Terminal.")
            }
            Text("Drop on a slice and the result appears right beside the original. Your files are never overwritten.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }
}

private struct Practice: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: SettingsStore
    let onSampleDragStart: ([URL]) -> Void

    var body: some View {
        HStack(spacing: 28) {
            VStack(spacing: 10) {
                if let url = model.sampleURL {
                    SampleCardView(url: url, onDragStart: onSampleDragStart).frame(width: 230, height: 190)
                } else {
                    Text("The practice file couldn't be created.").foregroundStyle(.secondary)
                }
                Text("Drag this card out of the window").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Try it now").font(.system(size: 22, weight: .bold))
                Text("Press and hold the card, then tap a modifier key without letting go. Move onto a slice and release.")
                    .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    check(.conversion, "Tap \(settings.conversionModifier.shortName) for the Convert wheel")
                    check(.tools, "Tap \(settings.toolsModifier.shortName) for the Tools wheel")
                    check(.actions, "Tap \(settings.actionsModifier.shortName) for the Actions wheel")
                }
                if model.allWheelsTried {
                    Label("Nice. You've seen every wheel.", systemImage: "party.popper.fill").foregroundStyle(Theme.accent).font(.system(size: 14, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 30)
    }

    private func check(_ kind: WheelKind, _ text: String) -> some View {
        let done = model.wheelsSeen.contains(kind)
        return HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.accent : .secondary)
            Text(text).font(.system(size: 14))
        }
    }
}

private struct QuickSetup: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick setup").font(.system(size: 22, weight: .bold)).padding(.top, 14)
            VStack(spacing: 0) {
                row { Toggle("Launch at login", isOn: $settings.launchAtLogin) }
                Divider().overlay(Color.white.opacity(0.08))
                row { Toggle("Sound and haptic feedback", isOn: $settings.feedbackEnabled) }
                Divider().overlay(Color.white.opacity(0.08))
                row { picker("Convert wheel", $settings.conversionModifier) }
                row { picker("Tools wheel", $settings.toolsModifier) }
                row { picker("Actions wheel", $settings.actionsModifier) }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
            if let conflict = settings.modifierConflict {
                Label(conflict, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            } else {
                Text("You can change all of this later in Settings.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func picker(_ title: String, _ selection: Binding<ModifierChoice>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) { ForEach(ModifierChoice.allCases) { Text($0.title).tag($0) } }
                .labelsHidden().frame(width: 190)
        }
    }
}

private struct AllSet: View {
    @ObservedObject var settings: SettingsStore
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(Theme.accent).padding(.top, 20)
            Text("You're all set").font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                line("menubar.rectangle", "Narengi lives in your menu bar. Use Convert Files… there to pick files without dragging.")
                line("hand.draw", "Drag any file and tap \(settings.conversionModifier.shortName), \(settings.toolsModifier.shortName) or \(settings.actionsModifier.shortName).")
                line("questionmark.circle", "Reopen this guide any time from the menu bar or from Settings → About.")
            }
            .frame(maxWidth: 440)
            Button("Open Settings…", action: onOpenSettings).buttonStyle(GreyButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
