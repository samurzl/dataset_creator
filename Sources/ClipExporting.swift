import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

struct ClipExportRequest: Identifiable {
    let id = UUID()
    let videoURL: URL
    let inFrame: Int
    let frameCount: Int
    let frameRate: Double
    let aspectRatio: CGFloat

    var startSeconds: Double {
        Double(inFrame) / frameRate
    }

    var durationSeconds: Double {
        Double(frameCount) / frameRate
    }
}

enum ClipExportError: LocalizedError {
    case noVideoSelected
    case invalidFrameRate
    case invalidFrameCount
    case missingVideoTrack
    case invalidSourceRange
    case failedToCreateCompositionTrack
    case failedToCreateWriterInput
    case failedToCreatePixelBuffer
    case writerAppendFailed
    case writerFailed(underlying: Error?)
    case readerFailed(underlying: Error?)
    case frameExtractionFailed(frameIndex: Int)
    case frameCountMismatch(expected: Int, actual: Int)
    case outputDirectoryMissing
    case outputFolderNotConfigured

    var errorDescription: String? {
        switch self {
        case .noVideoSelected:
            return "No video selected."
        case .invalidFrameRate:
            return "The video frame rate is invalid."
        case .invalidFrameCount:
            return "The selected clip length must follow 5, 9, 13, ... frames."
        case .missingVideoTrack:
            return "No video track found in the selected source."
        case .invalidSourceRange:
            return "The selected range is outside the source video duration."
        case .failedToCreateCompositionTrack:
            return "Failed to create a temporary composition track."
        case .failedToCreateWriterInput:
            return "Failed to configure the video writer."
        case .failedToCreatePixelBuffer:
            return "Failed to allocate a frame buffer for export."
        case .writerAppendFailed:
            return "Failed while writing one of the output frames."
        case let .writerFailed(underlying):
            return underlying?.localizedDescription ?? "The exporter failed to write the output clip."
        case let .readerFailed(underlying):
            return underlying?.localizedDescription ?? "Failed while validating exported frame count."
        case let .frameExtractionFailed(frameIndex):
            return "Could not extract source frame \(frameIndex)."
        case let .frameCountMismatch(expected, actual):
            return "Exported frame count mismatch. Expected \(expected), got \(actual)."
        case .outputDirectoryMissing:
            return "Output folder does not exist."
        case .outputFolderNotConfigured:
            return "Set an output folder before exporting."
        }
    }
}

enum ClipExporter {
    private enum ExportTimingMode {
        case sourceRate
        case integerRate
    }

    @MainActor
    static func createPreviewItem(for request: ClipExportRequest) async throws -> AVPlayerItem {
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

        return AVPlayerItem(asset: composition)
    }

    static func exportClip(
        request: ClipExportRequest,
        caption: String,
        to outputDirectory: URL
    ) async throws -> URL {
        guard request.frameRate > 0 else {
            throw ClipExportError.invalidFrameRate
        }

        guard ClipSelectionQuantization.isQuantized(request.frameCount) else {
            throw ClipExportError.invalidFrameCount
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: outputDirectory.path) else {
            throw ClipExportError.outputDirectoryMissing
        }

        let baseName = try nextOutputBaseName(in: outputDirectory)
        let outputVideoURL = outputDirectory.appendingPathComponent(baseName).appendingPathExtension("mp4")
        let outputCaptionURL = outputDirectory.appendingPathComponent(baseName).appendingPathExtension("txt")

        do {
            try await writeVideoClip(request: request, to: outputVideoURL, timingMode: .sourceRate)
        } catch ClipExportError.frameCountMismatch {
            // Some sources/encoders retime variable-rate timestamps; retry with strict integer CFR timeline.
            try await writeVideoClip(request: request, to: outputVideoURL, timingMode: .integerRate)
        }

        do {
            try caption.write(to: outputCaptionURL, atomically: true, encoding: .utf8)
        } catch {
            try? fileManager.removeItem(at: outputVideoURL)
            throw error
        }

        return outputVideoURL
    }

    private static func nextOutputBaseName(in outputDirectory: URL) throws -> String {
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let existingIndices = urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }

        let nextIndex = (existingIndices.max() ?? 0) + 1
        return String(nextIndex)
    }

    private static func writeVideoClip(
        request: ClipExportRequest,
        to outputURL: URL,
        timingMode: ExportTimingMode
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let sourceAsset = AVAsset(url: request.videoURL)
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ClipExportError.missingVideoTrack
        }

        let assetDuration = try await sourceAsset.load(.duration)
        let rawDurationSeconds = assetDuration.seconds
        let assetDurationSeconds = rawDurationSeconds.isFinite ? rawDurationSeconds : 0
        let startSeconds = request.startSeconds
        guard startSeconds < assetDurationSeconds else {
            throw ClipExportError.invalidSourceRange
        }

        let frameGenerator = AVAssetImageGenerator(asset: sourceAsset)
        frameGenerator.appliesPreferredTrackTransform = true

        let firstFrameTime = CMTime(seconds: startSeconds, preferredTimescale: 60_000)
        let firstFrameImage: CGImage
        do {
            firstFrameImage = try frameGenerator.copyCGImage(at: firstFrameTime, actualTime: nil)
        } catch {
            throw ClipExportError.frameExtractionFailed(frameIndex: request.inFrame)
        }

        let renderWidth = max(firstFrameImage.width, 1)
        let renderHeight = max(firstFrameImage.height, 1)
        let sourceEstimatedBitRate = Int((try await sourceVideoTrack.load(.estimatedDataRate)).rounded())
        let useSafeEncodingProfile = RuntimeEnvironment.shouldUseSafeExportEncoding

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let integerFrameRate = max(Int(request.frameRate.rounded()), 1)
        let compressionSettings: [String: Any]
        if useSafeEncodingProfile {
            // Virtualized environments often expose unstable hardware encode paths.
            // Keep settings conservative to favor stability over compression efficiency.
            let resolutionScaledBitRate = max(renderWidth * renderHeight * 8, 2_000_000)
            let sourceScaledBitRate = max(sourceEstimatedBitRate, 0)
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
            let sourceScaledBitRate = max(sourceEstimatedBitRate * 2, 0)
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
        writerInput.performsMultiPassEncodingIfSupported = !useSafeEncodingProfile
        writerInput.mediaTimeScale = 60_000
        writerInput.transform = .identity

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

        guard writer.canAdd(writerInput) else {
            throw ClipExportError.failedToCreateWriterInput
        }

        writer.add(writerInput)

        guard writer.startWriting() else {
            throw ClipExportError.writerFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw ClipExportError.failedToCreatePixelBuffer
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let lastSampleableSecond = max(assetDurationSeconds - (1.0 / 120_000.0), 0)
        var lastFrameImage = firstFrameImage

        defer {
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        for frameOffset in 0..<request.frameCount {
            try Task.checkCancellation()
            try await waitUntilReady(for: writerInput, writer: writer)

            let frameImage: CGImage
            if frameOffset == 0 {
                frameImage = firstFrameImage
            } else {
                let requestedSecond = startSeconds + (Double(frameOffset) / request.frameRate)
                let sampleSecond = min(max(requestedSecond, 0), lastSampleableSecond)
                let sampleTime = CMTime(seconds: sampleSecond, preferredTimescale: 60_000)

                do {
                    let sampledImage = try frameGenerator.copyCGImage(at: sampleTime, actualTime: nil)
                    lastFrameImage = sampledImage
                    frameImage = sampledImage
                } catch {
                    // If a timestamp cannot be decoded precisely, keep CFR output by reusing the previous frame.
                    frameImage = lastFrameImage
                }
            }

            let pixelBuffer = try renderPixelBuffer(
                from: frameImage,
                pool: pixelBufferPool,
                colorSpace: colorSpace
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
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw ClipExportError.writerFailed(underlying: writer.error)
        }

        let actualFrameCount = try await countVideoFrames(in: outputURL)
        guard actualFrameCount == request.frameCount else {
            try? fileManager.removeItem(at: outputURL)
            throw ClipExportError.frameCountMismatch(expected: request.frameCount, actual: actualFrameCount)
        }
    }

    private static func renderPixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool,
        colorSpace: CGColorSpace
    ) throws -> CVPixelBuffer {
        var maybeBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)

        guard status == kCVReturnSuccess, let pixelBuffer = maybeBuffer else {
            throw ClipExportError.failedToCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ClipExportError.failedToCreatePixelBuffer
        }

        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ClipExportError.failedToCreatePixelBuffer
        }

        context.setBlendMode(.copy)
        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return pixelBuffer
    }

    private static func waitUntilReady(for input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            switch writer.status {
            case .failed, .cancelled:
                throw ClipExportError.writerFailed(underlying: writer.error)
            default:
                break
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
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
