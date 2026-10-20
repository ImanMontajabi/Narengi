import SwiftUI

struct ProgressHUDView: View {
    @ObservedObject var queue: JobQueue
    @ObservedObject var settings: SettingsStore
    let visibleJobs: [Job]
    let hiddenCount: Int
    let onDismissAll: () -> Void

    private var header: String {
        let active = queue.jobs.filter { !$0.state.isTerminal }.count
        if active > 0 { return active == 1 ? "Working…" : "Working on \(active) files…" }
        if queue.jobs.contains(where: { if case .failed = $0.state { return true } else { return false } }) {
            return "Finished with errors"
        }
        return "Done"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(header).font(.system(size: 12, weight: .semibold))
                Spacer()
                if queue.jobs.contains(where: { !$0.state.isTerminal }) {
                    Button("Cancel All") { queue.cancelAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: onDismissAll) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: ProgressHUDMetrics.headerHeight)

            Divider().opacity(0.4)

            ForEach(visibleJobs) { job in
                JobRow(job: job, queue: queue)
                    .frame(height: ProgressHUDMetrics.rowHeight)
            }

            if hiddenCount > 0 {
                Text("+ \(hiddenCount) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(height: ProgressHUDMetrics.moreHeight)
            }
        }
        .frame(width: ProgressHUDMetrics.width)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .tint(Theme.accent)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var background: some View {
        switch settings.style {
        case .glass: Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.25))
        case .solid: Color(white: 0.13)
        }
    }
}

enum ProgressHUDMetrics {
    static let width: CGFloat = 340
    static let headerHeight: CGFloat = 34
    static let rowHeight: CGFloat = 56
    static let moreHeight: CGFloat = 24
    static let maxRows = 5

    static func height(rows: Int, hidden: Int) -> CGFloat {
        headerHeight + 1 + CGFloat(rows) * rowHeight + (hidden > 0 ? moreHeight : 0)
    }
}

private struct JobRow: View {
    @ObservedObject var job: Job
    let queue: JobQueue

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.8)
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch job.state {
        case .queued:
            Text("Waiting…").font(.system(size: 11)).foregroundStyle(.secondary)
        case .running:
            if job.cancelRequested {
                Text("Cancelling…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ProgressView(value: job.progress).progressViewStyle(.linear).tint(Theme.accent)
            }
        case .finished(let urls):
            Text(urls.count == 1 ? "Saved as \(urls[0].lastPathComponent)" : "Saved \(urls.count) files")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
        case .cancelled:
            Text("Cancelled").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch job.state {
        case .queued, .running:
            iconButton("xmark.circle.fill", help: "Cancel") { queue.cancel(job) }
        case .finished(let urls):
            iconButton("magnifyingglass.circle.fill", help: "Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        case .failed, .cancelled:
            iconButton("xmark.circle.fill", help: "Dismiss") { queue.remove(job) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
