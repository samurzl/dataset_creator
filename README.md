# VideoDatasetBrowser (macOS)

Native macOS GUI app to browse videos from an input folder, trim clips, and author Advanced Structured NSYNC datasets.

## Features

- Set input and dataset folders from the UI.
- Folder settings persist across app restarts.
- Auto-load all videos from the input folder.
- Large video preview that fills most of the window.
- Playback timeline scrubber below the preview.
- Timeline slider and controls to move through videos in the folder.
- Export selected clips into a dataset root under `positive/<n>.mp4`.
- Append validated Advanced NSYNC rows to `dataset.json`.
- Author per-row captions, categories, negatives, and anchors from the export sheet.

## Dataset output

The selected dataset folder becomes the dataset root. The app writes:

- `dataset.json`
- `positive/<n>.mp4`

The generated dataset rows use the Advanced Structured NSYNC JSON format with fixed `caption`, `media_path`, and `nsync` keys.

## Supported video formats

`mp4`, `mov`, `m4v`, `mkv`, `avi`, `mpg`, `mpeg`, `webm`

## Run in development

```bash
swift run VideoDatasetBrowser
```

## Build .app bundle

```bash
scripts/build_app.sh
```

This creates:

- `dist/VideoDatasetBrowser.app`

## Build and install to Applications

```bash
scripts/build_app.sh --install
```

This copies the app to:

- `/Applications/VideoDatasetBrowser.app`
