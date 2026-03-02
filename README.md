# VideoDatasetBrowser (macOS)

Native macOS GUI app to browse videos from an input folder with a large preview area and timeline controls.

## Features

- Set input and output folders from the UI.
- Folder settings persist across app restarts.
- Auto-load all videos from the input folder.
- Large video preview that fills most of the window.
- Playback timeline scrubber below the preview.
- Timeline slider and controls to move through videos in the folder.

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
