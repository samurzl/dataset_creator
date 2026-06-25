from __future__ import annotations

from contextlib import asynccontextmanager
import asyncio
from pathlib import Path
from typing import Any, Literal, Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .captioning import (
    CaptionQueueStore,
    CaptionWorker,
    PENDING_CAPTION_TEXT,
    new_caption_job_id,
)
from .dataset import DatasetStore, locked_dataset
from .media import (
    CropRect,
    MediaError,
    export_image,
    export_video_clip,
    list_media,
    probe_media,
    resolve_media_id,
)
from .settings import SettingsStore


class AppConfigPayload(BaseModel):
    input_folder: str = ""
    dataset_folder: str = ""
    default_caption_mode: Literal["manual", "automatic"] = "automatic"


class CaptionConfigPayload(BaseModel):
    tagger_backend: Optional[str] = None
    wd_tagger_command: Optional[str] = None
    wd_model_repo: Optional[str] = None
    wd_model_file: Optional[str] = None
    wd_tags_file: Optional[str] = None
    tagger_general_threshold: Optional[float] = None
    tagger_character_threshold: Optional[float] = None
    tagger_max_tags: Optional[int] = None
    vlm_provider: Optional[str] = None
    vlm_http_url: Optional[str] = None
    vlm_api_key: Optional[str] = None
    vlm_model: Optional[str] = None
    vlm_command: Optional[str] = None
    request_timeout_seconds: Optional[int] = None


class CropRectPayload(BaseModel):
    x: int
    y: int
    width: int = Field(gt=0)
    height: int = Field(gt=0)

    def to_crop_rect(self) -> CropRect:
        return CropRect(x=self.x, y=self.y, width=self.width, height=self.height)


class ExportPayload(BaseModel):
    media_id: str
    caption_mode: Literal["manual", "automatic"] = "automatic"
    manual_caption: str = ""
    in_frame: int = 0
    frame_count: Optional[int] = None
    loop_count: int = 1
    includes_audio: bool = True
    crop_rect: Optional[CropRectPayload] = None


class RetryPayload(BaseModel):
    job_id: str


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = SettingsStore()
    queue = CaptionQueueStore(settings.state_dir)
    worker = CaptionWorker(settings, queue)
    worker_task = asyncio.create_task(worker.run_forever())

    app.state.settings = settings
    app.state.caption_queue = queue
    app.state.caption_worker = worker
    try:
        yield
    finally:
        worker.stop()
        worker_task.cancel()
        try:
            await worker_task
        except asyncio.CancelledError:
            pass


app = FastAPI(title="Dataset Creator Web", lifespan=lifespan)


@app.get("/api/config")
def get_config() -> dict[str, Any]:
    return app.state.settings.get_app_config().__dict__


@app.post("/api/config")
def update_config(payload: AppConfigPayload) -> dict[str, Any]:
    input_folder = _optional_directory(payload.input_folder, "Input folder")
    dataset_folder = _optional_directory(payload.dataset_folder, "Dataset folder")
    updated = app.state.settings.update_app_config(
        {
            "input_folder": str(input_folder) if input_folder else "",
            "dataset_folder": str(dataset_folder) if dataset_folder else "",
            "default_caption_mode": payload.default_caption_mode,
        }
    )
    return updated.__dict__


@app.get("/api/caption-config")
def get_caption_config() -> dict[str, Any]:
    return app.state.settings.public_caption_config()


@app.post("/api/caption-config")
def update_caption_config(payload: CaptionConfigPayload) -> dict[str, Any]:
    values = {
        key: value
        for key, value in payload.model_dump().items()
        if value is not None
    }
    app.state.settings.update_caption_config(values)
    return app.state.settings.public_caption_config()


@app.get("/api/media")
def media_items() -> list[dict[str, Any]]:
    config = app.state.settings.get_app_config()
    if not config.input_folder:
        return []
    try:
        return list_media(Path(config.input_folder))
    except MediaError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/media/{media_id}/metadata")
def media_metadata(media_id: str) -> dict[str, Any]:
    path = _media_path(media_id)
    try:
        metadata = probe_media(path)
    except MediaError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    metadata["id"] = media_id
    metadata["name"] = path.name
    metadata["path"] = str(path)
    return metadata


@app.get("/api/media/{media_id}/content")
def media_content(media_id: str) -> FileResponse:
    path = _media_path(media_id)
    return FileResponse(path)


@app.post("/api/export")
def export(payload: ExportPayload) -> dict[str, Any]:
    config = app.state.settings.get_app_config()
    if not config.dataset_folder:
        raise HTTPException(status_code=400, detail="Dataset folder is not configured.")

    source_path = _media_path(payload.media_id)
    dataset_root = Path(config.dataset_folder).expanduser().resolve()
    caption_mode = payload.caption_mode
    manual_caption = payload.manual_caption.strip()
    if caption_mode == "manual" and not manual_caption:
        raise HTTPException(status_code=400, detail="Manual caption is required.")

    try:
        metadata = probe_media(source_path)
        media_kind = metadata["kind"]
        media_extension = "mp4" if media_kind == "video" else "png"
        caption_job_id = new_caption_job_id() if caption_mode == "automatic" else ""
        caption = manual_caption if caption_mode == "manual" else PENDING_CAPTION_TEXT
        extras = {
            "caption_mode": caption_mode,
            "caption_status": "pending" if caption_mode == "automatic" else "manual",
        }
        if caption_job_id:
            extras["caption_job_id"] = caption_job_id

        with locked_dataset(dataset_root):
            store = DatasetStore(dataset_root)
            prepared = store.prepare_append(caption, media_extension, extras)
            crop_rect = payload.crop_rect.to_crop_rect() if payload.crop_rect else None
            if media_kind == "video":
                frame_count = payload.frame_count or _default_frame_count(metadata)
                export_video_clip(
                    source_path,
                    prepared.output_media_url,
                    in_frame=payload.in_frame,
                    frame_count=frame_count,
                    loop_count=payload.loop_count,
                    includes_audio=payload.includes_audio,
                    crop_rect=crop_rect,
                )
            else:
                export_image(source_path, prepared.output_media_url, crop_rect)
            store.commit(prepared)

        queued_job = None
        if caption_mode == "automatic":
            queued_job = app.state.caption_queue.enqueue(
                caption_job_id,
                dataset_root,
                prepared.output_media_path,
                prepared.output_media_url,
            )

        return {
            "media_path": prepared.output_media_path,
            "output_path": str(prepared.output_media_url),
            "caption_mode": caption_mode,
            "caption_job": queued_job.__dict__ if queued_job else None,
        }
    except (MediaError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/dataset")
def dataset_rows() -> dict[str, Any]:
    config = app.state.settings.get_app_config()
    if not config.dataset_folder:
        return {"rows": []}
    dataset_root = Path(config.dataset_folder).expanduser().resolve()
    try:
        with locked_dataset(dataset_root):
            rows = DatasetStore(dataset_root).load_rows()
        return {"rows": rows}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@app.get("/api/caption-jobs")
def caption_jobs() -> dict[str, Any]:
    config = app.state.settings.get_app_config()
    dataset_root = Path(config.dataset_folder).expanduser().resolve() if config.dataset_folder else None
    jobs = app.state.caption_queue.list_jobs(dataset_root)
    return {"jobs": [job.__dict__ for job in jobs]}


@app.post("/api/caption-jobs/retry")
def retry_caption_job(payload: RetryPayload) -> dict[str, Any]:
    try:
        job = app.state.caption_queue.retry(payload.job_id)
        return job.__dict__
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Caption job not found.") from exc


def _media_path(media_id: str) -> Path:
    config = app.state.settings.get_app_config()
    if not config.input_folder:
        raise HTTPException(status_code=400, detail="Input folder is not configured.")
    try:
        return resolve_media_id(media_id, Path(config.input_folder))
    except MediaError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


def _optional_directory(path_value: str, label: str) -> Path | None:
    if not path_value.strip():
        return None
    path = Path(path_value).expanduser().resolve()
    if not path.is_dir():
        raise HTTPException(status_code=400, detail=f"{label} does not exist: {path}")
    return path


def _default_frame_count(metadata: dict[str, Any]) -> int:
    allowed = metadata.get("allowed_frame_counts") or []
    if not allowed:
        raise HTTPException(status_code=400, detail="Video is too short for a 9-frame export.")
    return int(allowed[-1])


static_dir = Path(__file__).resolve().parents[1] / "static"
app.mount("/", StaticFiles(directory=static_dir, html=True), name="static")
