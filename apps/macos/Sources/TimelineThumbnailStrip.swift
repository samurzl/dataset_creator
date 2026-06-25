import AVFoundation
import AppKit
import SwiftUI

struct TimelineThumbnailStrip: View {
    let videoURL: URL?
    @ObservedObject var playerController: VideoPlayerController

    @StateObject private var thumbnailStore = TimelineThumbnailStore()
    @State private var isScrubbing = false
    @State private var activeDragTarget: DragTarget?

    private enum MarkerKind {
        case inPoint
        case outPoint
    }

    private enum DragTarget {
        case playhead
        case inPoint
        case outPoint
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let slotCount = thumbnailSlotCount(for: size.width)
            let frames = thumbnailStore.displayFrames(expectedCount: slotCount)
            let inMarkerX = markerX(for: playerController.inFrame, width: size.width)
            let outMarkerX = markerX(for: playerController.outFrame, width: size.width)
            let playheadMarkerX = markerX(for: playerController.currentFrame, width: size.width)

            ZStack(alignment: .leading) {
                frameStrip(frames: frames, size: size)

                shadedOutsideRange(inMarkerX: inMarkerX, outMarkerX: outMarkerX, size: size)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)

                markerBar(kind: .inPoint, xPosition: inMarkerX, size: size)
                markerBar(kind: .outPoint, xPosition: outMarkerX, size: size)

                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: max(size.height - 2, 1))
                    .offset(x: playheadLineX(forMarkerX: playheadMarkerX, width: size.width))
                    .shadow(color: Color.red.opacity(0.5), radius: 2)
            }
            .coordinateSpace(name: "timeline-strip")
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(timelineDragGesture(width: size.width))
            .task(id: TimelineThumbnailRequest(url: videoURL, count: slotCount, pixelHeight: pixelHeight(for: size.height))) {
                thumbnailStore.requestThumbnails(
                    for: videoURL,
                    count: slotCount,
                    pixelHeight: pixelHeight(for: size.height)
                )
            }
            .onChange(of: videoURL) { _ in
                isScrubbing = false
                activeDragTarget = nil
            }
        }
        .frame(height: 86)
    }

    private func frameStrip(frames: [NSImage?], size: CGSize) -> some View {
        let frameCount = max(frames.count, 1)
        let segmentWidth = max(size.width / CGFloat(frameCount), 1)

        return HStack(spacing: 0) {
            ForEach(Array(frames.enumerated()), id: \.offset) { index, image in
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        placeholderFrame(for: index)
                    }
                }
                .frame(width: segmentWidth, height: size.height)
                .clipped()
            }
        }
        .frame(width: size.width, height: size.height, alignment: .leading)
        .background(Color.black.opacity(0.6))
    }

    private func placeholderFrame(for index: Int) -> some View {
        let opacity = 0.28 + (Double(index % 5) * 0.03)
        return LinearGradient(
            colors: [
                Color.white.opacity(opacity),
                Color.white.opacity(opacity * 0.5)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func shadedOutsideRange(inMarkerX: CGFloat, outMarkerX: CGFloat, size: CGSize) -> some View {
        let leftWidth = min(max(inMarkerX, 0), size.width)
        let rightOrigin = min(max(outMarkerX, 0), size.width)
        let rightWidth = max(size.width - rightOrigin, 0)

        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: leftWidth, height: size.height)

            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: rightWidth, height: size.height)
                .offset(x: rightOrigin)
        }
    }

    private func markerBar(kind: MarkerKind, xPosition: CGFloat, size: CGSize) -> some View {
        let barWidth: CGFloat = 6
        let barOffset = min(max(xPosition - (barWidth / 2), 0), max(size.width - barWidth, 0))
        let markerLabel = kind == .inPoint ? "IN" : "OUT"

        return Rectangle()
            .fill(Color.black.opacity(0.96))
            .overlay(
                Text(markerLabel)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .offset(y: 3),
                alignment: .top
            )
            .frame(width: barWidth, height: max(size.height - 2, 1))
            .offset(x: barOffset)
    }

    private func timelineDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline-strip"))
            .onChanged { value in
                guard playerController.totalFrames > 1 else { return }

                if activeDragTarget == nil {
                    activeDragTarget = nearestDragTarget(at: value.startLocation.x, width: width)
                    guard let selectedDragTarget = activeDragTarget else { return }

                    switch selectedDragTarget {
                    case .playhead:
                        isScrubbing = true
                        playerController.beginScrubbing()
                    case .inPoint, .outPoint:
                        if isScrubbing {
                            playerController.endScrubbing()
                            isScrubbing = false
                        }
                        playerController.beginRangeMarkerDrag()
                    }
                }

                let targetFrame = frameValue(for: value.location.x, width: width)
                switch activeDragTarget {
                case .playhead:
                    playerController.scrub(toFrame: targetFrame)
                case .inPoint:
                    playerController.dragInMarker(toFrame: targetFrame)
                case .outPoint:
                    playerController.dragOutMarker(toFrame: targetFrame)
                case .none:
                    break
                }
            }
            .onEnded { value in
                guard playerController.totalFrames > 1 else {
                    isScrubbing = false
                    activeDragTarget = nil
                    return
                }

                guard let selectedDragTarget = activeDragTarget else { return }

                let targetFrame = frameValue(for: value.location.x, width: width)
                switch selectedDragTarget {
                case .playhead:
                    playerController.scrub(toFrame: targetFrame)
                    if isScrubbing {
                        playerController.endScrubbing()
                    }
                    isScrubbing = false
                case .inPoint:
                    playerController.dragInMarker(toFrame: targetFrame)
                    playerController.endRangeMarkerDrag()
                case .outPoint:
                    playerController.dragOutMarker(toFrame: targetFrame)
                    playerController.endRangeMarkerDrag()
                }

                activeDragTarget = nil
            }
    }

    private func frameValue(for xPosition: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        let progress = min(max(xPosition / width, 0), 1)
        return progress * Double(max(playerController.totalFrames - 1, 0))
    }

    private func playheadLineX(forMarkerX markerX: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, playerController.totalFrames > 1 else { return 0 }
        return min(max(markerX - 1, 0), max(width - 2, 0))
    }

    private func markerX(for frameIndex: Int, width: CGFloat) -> CGFloat {
        guard width > 0, playerController.totalFrames > 1 else { return 0 }
        let progress = CGFloat(frameIndex) / CGFloat(max(playerController.totalFrames - 1, 1))
        return min(max(progress * width, 0), width)
    }

    private func nearestDragTarget(at xPosition: CGFloat, width: CGFloat) -> DragTarget {
        let playheadX = markerX(for: playerController.currentFrame, width: width)
        let inMarkerX = markerX(for: playerController.inFrame, width: width)
        let outMarkerX = markerX(for: playerController.outFrame, width: width)

        let distances: [(DragTarget, CGFloat)] = [
            (.playhead, abs(xPosition - playheadX)),
            (.inPoint, abs(xPosition - inMarkerX)),
            (.outPoint, abs(xPosition - outMarkerX))
        ]

        return distances.min { lhs, rhs in
            if lhs.1 == rhs.1 {
                return priority(for: lhs.0) < priority(for: rhs.0)
            }
            return lhs.1 < rhs.1
        }?.0 ?? .playhead
    }

    private func priority(for target: DragTarget) -> Int {
        switch target {
        case .playhead:
            return 0
        case .inPoint:
            return 1
        case .outPoint:
            return 2
        }
    }

    private func thumbnailSlotCount(for width: CGFloat) -> Int {
        min(max(Int((width / 76).rounded(.up)), 6), 48)
    }

    private func pixelHeight(for height: CGFloat) -> Int {
        max(Int((height * 2).rounded()), 60)
    }
}

@MainActor
final class TimelineThumbnailStore: ObservableObject {
    @Published private(set) var thumbnails: [NSImage] = []

    private var generationTask: Task<Void, Never>?
    private var cache: [TimelineThumbnailRequest: [NSImage]] = [:]
    private var activeRequest: TimelineThumbnailRequest?

    deinit {
        generationTask?.cancel()
    }

    func requestThumbnails(for url: URL?, count: Int, pixelHeight: Int) {
        let request = TimelineThumbnailRequest(url: url, count: max(count, 1), pixelHeight: max(pixelHeight, 1))
        activeRequest = request

        guard let url else {
            generationTask?.cancel()
            thumbnails = []
            return
        }

        if let cachedFrames = cache[request] {
            thumbnails = cachedFrames
            return
        }

        generationTask?.cancel()
        thumbnails = []

        generationTask = Task.detached(priority: .utility) {
            let generatedFrames = await Self.generateThumbnails(for: url, request: request)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard self.activeRequest == request else { return }
                self.cache[request] = generatedFrames
                self.thumbnails = generatedFrames
            }
        }
    }

    func displayFrames(expectedCount: Int) -> [NSImage?] {
        let required = max(expectedCount, 1)

        if thumbnails.isEmpty {
            return Array(repeating: nil, count: required)
        }

        var result = thumbnails.map(Optional.some)
        if let last = thumbnails.last, result.count < required {
            while result.count < required {
                result.append(last)
            }
        } else if result.count > required {
            result = Array(result.prefix(required))
        }

        return result
    }

    nonisolated private static func generateThumbnails(for url: URL, request: TimelineThumbnailRequest) async -> [NSImage] {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: CGFloat(request.pixelHeight * 16 / 9),
            height: CGFloat(request.pixelHeight)
        )

        var frames: [NSImage] = []
        frames.reserveCapacity(request.count)

        for index in 0..<request.count {
            if Task.isCancelled {
                return []
            }

            let progress = Double(index) / Double(max(request.count - 1, 1))
            let timestamp = CMTime(seconds: durationSeconds * progress, preferredTimescale: 600)

            if let cgImage = try? generator.copyCGImage(at: timestamp, actualTime: nil) {
                frames.append(NSImage(cgImage: cgImage, size: .zero))
            }
        }

        if frames.count < request.count, let last = frames.last {
            while frames.count < request.count {
                frames.append(last)
            }
        }

        return frames
    }
}

private struct TimelineThumbnailRequest: Hashable {
    let url: URL?
    let count: Int
    let pixelHeight: Int
}
