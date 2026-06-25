from __future__ import annotations

from dataclasses import dataclass
import base64
import json
import math
from pathlib import Path
import subprocess
import tempfile
from typing import Any


TARGET_FRAME_RATE = 16
MINIMUM_FRAME_COUNT = 9
FRAME_COUNT_STEP = 8
SUPPORTED_VIDEO_EXTENSIONS = {"mp4", "mov", "m4v", "mkv", "avi", "mpg", "mpeg", "webm", "gif"}
SUPPORTED_IMAGE_EXTENSIONS = {"png", "jpg", "jpeg", "webp", "heic", "heif", "bmp", "tif", "tiff"}


class MediaError(ValueError):
    pass


@dataclass
class CropRect:
    x: int
    y: int
    width: int
    height: int


def supported_extensions() -> set[str]:
    return SUPPORTED_VIDEO_EXTENSIONS | SUPPORTED_IMAGE_EXTENSIONS


def encode_media_id(path: Path, input_root: Path) -> str:
    relative_path = path.resolve().relative_to(input_root.resolve())
    raw_value = relative_path.as_posix().encode("utf-8")
    return base64.urlsafe_b64encode(raw_value).decode("ascii").rstrip("=")


def resolve_media_id(media_id: str, input_root: Path) -> Path:
    padded_id = media_id + "=" * (-len(media_id) % 4)
    try:
        relative_raw = base64.urlsafe_b64decode(padded_id.encode("ascii")).decode("utf-8")
    except Exception as exc:
        raise MediaError("Invalid media id.") from exc

    relative_path = Path(relative_raw)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise MediaError("Media id points outside the configured input folder.")

    root = input_root.expanduser().resolve()
    path = (root / relative_path).resolve()
    if not path.is_file() or root not in path.parents:
        raise MediaError("Media file is not inside the configured input folder.")
    if path.suffix.lower().lstrip(".") not in supported_extensions():
        raise MediaError("Unsupported media file.")
    return path


def list_media(input_root: Path) -> list[dict[str, Any]]:
    root = input_root.expanduser().resolve()
    if not root.is_dir():
        raise MediaError("Input folder does not exist.")

    items: list[dict[str, Any]] = []
    for path in sorted(root.iterdir(), key=lambda value: value.name.lower()):
        if not path.is_file():
            continue
        extension = path.suffix.lower().lstrip(".")
        if extension not in supported_extensions():
            continue
        kind = "video" if extension in SUPPORTED_VIDEO_EXTENSIONS else "image"
        items.append(
            {
                "id": encode_media_id(path, root),
                "name": path.name,
                "kind": kind,
                "extension": extension,
                "path": str(path),
            }
        )
    return items


def probe_media(path: Path) -> dict[str, Any]:
    extension = path.suffix.lower().lstrip(".")
    if extension in SUPPORTED_IMAGE_EXTENSIONS:
        return _probe_image(path)
    if extension in SUPPORTED_VIDEO_EXTENSIONS:
        return _probe_video(path)
    raise MediaError("Unsupported media file.")


def quantized_frame_counts(max_available: int) -> list[int]:
    if max_available < MINIMUM_FRAME_COUNT:
        return []
    values = []
    current = MINIMUM_FRAME_COUNT
    while current <= max_available:
        values.append(current)
        current += FRAME_COUNT_STEP
    return values


def is_quantized_frame_count(frame_count: int) -> bool:
    return frame_count >= MINIMUM_FRAME_COUNT and (frame_count - MINIMUM_FRAME_COUNT) % FRAME_COUNT_STEP == 0


def exported_frame_count(source_frame_count: int, loop_count: int) -> int:
    if source_frame_count <= 1:
        return max(source_frame_count, 0)
    return 1 + ((source_frame_count - 1) * max(1, min(loop_count, 3)))


def export_video_clip(
    source_path: Path,
    output_path: Path,
    in_frame: int,
    frame_count: int,
    loop_count: int,
    includes_audio: bool,
    crop_rect: CropRect | None,
) -> None:
    metadata = _probe_video(source_path)
    max_frames = int(metadata["frame_count"])
    if in_frame < 0 or in_frame >= max_frames:
        raise MediaError("In frame is outside the source media.")
    if not is_quantized_frame_count(frame_count):
        raise MediaError("Selected clip length must be 9, 17, 25, 33, ... frames.")
    if in_frame + frame_count > max_frames:
        raise MediaError("Selected clip range is outside the source media.")

    loop_count = max(1, min(int(loop_count), 3))
    resolved_crop = _bounded_crop(crop_rect, int(metadata["width"]), int(metadata["height"]))
    output_path.parent.mkdir(parents=True, exist_ok=True)

    video_filter = _video_filter(in_frame, frame_count, loop_count, resolved_crop)
    filter_parts = [f"[0:v]{video_filter}[v]"]
    should_include_audio = bool(includes_audio and metadata.get("has_audio"))
    if should_include_audio:
        filter_parts.append(_audio_filter(in_frame, frame_count, loop_count))

    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source_path),
        "-filter_complex",
        ";".join(filter_parts),
        "-map",
        "[v]",
    ]
    if should_include_audio:
        command += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k"]
    else:
        command += ["-an"]
    command += [
        "-r",
        str(TARGET_FRAME_RATE),
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(output_path),
    ]
    _run_command(command, timeout_seconds=3_600)


def export_image(
    source_path: Path,
    output_path: Path,
    crop_rect: CropRect | None,
) -> None:
    from PIL import Image

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with Image.open(source_path) as image:
        image.load()
        if crop_rect is not None:
            crop = _bounded_crop(crop_rect, image.width, image.height, force_even=False)
            image = image.crop((crop.x, crop.y, crop.x + crop.width, crop.y + crop.height))
        image.save(output_path, format="PNG")


def extract_middle_frame(media_path: Path, output_path: Path) -> Path:
    extension = media_path.suffix.lower().lstrip(".")
    if extension in SUPPORTED_IMAGE_EXTENSIONS:
        from PIL import Image

        with Image.open(media_path) as image:
            image.convert("RGB").save(output_path, format="JPEG", quality=95)
        return output_path

    metadata = _probe_video(media_path)
    duration = max(float(metadata.get("duration_seconds") or 0), 0.001)
    middle_seconds = duration / 2
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-ss",
        f"{middle_seconds:.6f}",
        "-i",
        str(media_path),
        "-frames:v",
        "1",
        str(output_path),
    ]
    _run_command(command, timeout_seconds=120)
    return output_path


def temporary_jpeg_path() -> Path:
    handle = tempfile.NamedTemporaryFile(prefix="dataset-caption-frame-", suffix=".jpg", delete=False)
    handle.close()
    return Path(handle.name)


def _probe_video(path: Path) -> dict[str, Any]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-of",
        "json",
        str(path),
    ]
    result = _run_command(command, timeout_seconds=120)
    data = json.loads(result.stdout)
    streams = data.get("streams") or []
    video_stream = next((stream for stream in streams if stream.get("codec_type") == "video"), None)
    if not video_stream:
        raise MediaError("No video stream found.")

    duration = _duration_from_probe(data, video_stream)
    width = int(video_stream.get("width") or 0)
    height = int(video_stream.get("height") or 0)
    if width <= 0 or height <= 0:
        raise MediaError("Unable to read video dimensions.")

    return {
        "kind": "video",
        "width": width,
        "height": height,
        "duration_seconds": duration,
        "source_frame_rate": _parse_rate(video_stream.get("avg_frame_rate") or video_stream.get("r_frame_rate")),
        "frame_rate": TARGET_FRAME_RATE,
        "frame_count": max(int(math.ceil(duration * TARGET_FRAME_RATE)), 1),
        "allowed_frame_counts": quantized_frame_counts(max(int(math.ceil(duration * TARGET_FRAME_RATE)), 1)),
        "has_audio": any(stream.get("codec_type") == "audio" for stream in streams),
    }


def _probe_image(path: Path) -> dict[str, Any]:
    from PIL import Image

    with Image.open(path) as image:
        width, height = image.size
    return {
        "kind": "image",
        "width": width,
        "height": height,
        "duration_seconds": 0,
        "frame_rate": 1,
        "frame_count": 1,
        "allowed_frame_counts": [],
        "has_audio": False,
    }


def _duration_from_probe(data: dict[str, Any], video_stream: dict[str, Any]) -> float:
    for raw_value in (
        video_stream.get("duration"),
        data.get("format", {}).get("duration"),
    ):
        try:
            duration = float(raw_value)
        except (TypeError, ValueError):
            continue
        if duration > 0:
            return duration
    frame_count = video_stream.get("nb_frames")
    frame_rate = _parse_rate(video_stream.get("avg_frame_rate") or video_stream.get("r_frame_rate"))
    try:
        if frame_count and frame_rate > 0:
            return int(frame_count) / frame_rate
    except ValueError:
        pass
    raise MediaError("Unable to read video duration.")


def _parse_rate(raw_value: Any) -> float:
    if not raw_value:
        return 0
    if isinstance(raw_value, (int, float)):
        return float(raw_value)
    text = str(raw_value)
    if "/" in text:
        numerator, denominator = text.split("/", 1)
        try:
            denominator_value = float(denominator)
            if denominator_value == 0:
                return 0
            return float(numerator) / denominator_value
        except ValueError:
            return 0
    try:
        return float(text)
    except ValueError:
        return 0


def _video_filter(
    in_frame: int,
    frame_count: int,
    loop_count: int,
    crop_rect: CropRect | None,
) -> str:
    filters = [
        f"fps={TARGET_FRAME_RATE}",
        f"trim=start_frame={in_frame}:end_frame={in_frame + frame_count}",
        "setpts=PTS-STARTPTS",
    ]
    if crop_rect is not None:
        filters.append(f"crop={crop_rect.width}:{crop_rect.height}:{crop_rect.x}:{crop_rect.y}")
    if loop_count > 1 and frame_count > 1:
        filters.append(f"loop=loop={loop_count - 1}:size={frame_count - 1}:start=1")
    filters.extend(
        [
            f"setpts=N/({TARGET_FRAME_RATE}*TB)",
            "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "format=yuv420p",
        ]
    )
    return ",".join(filters)


def _audio_filter(in_frame: int, frame_count: int, loop_count: int) -> str:
    start_seconds = in_frame / TARGET_FRAME_RATE
    source_duration = frame_count / TARGET_FRAME_RATE
    output_duration = exported_frame_count(frame_count, loop_count) / TARGET_FRAME_RATE
    if loop_count <= 1:
        return (
            f"[0:a]atrim=start={start_seconds:.6f}:duration={output_duration:.6f},"
            "asetpts=PTS-STARTPTS[a]"
        )

    split_labels = "".join(f"[a{index}]" for index in range(loop_count))
    concat_inputs = "".join(f"[a{index}]" for index in range(loop_count))
    return (
        f"[0:a]atrim=start={start_seconds:.6f}:duration={source_duration:.6f},"
        f"asetpts=PTS-STARTPTS,asplit={loop_count}{split_labels};"
        f"{concat_inputs}concat=n={loop_count}:v=0:a=1,"
        f"atrim=duration={output_duration:.6f},asetpts=PTS-STARTPTS[a]"
    )


def _bounded_crop(
    crop_rect: CropRect | None,
    width: int,
    height: int,
    force_even: bool = True,
) -> CropRect | None:
    if crop_rect is None:
        return None
    x = min(max(int(crop_rect.x), 0), max(width - 1, 0))
    y = min(max(int(crop_rect.y), 0), max(height - 1, 0))
    crop_width = min(max(int(crop_rect.width), 1), width - x)
    crop_height = min(max(int(crop_rect.height), 1), height - y)
    if force_even:
        x -= x % 2
        y -= y % 2
        crop_width = max(2, crop_width - (crop_width % 2))
        crop_height = max(2, crop_height - (crop_height % 2))
        crop_width = min(crop_width, width - x)
        crop_height = min(crop_height, height - y)
    return CropRect(x=x, y=y, width=crop_width, height=crop_height)


def _run_command(command: list[str], timeout_seconds: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
        )
    except FileNotFoundError as exc:
        raise MediaError(f"Required command not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()
        raise MediaError(detail) from exc
    except subprocess.TimeoutExpired as exc:
        raise MediaError(f"Command timed out while running {command[0]}.") from exc

