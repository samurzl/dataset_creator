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

struct ContentView: View {
    @StateObject private var viewModel = VideoBrowserViewModel()
    @State private var exportRequest: ClipExportRequest?
    @State private var exportAlertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsPanel

            if viewModel.hasVideos {
                videoBrowserView
            } else {
                emptyStateView
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $exportRequest) { request in
            ExportClipSheet(
                request: request,
                onCancel: { exportRequest = nil },
                onExport: { caption in
                    _ = try await viewModel.exportClip(request: request, caption: caption)
                }
            )
        }
        .alert("Export", isPresented: exportAlertIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    private var videoBrowserView: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerPreview(player: viewModel.playerController.player)
                .aspectRatio(viewModel.playerController.videoAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(minHeight: 120)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .layoutPriority(1)

            TimelineThumbnailStrip(
                videoURL: viewModel.selectedVideoURL,
                playerController: viewModel.playerController
            )

            selectionInfoRow

            HStack(spacing: 10) {
                Button(
                    viewModel.playerController.isLoopPlaying ? "Stop" : "Play Loop",
                    action: viewModel.playerController.toggleLoopPlayback
                )
                .disabled(viewModel.playerController.totalFrames <= 1)

                Button("Previous", action: viewModel.selectPreviousVideo)
                    .disabled(!viewModel.hasPreviousVideo)

                Button("Next", action: viewModel.selectNextVideo)
                    .disabled(!viewModel.hasNextVideo)

                Button("Export…", action: beginExport)
                    .disabled(!canOpenExportSheet)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var selectionInfoRow: some View {
        HStack(spacing: 14) {
            Text("Selection: \(formattedSelectionDuration) s")

            Text("Quantized frames (5, 9, 13, ...): \(viewModel.playerController.quantizedSelectedFrameCount)")
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var emptyStateView: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer()

            Text("Select an input folder to load videos")
                .font(.system(size: 18, weight: .semibold))

            Text("Supported formats: mp4, mov, m4v, mkv, avi, mpg, mpeg, webm")
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
                title: "Output Folder",
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
        viewModel.hasConfiguredOutputFolder &&
        ClipSelectionQuantization.isQuantized(viewModel.playerController.selectedFrameCount)
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
            exportRequest = try viewModel.makeExportRequest()
        } catch {
            exportAlertMessage = error.localizedDescription
        }
    }
}
