import AudioToolbox
import AVFoundation
import AppKit
import CoreGraphics
import CoreVideo
import Foundation

struct ClipExportRequest: Identifiable {
    struct VideoSelection {
        let videoURL: URL
        let inFrame: Int
        let frameCount: Int
        let frameRate: Double
        let cropRect: CGRect?
    }

    struct ImageSelection {
        let imageURL: URL
        let cropRect: CGRect
        let imageSize: CGSize
    }

    enum Source {
        case video(VideoSelection)
        case image(ImageSelection)
    }

    let id = UUID()
    let source: Source
    let aspectRatio: CGFloat

    init(
        videoURL: URL,
        inFrame: Int,
        frameCount: Int,
        frameRate: Double,
        aspectRatio: CGFloat,
        cropRect: CGRect? = nil
    ) {
        let resolvedCropRect = cropRect?.standardized
        source = .video(
            VideoSelection(
                videoURL: videoURL,
                inFrame: inFrame,
                frameCount: frameCount,
                frameRate: frameRate,
                cropRect: resolvedCropRect
            )
        )

        if let resolvedCropRect {
            let width = max(resolvedCropRect.width, 1)
            let height = max(resolvedCropRect.height, 1)
            self.aspectRatio = width / height
        } else {
            self.aspectRatio = aspectRatio
        }
    }

    init(
        imageURL: URL,
        cropRect: CGRect,
        imageSize: CGSize
    ) {
        let resolvedCropRect = cropRect.standardized
        source = .image(
            ImageSelection(
                imageURL: imageURL,
                cropRect: resolvedCropRect,
                imageSize: imageSize
            )
        )

        let width = max(resolvedCropRect.width, 1)
        let height = max(resolvedCropRect.height, 1)
        aspectRatio = width / height
    }

    var isVideo: Bool {
        if case .video = source {
            return true
        }
        return false
    }

    var isImage: Bool {
        if case .image = source {
            return true
        }
        return false
    }

    var mediaFileExtension: String {
        switch source {
        case .video:
            return "mp4"
        case .image:
            return "png"
        }
    }

    var videoSelection: VideoSelection? {
        guard case let .video(selection) = source else { return nil }
        return selection
    }

    var imageSelection: ImageSelection? {
        guard case let .image(selection) = source else { return nil }
        return selection
    }

    var startSeconds: Double {
        guard let videoSelection else { return 0 }
        return Double(videoSelection.inFrame) / videoSelection.frameRate
    }

    var durationSeconds: Double {
        guard let videoSelection else { return 0 }
        return Double(videoSelection.frameCount) / videoSelection.frameRate
    }

    var videoURL: URL {
        guard let videoSelection else {
            preconditionFailure("Attempted to read a video URL from an image export request.")
        }
        return videoSelection.videoURL
    }

    var inFrame: Int {
        guard let videoSelection else {
            preconditionFailure("Attempted to read a video frame range from an image export request.")
        }
        return videoSelection.inFrame
    }

    var frameCount: Int {
        guard let videoSelection else {
            preconditionFailure("Attempted to read a video frame count from an image export request.")
        }
        return videoSelection.frameCount
    }

    var frameRate: Double {
        guard let videoSelection else {
            preconditionFailure("Attempted to read a video frame rate from an image export request.")
        }
        return videoSelection.frameRate
    }

    var videoCropRect: CGRect? {
        guard let videoSelection else { return nil }
        return videoSelection.cropRect
    }
}

enum ClipExportError: LocalizedError {
    case noMediaSelected
    case invalidFrameRate
    case invalidFrameCount
    case invalidImage
    case invalidImageCrop
    case missingVideoTrack
    case invalidSourceRange
    case failedToCreateCompositionTrack
    case failedToCreateWriterInput
    case failedToCreatePixelBuffer
    case failedToWriteImage
    case writerAppendFailed
    case writerFailed(underlying: Error?)
    case readerFailed(underlying: Error?)
    case frameExtractionFailed(frameIndex: Int)
    case frameCountMismatch(expected: Int, actual: Int)
    case timedOut(stage: String)
    case outputDirectoryMissing
    case outputFolderNotConfigured

    var errorDescription: String? {
        switch self {
        case .noMediaSelected:
            return "No media selected."
        case .invalidFrameRate:
            return "The video frame rate is invalid."
        case .invalidFrameCount:
            return "The selected clip length must follow 5, 9, 13, ... frames."
        case .invalidImage:
            return "The selected image could not be loaded."
        case .invalidImageCrop:
            return "The selected image crop is invalid."
        case .missingVideoTrack:
            return "No video track found in the selected source."
        case .invalidSourceRange:
            return "The selected range is outside the source video duration."
        case .failedToCreateCompositionTrack:
            return "Failed to create a temporary composition track."
        case .failedToCreateWriterInput:
            return "Failed to configure the clip writer."
        case .failedToCreatePixelBuffer:
            return "Failed to allocate a frame buffer for export."
        case .failedToWriteImage:
            return "Failed to write the cropped image."
        case .writerAppendFailed:
            return "Failed while writing the output clip."
        case let .writerFailed(underlying):
            return underlying?.localizedDescription ?? "The exporter failed to write the output clip."
        case let .readerFailed(underlying):
            return underlying?.localizedDescription ?? "Failed while validating exported frame count."
        case let .frameExtractionFailed(frameIndex):
            return "Could not extract source frame \(frameIndex)."
        case let .frameCountMismatch(expected, actual):
            return "Exported frame count mismatch. Expected \(expected), got \(actual)."
        case let .timedOut(stage):
            return "Export timed out while \(stage)."
        case .outputDirectoryMissing:
            return "Dataset folder does not exist."
        case .outputFolderNotConfigured:
            return "Set a dataset folder before exporting."
        }
    }
}

enum ClipExporter {
    private enum ExportTimingMode {
        case sourceRate
        case integerRate
    }

    private struct RasterizedImage {
        let cgImage: CGImage
        let pixelSize: CGSize
    }

    private struct VideoRenderConfiguration {
        let readerOutput: AVAssetReaderOutput
        let writerTransform: CGAffineTransform
    }

    private static let pollingIntervalNanoseconds: UInt64 = 1_000_000

    private struct AudioExportContext {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let writerInput: AVAssetWriterInput
    }

    private final class FinishWritingState: @unchecked Sendable {
        private let lock = NSLock()
        private var didFinish = false

        func markFinished() {
            lock.lock()
            didFinish = true
            lock.unlock()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didFinish
        }
    }

    @MainActor
    static func createPreviewItem(for request: ClipExportRequest) async throws -> AVPlayerItem {
        guard request.isVideo else {
            throw ClipExportError.invalidSourceRange
        }

        guard request.frameRate > 0 else {
            throw ClipExportError.invalidFrameRate
        }

        let asset = AVAsset(url: request.videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds

        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ClipExportError.invalidSourceRange
        }

        let startSeconds = request.startSeconds
        guard startSeconds < durationSeconds else {
            throw ClipExportError.invalidSourceRange
        }

        let safeDuration = min(request.durationSeconds, max(durationSeconds - startSeconds, 0))
        guard safeDuration > 0 else {
            throw ClipExportError.invalidSourceRange
        }

        let timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 60_000),
            duration: CMTime(seconds: safeDuration, preferredTimescale: 60_000)
        )

        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ClipExportError.missingVideoTrack
        }

        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ClipExportError.failedToCreateCompositionTrack
        }

        try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudioTrack = audioTracks.first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
        }

        let playerItem = AVPlayerItem(asset: composition)
        if let cropRect = request.videoCropRect {
            let previewTimeRange = CMTimeRange(start: .zero, duration: timeRange.duration)
            playerItem.videoComposition = try await makeVideoComposition(
                for: compositionVideoTrack,
                timeRange: previewTimeRange,
                cropRect: cropRect,
                frameRate: request.frameRate
            )
        }
        return playerItem
    }

    @MainActor
    static func createPreviewImage(for request: ClipExportRequest) throws -> NSImage {
        guard let imageSelection = request.imageSelection else {
            throw ClipExportError.invalidImage
        }

        let croppedImage = try makeCroppedImage(from: imageSelection)
        return NSImage(
            cgImage: croppedImage,
            size: NSSize(width: croppedImage.width, height: croppedImage.height)
        )
    }

    static func exportClip(
        request: ClipExportRequest,
        to outputURL: URL
    ) async throws -> URL {
        switch request.source {
        case .video:
            return try await exportVideoClip(request: request, to: outputURL)
        case let .image(imageSelection):
            return try await exportImage(selection: imageSelection, to: outputURL)
        }
    }

    private static func exportVideoClip(
        request: ClipExportRequest,
        to outputURL: URL
    ) async throws -> URL {
        guard request.frameRate > 0 else {
            throw ClipExportError.invalidFrameRate
        }

        guard ClipSelectionQuantization.isQuantized(request.frameCount) else {
            throw ClipExportError.invalidFrameCount
        }

        let fileManager = FileManager.default
        let outputDirectory = outputURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: outputDirectory.path) else {
            throw ClipExportError.outputDirectoryMissing
        }

        let preferredSafeEncodingProfile = RuntimeEnvironment.shouldUseSafeExportEncoding

        do {
            try await writeClipWithTimingFallback(
                request: request,
                to: outputURL,
                useSafeEncodingProfile: preferredSafeEncodingProfile
            )
        } catch {
            guard shouldRetryWithSafeEncoding(
                after: error,
                safeEncodingAlreadyEnabled: preferredSafeEncodingProfile
            ) else {
                throw error
            }

            try await writeClipWithTimingFallback(
                request: request,
                to: outputURL,
                useSafeEncodingProfile: true
            )
        }

        return outputURL
    }

    private static func exportImage(
        selection: ClipExportRequest.ImageSelection,
        to outputURL: URL
    ) async throws -> URL {
        let fileManager = FileManager.default
        let outputDirectory = outputURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: outputDirectory.path) else {
            throw ClipExportError.outputDirectoryMissing
        }

        try? fileManager.removeItem(at: outputURL)

        let pngData = try await MainActor.run { () throws -> Data in
            let croppedImage = try makeCroppedImage(from: selection)
            let bitmap = NSBitmapImageRep(cgImage: croppedImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw ClipExportError.failedToWriteImage
            }
            return pngData
        }

        do {
            try pngData.write(to: outputURL, options: .atomic)
        } catch {
            throw ClipExportError.failedToWriteImage
        }

        return outputURL
    }

    @MainActor
    private static func makeCroppedImage(
        from selection: ClipExportRequest.ImageSelection
    ) throws -> CGImage {
        let rasterizedImage = try rasterizedImage(from: selection.imageURL)
        let cropRect = resolveCropRect(selection.cropRect, within: rasterizedImage.pixelSize)

        guard let croppedImage = rasterizedImage.cgImage.cropping(to: cropRect) else {
            throw ClipExportError.invalidImageCrop
        }

        return croppedImage
    }

    @MainActor
    private static func rasterizedImage(from url: URL) throws -> RasterizedImage {
        guard let image = NSImage(contentsOf: url) else {
            throw ClipExportError.invalidImage
        }

        let pixelSize = image.pixelSize
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw ClipExportError.invalidImage
        }

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let bitmap else {
            throw ClipExportError.invalidImage
        }

        bitmap.size = NSSize(width: pixelSize.width, height: pixelSize.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(
            in: NSRect(origin: .zero, size: bitmap.size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmap.cgImage else {
            throw ClipExportError.invalidImage
        }

        return RasterizedImage(
            cgImage: cgImage,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private static func resolveCropRect(_ cropRect: CGRect, within imageSize: CGSize) -> CGRect {
        let fullRect = CGRect(origin: .zero, size: imageSize)
        let requestedRect = cropRect.standardized.intersection(fullRect)

        let sourceRect = if requestedRect.width > 0, requestedRect.height > 0 {
            requestedRect
        } else {
            fullRect
        }

        let minX = min(max(Int(sourceRect.minX.rounded(.down)), 0), max(Int(imageSize.width) - 1, 0))
        let minY = min(max(Int(sourceRect.minY.rounded(.down)), 0), max(Int(imageSize.height) - 1, 0))
        let maxX = max(min(Int(sourceRect.maxX.rounded(.up)), Int(imageSize.width)), minX + 1)
        let maxY = max(min(Int(sourceRect.maxY.rounded(.up)), Int(imageSize.height)), minY + 1)

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private static func makeVideoRenderConfiguration(
        for request: ClipExportRequest,
        sourceVideoTrack: AVAssetTrack,
        sourceTimeRange: CMTimeRange,
        outputSettings: [String: Any]
    ) async throws -> VideoRenderConfiguration {
        guard let cropRect = request.videoCropRect else {
            let trackOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: outputSettings)
            return VideoRenderConfiguration(
                readerOutput: trackOutput,
                writerTransform: try await sourceVideoTrack.load(.preferredTransform)
            )
        }

        let videoComposition = try await makeVideoComposition(
            for: sourceVideoTrack,
            timeRange: sourceTimeRange,
            cropRect: cropRect,
            frameRate: request.frameRate
        )
        let compositionOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [sourceVideoTrack],
            videoSettings: outputSettings
        )
        compositionOutput.videoComposition = videoComposition

        return VideoRenderConfiguration(
            readerOutput: compositionOutput,
            writerTransform: .identity
        )
    }

    private static func makeVideoComposition(
        for videoTrack: AVAssetTrack,
        timeRange: CMTimeRange,
        cropRect: CGRect,
        frameRate: Double
    ) async throws -> AVMutableVideoComposition {
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let displaySize = displayedVideoSize(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let resolvedCropRect = resolveCropRect(cropRect, within: displaySize)
        let translation = CGAffineTransform(
            translationX: -resolvedCropRect.minX,
            y: -resolvedCropRect.minY
        )

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(preferredTransform.concatenating(translation), at: timeRange.start)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = resolvedCropRect.size
        videoComposition.frameDuration = CMTime(
            seconds: 1 / max(frameRate, 1),
            preferredTimescale: 60_000
        )
        return videoComposition
    }

    private static func displayedVideoSize(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> CGSize {
        let transformedSize = naturalSize.applying(preferredTransform)
        return CGSize(
            width: abs(transformedSize.width),
            height: abs(transformedSize.height)
        )
    }

    private static func writeClipWithTimingFallback(
        request: ClipExportRequest,
        to outputURL: URL,
        useSafeEncodingProfile: Bool
    ) async throws {
        do {
            try await writeVideoClip(
                request: request,
                to: outputURL,
                timingMode: .sourceRate,
                useSafeEncodingProfile: useSafeEncodingProfile
            )
        } catch ClipExportError.frameCountMismatch {
            // Some sources/encoders retime variable-rate timestamps; retry with strict integer CFR timeline.
            try await writeVideoClip(
                request: request,
                to: outputURL,
                timingMode: .integerRate,
                useSafeEncodingProfile: useSafeEncodingProfile
            )
        }
    }

    private static func shouldRetryWithSafeEncoding(
        after error: Error,
        safeEncodingAlreadyEnabled: Bool
    ) -> Bool {
        guard !safeEncodingAlreadyEnabled,
              let clipError = error as? ClipExportError else {
            return false
        }

        switch clipError {
        case .failedToCreateWriterInput, .writerAppendFailed, .writerFailed, .timedOut:
            return true
        default:
            return false
        }
    }

    private static func writeVideoClip(
        request: ClipExportRequest,
        to outputURL: URL,
        timingMode: ExportTimingMode,
        useSafeEncodingProfile: Bool
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let sourceAsset = AVAsset(url: request.videoURL)
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ClipExportError.missingVideoTrack
        }
        let sourceNaturalSize = try await sourceVideoTrack.load(.naturalSize)
        let sourcePixelCount = max(
            Int(abs(sourceNaturalSize.width * sourceNaturalSize.height).rounded()),
            1
        )
        let sourceEstimatedBitRate = try await sourceVideoTrack.load(.estimatedDataRate)
        let exportIdleTimeoutSeconds = idleTimeoutSeconds(
            for: request,
            sourcePixelCount: sourcePixelCount,
            sourceEstimatedBitRate: Double(sourceEstimatedBitRate)
        )

        let assetDuration = try await sourceAsset.load(.duration)
        let rawDurationSeconds = assetDuration.seconds
        let assetDurationSeconds = rawDurationSeconds.isFinite ? rawDurationSeconds : 0
        let startSeconds = request.startSeconds
        guard startSeconds < assetDurationSeconds else {
            throw ClipExportError.invalidSourceRange
        }

        let availableDurationSeconds = max(assetDurationSeconds - startSeconds, 0)
        guard availableDurationSeconds > 0 else {
            throw ClipExportError.invalidSourceRange
        }
        let safeVideoDurationSeconds = min(request.durationSeconds, availableDurationSeconds)
        guard safeVideoDurationSeconds > 0 else {
            throw ClipExportError.invalidSourceRange
        }
        let safeAudioDurationSeconds = min(request.durationSeconds, availableDurationSeconds)

        let reader = try AVAssetReader(asset: sourceAsset)
        let sourceTimeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 60_000),
            duration: CMTime(seconds: safeVideoDurationSeconds, preferredTimescale: 60_000)
        )
        reader.timeRange = sourceTimeRange

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let videoRenderConfiguration = try await makeVideoRenderConfiguration(
            for: request,
            sourceVideoTrack: sourceVideoTrack,
            sourceTimeRange: sourceTimeRange,
            outputSettings: readerOutputSettings
        )
        let readerOutput = videoRenderConfiguration.readerOutput
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }

        reader.add(readerOutput)
        guard reader.startReading() else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }

        guard let firstSourceSampleBuffer = try await readNextDecodedSampleBuffer(
            output: readerOutput,
            reader: reader,
            timeoutSeconds: exportIdleTimeoutSeconds,
            stage: "reading source video frames"
        ),
              let firstSourceBuffer = CMSampleBufferGetImageBuffer(firstSourceSampleBuffer) else {
            throw ClipExportError.frameExtractionFailed(frameIndex: request.inFrame)
        }

        let renderWidth = max(CVPixelBufferGetWidth(firstSourceBuffer), 1)
        let renderHeight = max(CVPixelBufferGetHeight(firstSourceBuffer), 1)
        let roundedSourceEstimatedBitRate = Int(sourceEstimatedBitRate.rounded())

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let integerFrameRate = max(Int(request.frameRate.rounded()), 1)
        let compressionSettings: [String: Any]
        if useSafeEncodingProfile {
            // Virtualized environments often expose unstable hardware encode paths.
            // Keep settings conservative to favor stability over compression efficiency.
            let resolutionScaledBitRate = max(renderWidth * renderHeight * 8, 2_000_000)
            let sourceScaledBitRate = max(roundedSourceEstimatedBitRate, 0)
            let targetBitRate = min(max(resolutionScaledBitRate, sourceScaledBitRate), 24_000_000)
            compressionSettings = [
                AVVideoAverageBitRateKey: targetBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                AVVideoExpectedSourceFrameRateKey: integerFrameRate,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: max(integerFrameRate, 1),
                AVVideoMaxKeyFrameIntervalDurationKey: 1
            ]
        } else {
            let resolutionScaledBitRate = max(renderWidth * renderHeight * 14, 12_000_000)
            let sourceScaledBitRate = max(roundedSourceEstimatedBitRate * 2, 0)
            let targetBitRate = min(max(resolutionScaledBitRate, sourceScaledBitRate), 240_000_000)
            compressionSettings = [
                AVVideoAverageBitRateKey: targetBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: integerFrameRate,
                AVVideoAverageNonDroppableFrameRateKey: integerFrameRate,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoMaxKeyFrameIntervalKey: max(integerFrameRate * 2, 1),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoQualityKey: 1.0
            ]
        }
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: renderWidth,
            AVVideoHeightKey: renderHeight,
            AVVideoCompressionPropertiesKey: compressionSettings
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        // These exports are tiny clips, so predictable completion matters more than multipass gains.
        writerInput.performsMultiPassEncodingIfSupported = false
        writerInput.mediaTimeScale = 60_000
        writerInput.transform = videoRenderConfiguration.writerTransform

        let adaptorAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: renderWidth,
            kCVPixelBufferHeightKey as String: renderHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: adaptorAttributes
        )
        let audioExportContext = try await makeAudioExportContext(
            sourceAsset: sourceAsset,
            startSeconds: startSeconds,
            durationSeconds: safeAudioDurationSeconds
        )

        guard writer.canAdd(writerInput) else {
            throw ClipExportError.failedToCreateWriterInput
        }

        writer.add(writerInput)
        if let audioWriterInput = audioExportContext?.writerInput {
            guard writer.canAdd(audioWriterInput) else {
                throw ClipExportError.failedToCreateWriterInput
            }
            writer.add(audioWriterInput)
        }

        guard writer.startWriting() else {
            throw ClipExportError.writerFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        if let audioReader = audioExportContext?.reader {
            guard audioReader.startReading() else {
                throw ClipExportError.readerFailed(underlying: audioReader.error)
            }
        }

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw ClipExportError.failedToCreatePixelBuffer
        }

        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }

            if let audioReader = audioExportContext?.reader,
               audioReader.status == .reading {
                audioReader.cancelReading()
            }

            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        var lastSourceSampleBuffer = firstSourceSampleBuffer

        for frameOffset in 0..<request.frameCount {
            try await waitUntilReady(
                for: writerInput,
                writer: writer,
                timeoutSeconds: exportIdleTimeoutSeconds,
                stage: "waiting for the video encoder"
            )

            let sourceSampleBuffer: CMSampleBuffer
            if frameOffset == 0 {
                sourceSampleBuffer = firstSourceSampleBuffer
            } else if let nextDecodedSampleBuffer = try await readNextDecodedSampleBuffer(
                output: readerOutput,
                reader: reader,
                timeoutSeconds: exportIdleTimeoutSeconds,
                stage: "reading source video frames"
            ) {
                sourceSampleBuffer = nextDecodedSampleBuffer
                lastSourceSampleBuffer = nextDecodedSampleBuffer
            } else {
                // If the source provides fewer decodable frames than requested, pad with the last frame.
                sourceSampleBuffer = lastSourceSampleBuffer
            }

            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sourceSampleBuffer) else {
                throw ClipExportError.frameExtractionFailed(frameIndex: request.inFrame + frameOffset)
            }

            let pixelBuffer = try clonePixelBuffer(
                from: sourceBuffer,
                pool: pixelBufferPool
            )

            let presentationTime: CMTime
            switch timingMode {
            case .sourceRate:
                presentationTime = CMTime(
                    seconds: Double(frameOffset) / request.frameRate,
                    preferredTimescale: 60_000
                )
            case .integerRate:
                presentationTime = CMTime(
                    value: Int64(frameOffset),
                    timescale: Int32(integerFrameRate)
                )
            }
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw ClipExportError.writerAppendFailed
            }
        }

        writerInput.markAsFinished()
        if reader.status == .reading {
            reader.cancelReading()
        }
        if let audioExportContext {
            try await appendAudioSamples(
                from: audioExportContext.output,
                reader: audioExportContext.reader,
                to: audioExportContext.writerInput,
                writer: writer,
                timeoutSeconds: exportIdleTimeoutSeconds
            )
            audioExportContext.writerInput.markAsFinished()
        }
        try await finishWriting(writer: writer, timeoutSeconds: exportIdleTimeoutSeconds)

        guard writer.status == .completed else {
            throw ClipExportError.writerFailed(underlying: writer.error)
        }

        let actualFrameCount = try await countVideoFrames(in: outputURL)
        guard actualFrameCount == request.frameCount else {
            try? fileManager.removeItem(at: outputURL)
            throw ClipExportError.frameCountMismatch(expected: request.frameCount, actual: actualFrameCount)
        }
    }

    private static func readNextDecodedSampleBuffer(
        output: AVAssetReaderOutput,
        reader: AVAssetReader,
        timeoutSeconds: Double,
        stage: String
    ) async throws -> CMSampleBuffer? {
        let deadline = OperationDeadline(timeoutSeconds: timeoutSeconds)

        while true {
            if let sampleBuffer = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sampleBuffer) != nil {
                    return sampleBuffer
                }
                continue
            }

            switch reader.status {
            case .completed, .cancelled:
                return nil
            case .failed:
                throw ClipExportError.readerFailed(underlying: reader.error)
            case .reading, .unknown:
                if deadline.hasExpired() {
                    reader.cancelReading()
                    throw ClipExportError.timedOut(stage: stage)
                }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
            @unknown default:
                return nil
            }
        }
    }

    private static func clonePixelBuffer(
        from sourceBuffer: CVPixelBuffer,
        pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
        var maybeBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)

        guard status == kCVReturnSuccess, let pixelBuffer = maybeBuffer else {
            throw ClipExportError.failedToCreatePixelBuffer
        }

        let sourcePlaneCount = CVPixelBufferGetPlaneCount(sourceBuffer)
        let destinationPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard sourcePlaneCount == destinationPlaneCount else {
            throw ClipExportError.failedToCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly)
        }

        if sourcePlaneCount == 0 {
            guard let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourceBuffer),
                  let destinationBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw ClipExportError.failedToCreatePixelBuffer
            }

            let rowCount = CVPixelBufferGetHeight(sourceBuffer)
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)
            let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let bytesToCopyPerRow = min(sourceBytesPerRow, destinationBytesPerRow)

            for row in 0..<rowCount {
                let sourceRow = sourceBaseAddress.advanced(by: row * sourceBytesPerRow)
                let destinationRow = destinationBaseAddress.advanced(by: row * destinationBytesPerRow)
                memcpy(destinationRow, sourceRow, bytesToCopyPerRow)
            }
        } else {
            for plane in 0..<sourcePlaneCount {
                guard let sourceBaseAddress = CVPixelBufferGetBaseAddressOfPlane(sourceBuffer, plane),
                      let destinationBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
                    throw ClipExportError.failedToCreatePixelBuffer
                }

                let rowCount = CVPixelBufferGetHeightOfPlane(sourceBuffer, plane)
                let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(sourceBuffer, plane)
                let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
                let bytesToCopyPerRow = min(sourceBytesPerRow, destinationBytesPerRow)

                for row in 0..<rowCount {
                    let sourceRow = sourceBaseAddress.advanced(by: row * sourceBytesPerRow)
                    let destinationRow = destinationBaseAddress.advanced(by: row * destinationBytesPerRow)
                    memcpy(destinationRow, sourceRow, bytesToCopyPerRow)
                }
            }
        }

        return pixelBuffer
    }

    private static func waitUntilReady(
        for input: AVAssetWriterInput,
        writer: AVAssetWriter,
        timeoutSeconds: Double,
        stage: String
    ) async throws {
        let deadline = OperationDeadline(timeoutSeconds: timeoutSeconds)

        while !input.isReadyForMoreMediaData {
            switch writer.status {
            case .failed, .cancelled:
                throw ClipExportError.writerFailed(underlying: writer.error)
            default:
                break
            }
            if deadline.hasExpired() {
                writer.cancelWriting()
                throw ClipExportError.timedOut(stage: stage)
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
        }
    }

    private static func makeAudioExportContext(
        sourceAsset: AVAsset,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> AudioExportContext? {
        guard durationSeconds > 0 else {
            return nil
        }

        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard let sourceAudioTrack = audioTracks.first else {
            return nil
        }

        let composition = AVMutableComposition()
        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ClipExportError.failedToCreateCompositionTrack
        }

        let timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 60_000),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 60_000)
        )
        try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)

        let compositionAudioTracks = try await composition.loadTracks(withMediaType: .audio)
        guard let trimmedAudioTrack = compositionAudioTracks.first else {
            return nil
        }

        let reader = try AVAssetReader(asset: composition)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: trimmedAudioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }
        reader.add(output)

        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: try await makeAudioOutputSettings(for: sourceAudioTrack)
        )
        writerInput.expectsMediaDataInRealTime = false

        return AudioExportContext(reader: reader, output: output, writerInput: writerInput)
    }

    private static func makeAudioOutputSettings(for sourceAudioTrack: AVAssetTrack) async throws -> [String: Any] {
        let formatDescriptions = try await sourceAudioTrack.load(.formatDescriptions)
        let audioFormat = formatDescriptions.lazy.compactMap { description in
            AVAudioFormat(cmAudioFormatDescription: description)
        }.first
        let sampleRate = audioFormat?.sampleRate ?? 44_100
        let channelCount = max(Int(audioFormat?.channelCount ?? 2), 1)
        let bitRate = min(max(channelCount * 96_000, 64_000), 320_000)

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate
        ]
    }

    private static func appendAudioSamples(
        from output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        timeoutSeconds: Double
    ) async throws {
        var deadline = OperationDeadline(timeoutSeconds: timeoutSeconds)

        while true {
            if let sampleBuffer = output.copyNextSampleBuffer() {
                try await waitUntilReady(
                    for: input,
                    writer: writer,
                    timeoutSeconds: timeoutSeconds,
                    stage: "waiting for the audio encoder"
                )
                guard input.append(sampleBuffer) else {
                    if writer.status == .failed {
                        throw ClipExportError.writerFailed(underlying: writer.error)
                    }
                    throw ClipExportError.writerAppendFailed
                }
                deadline = OperationDeadline(timeoutSeconds: timeoutSeconds)
                continue
            }

            switch reader.status {
            case .completed, .cancelled:
                return
            case .failed:
                throw ClipExportError.readerFailed(underlying: reader.error)
            case .reading, .unknown:
                if deadline.hasExpired() {
                    reader.cancelReading()
                    writer.cancelWriting()
                    throw ClipExportError.timedOut(stage: "reading source audio samples")
                }
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
            @unknown default:
                return
            }
        }
    }

    private static func finishWriting(
        writer: AVAssetWriter,
        timeoutSeconds: Double
    ) async throws {
        let state = FinishWritingState()
        let deadline = OperationDeadline(timeoutSeconds: timeoutSeconds)

        writer.finishWriting {
            state.markFinished()
        }

        while !state.isFinished {
            switch writer.status {
            case .completed:
                return
            case .failed, .cancelled:
                throw ClipExportError.writerFailed(underlying: writer.error)
            default:
                break
            }

            if deadline.hasExpired() {
                writer.cancelWriting()
                throw ClipExportError.timedOut(stage: "finalizing the clip file")
            }

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
        }
    }

    static func idleTimeoutSeconds(
        for request: ClipExportRequest,
        sourcePixelCount: Int = 0,
        sourceEstimatedBitRate: Double = 0
    ) -> Double {
        let baseSeconds = max(request.durationSeconds * 12, 45)
        let megapixels = max(Double(sourcePixelCount), 0) / 1_000_000
        let bitrateMegabitsPerSecond = max(sourceEstimatedBitRate, 0) / 1_000_000
        let complexityAllowance = (megapixels * 5) + min(bitrateMegabitsPerSecond * 0.5, 30)

        return min(baseSeconds + complexityAllowance, 300)
    }

    private static func countVideoFrames(in videoURL: URL) async throws -> Int {
        let asset = AVAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ClipExportError.missingVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }

        reader.add(output)
        guard reader.startReading() else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }

        var frameCount = 0
        var previousPTS: CMTime?
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if let previousPTS, pts == previousPTS {
                continue
            }
            frameCount += 1
            previousPTS = pts
        }

        guard reader.status == .completed else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }

        return frameCount
    }
}
