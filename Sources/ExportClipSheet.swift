import AVFoundation
import SwiftUI

@MainActor
final class ExportPreviewController: ObservableObject {
    private var backingPlayer: AVPlayer?

    var player: AVPlayer {
        if let backingPlayer {
            return backingPlayer
        }

        let player = AVPlayer()
        backingPlayer = player
        return player
    }

    @Published private(set) var loadingErrorMessage: String?

    private var itemDidPlayToEndObserver: NSObjectProtocol?

    func load(request: ClipExportRequest) async {
        stop()
        loadingErrorMessage = nil

        do {
            let item = try await ClipExporter.createPreviewItem(for: request)
            installLooping(for: item)
            player.replaceCurrentItem(with: item)
            player.play()
        } catch {
            loadingErrorMessage = error.localizedDescription
        }
    }

    func stop() {
        backingPlayer?.pause()
        backingPlayer?.replaceCurrentItem(with: nil)
        removeLoopingObserver()
    }

    private func installLooping(for item: AVPlayerItem) {
        removeLoopingObserver()

        let player = self.player
        player.actionAtItemEnd = .none
        itemDidPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let player = self?.backingPlayer else { return }
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
            }
        }
    }

    private func removeLoopingObserver() {
        guard let itemDidPlayToEndObserver else { return }
        NotificationCenter.default.removeObserver(itemDidPlayToEndObserver)
        self.itemDidPlayToEndObserver = nil
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

    private var isLivePreviewEnabled: Bool {
        !RuntimeEnvironment.shouldDisableExportPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Clip")
                .font(.system(size: 20, weight: .semibold))

            GeometryReader { geometry in
                let mediaAndCaptionHeight = max(geometry.size.height, 1)
                let previewHeight = max(mediaAndCaptionHeight * 0.58, 1)

                VStack(alignment: .leading, spacing: 12) {
                    if isLivePreviewEnabled {
                        PlayerPreview(player: previewController.player)
                            .aspectRatio(max(request.aspectRatio, 0.1), contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(height: previewHeight)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        VStack(spacing: 8) {
                            Text("Preview disabled in virtual machine")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Export remains fully available.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: previewHeight)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

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

                    if isLivePreviewEnabled, let loadingErrorMessage = previewController.loadingErrorMessage {
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
                    .disabled(
                        isExporting ||
                        (isLivePreviewEnabled && previewController.loadingErrorMessage != nil)
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request.id) {
            guard isLivePreviewEnabled else { return }
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
