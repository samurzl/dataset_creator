# VideoDatasetBrowser (macOS)

Native macOS GUI app to browse videos and images from an input folder, trim or crop them, and author flat captioned datasets.

## Features

- Set input and dataset folders from the UI.
- Folder settings persist across app restarts.
- Auto-load supported videos and images from the input folder.
- Input videos are normalized to 16 fps before preview and export.
- Large media preview that fills most of the window.
- Playback timeline scrubber for videos and drag-to-crop selection for both videos and images.
- Navigation controls to move through media in the folder.
- Export selected videos into `positive/<n>.mp4`, preserving source audio when present.
- Export cropped images into `positive/<n>.png`.
- Append validated flat rows to `dataset.json`.
- Author a caption for each exported row from the export sheet.
- Prefill the export caption with the last successfully exported value.

## Dataset output

The selected dataset folder becomes the dataset root. The app writes:

- `dataset.json`
- `positive/<n>.mp4`
- `positive/<n>.png`

The generated dataset rows use a flat JSON format with fixed `caption` and `media_path` keys:

```json
[
  {
    "caption": "A woman walking through a rainy city street at night, neon reflections on the wet pavement.",
    "media_path": "positive/1.mp4"
  },
  {
    "caption": "A static portrait of a red bicycle leaning against a white wall.",
    "media_path": "positive/2.png"
  }
]
```

## Flat dataset conversion helper

If you already have a flat dataset like:

```text
dataset/
  1.mp4
  1.txt
  2.png
  2.txt
```

you can convert it into this repo's dataset format with:

```bash
python3 scripts/convert_flat_dataset.py /path/to/input /path/to/output
```

This writes:

- `dataset.json`
- `positive/<n>.<ext>`

The converter expects exactly one `.txt` file and exactly one media file per stem, copies media into `positive/`, and writes one flat row per pair with the caption taken from the `.txt` file.

If Pillow is installed, unreadable image files are skipped with a warning and are not copied into `positive/` or included in `dataset.json`.

## Supported media formats

Videos: `mp4`, `mov`, `m4v`, `mkv`, `avi`, `mpg`, `mpeg`, `webm`

Images: `png`, `jpg`, `jpeg`, `webp`, `heic`, `heif`, `bmp`, `tif`, `tiff`, `gif`

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
