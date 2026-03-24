import Foundation
import XCTest
@testable import VideoDatasetBrowser

final class VideoBrowserViewModelTests: XCTestCase {
    @MainActor
    func testRefreshPreparesOnlySelectedVideoAndLookaheadWindow() async throws {
        let inputRootURL = try makeTemporaryDirectory()
        let defaults = try makeIsolatedDefaults()
        let videoPreparer = RecordingVideoPreparer()

        defer {
            try? FileManager.default.removeItem(at: inputRootURL)
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        for index in 1...6 {
            let videoURL = inputRootURL.appendingPathComponent("\(index).mp4")
            XCTAssertTrue(FileManager.default.createFile(atPath: videoURL.path, contents: Data()))
        }

        let viewModel = VideoBrowserViewModel(
            defaults: defaults,
            inputVideoResampler: videoPreparer
        )
        viewModel.inputFolderPath = inputRootURL.path
        viewModel.refreshVideos()

        try await waitUntil(timeout: 1.0) {
            await videoPreparer.requestedSourceURLs().count >= 3
        }
        try await Task.sleep(for: .milliseconds(100))

        let preparedNames = await videoPreparer.requestedSourceURLs()
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(preparedNames, ["1.mp4", "2.mp4", "3.mp4"])
        XCTAssertEqual(viewModel.mediaItems.count, 6)
        XCTAssertEqual(viewModel.selectedMediaURL?.lastPathComponent, "1.mp4")
    }

    @MainActor
    func testRememberLastExportPersistsCaptionAndCategories() throws {
        let defaults = try makeIsolatedDefaults()

        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let viewModel = VideoBrowserViewModel(
            defaults: defaults,
            inputVideoResampler: RecordingVideoPreparer()
        )

        viewModel.rememberLastExport(
            input: DatasetRowInput(
                caption: "a caption",
                categories: ["cat", "studio"]
            )
        )

        XCTAssertEqual(viewModel.lastExportCaption, "a caption")
        XCTAssertEqual(viewModel.lastExportCategoryText, "cat\nstudio")

        let reloadedViewModel = VideoBrowserViewModel(
            defaults: defaults,
            inputVideoResampler: RecordingVideoPreparer()
        )

        XCTAssertEqual(reloadedViewModel.lastExportCaption, "a caption")
        XCTAssertEqual(reloadedViewModel.lastExportCategoryText, "cat\nstudio")
    }

    private var defaultsSuiteName: String {
        "VideoBrowserViewModelTests-\(name)"
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw XCTSkip("Unable to create isolated defaults suite.")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition.")
    }
}

private actor RecordingVideoPreparer: InputVideoPreparing {
    private var requestedURLs: [URL] = []

    func preparedURL(for sourceURL: URL) async throws -> URL {
        requestedURLs.append(sourceURL)
        return sourceURL
    }

    func requestedSourceURLs() -> [URL] {
        requestedURLs
    }
}
