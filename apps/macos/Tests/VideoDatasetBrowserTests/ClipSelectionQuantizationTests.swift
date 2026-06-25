import XCTest
@testable import VideoDatasetBrowser

final class ClipSelectionQuantizationTests: XCTestCase {
    func testAllowsOnlyOnePlusEightFrameCounts() {
        XCTAssertFalse(ClipSelectionQuantization.isQuantized(5))
        XCTAssertTrue(ClipSelectionQuantization.isQuantized(9))
        XCTAssertFalse(ClipSelectionQuantization.isQuantized(13))
        XCTAssertTrue(ClipSelectionQuantization.isQuantized(17))
        XCTAssertTrue(ClipSelectionQuantization.isQuantized(25))
        XCTAssertTrue(ClipSelectionQuantization.isQuantized(33))
        XCTAssertTrue(ClipSelectionQuantization.isQuantized(41))
    }

    func testQuantizeDownUsesNearestAllowedFrameCount() {
        XCTAssertEqual(ClipSelectionQuantization.quantizeDown(8), 8)
        XCTAssertEqual(ClipSelectionQuantization.quantizeDown(16), 9)
        XCTAssertEqual(ClipSelectionQuantization.quantizeDown(24), 17)
        XCTAssertEqual(ClipSelectionQuantization.quantizeDown(41), 41)
        XCTAssertEqual(ClipSelectionQuantization.quantizeDown(100), 97)
    }

    func testResolveFrameCountCapsOnlyAtAvailableFrames() {
        XCTAssertEqual(
            ClipSelectionQuantization.resolveFrameCount(requested: 100, maxAvailable: 200),
            97
        )
        XCTAssertEqual(
            ClipSelectionQuantization.resolveFrameCount(requested: 100, maxAvailable: 25),
            25
        )
        XCTAssertEqual(
            ClipSelectionQuantization.resolveFrameCount(requested: 6, maxAvailable: 6),
            6
        )
    }

    func testQuantizedOutFrameAllowsSelectionsLongerThanThirtyThreeFrames() {
        XCTAssertEqual(
            ClipSelectionQuantization.quantizedOutFrame(
                inFrame: 10,
                requestedOutFrame: 80,
                maxOutFrame: 100
            ),
            74
        )
    }
}
