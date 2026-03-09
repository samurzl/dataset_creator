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

private enum ExportFormError: LocalizedError {
    case blankOriginalCaption
    case blankMissingCaption
    case blankCategory

    var errorDescription: String? {
        switch self {
        case .blankOriginalCaption:
            return "Original caption is required."
        case .blankMissingCaption:
            return "Missing caption is required."
        case .blankCategory:
            return "Category is required."
        }
    }
}

struct ExportClipSheet: View {
    let request: ClipExportRequest
    let onCancel: () -> Void
    let onExport: (DatasetRowInput) async throws -> Void

    @StateObject private var previewController = ExportPreviewController()
    @State private var originalCaptionText = ""
    @State private var missingCaptionText = ""
    @State private var categoryText = ""
    @State private var isExporting = false
    @State private var exportErrorMessage: String?
    @State private var exportTask: Task<Void, Never>?

    private var isLivePreviewEnabled: Bool {
        !RuntimeEnvironment.shouldDisableExportPreview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Dataset Row")
                .font(.system(size: 20, weight: .semibold))

            previewSection

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    originalCaptionSection
                    missingCaptionSection
                    categorySection
                    generatedSection

                    if isLivePreviewEnabled, let loadingErrorMessage = previewController.loadingErrorMessage {
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
            guard isLivePreviewEnabled else { return }
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
            if isLivePreviewEnabled {
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

    private var originalCaptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Original Caption")
            textEditor(
                text: $originalCaptionText,
                minHeight: 110,
                placeholder: "Positive caption and base negative caption"
            )
        }
    }

    private var missingCaptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Missing Caption")
            Text("Used as the prompt for the second synthetic negative.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            textEditor(
                text: $missingCaptionText,
                minHeight: 110,
                placeholder: "Prompt for the missing-caption synthetic negative"
            )
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Category")
            Text("Comma or newline separated. Each category generates two anchors.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            textEditor(
                text: $categoryText,
                minHeight: 72,
                placeholder: "cat, studio"
            )
        }
    }

    private var generatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Generated")
            Text("This export automatically saves:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            generatedLine("Positive caption", "original caption")
            generatedLine("Categories", "[all provided categories]")
            generatedLine("Negative 1", "synthetic, caption = original caption, prompt = original caption")
            generatedLine("Negative 2", "synthetic, caption = original caption, prompt = missing caption")
            generatedLine("Anchors", "for each category: one anchor with [category], one with [category] + allow random")
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
                    (isLivePreviewEnabled && previewController.loadingErrorMessage != nil)
                )
                .keyboardShortcut(.defaultAction)
        }
    }

    private func generatedLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        let originalCaption = originalCaptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalCaption.isEmpty else {
            throw ExportFormError.blankOriginalCaption
        }

        let missingCaption = missingCaptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !missingCaption.isEmpty else {
            throw ExportFormError.blankMissingCaption
        }

        let categories = parseUniqueItems(from: categoryText)
        guard !categories.isEmpty else {
            throw ExportFormError.blankCategory
        }

        return DatasetRowInput(
            originalCaption: originalCaption,
            missingCaption: missingCaption,
            categories: categories
        )
    }

    private func parseUniqueItems(from text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        var values: [String] = []
        var seen: Set<String> = []

        for candidate in text.components(separatedBy: separators) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                values.append(trimmed)
            }
        }

        return values
    }
}
