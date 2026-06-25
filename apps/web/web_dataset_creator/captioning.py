from __future__ import annotations

from dataclasses import asdict, dataclass, field
import asyncio
import csv
import json
from pathlib import Path
import shlex
import subprocess
import time
from threading import RLock
from typing import Any
from uuid import uuid4

from .dataset import DatasetStore, locked_dataset
from .media import extract_middle_frame, temporary_jpeg_path
from .settings import CaptionConfig, SettingsStore


PENDING_CAPTION_TEXT = "Automatic caption pending."


@dataclass
class CaptionJob:
    id: str
    dataset_root: str
    media_path: str
    absolute_media_path: str
    status: str = "pending"
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    attempts: int = 0
    tags: list[str] = field(default_factory=list)
    caption: str = ""
    error: str = ""


def new_caption_job_id() -> str:
    return str(uuid4())


def ltx_caption_prompt(tags: list[str]) -> str:
    tag_text = ", ".join(tags) if tags else "no tags available"
    return (
        "You are writing one caption for an LTX 2.3 video training dataset. "
        "Use the supplied full video clip as the source of truth and use the WD tags only as hints. "
        "Write a single detailed paragraph in present tense. Describe the main subject, the action as it changes over time, "
        "the setting, lighting, color, material details, shot scale, framing, camera movement, and any audible speech, music, "
        "or ambient sound. Keep it factual and avoid hallucinating identities, readable text, logos, or dialogue unless they "
        "are clear in the clip. Do not write bullets, labels, markdown, or a tag list. Aim for 60 to 140 words.\n\n"
        f"WD tags from the middle frame: {tag_text}"
    )


class CaptionQueueStore:
    def __init__(self, state_dir: Path) -> None:
        self.state_dir = state_dir
        self.queue_path = self.state_dir / "caption_jobs.json"
        self._lock = RLock()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        if not self.queue_path.exists():
            self._write_jobs([])

    def enqueue(
        self,
        job_id: str,
        dataset_root: Path,
        media_path: str,
        absolute_media_path: Path,
    ) -> CaptionJob:
        with self._lock:
            jobs = self._read_jobs()
            job = CaptionJob(
                id=job_id,
                dataset_root=str(dataset_root),
                media_path=media_path,
                absolute_media_path=str(absolute_media_path),
            )
            jobs.append(job)
            self._write_jobs(jobs)
            return job

    def list_jobs(self, dataset_root: Path | None = None) -> list[CaptionJob]:
        with self._lock:
            jobs = self._read_jobs()
        if dataset_root is None:
            return jobs
        resolved_root = str(dataset_root.expanduser().resolve())
        return [job for job in jobs if str(Path(job.dataset_root).expanduser().resolve()) == resolved_root]

    def retry(self, job_id: str) -> CaptionJob:
        with self._lock:
            jobs = self._read_jobs()
            for job in jobs:
                if job.id == job_id:
                    job.status = "pending"
                    job.error = ""
                    job.updated_at = time.time()
                    self._write_jobs(jobs)
                    return job
        raise KeyError(job_id)

    def claim_next(self) -> CaptionJob | None:
        with self._lock:
            jobs = self._read_jobs()
            for job in jobs:
                if job.status != "pending":
                    continue
                job.status = "running"
                job.attempts += 1
                job.error = ""
                job.updated_at = time.time()
                self._write_jobs(jobs)
                return job
        return None

    def complete(self, job_id: str, caption: str, tags: list[str]) -> None:
        with self._lock:
            jobs = self._read_jobs()
            for job in jobs:
                if job.id == job_id:
                    job.status = "done"
                    job.caption = caption
                    job.tags = tags
                    job.error = ""
                    job.updated_at = time.time()
                    self._write_jobs(jobs)
                    return

    def fail(self, job_id: str, error: str) -> None:
        with self._lock:
            jobs = self._read_jobs()
            for job in jobs:
                if job.id == job_id:
                    job.status = "failed"
                    job.error = error[:4_000]
                    job.updated_at = time.time()
                    self._write_jobs(jobs)
                    return

    def _read_jobs(self) -> list[CaptionJob]:
        try:
            raw_data = json.loads(self.queue_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        raw_jobs = raw_data.get("jobs", []) if isinstance(raw_data, dict) else []
        jobs = []
        for raw_job in raw_jobs:
            if isinstance(raw_job, dict):
                try:
                    jobs.append(CaptionJob(**raw_job))
                except TypeError:
                    continue
        return jobs

    def _write_jobs(self, jobs: list[CaptionJob]) -> None:
        payload = {"jobs": [asdict(job) for job in jobs]}
        tmp_path = self.queue_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp_path.replace(self.queue_path)


class WDTagger:
    def __init__(self, config: CaptionConfig) -> None:
        self.config = config

    def tags_for_image(self, image_path: Path) -> list[str]:
        backend = self.config.tagger_backend.strip().lower()
        if backend in {"", "disabled", "none"}:
            return []
        if backend == "command" or self.config.wd_tagger_command:
            return self._command_tags(image_path)
        return self._wd14_tags(image_path)

    def _command_tags(self, image_path: Path) -> list[str]:
        if not self.config.wd_tagger_command:
            raise RuntimeError("WD_TAGGER_COMMAND is required when tagger_backend=command.")
        command = [
            part.format(image=str(image_path))
            for part in shlex.split(self.config.wd_tagger_command)
        ]
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=self.config.request_timeout_seconds,
        )
        return _clean_tags(result.stdout.replace("\n", ",").split(","), self.config.tagger_max_tags)

    def _wd14_tags(self, image_path: Path) -> list[str]:
        try:
            import numpy as np
            import onnxruntime as ort
            from huggingface_hub import hf_hub_download
            from PIL import Image
        except ImportError as exc:
            raise RuntimeError(
                "Install the web app requirements, including onnxruntime, huggingface_hub, Pillow, and numpy, "
                "or set WD_TAGGER_COMMAND to an existing wd-tagger command."
            ) from exc

        model_path = hf_hub_download(self.config.wd_model_repo, self.config.wd_model_file)
        tags_path = hf_hub_download(self.config.wd_model_repo, self.config.wd_tags_file)

        session = ort.InferenceSession(model_path, providers=ort.get_available_providers())
        input_meta = session.get_inputs()[0]
        input_name = input_meta.name
        input_shape = input_meta.shape
        image_size = int(input_shape[1] if isinstance(input_shape[1], int) else input_shape[2])

        with Image.open(image_path) as image:
            image = image.convert("RGBA")
            background = Image.new("RGBA", image.size, "WHITE")
            background.alpha_composite(image)
            image = background.convert("RGB")
            image.thumbnail((image_size, image_size), Image.Resampling.LANCZOS)
            canvas = Image.new("RGB", (image_size, image_size), "WHITE")
            canvas.paste(image, ((image_size - image.width) // 2, (image_size - image.height) // 2))
            array = np.asarray(canvas, dtype=np.float32)

        array = array[:, :, ::-1]
        batch = np.expand_dims(array, axis=0)
        probabilities = session.run(None, {input_name: batch})[0][0]

        tag_rows = _read_tag_rows(Path(tags_path))
        scored_tags: list[tuple[str, float]] = []
        for index, row in enumerate(tag_rows):
            if index >= len(probabilities):
                break
            name = str(row.get("name", "")).replace("_", " ").strip()
            category = str(row.get("category", ""))
            if not name:
                continue
            threshold = self.config.tagger_character_threshold if category == "4" else self.config.tagger_general_threshold
            score = float(probabilities[index])
            if score >= threshold:
                scored_tags.append((name, score))

        scored_tags.sort(key=lambda item: item[1], reverse=True)
        return [name for name, _ in scored_tags[: self.config.tagger_max_tags]]


class VLMCaptioner:
    def __init__(self, config: CaptionConfig) -> None:
        self.config = config

    def caption_video(self, media_path: Path, tags: list[str]) -> str:
        provider = self.config.vlm_provider.strip().lower()
        prompt = ltx_caption_prompt(tags)
        if provider == "http":
            return self._http_caption(media_path, tags, prompt)
        if provider == "command":
            return self._command_caption(media_path, tags, prompt)
        if provider in {"", "mock", "dry-run"}:
            return self._mock_caption(media_path, tags)
        raise RuntimeError(f"Unsupported VLM_PROVIDER '{self.config.vlm_provider}'.")

    def _http_caption(self, media_path: Path, tags: list[str], prompt: str) -> str:
        if not self.config.vlm_http_url:
            raise RuntimeError("VLM_HTTP_URL is required when VLM_PROVIDER=http.")
        try:
            import httpx
        except ImportError as exc:
            raise RuntimeError("Install httpx or use VLM_PROVIDER=command.") from exc

        headers = {}
        if self.config.vlm_api_key:
            headers["Authorization"] = f"Bearer {self.config.vlm_api_key}"

        with media_path.open("rb") as video_file:
            files = {"video": (media_path.name, video_file, "application/octet-stream")}
            data = {
                "prompt": prompt,
                "tags": json.dumps(tags),
                "model": self.config.vlm_model,
            }
            with httpx.Client(timeout=self.config.request_timeout_seconds) as client:
                response = client.post(self.config.vlm_http_url, headers=headers, data=data, files=files)
                response.raise_for_status()

        content_type = response.headers.get("content-type", "")
        if "application/json" in content_type:
            payload = response.json()
            if isinstance(payload, dict):
                for key in ("caption", "text", "output"):
                    value = payload.get(key)
                    if isinstance(value, str) and value.strip():
                        return value.strip()
            raise RuntimeError("VLM HTTP response JSON did not include caption, text, or output.")
        return response.text.strip()

    def _command_caption(self, media_path: Path, tags: list[str], prompt: str) -> str:
        if not self.config.vlm_command:
            raise RuntimeError("VLM_COMMAND is required when VLM_PROVIDER=command.")
        prompt_path = media_path.with_suffix(media_path.suffix + ".caption_prompt.txt")
        tags_path = media_path.with_suffix(media_path.suffix + ".wd_tags.json")
        prompt_path.write_text(prompt, encoding="utf-8")
        tags_path.write_text(json.dumps(tags, ensure_ascii=False), encoding="utf-8")
        try:
            command = [
                part.format(
                    video=str(media_path),
                    prompt_file=str(prompt_path),
                    tags_file=str(tags_path),
                    tags=", ".join(tags),
                )
                for part in shlex.split(self.config.vlm_command)
            ]
            result = subprocess.run(
                command,
                check=True,
                capture_output=True,
                text=True,
                timeout=self.config.request_timeout_seconds,
            )
            return result.stdout.strip()
        finally:
            prompt_path.unlink(missing_ok=True)
            tags_path.unlink(missing_ok=True)

    @staticmethod
    def _mock_caption(media_path: Path, tags: list[str]) -> str:
        tag_phrase = ", ".join(tags[:12]) if tags else "the visible subject, motion, setting, lighting, and camera behavior"
        return (
            f"A detailed video clip shows {media_path.stem} with visual cues including {tag_phrase}. "
            "The caption should be reviewed and replaced with a real video VLM output before training."
        )


class CaptionWorker:
    def __init__(
        self,
        settings: SettingsStore,
        queue: CaptionQueueStore,
        poll_interval_seconds: float = 3.0,
    ) -> None:
        self.settings = settings
        self.queue = queue
        self.poll_interval_seconds = poll_interval_seconds
        self._stopping = False

    async def run_forever(self) -> None:
        while not self._stopping:
            did_work = await asyncio.to_thread(self.process_one)
            if not did_work:
                await asyncio.sleep(self.poll_interval_seconds)

    def stop(self) -> None:
        self._stopping = True

    def process_one(self) -> bool:
        job = self.queue.claim_next()
        if job is None:
            return False

        config = self.settings.get_caption_config()
        frame_path = temporary_jpeg_path()
        try:
            media_path = Path(job.absolute_media_path)
            if not media_path.exists():
                raise RuntimeError(f"Media file no longer exists: {media_path}")
            extract_middle_frame(media_path, frame_path)
            tags = WDTagger(config).tags_for_image(frame_path)
            caption = _normalize_caption(VLMCaptioner(config).caption_video(media_path, tags))

            dataset_root = Path(job.dataset_root)
            with locked_dataset(dataset_root):
                DatasetStore(dataset_root).update_caption(
                    job.media_path,
                    caption,
                    caption_status="done",
                    extras={
                        "caption_mode": "automatic",
                        "caption_job_id": job.id,
                        "wd_tags": tags,
                    },
                )
            self.queue.complete(job.id, caption, tags)
        except Exception as exc:
            error = str(exc) or exc.__class__.__name__
            try:
                dataset_root = Path(job.dataset_root)
                with locked_dataset(dataset_root):
                    DatasetStore(dataset_root).mark_caption_failed(job.media_path, error)
            finally:
                self.queue.fail(job.id, error)
        finally:
            frame_path.unlink(missing_ok=True)
        return True


def _read_tag_rows(tags_path: Path) -> list[dict[str, str]]:
    with tags_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        return list(reader)


def _clean_tags(raw_tags: list[str], max_tags: int) -> list[str]:
    tags: list[str] = []
    seen: set[str] = set()
    for raw_tag in raw_tags:
        tag = raw_tag.strip().replace("_", " ")
        if not tag or tag in seen:
            continue
        seen.add(tag)
        tags.append(tag)
        if len(tags) >= max_tags:
            break
    return tags


def _normalize_caption(caption: str) -> str:
    normalized = " ".join(caption.strip().split())
    if not normalized:
        raise RuntimeError("VLM returned an empty caption.")
    return normalized

