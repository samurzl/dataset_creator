import AppKit
import Combine
import Foundation

@MainActor
final class VideoBrowserViewModel: ObservableObject {
    @Published var inputFolderPath: String {
        didSet {
            defaults.set(inputFolderPath, forKey: Self.inputFolderDefaultsKey)
        }
    }

    @Published var outputFolderPath: String {
        didSet {
            defaults.set(outputFolderPath, forKey: Self.outputFolderDefaultsKey)
        }
    }

    @Published private(set) var mediaItems: [BrowserMediaItem] = []
    @Published private(set) var selectedMediaIndex: Int = 0
    @Published private(set) var selectedMediaURL: URL?
    @Published private(set) var selectedMediaKind: BrowserMediaKind?
    @Published private(set) var lastExportCaption: String {
        didSet {
            defaults.set(lastExportCaption, forKey: Self.lastExportCaptionDefaultsKey)
        }
    }

    @Published private(set) var lastExportCategoryText: String {
        didSet {
            defaults.set(lastExportCategoryText, forKey: Self.lastExportCategoryDefaultsKey)
        }
    }

    let playerController = VideoPlayerController()
    let imageCropController = ImageCropController()

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let inputVideoResampler: any InputVideoPreparing
    private let datasetAuthoringService = DatasetAuthoringService()
    private var cancellables: Set<AnyCancellable> = []
    private var activeLoadTask: Task<Void, Never>?
    private var activeSelectionToken = UUID()
    private var preloadingSourceURLs: Set<URL> = []

    private static let inputFolderDefaultsKey = "inputFolderPath"
    private static let outputFolderDefaultsKey = "outputFolderPath"
    private static let lastExportCaptionDefaultsKey = "lastExportCaption"
    private static let lastExportCategoryDefaultsKey = "lastExportCategoryText"

    private let supportedVideoExtensions: Set<String> = [
        "mp4",
        "mov",
        "m4v",
        "mkv",
        "avi",
        "mpg",
        "mpeg",
        "webm"
    ]

    private let supportedImageExtensions: Set<String> = [
        "png",
        "jpg",
        "jpeg",
        "webp",
        "heic",
        "heif",
        "bmp",
        "tif",
        "tiff",
        "gif"
    ]

    private let preloadLookaheadCount = 2

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        inputVideoResampler: any InputVideoPreparing = InputVideoResampler()
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.inputVideoResampler = inputVideoResampler
        inputFolderPath = defaults.string(forKey: Self.inputFolderDefaultsKey) ?? ""
        outputFolderPath = defaults.string(forKey: Self.outputFolderDefaultsKey) ?? ""
        lastExportCaption = defaults.string(forKey: Self.lastExportCaptionDefaultsKey) ?? ""
        lastExportCategoryText = defaults.string(forKey: Self.lastExportCategoryDefaultsKey) ?? ""

        playerController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        imageCropController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if !inputFolderPath.isEmpty {
            refreshVideos()
        }
    }

    deinit {
        activeLoadTask?.cancel()
    }

    private var supportedExtensions: Set<String> {
        supportedVideoExtensions.union(supportedImageExtensions)
    }

    private var selectedSourceMediaItem: BrowserMediaItem? {
        guard mediaItems.indices.contains(selectedMediaIndex) else { return nil }
        return mediaItems[selectedMediaIndex]
    }

    var mediaCountLabel: String {
        guard !mediaItems.isEmpty else { return "0 / 0" }
        return "\(selectedMediaIndex + 1) / \(mediaItems.count)"
    }

    var hasMedia: Bool {
        !mediaItems.isEmpty
    }

    var hasPreviousMedia: Bool {
        selectedMediaIndex > 0
    }

    var hasNextMedia: Bool {
        selectedMediaIndex < mediaItems.count - 1
    }

    var hasConfiguredOutputFolder: Bool {
        !outputFolderPath.isEmpty
    }

    var isShowingVideo: Bool {
        selectedMediaKind == .video
    }

    var isShowingImage: Bool {
        selectedMediaKind == .image
    }

    var selectedImageCropLabel: String {
        let imageSize = imageCropController.imagePixelSize
        let cropSize = imageCropController.cropPixelSize

        guard imageSize.width > 0, imageSize.height > 0 else {
            return "Crop unavailable"
        }

        if imageCropController.hasCustomCrop {
            return "Crop: \(Int(cropSize.width)) x \(Int(cropSize.height)) px"
        }

        return "Crop: full image (\(Int(imageSize.width)) x \(Int(imageSize.height)) px)"
    }

    func makeExportRequest() throws -> ClipExportRequest {
        guard let selectedMediaURL, let selectedMediaKind else {
            throw ClipExportError.noMediaSelected
        }

        switch selectedMediaKind {
        case .video:
            let frameRate = playerController.currentFrameRate
            guard frameRate.isFinite, frameRate > 0 else {
                throw ClipExportError.invalidFrameRate
            }

            let frameCount = playerController.selectedFrameCount
            guard ClipSelectionQuantization.isQuantized(frameCount) else {
                throw ClipExportError.invalidFrameCount
            }

            return ClipExportRequest(
                videoURL: selectedMediaURL,
                inFrame: playerController.inFrame,
                frameCount: frameCount,
                frameRate: frameRate,
                aspectRatio: playerController.videoAspectRatio
            )
        case .image:
            let cropRect = imageCropController.exportCropRectPixels
            guard cropRect.width > 0, cropRect.height > 0 else {
                throw ClipExportError.invalidImageCrop
            }

            return ClipExportRequest(
                imageURL: selectedMediaURL,
                cropRect: cropRect,
                imageSize: imageCropController.imagePixelSize
            )
        }
    }

    func exportClip(request: ClipExportRequest, input: DatasetRowInput) async throws -> URL {
        guard !outputFolderPath.isEmpty else {
            throw ClipExportError.outputFolderNotConfigured
        }

        let outputDirectory = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ClipExportError.outputDirectoryMissing
        }

        return try await datasetAuthoringService.exportClip(
            request: request,
            input: input,
            datasetRootURL: outputDirectory
        )
    }

    func rememberLastExport(input: DatasetRowInput) {
        lastExportCaption = input.caption
        lastExportCategoryText = input.nsync.categories.joined(separator: "\n")
    }

    func chooseInputFolder() {
        guard let folder = pickFolder(startingAt: inputFolderPath) else { return }
        inputFolderPath = folder.path
        refreshVideos()
    }

    func chooseOutputFolder() {
        guard let folder = pickFolder(startingAt: outputFolderPath) else { return }
        outputFolderPath = folder.path
    }

    func refreshVideos() {
        guard !inputFolderPath.isEmpty else {
            clearSelection()
            mediaItems = []
            selectedMediaIndex = 0
            return
        }

        let previousSelection = selectedSourceMediaItem
        let folderURL = URL(fileURLWithPath: inputFolderPath, isDirectory: true)

        let discoveredMedia: [BrowserMediaItem]
        do {
            let allItems = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            discoveredMedia = allItems
                .filter { url in
                    supportedExtensions.contains(url.pathExtension.lowercased())
                }
                .sorted {
                    $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
                }
                .compactMap(makeMediaItem)
        } catch {
            discoveredMedia = []
        }

        mediaItems = discoveredMedia
        preloadingSourceURLs.removeAll(keepingCapacity: true)

        guard !mediaItems.isEmpty else {
            clearSelection()
            selectedMediaIndex = 0
            return
        }

        if let previousSelection,
           let index = mediaItems.firstIndex(of: previousSelection) {
            selectedMediaIndex = index
        } else {
            selectedMediaIndex = min(selectedMediaIndex, mediaItems.count - 1)
        }

        loadSelectedMedia()
    }

    func selectMedia(at index: Int) {
        guard mediaItems.indices.contains(index) else { return }
        selectedMediaIndex = index
        loadSelectedMedia()
    }

    func selectNextMedia() {
        selectMedia(at: selectedMediaIndex + 1)
    }

    func selectPreviousMedia() {
        selectMedia(at: selectedMediaIndex - 1)
    }

    private func makeMediaItem(for url: URL) -> BrowserMediaItem? {
        let pathExtension = url.pathExtension.lowercased()

        if supportedVideoExtensions.contains(pathExtension) {
            return BrowserMediaItem(sourceURL: url, kind: .video)
        }

        if supportedImageExtensions.contains(pathExtension) {
            return BrowserMediaItem(sourceURL: url, kind: .image)
        }

        return nil
    }

    private func clearSelection() {
        cancelVideoLoading()
        preloadingSourceURLs.removeAll(keepingCapacity: true)
        selectedMediaURL = nil
        selectedMediaKind = nil
        playerController.clearVideo()
        imageCropController.clearImage()
    }

    private func loadSelectedMedia() {
        guard let selectedSourceMediaItem else {
            clearSelection()
            return
        }

        cancelVideoLoading()
        selectedMediaKind = selectedSourceMediaItem.kind
        selectedMediaURL = nil
        playerController.clearVideo()
        imageCropController.clearImage()

        switch selectedSourceMediaItem.kind {
        case .image:
            selectedMediaURL = selectedSourceMediaItem.sourceURL
            imageCropController.loadImage(at: selectedSourceMediaItem.sourceURL)

        case .video:
            let selectionToken = UUID()
            activeSelectionToken = selectionToken

            activeLoadTask = Task { [weak self] in
                guard let self else { return }

                do {
                    let preparedVideoURL = try await self.inputVideoResampler.preparedURL(
                        for: selectedSourceMediaItem.sourceURL
                    )
                    guard !Task.isCancelled, self.activeSelectionToken == selectionToken else { return }

                    self.selectedMediaURL = preparedVideoURL
                    self.playerController.loadVideo(at: preparedVideoURL)
                    self.scheduleLookaheadPreload(after: self.selectedMediaIndex)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.activeSelectionToken == selectionToken else { return }
                    self.selectedMediaURL = nil
                    self.playerController.clearVideo()
                }

                self.activeLoadTask = nil
            }
        }
    }

    private func cancelVideoLoading() {
        activeSelectionToken = UUID()
        activeLoadTask?.cancel()
        activeLoadTask = nil
    }

    private func scheduleLookaheadPreload(after index: Int) {
        guard !mediaItems.isEmpty else { return }

        var scheduledCount = 0
        for preloadIndex in (index + 1)..<mediaItems.count {
            let preloadItem = mediaItems[preloadIndex]
            guard preloadItem.kind == .video else { continue }

            schedulePreload(for: preloadItem.sourceURL)
            scheduledCount += 1

            if scheduledCount >= preloadLookaheadCount {
                break
            }
        }
    }

    private func schedulePreload(for sourceURL: URL) {
        guard preloadingSourceURLs.insert(sourceURL).inserted else { return }

        Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.preloadingSourceURLs.remove(sourceURL)
            }
            _ = try? await self.inputVideoResampler.preparedURL(for: sourceURL)
        }
    }

    private func pickFolder(startingAt path: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"

        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
