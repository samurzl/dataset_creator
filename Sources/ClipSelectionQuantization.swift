import Foundation

enum ClipSelectionQuantization {
    static let minimumFrameCount = 5
    static let step = 4

    static func isQuantized(_ frameCount: Int) -> Bool {
        guard frameCount >= minimumFrameCount else { return false }
        return (frameCount - minimumFrameCount).isMultiple(of: step)
    }

    static func quantizeDown(_ frameCount: Int) -> Int {
        guard frameCount >= minimumFrameCount else { return frameCount }
        return minimumFrameCount + ((frameCount - minimumFrameCount) / step) * step
    }

    static func resolveFrameCount(requested: Int, maxAvailable: Int) -> Int {
        guard maxAvailable > 0 else { return 0 }

        if maxAvailable < minimumFrameCount {
            return maxAvailable
        }

        let bounded = min(max(requested, minimumFrameCount), maxAvailable)
        return quantizeDown(bounded)
    }

    static func quantizedOutFrame(inFrame: Int, requestedOutFrame: Int, maxOutFrame: Int) -> Int {
        let available = max(maxOutFrame - inFrame + 1, 0)
        guard available > 0 else { return inFrame }

        let requestedCount = max(requestedOutFrame - inFrame + 1, 1)
        let resolvedCount = resolveFrameCount(requested: requestedCount, maxAvailable: available)
        return min(inFrame + max(resolvedCount - 1, 0), maxOutFrame)
    }
}
