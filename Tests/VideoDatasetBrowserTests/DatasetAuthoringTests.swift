import CoreGraphics
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

    func testFlatRowsLoadSuccessfully() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [
            rawFlatRow(caption: "first", mediaPath: "positive/1.mp4"),
            rawFlatRow(caption: "second", mediaPath: "positive/2.png", extras: ["source_id": "abc123"])
        ]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let rows = try DatasetStore(datasetRootURL: rootURL).loadRows()
        XCTAssertEqual(rows.map(\.caption), ["first", "second"])
        XCTAssertEqual(rows.map(\.mediaPath), ["positive/1.mp4", "positive/2.png"])
        XCTAssertEqual(rows[1].extras["source_id"], .string("abc123"))
    }

    func testLegacyRowsLoadAndDiscardLegacyFieldsWithoutValidatingNSync() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [[
            "caption": "legacy row",
            "media_path": "positive/1.mp4",
            "source_id": "abc123",
            "nsync": "definitely-not-an-object",
            "negative_caption": "old negative",
            "negative_media_path": "positive/old.mp4"
        ]]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let rows = try DatasetStore(datasetRootURL: rootURL).loadRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].caption, "legacy row")
        XCTAssertEqual(rows[0].mediaPath, "positive/1.mp4")
        XCTAssertEqual(rows[0].extras["source_id"], .string("abc123"))
        XCTAssertNil(rows[0].extras["nsync"])
        XCTAssertNil(rows[0].extras["negative_caption"])
        XCTAssertNil(rows[0].extras["negative_media_path"])
    }

    func testBlankCaptionAndMediaPathAreRejected() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let datasetURL = rootURL.appendingPathComponent("dataset.json")

        try writeJSONObject(
            [rawFlatRow(caption: "   ", mediaPath: "positive/1.mp4")],
            to: datasetURL
        )

        let store = DatasetStore(datasetRootURL: rootURL)
        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .blankString(row: 0, key: "caption"))
        }

        try writeJSONObject(
            [rawFlatRow(caption: "valid", mediaPath: "  \n")],
            to: datasetURL
        )

        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .blankString(row: 0, key: "media_path"))
        }
    }

    func testCollapsedSamplePathDuplicatesAreRejected() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [
            rawFlatRow(caption: "first", mediaPath: "positive/1.mp4"),
            rawFlatRow(caption: "second", mediaPath: "positive/1.mov")
        ]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let store = DatasetStore(datasetRootURL: rootURL)
        XCTAssertThrowsError(try store.loadRows()) { error in
            XCTAssertEqual(error as? DatasetStoreError, .duplicateSamplePath(path: "positive/1.pt"))
        }
    }

    func testAppendMigratesLegacyRowsAndRewritesJSONArray() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let dataset: [Any] = [[
            "caption": "existing",
            "media_path": "positive/1.mp4",
            "source_id": "abc123",
            "nsync": rawNSyncObject(),
            "negative_caption": "old negative",
            "negative_media_path": "positive/old.mp4"
        ]]
        try writeJSONObject(dataset, to: rootURL.appendingPathComponent("dataset.json"))

        let store = DatasetStore(datasetRootURL: rootURL)
        let preparedAppend = try store.prepareAppend(input: sampleInput(caption: "new row"))
        try store.commit(preparedAppend)

        let loadedRows = try store.loadRows()
        XCTAssertEqual(loadedRows.count, 2)
        XCTAssertEqual(loadedRows[0].extras["source_id"], .string("abc123"))
        XCTAssertEqual(loadedRows[1].mediaPath, "positive/2.mp4")

        let rawJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: rootURL.appendingPathComponent("dataset.json"))
        )
        guard let rawArray = rawJSON as? [[String: Any]] else {
            return XCTFail("dataset.json should remain a top-level array of objects.")
        }

        XCTAssertEqual(rawArray.count, 2)
        XCTAssertNil(rawArray[0]["nsync"])
        XCTAssertNil(rawArray[0]["negative_caption"])
        XCTAssertNil(rawArray[0]["negative_media_path"])
        XCTAssertEqual(rawArray[0]["source_id"] as? String, "abc123")
        XCTAssertNil(rawArray[1]["nsync"])
        XCTAssertEqual(rawArray[1]["caption"] as? String, "new row")
        XCTAssertEqual(rawArray[1]["media_path"] as? String, "positive/2.mp4")
    }

    func testPrepareAppendUsesNextMixedMediaIndexAndRequestedExtension() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("positive", isDirectory: true),
            withIntermediateDirectories: true
        )

        let existingDataset: [Any] = [
            rawFlatRow(caption: "existing", mediaPath: "positive/2.mp4")
        ]
        try writeJSONObject(existingDataset, to: rootURL.appendingPathComponent("dataset.json"))
        try Data("image".utf8).write(to: rootURL.appendingPathComponent("positive/3.png"))

        let store = DatasetStore(datasetRootURL: rootURL)
        let preparedAppend = try store.prepareAppend(
            input: sampleInput(caption: "new row"),
            mediaFileExtension: "png"
        )

        XCTAssertEqual(preparedAppend.rows.last?.mediaPath, "positive/4.png")
        XCTAssertEqual(preparedAppend.outputMediaURL.lastPathComponent, "4.png")
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

    func testImageExportUsesPNGMediaPath() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let service = makeAuthoringService()
        let outputURL = try await service.exportClip(
            request: dummyImageRequest(),
            input: sampleInput(caption: "image row"),
            datasetRootURL: rootURL
        )

        XCTAssertEqual(outputURL.lastPathComponent, "1.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("positive/1.png").path))

        let rows = try DatasetStore(datasetRootURL: rootURL).loadRows()
        XCTAssertEqual(rows.map(\.mediaPath), ["positive/1.png"])
        XCTAssertEqual(rows.map(\.caption), ["image row"])
    }

    func testValidationFailureDoesNotMutateDatasetFile() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let invalidDataset: [Any] = [[
            "caption": "invalid"
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
            XCTAssertEqual(error as? DatasetStoreError, .missingString(row: 0, key: "media_path"))
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

    private func rawFlatRow(
        caption: String,
        mediaPath: String,
        extras: [String: Any] = [:]
    ) -> [String: Any] {
        var row: [String: Any] = [
            "caption": caption,
            "media_path": mediaPath
        ]
        for (key, value) in extras {
            row[key] = value
        }
        return row
    }

    private func rawNSyncObject() -> [String: Any] {
        [
            "categories": ["cat", "studio"],
            "negatives": [[
                "media": "synthetic",
                "caption": "negative caption",
                "prompt": "negative prompt"
            ]],
            "anchors": [[
                "required_categories": ["cat", "studio"]
            ]]
        ]
    }

    private func sampleInput(caption: String) -> DatasetRowInput {
        DatasetRowInput(caption: caption)
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

    private func dummyImageRequest() -> ClipExportRequest {
        ClipExportRequest(
            imageURL: URL(fileURLWithPath: "/tmp/source.png"),
            cropRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            imageSize: CGSize(width: 64, height: 64)
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
