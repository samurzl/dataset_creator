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

        let availableDurationSeconds = max(assetDurationSeconds - startSeconds, 0)
        guard availableDurationSeconds > 0 else {
            throw ClipExportError.invalidSourceRange
        }

        let reader = try AVAssetReader(asset: sourceAsset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 60_000),
            duration: CMTime(seconds: availableDurationSeconds, preferredTimescale: 60_000)
        )

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: sourceVideoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }

        reader.add(readerOutput)
        guard reader.startReading() else {
            throw ClipExportError.readerFailed(underlying: reader.error)
        }

        guard let firstSourceSampleBuffer = try await readNextDecodedSampleBuffer(output: readerOutput, reader: reader),
              let firstSourceBuffer = CMSampleBufferGetImageBuffer(firstSourceSampleBuffer) else {
            throw ClipExportError.frameExtractionFailed(frameIndex: request.inFrame)
        }

        let renderWidth = max(CVPixelBufferGetWidth(firstSourceBuffer), 1)
        let renderHeight = max(CVPixelBufferGetHeight(firstSourceBuffer), 1)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        let sourceEstimatedBitRate = Int((try await sourceVideoTrack.load(.estimatedDataRate)).rounded())

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let integerFrameRate = max(Int(request.frameRate.rounded()), 1)
        let resolutionScaledBitRate = max(renderWidth * renderHeight * 14, 12_000_000)
        let sourceScaledBitRate = max(sourceEstimatedBitRate * 2, 0)
        let targetBitRate = min(max(resolutionScaledBitRate, sourceScaledBitRate), 240_000_000)
        let compressionSettings: [String: Any] = [
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
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: renderWidth,
            AVVideoHeightKey: renderHeight,
            AVVideoCompressionPropertiesKey: compressionSettings
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.performsMultiPassEncodingIfSupported = true
        writerInput.mediaTimeScale = 60_000
        writerInput.transform = preferredTransform

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

        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }

            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        var lastSourceSampleBuffer = firstSourceSampleBuffer

        for frameOffset in 0..<request.frameCount {
            try await waitUntilReady(for: writerInput, writer: writer)

            let sourceSampleBuffer: CMSampleBuffer
            if frameOffset == 0 {
                sourceSampleBuffer = firstSourceSampleBuffer
            } else if let nextDecodedSampleBuffer = try await readNextDecodedSampleBuffer(output: readerOutput, reader: reader) {
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

    private static func readNextDecodedSampleBuffer(
        output: AVAssetReaderTrackOutput,
        reader: AVAssetReader
    ) async throws -> CMSampleBuffer? {
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
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
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
