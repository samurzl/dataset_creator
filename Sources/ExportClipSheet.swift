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
    @Published private(set) var previewImage: NSImage?

    private var itemDidPlayToEndObserver: NSObjectProtocol?

    func load(request: ClipExportRequest) async {
        stop()
        loadingErrorMessage = nil

        do {
            if request.isImage {
                previewImage = try ClipExporter.createPreviewImage(for: request)
            } else {
                let item = try await ClipExporter.createPreviewItem(for: request)
                installLooping(for: item)
                player.replaceCurrentItem(with: item)
                player.play()
            }
        } catch {
            loadingErrorMessage = error.localizedDescription
        }
    }

    func stop() {
        backingPlayer?.pause()
        backingPlayer?.replaceCurrentItem(with: nil)
        previewImage = nil
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

private enum ExportFormError: LocalizedError {
    case blankCaption

    var errorDescription: String? {
        switch self {
        case .blankCaption:
            return "Caption is required."
        }
    }
}

struct ExportClipSheet: View {
    let request: ClipExportRequest
    let onCancel: () -> Void
    let onExport: (DatasetRowInput) async throws -> Void

    @StateObject private var previewController = ExportPreviewController()
    @State private var captionText = ""
    @State private var isExporting = false
    @State private var exportErrorMessage: String?
    @State private var exportTask: Task<Void, Never>?

    init(
        request: ClipExportRequest,
        initialCaptionText: String,
        onCancel: @escaping () -> Void,
        onExport: @escaping (DatasetRowInput) async throws -> Void
    ) {
        self.request = request
        self.onCancel = onCancel
        self.onExport = onExport
        _captionText = State(initialValue: initialCaptionText)
    }

    private var isPreviewEnabled: Bool {
        request.isImage || !RuntimeEnvironment.shouldDisableExportPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Dataset Row")
                .font(.system(size: 20, weight: .semibold))

            previewSection

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    captionSection

                    if isPreviewEnabled, let loadingErrorMessage = previewController.loadingErrorMessage {
                        Text("Preview error: \(loadingErrorMessage)")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    if let exportErrorMessage {
                        Text("Export error: \(exportErrorMessage)")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
            }

            actionRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: request.id) {
            guard isPreviewEnabled else { return }
            await previewController.load(request: request)
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            previewController.stop()
        }
    }

    private var previewSection: some View {
        Group {
            if request.isImage {
                Group {
                    if let previewImage = previewController.previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Color.secondary.opacity(0.1)
                            .overlay(
                                ProgressView()
                                    .controlSize(.small)
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if isPreviewEnabled {
                PlayerPreview(player: previewController.player)
                    .aspectRatio(max(request.aspectRatio, 0.1), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Text("Preview disabled in virtual machine")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Dataset export remains fully available.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Caption")
            textEditor(
                text: $captionText,
                minHeight: 110,
                placeholder: "Saved as the clip caption in dataset.json"
            )
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Cancel", role: .cancel, action: onCancel)
                .disabled(isExporting)
                .keyboardShortcut(.cancelAction)

            Spacer()

            if isExporting {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Add to Dataset", action: performExport)
                .disabled(
                    isExporting ||
                    (isPreviewEnabled && previewController.loadingErrorMessage != nil)
                )
                .keyboardShortcut(.defaultAction)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
    }

    private func textEditor(
        text: Binding<String>,
        minHeight: CGFloat,
        placeholder: String? = nil
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if let placeholder, text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
            }

            TextEditor(text: text)
                .font(.system(size: 13, design: .monospaced))
                .frame(minHeight: minHeight)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
        )
    }

    private func performExport() {
        guard !isExporting else { return }

        do {
            let input = try buildDatasetRowInput()
            exportErrorMessage = nil
            isExporting = true

            exportTask?.cancel()
            exportTask = Task(priority: .userInitiated) {
                do {
                    try await onExport(input)

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
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func buildDatasetRowInput() throws -> DatasetRowInput {
        let caption = captionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else {
            throw ExportFormError.blankCaption
        }

        return DatasetRowInput(caption: caption)
    }
}
