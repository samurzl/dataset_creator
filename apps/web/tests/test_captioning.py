from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from web_dataset_creator.captioning import CaptionQueueStore


class CaptionQueueStoreTests(unittest.TestCase):
    def test_queue_persists_claim_and_completion(self) -> None:
        with tempfile.TemporaryDirectory() as state_name, tempfile.TemporaryDirectory() as dataset_name:
            queue = CaptionQueueStore(Path(state_name))
            job = queue.enqueue(
                "job-1",
                Path(dataset_name),
                "positive/1.mp4",
                Path(dataset_name) / "positive/1.mp4",
            )

            self.assertEqual(job.status, "pending")
            claimed = queue.claim_next()
            self.assertIsNotNone(claimed)
            self.assertEqual(claimed.status, "running")
            self.assertEqual(claimed.attempts, 1)

            queue.complete("job-1", "caption", ["tag"])
            reloaded = CaptionQueueStore(Path(state_name)).list_jobs()
            self.assertEqual(reloaded[0].status, "done")
            self.assertEqual(reloaded[0].caption, "caption")
            self.assertEqual(reloaded[0].tags, ["tag"])


if __name__ == "__main__":
    unittest.main()

