#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SourcePair:
    stem: str
    media_path: Path
    caption_path: Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Convert a flat dataset like 1.mp4 + 1.txt into this repo's dataset format "
            "with positive/<n>.<ext> and dataset.json."
        )
    )
    parser.add_argument("input_dir", type=Path, help="Directory containing flat media/txt pairs.")
    parser.add_argument("output_dir", type=Path, help="Directory to write dataset.json and positive/.")
    parser.add_argument("category", help="Single category applied to every dataset row.")
    return parser.parse_args()


def natural_sort_key(value: str) -> list[object]:
    parts = re.split(r"(\d+)", value)
    key: list[object] = []
    for part in parts:
        if not part:
            continue
        if part.isdigit():
            key.append(int(part))
        else:
            key.append(part.lower())
    return key


def collect_pairs(input_dir: Path) -> list[SourcePair]:
    grouped: dict[str, dict[str, object]] = {}

    for path in sorted(input_dir.iterdir(), key=lambda item: natural_sort_key(item.name)):
        if not path.is_file():
            continue

        stem = path.stem
        entry = grouped.setdefault(stem, {"text": None, "media": []})

        if path.suffix.lower() == ".txt":
            if entry["text"] is not None:
                raise ValueError(f"Multiple caption files found for stem '{stem}'.")
            entry["text"] = path
            continue

        media_paths = entry["media"]
        assert isinstance(media_paths, list)
        media_paths.append(path)

    if not grouped:
        raise ValueError(f"No files found in '{input_dir}'.")

    pairs: list[SourcePair] = []
    errors: list[str] = []

    for stem in sorted(grouped, key=natural_sort_key):
        entry = grouped[stem]
        caption_path = entry["text"]
        media_paths = entry["media"]

        if caption_path is None:
            errors.append(f"Missing caption file for stem '{stem}'.")
            continue

        assert isinstance(media_paths, list)
        if not media_paths:
            errors.append(f"Missing media file for stem '{stem}'.")
            continue

        if len(media_paths) > 1:
            listed_paths = ", ".join(
                path.name for path in sorted(media_paths, key=lambda candidate: natural_sort_key(candidate.name))
            )
            errors.append(f"Multiple media files found for stem '{stem}': {listed_paths}.")
            continue

        pairs.append(SourcePair(stem=stem, media_path=media_paths[0], caption_path=caption_path))

    if errors:
        raise ValueError("\n".join(errors))

    return pairs


def ensure_output_dir(output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)

    dataset_json = output_dir / "dataset.json"
    if dataset_json.exists():
        raise ValueError(f"Refusing to overwrite existing file '{dataset_json}'.")

    positive_dir = output_dir / "positive"
    if positive_dir.exists() and not positive_dir.is_dir():
        raise ValueError(f"Output path '{positive_dir}' exists and is not a directory.")
    if positive_dir.exists() and any(positive_dir.iterdir()):
        raise ValueError(f"Refusing to write into non-empty directory '{positive_dir}'.")


def convert_dataset(input_dir: Path, output_dir: Path, category: str) -> tuple[int, Path]:
    trimmed_category = category.strip()
    if not trimmed_category:
        raise ValueError("Category must not be blank.")

    if not input_dir.exists():
        raise ValueError(f"Input directory '{input_dir}' does not exist.")
    if not input_dir.is_dir():
        raise ValueError(f"Input path '{input_dir}' is not a directory.")

    ensure_output_dir(output_dir)
    positive_dir = output_dir / "positive"
    positive_dir.mkdir(parents=True, exist_ok=True)

    rows = []

    for index, pair in enumerate(collect_pairs(input_dir), start=1):
        caption = pair.caption_path.read_text(encoding="utf-8").strip()
        if not caption:
            raise ValueError(f"Caption file '{pair.caption_path}' is empty.")

        destination_name = f"{index}{pair.media_path.suffix.lower()}"
        destination_path = positive_dir / destination_name
        shutil.copy2(pair.media_path, destination_path)

        rows.append(
            {
                "caption": caption,
                "media_path": f"positive/{destination_name}",
                "nsync": {
                    "categories": [trimmed_category],
                    "negatives": [
                        {
                            "media": "synthetic",
                            "prompt": caption,
                            "caption": caption,
                        }
                    ],
                    "anchors": [
                        {
                            "required_categories": [trimmed_category],
                        }
                    ],
                },
            }
        )

    dataset_json = output_dir / "dataset.json"
    dataset_json.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    return len(rows), dataset_json


def main() -> int:
    args = parse_args()

    try:
        row_count, dataset_json = convert_dataset(
            input_dir=args.input_dir.expanduser().resolve(),
            output_dir=args.output_dir.expanduser().resolve(),
            category=args.category,
        )
    except (OSError, UnicodeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Wrote {row_count} rows to {dataset_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
