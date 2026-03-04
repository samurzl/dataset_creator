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

    @Published private(set) var videoURLs: [URL] = []
    @Published private(set) var selectedVideoIndex: Int = 0
    @Published private(set) var selectedVideoURL: URL?

    let playerController = VideoPlayerController()

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private let inputVideoResampler = InputVideoResampler(targetFrameRate: 16)
    private var cancellables: Set<AnyCancellable> = []
    private var activeLoadTask: Task<Void, Never>?
    private var activeSelectionToken = UUID()
    private var preloadingSourceURLs: Set<URL> = []

    private static let inputFolderDefaultsKey = "inputFolderPath"
    private static let outputFolderDefaultsKey = "outputFolderPath"
    private let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "mpg", "mpeg", "webm"]
    private let preloadLookaheadCount = 2

    init() {
        inputFolderPath = defaults.string(forKey: Self.inputFolderDefaultsKey) ?? ""
        outputFolderPath = defaults.string(forKey: Self.outputFolderDefaultsKey) ?? ""

        playerController.objectWillChange
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

    private var selectedSourceVideoURL: URL? {
        guard videoURLs.indices.contains(selectedVideoIndex) else { return nil }
        return videoURLs[selectedVideoIndex]
    }

    var selectedVideoName: String {
        selectedSourceVideoURL?.lastPathComponent ?? "No video selected"
    }

    var videoCountLabel: String {
        guard !videoURLs.isEmpty else { return "0 / 0" }
        return "\(selectedVideoIndex + 1) / \(videoURLs.count)"
    }

    var hasVideos: Bool {
        !videoURLs.isEmpty
    }

    var hasPreviousVideo: Bool {
        selectedVideoIndex > 0
    }

    var hasNextVideo: Bool {
        selectedVideoIndex < videoURLs.count - 1
    }

    var hasConfiguredOutputFolder: Bool {
        !outputFolderPath.isEmpty
    }

    func makeExportRequest() throws -> ClipExportRequest {
        guard let selectedVideoURL else {
            throw ClipExportError.noVideoSelected
        }

        let frameRate = playerController.currentFrameRate
        guard frameRate.isFinite, frameRate > 0 else {
            throw ClipExportError.invalidFrameRate
        }

        let frameCount = playerController.selectedFrameCount
        guard ClipSelectionQuantization.isQuantized(frameCount) else {
            throw ClipExportError.invalidFrameCount
        }

        return ClipExportRequest(
            videoURL: selectedVideoURL,
            inFrame: playerController.inFrame,
            frameCount: frameCount,
            frameRate: frameRate,
            aspectRatio: playerController.videoAspectRatio
        )
    }

    func exportClip(request: ClipExportRequest, caption: String) async throws -> URL {
        guard !outputFolderPath.isEmpty else {
            throw ClipExportError.outputFolderNotConfigured
        }

        let outputDirectory = URL(fileURLWithPath: outputFolderPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: outputDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ClipExportError.outputDirectoryMissing
        }

        return try await ClipExporter.exportClip(
            request: request,
            caption: caption,
            to: outputDirectory
        )
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
            cancelVideoLoading()
            preloadingSourceURLs.removeAll(keepingCapacity: true)
            videoURLs = []
            selectedVideoIndex = 0
            selectedVideoURL = nil
            playerController.clearVideo()
            return
        }

        let previousSelection = selectedSourceVideoURL
        let folderURL = URL(fileURLWithPath: inputFolderPath, isDirectory: true)

        let discoveredVideos: [URL]
        do {
            let allItems = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            discoveredVideos = allItems
                .filter { url in
                    supportedExtensions.contains(url.pathExtension.lowercased())
                }
                .sorted {
                    $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
                }
        } catch {
            discoveredVideos = []
        }

        videoURLs = discoveredVideos
        preloadingSourceURLs.removeAll(keepingCapacity: true)

        guard !videoURLs.isEmpty else {
            cancelVideoLoading()
            selectedVideoIndex = 0
            selectedVideoURL = nil
            playerController.clearVideo()
            return
        }

        if let previousSelection,
           let index = videoURLs.firstIndex(of: previousSelection) {
            selectedVideoIndex = index
        } else {
            selectedVideoIndex = min(selectedVideoIndex, videoURLs.count - 1)
        }

        loadSelectedVideo()
    }

    func selectVideo(at index: Int) {
        guard videoURLs.indices.contains(index) else { return }
        selectedVideoIndex = index
        loadSelectedVideo()
    }

    func selectNextVideo() {
        selectVideo(at: selectedVideoIndex + 1)
    }

    func selectPreviousVideo() {
        selectVideo(at: selectedVideoIndex - 1)
    }

    private func loadSelectedVideo() {
        guard let selectedSourceVideoURL else {
            cancelVideoLoading()
            preloadingSourceURLs.removeAll(keepingCapacity: true)
            selectedVideoURL = nil
            playerController.clearVideo()
            return
        }

        cancelVideoLoading()
        selectedVideoURL = nil
        playerController.clearVideo()
        scheduleLookaheadPreload(after: selectedVideoIndex)

        let selectionToken = UUID()
        activeSelectionToken = selectionToken

        activeLoadTask = Task { [weak self] in
            guard let self else { return }

            do {
                let preparedVideoURL = try await self.inputVideoResampler.resampledURL(for: selectedSourceVideoURL)
                guard !Task.isCancelled, self.activeSelectionToken == selectionToken else { return }

                self.selectedVideoURL = preparedVideoURL
                self.playerController.loadVideo(at: preparedVideoURL)
            } catch is CancellationError {
                return
            } catch {
                guard self.activeSelectionToken == selectionToken else { return }
                self.selectedVideoURL = nil
                self.playerController.clearVideo()
            }
            self.activeLoadTask = nil
        }
    }

    private func cancelVideoLoading() {
        activeSelectionToken = UUID()
        activeLoadTask?.cancel()
        activeLoadTask = nil
    }

    private func scheduleLookaheadPreload(after index: Int) {
        guard !videoURLs.isEmpty else { return }

        let startIndex = index + 1
        let endIndex = min(index + preloadLookaheadCount, videoURLs.count - 1)
        guard startIndex <= endIndex else { return }

        for preloadIndex in startIndex...endIndex {
            schedulePreload(for: videoURLs[preloadIndex])
        }
    }

    private func schedulePreload(for sourceURL: URL) {
        guard preloadingSourceURLs.insert(sourceURL).inserted else { return }

        Task(priority: .background) { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.preloadingSourceURLs.remove(sourceURL)
            }
            _ = try? await self.inputVideoResampler.resampledURL(for: sourceURL)
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
