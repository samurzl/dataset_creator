import AVFAudio
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

    func testPreparedURLConvertsAnimatedGIFToMP4AtDefaultFrameRate() async throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let sourceURL = try makeAnimatedGIF(in: rootURL)
        let resampler = InputVideoResampler()

        let preparedURL = try await resampler.preparedURL(for: sourceURL)

        XCTAssertEqual(preparedURL.pathExtension.lowercased(), "mp4")

        let preparedAsset = AVAsset(url: preparedURL)
        let videoTracks = try await preparedAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
        let frameColors = try await centerColorsByFrame(in: preparedURL)

        XCTAssertEqual(
            nominalFrameRate,
            Double(InputVideoResampler.defaultTargetFrameRate),
            accuracy: 0.25
        )
        XCTAssertEqual(frameColors.count, ClipSelectionQuantization.minimumFrameCount)

        let firstColor = try XCTUnwrap(frameColors.first)
        let greenFrame = try XCTUnwrap(frameColors.first { color in
            Int(color.green) > 150 && Int(color.red) < 120
        })

        XCTAssertGreaterThan(Int(firstColor.red), 150)
        XCTAssertLessThan(Int(firstColor.green), 120)
        XCTAssertGreaterThan(Int(greenFrame.green), 150)
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

    private struct PixelColor {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    private func makeAnimatedGIF(in rootURL: URL) throws -> URL {
        let outputURL = rootURL.appendingPathComponent("animated.gif")

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            2,
            nil
        ) else {
            throw XCTSkip("Unable to create GIF destination.")
        }

        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.25
            ]
        ]
        CGImageDestinationAddImage(
            destination,
            try makeSolidImage(red: 255, green: 0, blue: 0),
            frameProperties as CFDictionary
        )
        CGImageDestinationAddImage(
            destination,
            try makeSolidImage(red: 0, green: 255, blue: 0),
            frameProperties as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("Unable to finalize GIF fixture.")
        }

        return outputURL
    }

    private func makeSolidImage(red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let width = 16
        let height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Unable to create GIF fixture image context.")
        }

        context.setFillColor(
            CGColor(
                red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: 1
            )
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let image = context.makeImage() else {
            throw XCTSkip("Unable to create GIF fixture frame.")
        }

        return image
    }

    private func centerColorsByFrame(in videoURL: URL) async throws -> [PixelColor] {
        let asset = AVAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
        )

        guard reader.canAdd(output) else {
            XCTFail("Failed to add video reader output.")
            return []
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? InputVideoResampleError.readerFailed(underlying: nil)
        }

        var colors: [PixelColor] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            colors.append(try centerColor(from: pixelBuffer))
        }

        guard reader.status == .completed else {
            throw reader.error ?? InputVideoResampleError.readerFailed(underlying: nil)
        }

        return colors
    }

    private func centerColor(from pixelBuffer: CVPixelBuffer) throws -> PixelColor {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw XCTSkip("Missing decoded frame base address.")
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let centerX = max(width / 2, 0)
        let centerY = max(height / 2, 0)
        let row = baseAddress.advanced(by: centerY * bytesPerRow)
        let pixel = row.advanced(by: centerX * 4)
        let bytes = pixel.assumingMemoryBound(to: UInt8.self)

        return PixelColor(
            red: bytes[2],
            green: bytes[1],
            blue: bytes[0]
        )
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
