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

private struct NegativeDraft: Identifiable {
    let id = UUID()
    var media: DatasetNegativeMedia = .positive
    var caption = ""
    var prompt = ""
}

private struct AnchorDraft: Identifiable {
    let id = UUID()
    var requiredCategories = ""
    var extraRandomCategory = false
}

private enum ExportFormError: LocalizedError {
    case blankCaption
    case missingCategories
    case blankNegativeCaption(index: Int)
    case blankNegativePrompt(index: Int)
    case blankAnchorCategories(index: Int)

    var errorDescription: String? {
        switch self {
        case .blankCaption:
            return "Caption is required."
        case .missingCategories:
            return "Add at least one category."
        case let .blankNegativeCaption(index):
            return "Negative \(index + 1) requires a caption."
        case let .blankNegativePrompt(index):
            return "Negative \(index + 1) requires a prompt when media is synthetic."
        case let .blankAnchorCategories(index):
            return "Anchor \(index + 1) requires at least one category."
        }
    }
}

struct ExportClipSheet: View {
    let request: ClipExportRequest
    let onCancel: () -> Void
    let onExport: (DatasetRowInput) async throws -> Void

    @StateObject private var previewController = ExportPreviewController()
    @State private var captionText = ""
    @State private var categoriesText = ""
    @State private var negatives: [NegativeDraft] = [NegativeDraft()]
    @State private var anchors: [AnchorDraft] = []
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
                    captionSection
                    categoriesSection
                    negativesSection
                    anchorsSection

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

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Caption")
            textEditor(text: $captionText, minHeight: 110)
        }
    }

    private var categoriesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Categories")
            Text("Comma or newline separated. Duplicate entries are deduplicated automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            textEditor(
                text: $categoriesText,
                minHeight: 72,
                placeholder: "cat, cinematic, studio"
            )
        }
    }

    private var negativesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Negatives")
                Spacer()
                Button("Add Negative", action: addNegative)
            }

            Text("Each row requires at least one negative.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ForEach(Array(negatives.enumerated()), id: \.element.id) { index, negative in
                negativeCard(index: index, negative: negative)
            }
        }
    }

    private var anchorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Anchors")
                Spacer()
                Button("Add Anchor", action: addAnchor)
            }

            Text("Anchors are optional and always reuse another positive sample.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if anchors.isEmpty {
                Text("No anchors added.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(anchors.enumerated()), id: \.element.id) { index, anchor in
                    anchorCard(index: index, anchor: anchor)
                }
            }
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

    private func negativeCard(index: Int, negative: NegativeDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Negative \(index + 1)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Remove") {
                    removeNegative(id: negative.id)
                }
                .disabled(negatives.count == 1)
            }

            Picker("Media", selection: bindingForNegative(id: negative.id).media) {
                ForEach(DatasetNegativeMedia.allCases, id: \.self) { media in
                    Text(media.label).tag(media)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("Caption")
                    .font(.system(size: 12, weight: .medium))
                textEditor(
                    text: bindingForNegative(id: negative.id).caption,
                    minHeight: 72,
                    placeholder: "Negative caption"
                )
            }

            if negative.media == .synthetic {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.system(size: 12, weight: .medium))
                    textEditor(
                        text: bindingForNegative(id: negative.id).prompt,
                        minHeight: 72,
                        placeholder: "Synthetic media prompt"
                    )
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func anchorCard(index: Int, anchor: AnchorDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Anchor \(index + 1)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Remove") {
                    removeAnchor(id: anchor.id)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Required Categories")
                    .font(.system(size: 12, weight: .medium))
                textEditor(
                    text: bindingForAnchor(id: anchor.id).requiredCategories,
                    minHeight: 72,
                    placeholder: "cat, studio"
                )
            }

            Toggle(
                "Allow one extra random category",
                isOn: bindingForAnchor(id: anchor.id).extraRandomCategory
            )
            .toggleStyle(.checkbox)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func addNegative() {
        negatives.append(NegativeDraft())
    }

    private func removeNegative(id: UUID) {
        negatives.removeAll { $0.id == id }
        if negatives.isEmpty {
            negatives = [NegativeDraft()]
        }
    }

    private func addAnchor() {
        anchors.append(AnchorDraft())
    }

    private func removeAnchor(id: UUID) {
        anchors.removeAll { $0.id == id }
    }

    private func bindingForNegative(id: UUID) -> Binding<NegativeDraft> {
        Binding(
            get: {
                negatives.first(where: { $0.id == id }) ?? NegativeDraft()
            },
            set: { updatedValue in
                guard let index = negatives.firstIndex(where: { $0.id == id }) else { return }
                negatives[index] = updatedValue
            }
        )
    }

    private func bindingForAnchor(id: UUID) -> Binding<AnchorDraft> {
        Binding(
            get: {
                anchors.first(where: { $0.id == id }) ?? AnchorDraft()
            },
            set: { updatedValue in
                guard let index = anchors.firstIndex(where: { $0.id == id }) else { return }
                anchors[index] = updatedValue
            }
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

        let categories = parseUniqueItems(from: categoriesText)
        guard !categories.isEmpty else {
            throw ExportFormError.missingCategories
        }

        let negativeValues = try negatives.enumerated().map { index, draft in
            let caption = draft.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !caption.isEmpty else {
                throw ExportFormError.blankNegativeCaption(index: index)
            }

            switch draft.media {
            case .positive:
                return DatasetNegative(media: .positive, caption: caption, prompt: nil)
            case .synthetic:
                let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !prompt.isEmpty else {
                    throw ExportFormError.blankNegativePrompt(index: index)
                }
                return DatasetNegative(media: .synthetic, caption: caption, prompt: prompt)
            }
        }

        let anchorValues = try anchors.enumerated().map { index, draft in
            let requiredCategories = parseUniqueItems(from: draft.requiredCategories)
            guard !requiredCategories.isEmpty else {
                throw ExportFormError.blankAnchorCategories(index: index)
            }
            return DatasetAnchor(
                requiredCategories: requiredCategories,
                extraRandomCategory: draft.extraRandomCategory
            )
        }

        return DatasetRowInput(
            caption: caption,
            nsync: DatasetNSync(
                categories: categories,
                negatives: negativeValues,
                anchors: anchorValues
            )
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

private extension DatasetNegativeMedia {
    var label: String {
        switch self {
        case .positive:
            return "positive"
        case .synthetic:
            return "synthetic"
        }
    }
}
