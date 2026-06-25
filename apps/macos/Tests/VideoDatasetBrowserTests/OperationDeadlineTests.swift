import XCTest
@testable import VideoDatasetBrowser

final class OperationDeadlineTests: XCTestCase {
    func testDeadlineDoesNotExpireBeforeBoundary() {
        let deadline = OperationDeadline(timeoutSeconds: 1, startUptimeNanoseconds: 100)

        XCTAssertFalse(deadline.hasExpired(currentUptimeNanoseconds: 1_000_000_099))
    }

    func testDeadlineExpiresAtBoundary() {
        let deadline = OperationDeadline(timeoutSeconds: 1, startUptimeNanoseconds: 100)

        XCTAssertTrue(deadline.hasExpired(currentUptimeNanoseconds: 1_000_000_100))
    }

    func testZeroTimeoutExpiresImmediately() {
        let deadline = OperationDeadline(timeoutSeconds: 0, startUptimeNanoseconds: 42)

        XCTAssertTrue(deadline.hasExpired(currentUptimeNanoseconds: 42))
    }
}
