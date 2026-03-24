import AppKit
import Foundation
import SwiftUI

@main
struct VideoDatasetBrowserApp: App {
    var body: some Scene {
        WindowGroup("Video Dataset Browser") {
            ContentView()
        }
        .defaultSize(width: 1200, height: 820)
        .windowResizability(.automatic)
    }
}

@MainActor
final class ExportWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?

    func present(
        request: ClipExportRequest,
        initialCaption: String,
        initialCategoryText: String,
        onExport: @escaping (DatasetRowInput) async throws -> Void
    ) {
        close()

        let rootView = ExportClipSheet(
            request: request,
            initialCaptionText: initialCaption,
            initialCategoryText: initialCategoryText,
            onCancel: { [weak self] in
                self?.close()
            },
            onExport: onExport
        )

        let hostingController = NSHostingController(rootView: rootView)
        let exportWindow = NSWindow(contentViewController: hostingController)
        exportWindow.title = "Add Dataset Row"
        exportWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        exportWindow.delegate = self
        exportWindow.minSize = .zero
        exportWindow.contentMinSize = .zero
        exportWindow.isReleasedWhenClosed = false

        setInitialFrame(for: exportWindow, relativeTo: NSApp.keyWindow ?? NSApp.mainWindow)

        window = exportWindow
        exportWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow == window else {
            return
        }
        window = nil
    }

    private func setInitialFrame(for exportWindow: NSWindow, relativeTo parentWindow: NSWindow?) {
        let fallbackSize = NSSize(width: 960, height: 680)

        guard let parentWindow else {
            exportWindow.setContentSize(fallbackSize)
            return
        }

        let parentFrame = parentWindow.frame
        let width = max(parentFrame.width * 0.88, 520)
        let height = max(parentFrame.height * 0.88, 420)
        let origin = NSPoint(
            x: parentFrame.midX - (width / 2),
            y: parentFrame.midY - (height / 2)
        )

        exportWindow.setFrame(
            NSRect(origin: origin, size: NSSize(width: width, height: height)),
            display: false
        )
    }
}

struct ContentView: View {
    @StateObject private var viewModel = VideoBrowserViewModel()
    @StateObject private var exportWindowCoordinator = ExportWindowCoordinator()
    @State private var exportAlertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsPanel

            if viewModel.hasMedia {
                mediaBrowserView
            } else {
                emptyStateView
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear(perform: exportWindowCoordinator.close)
        .alert("Dataset", isPresented: exportAlertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    private var mediaBrowserView: some View {
        VStack(alignment: .leading, spacing: 12) {
            mediaPreview

            if viewModel.isShowingVideo {
                TimelineThumbnailStrip(
                    videoURL: viewModel.selectedMediaURL,
                    playerController: viewModel.playerController
                )
            }

            selectionInfoRow

            HStack(spacing: 10) {
                if viewModel.isShowingVideo {
                    Button(
                        viewModel.playerController.isLoopPlaying ? "Stop" : "Play Loop",
                        action: viewModel.playerController.toggleLoopPlayback
                    )
                    .disabled(viewModel.playerController.totalFrames <= 1)
                }

                if viewModel.isShowingImage {
                    Button("Reset Crop", action: viewModel.imageCropController.resetCrop)
                        .disabled(!viewModel.imageCropController.hasCustomCrop)
                }

                Button("Previous", action: viewModel.selectPreviousMedia)
                    .disabled(!viewModel.hasPreviousMedia)

                Button("Next", action: viewModel.selectNextMedia)
                    .disabled(!viewModel.hasNextMedia)

                Button("Add to Dataset…", action: beginExport)
                    .disabled(!canOpenExportSheet)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var mediaPreview: some View {
        Group {
            if viewModel.isShowingImage {
                ImageCropEditor(controller: viewModel.imageCropController)
                    .aspectRatio(viewModel.imageCropController.imageAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .frame(minHeight: 120)
                    .layoutPriority(1)
            } else {
                PlayerPreview(player: viewModel.playerController.player)
                    .aspectRatio(viewModel.playerController.videoAspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .frame(minHeight: 120)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .layoutPriority(1)
            }
        }
    }

    private var selectionInfoRow: some View {
        HStack(spacing: 14) {
            if viewModel.isShowingVideo {
                Text("Selection: \(formattedSelectionDuration) s")
                Text("Quantized frames (5, 9, 13, ...): \(viewModel.playerController.quantizedSelectedFrameCount)")
            } else if viewModel.isShowingImage {
                Text(viewModel.selectedImageCropLabel)
            }

            Spacer()

            Text(viewModel.mediaCountLabel)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var emptyStateView: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer()

            Text("Select an input folder to load videos or images")
                .font(.system(size: 18, weight: .semibold))

            Text("Supported formats: mp4, mov, m4v, mkv, avi, mpg, mpeg, webm, png, jpg, jpeg, webp, heic, heif, bmp, tif, tiff, gif")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            folderRow(
                title: "Input Folder",
                path: viewModel.inputFolderPath,
                action: viewModel.chooseInputFolder
            )

            folderRow(
                title: "Dataset Folder",
                path: viewModel.outputFolderPath,
                action: viewModel.chooseOutputFolder
            )
        }
        .padding(12)
        .background(Color.secondary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func folderRow(title: String, path: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 95, alignment: .leading)

            Text(path.isEmpty ? "Not set" : path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Choose…", action: action)
        }
    }

    private var formattedSelectionDuration: String {
        String(format: "%.3f", viewModel.playerController.selectedDurationSeconds)
    }

    private var canOpenExportSheet: Bool {
        guard viewModel.hasConfiguredOutputFolder else {
            return false
        }

        if viewModel.isShowingImage {
            return viewModel.imageCropController.hasLoadedImage
        }

        return ClipSelectionQuantization.isQuantized(viewModel.playerController.selectedFrameCount)
    }

    private var exportAlertIsPresented: Binding<Bool> {
        Binding(
            get: { exportAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportAlertMessage = nil
                }
            }
        )
    }

    private func beginExport() {
        do {
            let request = try viewModel.makeExportRequest()
            exportWindowCoordinator.present(
                request: request,
                initialCaption: viewModel.lastExportCaption,
                initialCategoryText: viewModel.lastExportCategoryText
            ) { input in
                _ = try await viewModel.exportClip(request: request, input: input)
                viewModel.rememberLastExport(input: input)
            }
        } catch {
            exportAlertMessage = error.localizedDescription
        }
    }
}
