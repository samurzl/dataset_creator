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
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Clip")
                .font(.system(size: 20, weight: .semibold))

            GeometryReader { geometry in
                let mediaAndCaptionHeight = max(geometry.size.height, 1)
                let previewHeight = max(mediaAndCaptionHeight * 0.58, 1)

                VStack(alignment: .leading, spacing: 12) {
                    PlayerPreview(player: previewController.player)
                        .aspectRatio(max(request.aspectRatio, 0.1), contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: previewHeight)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Caption")
                            .font(.system(size: 13, weight: .semibold))

                        TextEditor(text: $captionText)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minHeight: 1, maxHeight: .infinity)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
                            )
                    }
                    .frame(minHeight: 1, maxHeight: .infinity)

                    if let loadingErrorMessage = previewController.loadingErrorMessage {
                        Text("Preview error: \(loadingErrorMessage)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.red)
                    }

                    if let exportErrorMessage {
                        Text("Export error: \(exportErrorMessage)")
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request.id) {
            await previewController.load(request: request)
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            previewController.stop()
        }
    }

    private func performExport() {
        guard !isExporting else { return }
        exportErrorMessage = nil
        isExporting = true
        let caption = captionText

        exportTask?.cancel()
        exportTask = Task(priority: .userInitiated) {
            do {
                try await onExport(caption)

                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                    onCancel()
                }
            } catch is CancellationError {
                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                    exportErrorMessage = error.localizedDescription
                }
            }
        }

    }
}
