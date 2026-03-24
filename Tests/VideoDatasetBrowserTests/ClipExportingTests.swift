import AppKit
import AVFoundation
import AVFAudio
import CoreGraphics
import Foundation
import XCTest
@testable import VideoDatasetBrowser

final class ClipExportingTests: XCTestCase {
    func testIdleTimeoutHasGenerousFloorForShortClips() {
        let request = ClipExportRequest(
            videoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            inFrame: 0,
            frameCount: 5,
            frameRate: 16,
            aspectRatio: 1
        )

        let timeoutSeconds = ClipExporter.idleTimeoutSeconds(
            for: request,
            sourcePixelCount: 640 * 360,
            sourceEstimatedBitRate: 2_000_000
        )

        XCTAssertGreaterThanOrEqual(timeoutSeconds, 45)
    }

    func testIdleTimeoutIncreasesForMoreDemandingSources() {
        let request = ClipExportRequest(
            videoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            inFrame: 0,
            frameCount: 5,
            frameRate: 16,
            aspectRatio: 1
        )

        let lowComplexityTimeout = ClipExporter.idleTimeoutSeconds(
            for: request,
            sourcePixelCount: 640 * 360,
            sourceEstimatedBitRate: 2_000_000
        )
        let highComplexityTimeout = ClipExporter.idleTimeoutSeconds(
            for: request,
            sourcePixelCount: 3_840 * 2_160,
            sourceEstimatedBitRate: 80_000_000
        )

        XCTAssertGreaterThan(highComplexityTimeout, lowComplexityTimeout)
    }

    func testIdleTimeoutCapsForVeryLongOrComplexExports() {
        let request = ClipExportRequest(
            videoURL: URL(fileURLWithPath: "/tmp/source.mp4"),
            inFrame: 0,
            frameCount: 16 * 60,
            frameRate: 16,
            aspectRatio: 1
        )

        let timeoutSeconds = ClipExporter.idleTimeoutSeconds(
            for: request,
            sourcePixelCount: 7_680 * 4_320,
            sourceEstimatedBitRate: 240_000_000
        )

        XCTAssertEqual(timeoutSeconds, 300)
    }

    func testExportClipRetainsAudioWhenSourceContainsAudio() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = try await makeVideoWithAudio(in: rootURL)
        let sourceAsset = AVAsset(url: sourceURL)
        let videoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let sourceVideoTrack = try XCTUnwrap(videoTracks.first)
        let frameRate = Double(try await sourceVideoTrack.load(.nominalFrameRate))
        XCTAssertGreaterThan(frameRate, 0)

        let outputURL = rootURL.appendingPathComponent("clip.mp4")
        let request = ClipExportRequest(
            videoURL: sourceURL,
            inFrame: 0,
            frameCount: 5,
            frameRate: frameRate,
            aspectRatio: 1
        )

        _ = try await ClipExporter.exportClip(request: request, to: outputURL)

        let exportedAsset = AVAsset(url: outputURL)
        let audioTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertTrue(assetContainsSamples(asset: exportedAsset, track: audioTracks[0]))
    }

    func testExportImageWritesPNGForSelectedCrop() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = rootURL.appendingPathComponent("source.png")
        try writeQuadrantImage(to: sourceURL)

        let outputURL = rootURL.appendingPathComponent("crop.png")
        let request = ClipExportRequest(
            imageURL: sourceURL,
            cropRect: CGRect(x: 0, y: 0, width: 2, height: 2),
            imageSize: CGSize(width: 4, height: 4)
        )

        _ = try await ClipExporter.exportClip(request: request, to: outputURL)

        XCTAssertEqual(outputURL.pathExtension.lowercased(), "png")

        let exportedImage = try XCTUnwrap(NSImage(contentsOf: outputURL))
        XCTAssertEqual(exportedImage.pixelSize.width, 2)
        XCTAssertEqual(exportedImage.pixelSize.height, 2)

        let cgImage = try XCTUnwrap(exportedImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixelData = try XCTUnwrap(cgImage.dataProvider?.data) as Data
        XCTAssertEqual(Array(pixelData.prefix(4)), [255, 0, 0, 255])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private func writeQuadrantImage(to outputURL: URL) throws {
        let width = 4
        let height = 4
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: width * height * 4)

        func setPixel(x: Int, y: Int, red: UInt8, green: UInt8, blue: UInt8) {
            let index = (y * width + x) * 4
            data[index] = red
            data[index + 1] = green
            data[index + 2] = blue
            data[index + 3] = 255
        }

        for y in 0..<height {
            for x in 0..<width {
                if x < 2 && y < 2 {
                    setPixel(x: x, y: y, red: 255, green: 0, blue: 0)
                } else if x >= 2 && y < 2 {
                    setPixel(x: x, y: y, red: 0, green: 255, blue: 0)
                } else if x < 2 && y >= 2 {
                    setPixel(x: x, y: y, red: 0, green: 0, blue: 255)
                } else {
                    setPixel(x: x, y: y, red: 255, green: 255, blue: 0)
                }
            }
        }

        let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count))
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider,
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            XCTFail("Failed to allocate test image data.")
            return
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try pngData.write(to: outputURL)
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
