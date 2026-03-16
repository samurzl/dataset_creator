import AVFoundation
import Foundation

protocol InputVideoPreparing: Sendable {
    func preparedURL(for sourceURL: URL) async throws -> URL
}

enum InputVideoResampleError: LocalizedError {
    case missingVideoTrack
    case failedToCreateReader
    case failedToCreateWriterInput
    case failedToCreatePixelBuffer
    case failedToCreateExportSession
    case unsupportedOutputFileType
    case readerFailed(underlying: Error?)
    case writerFailed(underlying: Error?)
    case exportFailed(underlying: Error?)
    case timedOut(stage: String)
    case unknownExportStatus

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "No video track found in the source file."
        case .failedToCreateReader:
            return "Failed to create a reader for the source video."
        case .failedToCreateWriterInput:
            return "Failed to configure the resampled video writer."
        case .failedToCreatePixelBuffer:
            return "Failed to allocate a frame buffer while resampling the video."
        case .failedToCreateExportSession:
            return "Failed to create a video export session."
        case .unsupportedOutputFileType:
            return "The current source cannot be exported as MP4."
        case let .readerFailed(underlying):
            return underlying?.localizedDescription ?? "Failed while reading the source video."
        case let .writerFailed(underlying):
            return underlying?.localizedDescription ?? "Failed while writing the resampled video."
        case let .exportFailed(underlying):
            return underlying?.localizedDescription ?? "Failed to resample the source video."
        case let .timedOut(stage):
            return "Video resampling timed out while \(stage)."
        case .unknownExportStatus:
            return "Video resampling finished with an unknown export status."
        }
    }
}

actor InputVideoResampler {
    static let defaultTargetFrameRate = 16
    private static let pollingIntervalNanoseconds: UInt64 = 1_000_000

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

    private let targetFrameRate: Int
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var preparedVideoBySource: [URL: URL] = [:]
    private var inFlightTasks: [URL: Task<URL, Error>] = [:]
    private var nextOutputIndex: Int = 0

    init(targetFrameRate: Int = InputVideoResampler.defaultTargetFrameRate) {
        self.targetFrameRate = max(targetFrameRate, 1)
        let runScopedDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("VideoDatasetBrowser-Preprocessed", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        cacheDirectory = runScopedDirectory
        try? fileManager.createDirectory(at: runScopedDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? fileManager.removeItem(at: cacheDirectory)
    }

    func resampledURL(for sourceURL: URL) async throws -> URL {
        if let cachedURL = preparedVideoBySource[sourceURL],
           fileManager.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }

        if let existingTask = inFlightTasks[sourceURL] {
            return try await existingTask.value
        }

        let outputURL = nextOutputURL(for: sourceURL)
        let task = Task(priority: .utility) { [targetFrameRate] () throws -> URL in
            try await Self.exportResampledVideo(
                from: sourceURL,
                to: outputURL,
                targetFrameRate: targetFrameRate
            )
            return outputURL
        }

        inFlightTasks[sourceURL] = task

        do {
            let processedURL = try await task.value
            preparedVideoBySource[sourceURL] = processedURL
            inFlightTasks[sourceURL] = nil
            return processedURL
        } catch {
            inFlightTasks[sourceURL] = nil
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    private func nextOutputURL(for sourceURL: URL) -> URL {
        nextOutputIndex += 1

        let safeName = sanitizedBaseName(from: sourceURL.deletingPathExtension().lastPathComponent)
        let outputName = "\(nextOutputIndex)_\(safeName)_\(targetFrameRate)fps.mp4"

        return cacheDirectory.appendingPathComponent(outputName)
    }

    private func sanitizedBaseName(from rawName: String) -> String {
        let mapped = rawName.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "_"
        }
        let collapsed = String(mapped)
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        let fallbackName = collapsed.isEmpty ? "video" : collapsed
        return String(fallbackName.prefix(48))
    }

    private static func exportResampledVideo(
        from sourceURL: URL,
        to outputURL: URL,
        targetFrameRate: Int
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let sourceAsset = AVAsset(url: sourceURL)
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw InputVideoResampleError.missingVideoTrack
        }

        let intermediateVideoURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try? fileManager.removeItem(at: intermediateVideoURL)

        defer {
            try? fileManager.removeItem(at: intermediateVideoURL)
        }

        try await writeResampledVideoTrack(
            from: sourceAsset,
            videoTrack: sourceVideoTrack,
            to: intermediateVideoURL,
            targetFrameRate: max(targetFrameRate, 1)
        )

        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        if audioTracks.isEmpty {
            try fileManager.moveItem(at: intermediateVideoURL, to: outputURL)
            return
        }

        try await muxAudioIfPresent(
            from: sourceAsset,
            withResampledVideoAt: intermediateVideoURL,
            to: outputURL
        )
    }

    private static func writeResampledVideoTrack(
        from sourceAsset: AVAsset,
        videoTrack: AVAssetTrack,
        to outputURL: URL,
        targetFrameRate: Int
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        let duration = try await sourceAsset.load(.duration)
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw InputVideoResampleError.exportFailed(underlying: nil)
        }

        let timeoutSeconds = min(max(durationSeconds * 12, 60), 1_800)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: sourceAsset)
        } catch {
            throw InputVideoResampleError.readerFailed(underlying: error)
        }

        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw InputVideoResampleError.failedToCreateReader
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw InputVideoResampleError.readerFailed(underlying: reader.error)
        }

        guard let firstSourceSampleBuffer = try await readNextDecodedSampleBuffer(
            output: readerOutput,
            reader: reader,
            timeoutSeconds: timeoutSeconds,
            stage: "reading source video frames"
        ),
              let firstSourceBuffer = CMSampleBufferGetImageBuffer(firstSourceSampleBuffer) else {
            throw InputVideoResampleError.exportFailed(underlying: nil)
        }

        let renderWidth = max(CVPixelBufferGetWidth(firstSourceBuffer), 1)
        let renderHeight = max(CVPixelBufferGetHeight(firstSourceBuffer), 1)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let roundedSourceEstimatedBitRate = Int((try await videoTrack.load(.estimatedDataRate)).rounded())

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw InputVideoResampleError.writerFailed(underlying: error)
        }

        let compressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: min(max(max(renderWidth * renderHeight * 8, 2_000_000), roundedSourceEstimatedBitRate), 24_000_000),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
            AVVideoExpectedSourceFrameRateKey: targetFrameRate,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: max(targetFrameRate, 1),
            AVVideoMaxKeyFrameIntervalDurationKey: 1
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: renderWidth,
            AVVideoHeightKey: renderHeight,
            AVVideoCompressionPropertiesKey: compressionSettings
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writerInput.performsMultiPassEncodingIfSupported = false
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
            throw InputVideoResampleError.failedToCreateWriterInput
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw InputVideoResampleError.writerFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw InputVideoResampleError.failedToCreatePixelBuffer
        }

        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
            if writer.status == .writing {
                writer.cancelWriting()
            }
        }

        let frameCount = max(Int((durationSeconds * Double(targetFrameRate)).rounded(.up)), 1)
        var currentSourceSampleBuffer = firstSourceSampleBuffer
        var nextSourceSampleBuffer = try await readNextDecodedSampleBuffer(
            output: readerOutput,
            reader: reader,
            timeoutSeconds: timeoutSeconds,
            stage: "reading source video frames"
        )

        for frameIndex in 0..<frameCount {
            try await waitUntilReady(
                for: writerInput,
                writer: writer,
                timeoutSeconds: timeoutSeconds,
                stage: "waiting for the video encoder"
            )

            let presentationTime = CMTime(
                value: Int64(frameIndex),
                timescale: Int32(targetFrameRate)
            )

            while let candidate = nextSourceSampleBuffer,
                  CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(candidate), presentationTime) <= 0 {
                currentSourceSampleBuffer = candidate
                nextSourceSampleBuffer = try await readNextDecodedSampleBuffer(
                    output: readerOutput,
                    reader: reader,
                    timeoutSeconds: timeoutSeconds,
                    stage: "reading source video frames"
                )
            }

            let selectedSampleBuffer = sampleBufferClosest(
                to: presentationTime,
                current: currentSourceSampleBuffer,
                next: nextSourceSampleBuffer
            )
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(selectedSampleBuffer) else {
                throw InputVideoResampleError.exportFailed(underlying: nil)
            }

            let pixelBuffer = try clonePixelBuffer(from: sourceBuffer, pool: pixelBufferPool)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw InputVideoResampleError.writerFailed(underlying: writer.error)
            }
        }

        writerInput.markAsFinished()
        try await finishWriting(writer: writer, timeoutSeconds: timeoutSeconds)

        guard writer.status == .completed else {
            throw InputVideoResampleError.writerFailed(underlying: writer.error)
        }
    }

    private static func sampleBufferClosest(
        to targetTime: CMTime,
        current: CMSampleBuffer,
        next: CMSampleBuffer?
    ) -> CMSampleBuffer {
        guard let next else {
            return current
        }

        let currentTime = CMSampleBufferGetPresentationTimeStamp(current)
        let nextTime = CMSampleBufferGetPresentationTimeStamp(next)
        let currentDelta = abs(CMTimeSubtract(currentTime, targetTime).seconds)
        let nextDelta = abs(CMTimeSubtract(nextTime, targetTime).seconds)

        return nextDelta < currentDelta ? next : current
    }

    private static func muxAudioIfPresent(
        from sourceAsset: AVAsset,
        withResampledVideoAt videoURL: URL,
        to outputURL: URL
    ) async throws {
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard let sourceAudioTrack = sourceAudioTracks.first else {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: outputURL)
            try fileManager.moveItem(at: videoURL, to: outputURL)
            return
        }

        let resampledVideoAsset = AVAsset(url: videoURL)
        let resampledVideoTracks = try await resampledVideoAsset.loadTracks(withMediaType: .video)
        guard let resampledVideoTrack = resampledVideoTracks.first else {
            throw InputVideoResampleError.missingVideoTrack
        }

        let videoDuration = try await resampledVideoAsset.load(.duration)
        let sourceAudioTimeRange = try await sourceAudioTrack.load(.timeRange)
        let audioDuration = CMTimeMinimum(videoDuration, sourceAudioTimeRange.duration)

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
              let compositionAudioTrack = composition.addMutableTrack(
                  withMediaType: .audio,
                  preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw InputVideoResampleError.failedToCreateReader
        }

        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: resampledVideoTrack,
            at: .zero
        )
        try compositionAudioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: sourceAudioTrack,
            at: .zero
        )

        let exportSession: AVAssetExportSession
        if let passthroughSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ),
           passthroughSession.supportedFileTypes.contains(.mp4) {
            exportSession = passthroughSession
        } else if let fallbackSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) {
            exportSession = fallbackSession
        } else {
            throw InputVideoResampleError.failedToCreateExportSession
        }

        guard exportSession.supportedFileTypes.contains(.mp4) else {
            throw InputVideoResampleError.unsupportedOutputFileType
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }

        switch exportSession.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        case .failed:
            throw InputVideoResampleError.exportFailed(underlying: exportSession.error)
        default:
            throw InputVideoResampleError.unknownExportStatus
        }
    }

    private static func readNextDecodedSampleBuffer(
        output: AVAssetReaderTrackOutput,
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
                throw InputVideoResampleError.readerFailed(underlying: reader.error)
            case .reading, .unknown:
                if deadline.hasExpired() {
                    reader.cancelReading()
                    throw InputVideoResampleError.timedOut(stage: stage)
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
            throw InputVideoResampleError.failedToCreatePixelBuffer
        }

        let sourcePlaneCount = CVPixelBufferGetPlaneCount(sourceBuffer)
        let destinationPlaneCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        guard sourcePlaneCount == destinationPlaneCount else {
            throw InputVideoResampleError.failedToCreatePixelBuffer
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
                throw InputVideoResampleError.failedToCreatePixelBuffer
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
                    throw InputVideoResampleError.failedToCreatePixelBuffer
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
                throw InputVideoResampleError.writerFailed(underlying: writer.error)
            default:
                break
            }

            if deadline.hasExpired() {
                writer.cancelWriting()
                throw InputVideoResampleError.timedOut(stage: stage)
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
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
                throw InputVideoResampleError.writerFailed(underlying: writer.error)
            default:
                break
            }

            if deadline.hasExpired() {
                writer.cancelWriting()
                throw InputVideoResampleError.timedOut(stage: "finishing the resampled video")
            }

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollingIntervalNanoseconds)
        }
    }
}

extension InputVideoResampler: InputVideoPreparing {
    func preparedURL(for sourceURL: URL) async throws -> URL {
        try await resampledURL(for: sourceURL)
    }
}
