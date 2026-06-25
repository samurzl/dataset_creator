from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
import json
from pathlib import Path
from threading import RLock
from typing import Any, Iterator


SUPPORTED_POSITIVE_MEDIA_EXTENSIONS = {
    "mp4",
    "mov",
    "m4v",
    "mkv",
    "avi",
    "mpg",
    "mpeg",
    "webm",
    "png",
    "jpg",
    "jpeg",
    "webp",
    "heic",
    "heif",
    "bmp",
    "tif",
    "tiff",
    "gif",
}

LEGACY_DATASET_KEYS = {"nsync", "negative_caption", "negative_media_path"}
_DATASET_LOCKS: dict[str, RLock] = {}
_DATASET_LOCKS_LOCK = RLock()


class DatasetError(ValueError):
    pass


@dataclass
class PreparedDatasetAppend:
    rows: list[dict[str, Any]]
    output_media_path: str
    output_media_url: Path


def dataset_lock(root: Path) -> RLock:
    key = str(root.expanduser().resolve())
    with _DATASET_LOCKS_LOCK:
        lock = _DATASET_LOCKS.get(key)
        if lock is None:
            lock = RLock()
            _DATASET_LOCKS[key] = lock
        return lock


@contextmanager
def locked_dataset(root: Path) -> Iterator[None]:
    lock = dataset_lock(root)
    lock.acquire()
    try:
        yield
    finally:
        lock.release()


class DatasetStore:
    def __init__(self, dataset_root: Path) -> None:
        self.dataset_root = dataset_root.expanduser().resolve()

    @property
    def dataset_path(self) -> Path:
        return self.dataset_root / "dataset.json"

    @property
    def positive_dir(self) -> Path:
        return self.dataset_root / "positive"

    def load_rows(self) -> list[dict[str, Any]]:
        if not self.dataset_path.exists():
            return []

        try:
            raw_data = json.loads(self.dataset_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise DatasetError(f"dataset.json is not valid JSON: {exc}") from exc

        if not isinstance(raw_data, list):
            raise DatasetError("dataset.json must contain a top-level array of objects.")

        rows: list[dict[str, Any]] = []
        for index, raw_row in enumerate(raw_data):
            if not isinstance(raw_row, dict):
                raise DatasetError(f"Row {index + 1} in dataset.json must be an object.")
            rows.append(self._normalized_row(index, raw_row))

        return self._validated_rows(rows)

    def prepare_append(
        self,
        caption: str,
        media_file_extension: str,
        extras: dict[str, Any] | None = None,
    ) -> PreparedDatasetAppend:
        self._validate_supported_dataset_files()
        existing_rows = self.load_rows()
        next_media_path = self._next_positive_media_path(existing_rows, media_file_extension)
        new_row = self._normalized_row(
            len(existing_rows),
            {
                "caption": caption,
                "media_path": next_media_path,
                **(extras or {}),
            },
        )
        rows = self._validated_rows(existing_rows + [new_row])
        return PreparedDatasetAppend(
            rows=rows,
            output_media_path=next_media_path,
            output_media_url=self.dataset_root / next_media_path,
        )

    def commit(self, prepared_append: PreparedDatasetAppend) -> None:
        self.dataset_root.mkdir(parents=True, exist_ok=True)
        self.positive_dir.mkdir(parents=True, exist_ok=True)
        self._write_rows(prepared_append.rows)

    def update_caption(
        self,
        media_path: str,
        caption: str,
        caption_status: str,
        extras: dict[str, Any] | None = None,
    ) -> None:
        rows = self.load_rows()
        trimmed_caption = caption.strip()
        if not trimmed_caption:
            raise DatasetError("Generated caption cannot be blank.")

        target_path = self._normalize_path(media_path)
        did_update = False
        for row in rows:
            if self._normalize_path(str(row.get("media_path", ""))) != target_path:
                continue
            row["caption"] = trimmed_caption
            row["caption_status"] = caption_status
            for key, value in (extras or {}).items():
                if key not in {"caption", "media_path"} and key not in LEGACY_DATASET_KEYS:
                    row[key] = value
            did_update = True
            break

        if not did_update:
            raise DatasetError(f"No dataset row found for '{media_path}'.")

        self._write_rows(self._validated_rows(rows))

    def mark_caption_failed(self, media_path: str, error: str) -> None:
        rows = self.load_rows()
        target_path = self._normalize_path(media_path)
        for row in rows:
            if self._normalize_path(str(row.get("media_path", ""))) == target_path:
                row["caption_status"] = "failed"
                row["caption_error"] = error[:2_000]
                self._write_rows(self._validated_rows(rows))
                return

    def _write_rows(self, rows: list[dict[str, Any]]) -> None:
        self.dataset_root.mkdir(parents=True, exist_ok=True)
        tmp_path = self.dataset_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp_path.replace(self.dataset_path)

    def _validate_supported_dataset_files(self) -> None:
        for file_name in ("dataset.jsonl", "dataset.csv"):
            if (self.dataset_root / file_name).exists():
                raise DatasetError(f"Unsupported dataset file found: {file_name}. This app only supports dataset.json.")

    def _normalized_row(self, row_index: int, row: dict[str, Any]) -> dict[str, Any]:
        caption = row.get("caption")
        media_path = row.get("media_path")
        if not isinstance(caption, str):
            raise DatasetError(f"Row {row_index + 1} is missing the required string field 'caption'.")
        if not isinstance(media_path, str):
            raise DatasetError(f"Row {row_index + 1} is missing the required string field 'media_path'.")

        trimmed_caption = caption.strip()
        trimmed_media_path = media_path.strip()
        if not trimmed_caption:
            raise DatasetError(f"Row {row_index + 1} has a blank 'caption' field.")
        if not trimmed_media_path:
            raise DatasetError(f"Row {row_index + 1} has a blank 'media_path' field.")

        normalized = {
            "caption": trimmed_caption,
            "media_path": self._normalize_path(trimmed_media_path),
        }
        for key, value in row.items():
            if key in {"caption", "media_path"} or key in LEGACY_DATASET_KEYS:
                continue
            normalized[key] = value
        return normalized

    def _validated_rows(self, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        normalized_rows = [self._normalized_row(index, row) for index, row in enumerate(rows)]
        sample_paths: set[str] = set()
        for row in normalized_rows:
            collapsed = self._collapsed_sample_path(str(row["media_path"]))
            if collapsed in sample_paths:
                raise DatasetError(f"Multiple rows collapse to the same future sample path '{collapsed}'.")
            sample_paths.add(collapsed)
        return normalized_rows

    def _next_positive_media_path(self, rows: list[dict[str, Any]], media_file_extension: str) -> str:
        normalized_extension = media_file_extension.strip().lstrip(".").lower() or "mp4"
        max_index = 0

        if self.positive_dir.exists():
            for path in self.positive_dir.iterdir():
                if path.suffix.lower().lstrip(".") not in SUPPORTED_POSITIVE_MEDIA_EXTENSIONS:
                    continue
                try:
                    max_index = max(max_index, int(path.stem))
                except ValueError:
                    continue

        for row in rows:
            normalized_path = self._normalize_path(str(row["media_path"]))
            parts = normalized_path.split("/")
            if len(parts) != 2 or parts[0] != "positive":
                continue
            try:
                max_index = max(max_index, int(Path(parts[1]).stem))
            except ValueError:
                continue

        return f"positive/{max_index + 1}.{normalized_extension}"

    @staticmethod
    def _collapsed_sample_path(media_path: str) -> str:
        normalized_path = DatasetStore._normalize_path(media_path)
        return str(Path(normalized_path).with_suffix(".pt")).replace("\\", "/")

    @staticmethod
    def _normalize_path(path: str) -> str:
        normalized_slashes = path.replace("\\", "/")
        is_absolute = normalized_slashes.startswith("/")
        parts: list[str] = []
        for component in normalized_slashes.split("/"):
            if component in {"", "."}:
                continue
            if component == "..":
                if parts and parts[-1] != "..":
                    parts.pop()
                elif not is_absolute:
                    parts.append(component)
                continue
            parts.append(component)
        joined = "/".join(parts)
        return f"/{joined}" if is_absolute else joined

