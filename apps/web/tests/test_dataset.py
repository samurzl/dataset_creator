from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from web_dataset_creator.dataset import DatasetError, DatasetStore, locked_dataset


class DatasetStoreTests(unittest.TestCase):
    def test_append_and_update_caption(self) -> None:
        with tempfile.TemporaryDirectory() as root_name:
            root = Path(root_name)
            store = DatasetStore(root)

            with locked_dataset(root):
                prepared = store.prepare_append(
                    "Automatic caption pending.",
                    "mp4",
                    {"caption_status": "pending", "caption_job_id": "job-1"},
                )
                prepared.output_media_url.parent.mkdir(parents=True, exist_ok=True)
                prepared.output_media_url.write_bytes(b"video")
                store.commit(prepared)
                store.update_caption(
                    prepared.output_media_path,
                    "A real generated caption.",
                    "done",
                    {"wd_tags": ["close up", "smile"]},
                )

            rows = json.loads((root / "dataset.json").read_text(encoding="utf-8"))
            self.assertEqual(rows[0]["caption"], "A real generated caption.")
            self.assertEqual(rows[0]["caption_status"], "done")
            self.assertEqual(rows[0]["caption_job_id"], "job-1")
            self.assertEqual(rows[0]["wd_tags"], ["close up", "smile"])

    def test_duplicate_collapsed_sample_paths_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as root_name:
            root = Path(root_name)
            (root / "dataset.json").write_text(
                json.dumps(
                    [
                        {"caption": "first", "media_path": "positive/1.mp4"},
                        {"caption": "second", "media_path": "positive/1.mov"},
                    ]
                ),
                encoding="utf-8",
            )

            with self.assertRaises(DatasetError):
                DatasetStore(root).load_rows()


if __name__ == "__main__":
    unittest.main()

