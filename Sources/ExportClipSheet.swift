import AVFoundation
import SwiftUI

@MainActor
final class ExportPreviewController: ObservableObject {
    let player = AVQueuePlayer()

    @Published private(set) var loadingErrorMessage: String?

    private var looper: AVPlayerLooper?

    func load(request: ClipExportRequest) async {
        player.pause()
        player.removeAllItems()
        looper = nil
        loadingErrorMessage = nil

        do {
            let item = try await ClipExporter.createPreviewItem(for: request)
            looper = AVPlayerLooper(player: player, templateItem: item)
            player.play()
        } catch {
            loadingErrorMessage = error.localizedDescription
        }
    }

    func stop() {
        player.pause()
        player.removeAllItems()
        looper = nil
    }
}

struct ExportClipSheet: View {
    let request: ClipExportRequest
    let onCancel: () -> Void
    let onExport: (String) async throws -> Void

    @StateObject private var previewController = ExportPreviewController()
    @State private var captionText = ""
    @State private var isExporting = false
    @State private var exportErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Clip")
                .font(.system(size: 20, weight: .semibold))

            PlayerPreview(player: previewController.player)
                .aspectRatio(max(request.aspectRatio, 0.1), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 320)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text("Caption")
                    .font(.system(size: 13, weight: .semibold))

                TextEditor(text: $captionText)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                    )
            }

            if let loadingErrorMessage = previewController.loadingErrorMessage {
                Text("Preview error: \(loadingErrorMessage)")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            if let exportErrorMessage {
                Text("Export error: \(exportErrorMessage)")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isExporting)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Export", action: performExport)
                    .disabled(isExporting || previewController.loadingErrorMessage != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 950, minHeight: 760)
        .task(id: request.id) {
            await previewController.load(request: request)
        }
        .onDisappear {
            previewController.stop()
        }
    }

    private func performExport() {
        guard !isExporting else { return }
        exportErrorMessage = nil
        isExporting = true

        Task {
            defer { isExporting = false }

            do {
                try await onExport(captionText)
                onCancel()
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }
}
