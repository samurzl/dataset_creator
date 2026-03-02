import AVFoundation
import Foundation

enum InputVideoResampleError: LocalizedError {
    case missingVideoTrack
    case failedToCreateExportSession
    case unsupportedOutputFileType
    case exportFailed(underlying: Error?)
    case unknownExportStatus

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "No video track found in the source file."
        case .failedToCreateExportSession:
            return "Failed to create a video export session."
        case .unsupportedOutputFileType:
            return "The current source cannot be exported as MP4."
        case let .exportFailed(underlying):
            return underlying?.localizedDescription ?? "Failed to resample the source video."
        case .unknownExportStatus:
            return "Video resampling finished with an unknown export status."
        }
    }
}

actor InputVideoResampler {
    private let targetFrameRate: Int
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var preparedVideoBySource: [URL: URL] = [:]
    private var inFlightTasks: [URL: Task<URL, Error>] = [:]
    private var nextOutputIndex: Int = 0

    init(targetFrameRate: Int) {
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

        let asset = AVAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw InputVideoResampleError.missingVideoTrack
        }

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw InputVideoResampleError.failedToCreateExportSession
        }

        guard exportSession.supportedFileTypes.contains(.mp4) else {
            throw InputVideoResampleError.unsupportedOutputFileType
        }

        let videoComposition = AVMutableVideoComposition(propertiesOf: asset)
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: Int32(max(targetFrameRate, 1))
        )

        exportSession.videoComposition = videoComposition
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
}
