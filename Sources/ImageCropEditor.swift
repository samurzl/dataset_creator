import AppKit
import CoreGraphics
import SwiftUI

enum BrowserMediaKind: String {
    case video
    case image
}

struct BrowserMediaItem: Identifiable, Equatable {
    let sourceURL: URL
    let kind: BrowserMediaKind

    var id: URL {
        sourceURL
    }
}

@MainActor
final class ImageCropController: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var imagePixelSize: CGSize = .zero
    @Published private(set) var cropRectNormalized: CGRect?

    private var activeURL: URL?

    var hasLoadedImage: Bool {
        image != nil && imagePixelSize.width > 0 && imagePixelSize.height > 0
    }

    var hasCustomCrop: Bool {
        cropRectNormalized != nil
    }

    var imageAspectRatio: CGFloat {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return 16.0 / 9.0
        }
        return imagePixelSize.width / imagePixelSize.height
    }

    var cropPixelSize: CGSize {
        exportCropRectPixels.size
    }

    var exportCropRectPixels: CGRect {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return .zero
        }

        let normalizedRect = cropRectNormalized ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let imageWidth = imagePixelSize.width
        let imageHeight = imagePixelSize.height

        let minX = min(max(Int((normalizedRect.minX * imageWidth).rounded(.down)), 0), max(Int(imageWidth) - 1, 0))
        let minY = min(max(Int((normalizedRect.minY * imageHeight).rounded(.down)), 0), max(Int(imageHeight) - 1, 0))
        let maxX = max(min(Int((normalizedRect.maxX * imageWidth).rounded(.up)), Int(imageWidth)), minX + 1)
        let maxY = max(min(Int((normalizedRect.maxY * imageHeight).rounded(.up)), Int(imageHeight)), minY + 1)

        return CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    func loadImage(at url: URL) {
        activeURL = url

        guard let image = NSImage(contentsOf: url) else {
            clearImage()
            return
        }

        let pixelSize = image.pixelSize
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            clearImage()
            return
        }

        self.image = image
        imagePixelSize = pixelSize
        cropRectNormalized = nil
    }

    func clearImage() {
        activeURL = nil
        image = nil
        imagePixelSize = .zero
        cropRectNormalized = nil
    }

    func resetCrop() {
        guard hasLoadedImage else { return }
        cropRectNormalized = nil
    }

    func replaceCrop(withDisplayRect displayRect: CGRect, in imageFrame: CGRect) {
        guard hasLoadedImage, imageFrame.width > 0, imageFrame.height > 0 else { return }

        let boundedRect = displayRect.standardized.intersection(imageFrame)
        guard boundedRect.width >= 4, boundedRect.height >= 4 else { return }

        let normalizedRect = CGRect(
            x: (boundedRect.minX - imageFrame.minX) / imageFrame.width,
            y: (boundedRect.minY - imageFrame.minY) / imageFrame.height,
            width: boundedRect.width / imageFrame.width,
            height: boundedRect.height / imageFrame.height
        )
        .standardized
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        guard normalizedRect.width > 0, normalizedRect.height > 0 else { return }
        cropRectNormalized = normalizedRect
    }

    func displayedCropRect(in imageFrame: CGRect) -> CGRect? {
        guard let cropRectNormalized else { return nil }

        return CGRect(
            x: imageFrame.minX + (cropRectNormalized.minX * imageFrame.width),
            y: imageFrame.minY + (cropRectNormalized.minY * imageFrame.height),
            width: cropRectNormalized.width * imageFrame.width,
            height: cropRectNormalized.height * imageFrame.height
        )
    }
}

struct ImageCropEditor: View {
    @ObservedObject var controller: ImageCropController

    @State private var dragStartPoint: CGPoint?
    @State private var draftCropRect: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = geometry.size
            let imageFrame = fittedRect(for: controller.imagePixelSize, inside: canvasSize)
            let visibleCropRect = draftCropRect ?? controller.displayedCropRect(in: imageFrame)

            ZStack(alignment: .topLeading) {
                Color.secondary.opacity(0.1)

                if let image = controller.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)

                    if let visibleCropRect {
                        cropOverlay(imageFrame: imageFrame, cropRect: visibleCropRect)
                    }

                    Text(controller.hasCustomCrop ? "Drag to replace crop" : "Drag to crop")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.7))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(10)
                } else {
                    VStack(spacing: 8) {
                        Text("Image preview unavailable")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Choose a supported image to enable cropping.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(cropGesture(imageFrame: imageFrame))
        }
    }

    private func cropOverlay(imageFrame: CGRect, cropRect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(imageFrame)
                path.addRect(cropRect)
            }
            .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .shadow(color: Color.black.opacity(0.45), radius: 6)
        }
    }

    private func cropGesture(imageFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard controller.hasLoadedImage else { return }
                guard imageFrame.width > 0, imageFrame.height > 0 else { return }

                if dragStartPoint == nil {
                    guard imageFrame.contains(value.startLocation) else { return }
                    dragStartPoint = clampedPoint(value.startLocation, to: imageFrame)
                }

                guard let dragStartPoint else { return }
                let currentPoint = clampedPoint(value.location, to: imageFrame)
                draftCropRect = rect(from: dragStartPoint, to: currentPoint)
            }
            .onEnded { value in
                defer {
                    dragStartPoint = nil
                    draftCropRect = nil
                }

                guard controller.hasLoadedImage else { return }
                guard let dragStartPoint else { return }

                let currentPoint = clampedPoint(value.location, to: imageFrame)
                controller.replaceCrop(
                    withDisplayRect: rect(from: dragStartPoint, to: currentPoint),
                    in: imageFrame
                )
            }
    }

    private func fittedRect(for imageSize: CGSize, inside canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 else {
            return .zero
        }

        let scale = min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale

        return CGRect(
            x: (canvasSize.width - width) / 2,
            y: (canvasSize.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func clampedPoint(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func rect(from startPoint: CGPoint, to endPoint: CGPoint) -> CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}

extension NSImage {
    var pixelSize: CGSize {
        let proposedRect = NSRect(origin: .zero, size: size)

        if let bestRepresentation = bestRepresentation(for: proposedRect, context: nil, hints: nil),
           bestRepresentation.pixelsWide > 0,
           bestRepresentation.pixelsHigh > 0 {
            return CGSize(width: bestRepresentation.pixelsWide, height: bestRepresentation.pixelsHigh)
        }

        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }

        return size
    }
}
