import AVFAudio
import AVFoundation
import Foundation
import XCTest
@testable import VideoDatasetBrowser

final class InputVideoResamplerTests: XCTestCase {
    func testPreparedURLResamplesVideoToDefaultFrameRate() async throws {
        let sourceURL = repositoryRootURL().appendingPathComponent("example_dataset/positive/1.mp4")
        let resampler = InputVideoResampler()

        let preparedURL = try await resampler.preparedURL(for: sourceURL)

        XCTAssertNotEqual(preparedURL, sourceURL)

        let preparedAsset = AVAsset(url: preparedURL)
        let videoTracks = try await preparedAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))

        XCTAssertEqual(
            nominalFrameRate,
            Double(InputVideoResampler.defaultTargetFrameRate),
            accuracy: 0.25
        )
    }

    func testPreparedURLPreservesAudioWhileResamplingFrameRate() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = try await makeVideoWithAudio(in: rootURL)
        let resampler = InputVideoResampler()

        let preparedURL = try await resampler.preparedURL(for: sourceURL)
        let preparedAsset = AVAsset(url: preparedURL)
        let videoTracks = try await preparedAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let audioTracks = try await preparedAsset.loadTracks(withMediaType: .audio)

        XCTAssertEqual(
            nominalFrameRate,
            Double(InputVideoResampler.defaultTargetFrameRate),
            accuracy: 0.25
        )
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertTrue(assetContainsSamples(asset: preparedAsset, track: audioTracks[0]))
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeVideoWithAudio(in rootURL: URL) async throws -> URL {
        let silentVideoURL = repositoryRootURL().appendingPathComponent("example_dataset/positive/1.mp4")
        let audioURL = rootURL.appendingPathComponent("tone.caf")
        try writeToneAudio(to: audioURL, durationSeconds: 1)

        let outputURL = rootURL.appendingPathComponent("source-with-audio.mov")
        try await muxVideoAndAudio(videoURL: silentVideoURL, audioURL: audioURL, outputURL: outputURL)
        return outputURL
    }

    private func writeToneAudio(to outputURL: URL, durationSeconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frameCount = AVAudioFrameCount(durationSeconds * format.sampleRate)
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        if let channelData = buffer.floatChannelData?[0] {
            for sampleIndex in 0..<Int(frameCount) {
                let phase = (2 * Double.pi * 440 * Double(sampleIndex)) / format.sampleRate
                channelData[sampleIndex] = Float(sin(phase)) * 0.25
            }
        }

        try file.write(from: buffer)
    }

    private func muxVideoAndAudio(videoURL: URL, audioURL: URL, outputURL: URL) async throws {
        let videoAsset = AVAsset(url: videoURL)
        let audioAsset = AVAsset(url: audioURL)
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let exportDuration = CMTimeMinimum(videoDuration, audioDuration)

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            XCTFail("Failed to create composition video track.")
            return
        }
        guard let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            XCTFail("Failed to create composition audio track.")
            return
        }

        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let timeRange = CMTimeRange(start: .zero, duration: exportDuration)

        try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }

        if let error = exporter.error {
            throw error
        }
        XCTAssertEqual(exporter.status, .completed)
    }

    private func assetContainsSamples(asset: AVAsset, track: AVAssetTrack) -> Bool {
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else {
                return false
            }
            reader.add(output)
            guard reader.startReading() else {
                return false
            }
            return output.copyNextSampleBuffer() != nil
        } catch {
            return false
        }
    }
}
