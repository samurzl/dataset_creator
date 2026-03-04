import AVFoundation
import CoreGraphics
import Foundation

@MainActor
final class VideoPlayerController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentFrame: Int = 0
    @Published private(set) var totalFrames: Int = 1
    @Published private(set) var inFrame: Int = 0
    @Published private(set) var outFrame: Int = 0
    @Published private(set) var isScrubbing = false
    @Published private(set) var isLoopPlaying = false
    @Published private(set) var videoAspectRatio: CGFloat = 16.0 / 9.0

    var currentFrameRate: Double {
        frameRate
    }

    var selectedFrameCount: Int {
        guard totalFrames > 0 else { return 0 }
        return max(outFrame - inFrame + 1, 1)
    }

    var selectedDurationSeconds: Double {
        guard frameRate > 0 else { return 0 }
        return Double(selectedFrameCount) / frameRate
    }

    var quantizedSelectedFrameCount: Int {
        ClipSelectionQuantization.quantizeDown(selectedFrameCount)
    }

    private var timeObserverToken: Any?
    private var activeURL: URL?
    private var durationSeconds: Double = 0
    private var frameRate: Double = 30
    private var isRangeMarkerDragging = false

    init() {
        installPeriodicTimeObserver()
    }

    func loadVideo(at url: URL) {
        guard activeURL != url else { return }

        activeURL = url
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.pause()

        currentFrame = 0
        totalFrames = 1
        inFrame = 0
        outFrame = 0
        durationSeconds = 0
        frameRate = 30
        videoAspectRatio = 16.0 / 9.0
        isLoopPlaying = false
        isRangeMarkerDragging = false

        applyMetadata(from: item)
        inFrame = 0
        outFrame = max(totalFrames - 1, 0)
        applyQuantizedSelection(requestedFrameCount: totalFrames)
        seek(toFrame: 0)
    }

    func clearVideo() {
        activeURL = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentFrame = 0
        totalFrames = 1
        inFrame = 0
        outFrame = 0
        durationSeconds = 0
        frameRate = 30
        videoAspectRatio = 16.0 / 9.0
        isScrubbing = false
        isLoopPlaying = false
        isRangeMarkerDragging = false
    }

    func beginScrubbing() {
        isScrubbing = true
        stopLoopPlayback()
        player.pause()
    }

    func beginRangeMarkerDrag() {
        if !isRangeMarkerDragging {
            isRangeMarkerDragging = true
            isScrubbing = false
            stopLoopPlayback()
        }
        player.pause()
    }

    func dragInMarker(toFrame frameValue: Double) {
        let previousIn = inFrame
        let requestedFrameCount = selectedFrameCount
        let frameIndex = clampedFrameIndex(Int(frameValue.rounded()))
        inFrame = min(frameIndex, max(totalFrames - 1, 0))
        applyQuantizedSelection(requestedFrameCount: requestedFrameCount)

        if currentFrame < inFrame, currentFrame >= previousIn {
            currentFrame = inFrame
        }

        if currentFrame > outFrame {
            currentFrame = outFrame
        }

        preview(markerFrame: inFrame)
    }

    func dragOutMarker(toFrame frameValue: Double) {
        let previousOut = outFrame
        let requestedOutFrame = clampedFrameIndex(Int(frameValue.rounded()))
        outFrame = ClipSelectionQuantization.quantizedOutFrame(
            inFrame: inFrame,
            requestedOutFrame: max(requestedOutFrame, inFrame),
            maxOutFrame: max(totalFrames - 1, 0)
        )

        if currentFrame > outFrame, currentFrame <= previousOut {
            currentFrame = outFrame
        }

        preview(markerFrame: outFrame)
    }

    func endRangeMarkerDrag() {
        guard isRangeMarkerDragging else { return }
        isRangeMarkerDragging = false
        seek(toFrame: currentFrame, updateCurrentFrame: false)
    }

    func scrub(toFrame frameValue: Double) {
        let frameIndex = Int(frameValue.rounded())
        seek(toFrame: frameIndex)
    }

    func endScrubbing() {
        isScrubbing = false
        seek(toFrame: currentFrame)
    }

    func toggleLoopPlayback() {
        isLoopPlaying ? stopLoopPlayback() : startLoopPlayback()
    }

    private func startLoopPlayback() {
        guard player.currentItem != nil, totalFrames > 1 else { return }
        isRangeMarkerDragging = false
        isScrubbing = false
        isLoopPlaying = true

        let loopStart: Int
        if currentFrame < inFrame || currentFrame > outFrame {
            loopStart = inFrame
        } else {
            loopStart = currentFrame
        }
        currentFrame = loopStart
        seek(toFrame: loopStart, updateCurrentFrame: false)
        player.play()
    }

    private func stopLoopPlayback() {
        guard isLoopPlaying else { return }
        isLoopPlaying = false
        player.pause()
    }

    private func applyMetadata(from item: AVPlayerItem) {
        if let track = item.asset.tracks(withMediaType: .video).first {
            let nominalRate = Double(track.nominalFrameRate)
            if nominalRate.isFinite, nominalRate > 0 {
                frameRate = nominalRate
            }

            let transformedSize = track.naturalSize.applying(track.preferredTransform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            if width > 0, height > 0 {
                videoAspectRatio = width / height
            }
        }

        let assetDuration = item.asset.duration.safeSeconds
        let itemDuration = item.duration.safeSeconds
        if assetDuration > 0 {
            durationSeconds = assetDuration
        } else if itemDuration > 0 {
            durationSeconds = itemDuration
        }

        recomputeFrameCount()
    }

    private func installPeriodicTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let itemDuration = self.player.currentItem?.duration.safeSeconds,
                   itemDuration.isFinite,
                   itemDuration > 0,
                   itemDuration != self.durationSeconds {
                    self.durationSeconds = itemDuration
                    self.recomputeFrameCount()
                }

                let currentSeconds = max(time.safeSeconds, 0)
                let observedFrame = self.frameIndex(for: currentSeconds)

                if self.isLoopPlaying, observedFrame >= self.outFrame {
                    self.seek(toFrame: self.inFrame)
                    self.player.play()
                    return
                }

                guard !self.isScrubbing, !self.isRangeMarkerDragging else { return }

                self.currentFrame = observedFrame
            }
        }
    }

    private func recomputeFrameCount() {
        let previousMax = max(totalFrames - 1, 0)

        guard durationSeconds > 0, frameRate > 0 else {
            totalFrames = 1
            currentFrame = 0
            inFrame = 0
            outFrame = 0
            return
        }

        totalFrames = max(Int((durationSeconds * frameRate).rounded(.up)), 1)
        let newMax = max(totalFrames - 1, 0)

        currentFrame = min(currentFrame, newMax)
        inFrame = min(max(inFrame, 0), newMax)
        let requestedSelectionCount = outFrame == previousMax
            ? totalFrames
            : max(outFrame - inFrame + 1, 1)
        applyQuantizedSelection(requestedFrameCount: requestedSelectionCount)
    }

    private func frameIndex(for seconds: Double) -> Int {
        guard frameRate > 0 else { return 0 }
        let index = Int((seconds * frameRate).rounded())
        return clampedFrameIndex(index)
    }

    private func preview(markerFrame: Int) {
        seek(toFrame: markerFrame, updateCurrentFrame: false)
    }

    private func clampedFrameIndex(_ index: Int) -> Int {
        min(max(index, 0), max(totalFrames - 1, 0))
    }

    private func applyQuantizedSelection(requestedFrameCount: Int) {
        let maxOutFrame = max(totalFrames - 1, 0)
        let availableFrameCount = max(maxOutFrame - inFrame + 1, 0)
        let resolvedCount = ClipSelectionQuantization.resolveFrameCount(
            requested: requestedFrameCount,
            maxAvailable: availableFrameCount
        )

        outFrame = min(inFrame + max(resolvedCount - 1, 0), maxOutFrame)
    }

    private func seek(toFrame frameIndex: Int, updateCurrentFrame: Bool = true) {
        let bounded = clampedFrameIndex(frameIndex)
        if updateCurrentFrame {
            currentFrame = bounded
        }

        guard frameRate > 0 else { return }

        let targetSeconds = min(max(Double(bounded) / frameRate, 0), durationSeconds)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

private extension CMTime {
    var safeSeconds: Double {
        let seconds = self.seconds
        return seconds.isFinite ? seconds : 0
    }
}
