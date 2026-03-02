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

    let playerController = VideoPlayerController()

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default
    private var cancellables: Set<AnyCancellable> = []

    private static let inputFolderDefaultsKey = "inputFolderPath"
    private static let outputFolderDefaultsKey = "outputFolderPath"
    private let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "mpg", "mpeg", "webm"]

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

    var selectedVideoURL: URL? {
        guard videoURLs.indices.contains(selectedVideoIndex) else { return nil }
        return videoURLs[selectedVideoIndex]
    }

    var selectedVideoName: String {
        selectedVideoURL?.lastPathComponent ?? "No video selected"
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
            videoURLs = []
            selectedVideoIndex = 0
            playerController.clearVideo()
            return
        }

        let previousSelection = selectedVideoURL
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

        guard !videoURLs.isEmpty else {
            selectedVideoIndex = 0
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
        guard let selectedVideoURL else {
            playerController.clearVideo()
            return
        }

        playerController.loadVideo(at: selectedVideoURL)
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
