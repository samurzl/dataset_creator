import Foundation
import XCTest
@testable import VideoDatasetBrowser

final class DatasetAuthoringTests: XCTestCase {
    func testDatasetFileMustBeTopLevelArray() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeJSONObject(["caption": "not-an-array"], to: rootURL.appendingPathComponent("dataset.json"))

        let store = DatasetStore(datasetRootURL: rootURL)
        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .datasetFileNotArray)
        }
    }

    func testMissingNSyncOnAnyRowIsRejected() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [
            rawRow(caption: "first", mediaPath: "positive/1.mp4"),
            [
                "caption": "second",
                "media_path": "positive/2.mp4"
            ]
        ]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let store = DatasetStore(datasetRootURL: rootURL)
        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .missingNSync(row: 1))
        }
    }

    func testLegacyNegativeColumnsAreRejected() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [[
            "caption": "first",
            "media_path": "positive/1.mp4",
            "negative_caption": "legacy",
            "nsync": rawNSyncObject()
        ]]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let store = DatasetStore(datasetRootURL: rootURL)
        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .legacyNegativeColumn(row: 0, key: "negative_caption"))
        }
    }

    func testCategoriesAndAnchorCategoriesAreDeduplicatedPreservingFirstOccurrence() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let store = DatasetStore(datasetRootURL: rootURL)
        let preparedAppend = try store.prepareAppend(
            input: DatasetRowInput(
                caption: "caption",
                nsync: DatasetNSync(
                    categories: ["cat", "studio", "cat", "cinematic", "studio"],
                    negatives: [DatasetNegative(media: .positive, caption: "negative caption")],
                    anchors: [
                        DatasetAnchor(
                            requiredCategories: ["studio", "cat", "studio", "cat", "cinematic"],
                            extraRandomCategory: true
                        )
                    ]
                )
            )
        )

        XCTAssertEqual(preparedAppend.rows.count, 1)
        XCTAssertEqual(preparedAppend.rows[0].nsync.categories, ["cat", "studio", "cinematic"])
        XCTAssertEqual(preparedAppend.rows[0].nsync.anchors[0].requiredCategories, ["studio", "cat", "cinematic"])
    }

    func testQuickExportInputBuildsDerivedNSyncTemplate() {
        let input = DatasetRowInput(
            caption: "original caption",
            categories: ["cat", "studio"]
        )

        XCTAssertEqual(input.caption, "original caption")
        XCTAssertEqual(input.nsync.categories, ["cat", "studio"])
        XCTAssertEqual(
            input.nsync.negatives,
            [
                DatasetNegative(
                    media: .synthetic,
                    caption: "original caption",
                    prompt: "original caption"
                )
            ]
        )
        XCTAssertEqual(
            input.nsync.anchors,
            [
                DatasetAnchor(requiredCategories: ["cat"], extraRandomCategory: false),
                DatasetAnchor(requiredCategories: ["studio"], extraRandomCategory: false)
            ]
        )
    }

    func testSyntheticPromptRequiredAndPositivePromptForbidden() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try writeJSONObject(
            [
                rawRow(
                    caption: "synthetic missing prompt",
                    mediaPath: "positive/1.mp4",
                    negatives: [[
                        "media": "synthetic",
                        "caption": "negative caption"
                    ]]
                )
            ],
            to: rootURL.appendingPathComponent("dataset.json")
        )

        let store = DatasetStore(datasetRootURL: rootURL)
        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .missingNegativePrompt(row: 0, index: 0))
        }

        try writeJSONObject(
            [
                rawRow(
                    caption: "positive with prompt",
                    mediaPath: "positive/1.mp4",
                    negatives: [[
                        "media": "positive",
                        "caption": "negative caption",
                        "prompt": "forbidden"
                    ]]
                )
            ],
            to: rootURL.appendingPathComponent("dataset.json")
        )

        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .forbiddenNegativePrompt(row: 0, index: 0))
        }
    }

    func testCollapsedSamplePathDuplicatesAreRejected() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [
            rawRow(caption: "first", mediaPath: "positive/1.mp4"),
            rawRow(caption: "second", mediaPath: "positive/1.mov")
        ]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let store = DatasetStore(datasetRootURL: rootURL)
        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .duplicateSamplePath(path: "positive/1.pt"))
        }
    }

    func testAppendPreservesExistingRowsAndRewritesJSONArray() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [[
            "caption": "existing",
            "media_path": "positive/1.mp4",
            "source_id": "abc123",
            "nsync": rawNSyncObject()
        ]]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let store = DatasetStore(datasetRootURL: rootURL)
        let preparedAppend = try store.prepareAppend(input: sampleInput(caption: "new row"))
        try store.commit(preparedAppend)

        let loadedRows = try store.loadRows()
        XCTAssertEqual(loadedRows.count, 2)
        XCTAssertEqual(loadedRows[0].extras["source_id"], .string("abc123"))
        XCTAssertEqual(loadedRows[1].mediaPath, "positive/2.mp4")

        let rawJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: rootURL.appendingPathComponent("dataset.json")))
        guard let rawArray = rawJSON as? [Any] else {
            return XCTFail("dataset.json should remain a top-level array.")
        }
        XCTAssertEqual(rawArray.count, 2)
    }

    func testFirstAndSecondExportsCreateNumberedPositiveClipsAndAppendDataset() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let service = makeAuthoringService()
        let request = dummyRequest()

        let firstURL = try await service.exportClip(
            request: request,
            input: sampleInput(caption: "first row"),
            datasetRootURL: rootURL
        )
        let secondURL = try await service.exportClip(
            request: request,
            input: sampleInput(caption: "second row"),
            datasetRootURL: rootURL
        )

        XCTAssertEqual(firstURL.lastPathComponent, "1.mp4")
        XCTAssertEqual(secondURL.lastPathComponent, "2.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("positive/1.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("positive/2.mp4").path))

        let rows = try DatasetStore(datasetRootURL: rootURL).loadRows()
        XCTAssertEqual(rows.map(\.mediaPath), ["positive/1.mp4", "positive/2.mp4"])
        XCTAssertEqual(rows.map(\.caption), ["first row", "second row"])
    }

    func testValidationFailureDoesNotMutateDatasetFile() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let invalidDataset: [Any] = [[
            "caption": "invalid",
            "media_path": "positive/1.mp4"
        ]]
        let datasetURL = rootURL.appendingPathComponent("dataset.json")
        try writeJSONObject(invalidDataset, to: datasetURL)
        let originalData = try Data(contentsOf: datasetURL)

        let service = makeAuthoringService()

        do {
            _ = try await service.exportClip(
                request: dummyRequest(),
                input: sampleInput(caption: "new row"),
                datasetRootURL: rootURL
            )
            XCTFail("Expected export to fail when the existing dataset is invalid.")
        } catch {
            XCTAssertEqual(error as? DatasetStoreError, .missingNSync(row: 0))
        }

        XCTAssertEqual(try Data(contentsOf: datasetURL), originalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("positive/1.mp4").path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJSONObject(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func rawRow(
        caption: String,
        mediaPath: String,
        negatives: [[String: Any]]? = nil
    ) -> [String: Any] {
        [
            "caption": caption,
            "media_path": mediaPath,
            "nsync": rawNSyncObject(negatives: negatives)
        ]
    }

    private func rawNSyncObject(negatives: [[String: Any]]? = nil) -> [String: Any] {
        [
            "categories": ["cat", "studio"],
            "negatives": negatives ?? [[
                "media": "positive",
                "caption": "negative caption"
            ]],
            "anchors": [[
                "required_categories": ["cat", "studio"]
            ]]
        ]
    }

    private func sampleInput(caption: String) -> DatasetRowInput {
        DatasetRowInput(
            caption: caption,
            nsync: DatasetNSync(
                categories: ["cat", "studio"],
                negatives: [DatasetNegative(media: .positive, caption: "negative caption")],
                anchors: [DatasetAnchor(requiredCategories: ["cat"], extraRandomCategory: true)]
            )
        )
    }

    private func dummyRequest() -> ClipExportRequest {
        ClipExportRequest(
            videoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            inFrame: 0,
            frameCount: 5,
            frameRate: 16,
            aspectRatio: 1
        )
    }

    private func makeAuthoringService() -> DatasetAuthoringService {
        DatasetAuthoringService(
            fileManager: .default,
            clipExportOperation: { _, outputURL in
                try Data("video".utf8).write(to: outputURL)
                return outputURL
            }
        )
    }
}
