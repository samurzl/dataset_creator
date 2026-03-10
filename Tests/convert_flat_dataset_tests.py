from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


try:
    from PIL import Image
except ImportError:  # pragma: no cover - local environment dependent
    PIL_AVAILABLE = False
else:
    PIL_AVAILABLE = True


@unittest.skipUnless(PIL_AVAILABLE, "Pillow is required for image validation tests.")
class ConvertFlatDatasetTests(unittest.TestCase):
    def test_skips_unidentified_images(self) -> None:
        with tempfile.TemporaryDirectory() as input_dir_name, tempfile.TemporaryDirectory() as output_dir_name:
            input_dir = Path(input_dir_name)
            output_dir = Path(output_dir_name)

            (input_dir / "1.txt").write_text("valid caption\n", encoding="utf-8")
            Image.new("RGB", (1, 1), color=(255, 0, 0)).save(input_dir / "1.png")

            (input_dir / "2.txt").write_text("bad caption\n", encoding="utf-8")
            (input_dir / "2.png").write_text("not really an image", encoding="utf-8")

            result = subprocess.run(
                [
                    sys.executable,
                    "scripts/convert_flat_dataset.py",
                    str(input_dir),
                    str(output_dir),
                    "category",
                ],
                cwd=Path(__file__).resolve().parent.parent,
                capture_output=True,
                text=True,
                check=True,
            )

            dataset = json.loads((output_dir / "dataset.json").read_text(encoding="utf-8"))
            self.assertEqual(len(dataset), 1)
            self.assertEqual(dataset[0]["caption"], "valid caption")
            self.assertEqual(dataset[0]["media_path"], "positive/1.png")
            self.assertTrue((output_dir / "positive" / "1.png").exists())
            self.assertFalse((output_dir / "positive" / "2.png").exists())
            self.assertIn("warning: skipping unreadable media", result.stderr)


if __name__ == "__main__":
    unittest.main()
