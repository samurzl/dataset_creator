import Dispatch
import Foundation

struct OperationDeadline {
    private let deadlineUptimeNanoseconds: UInt64

    init(
        timeoutSeconds: Double,
        startUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let clampedTimeoutSeconds = max(timeoutSeconds, 0)
        let timeoutNanoseconds = UInt64((clampedTimeoutSeconds * 1_000_000_000).rounded(.up))
        deadlineUptimeNanoseconds = startUptimeNanoseconds &+ timeoutNanoseconds
    }

    func hasExpired(
        currentUptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        currentUptimeNanoseconds >= deadlineUptimeNanoseconds
    }
}
