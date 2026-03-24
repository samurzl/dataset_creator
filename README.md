# VideoDatasetBrowser (macOS)

Native macOS GUI app to browse videos and images from an input folder, trim or crop them, and author Advanced Structured NSYNC datasets.

## Features

- Set input and dataset folders from the UI.
- Folder settings persist across app restarts.
- Auto-load supported videos and images from the input folder.
- Input videos are normalized to 16 fps before preview and export.
- Large media preview that fills most of the window.
- Playback timeline scrubber for videos and drag-to-crop selection for images.
- Navigation controls to move through media in the folder.
- Export selected videos into `positive/<n>.mp4`, preserving source audio when present.
- Export cropped images into `positive/<n>.png`.
- Append validated Advanced NSYNC rows to `dataset.json`.
- Author per-row caption and categories from the export sheet, with one synthetic negative and one anchor per category generated automatically.
- Prefill the export caption and categories with the last successfully exported values.

## Dataset output

The selected dataset folder becomes the dataset root. The app writes:

- `dataset.json`
- `positive/<n>.mp4`
- `positive/<n>.png`

The generated dataset rows use the Advanced Structured NSYNC JSON format with fixed `caption`, `media_path`, and `nsync` keys.

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
python3 scripts/convert_flat_dataset.py /path/to/input /path/to/output my-category
```

This writes:

- `dataset.json`
- `positive/<n>.<ext>`

The converter expects exactly one `.txt` file and exactly one media file per stem, copies media into `positive/`, applies the same single category to every row, adds one synthetic negative with `caption == prompt == txt contents`, and adds one anchor with `required_categories = [category]`.

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
