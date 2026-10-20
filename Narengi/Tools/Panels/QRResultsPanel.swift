import AppKit
import SwiftUI

struct QRResultsPanel: View {
    let fileName: String
    let results: [QRResult]
    let error: String?
    let isScanning: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(fileName).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
            if isScanning {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error).foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No QR codes found").font(.system(size: 15, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(results) { result in QRRow(result: result) }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 12)
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Spacer()
                Button("Copy All") { QRResultsPanel.copy(results.map(\.payload).joined(separator: "\n")) }
                    .buttonStyle(OrangeButtonStyle()).disabled(results.isEmpty)
            }
            .padding(14)
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct QRRow: View {
    let result: QRResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.payload).font(.system(size: 14)).textSelection(.enabled).lineLimit(4)
                Text([result.kind, result.page.map { "page \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let url = result.url {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).help("Open")
            }
            Button { QRResultsPanel.copy(result.payload) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help("Copy")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)))
    }
}
