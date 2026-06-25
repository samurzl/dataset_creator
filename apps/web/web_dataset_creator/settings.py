from __future__ import annotations

from dataclasses import asdict, dataclass, fields
import json
import os
from pathlib import Path
from threading import RLock
from typing import Any


def _env_float(name: str, default: float) -> float:
    raw_value = os.getenv(name)
    if raw_value is None:
        return default
    try:
        return float(raw_value)
    except ValueError:
        return default


def _env_int(name: str, default: int) -> int:
    raw_value = os.getenv(name)
    if raw_value is None:
        return default
    try:
        return int(raw_value)
    except ValueError:
        return default


def state_dir_from_env() -> Path:
    raw_path = os.getenv("DATASET_CREATOR_STATE_DIR")
    if raw_path:
        return Path(raw_path).expanduser().resolve()
    return (Path.home() / ".dataset_creator_web").resolve()


@dataclass
class AppConfig:
    input_folder: str = os.getenv("DATASET_CREATOR_INPUT_DIR", "")
    dataset_folder: str = os.getenv("DATASET_CREATOR_DATASET_DIR", "")
    default_caption_mode: str = os.getenv("DATASET_CREATOR_DEFAULT_CAPTION_MODE", "automatic")


@dataclass
class CaptionConfig:
    tagger_backend: str = os.getenv("WD_TAGGER_BACKEND", "wd14")
    wd_tagger_command: str = os.getenv("WD_TAGGER_COMMAND", "")
    wd_model_repo: str = os.getenv("WD_TAGGER_MODEL_REPO", "SmilingWolf/wd-swinv2-tagger-v3")
    wd_model_file: str = os.getenv("WD_TAGGER_MODEL_FILE", "model.onnx")
    wd_tags_file: str = os.getenv("WD_TAGGER_TAGS_FILE", "selected_tags.csv")
    tagger_general_threshold: float = _env_float("WD_TAGGER_GENERAL_THRESHOLD", 0.35)
    tagger_character_threshold: float = _env_float("WD_TAGGER_CHARACTER_THRESHOLD", 0.85)
    tagger_max_tags: int = _env_int("WD_TAGGER_MAX_TAGS", 40)
    vlm_provider: str = os.getenv("VLM_PROVIDER", "mock")
    vlm_http_url: str = os.getenv("VLM_HTTP_URL", "")
    vlm_api_key: str = os.getenv("VLM_API_KEY", "")
    vlm_model: str = os.getenv("VLM_MODEL", "")
    vlm_command: str = os.getenv("VLM_COMMAND", "")
    request_timeout_seconds: int = _env_int("VLM_REQUEST_TIMEOUT_SECONDS", 600)


class SettingsStore:
    def __init__(self, state_dir: Path | None = None) -> None:
        self.state_dir = state_dir or state_dir_from_env()
        self.settings_path = self.state_dir / "settings.json"
        self._lock = RLock()
        self._app_config = AppConfig()
        self._caption_config = CaptionConfig()
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self._load()

    def get_app_config(self) -> AppConfig:
        with self._lock:
            return AppConfig(**asdict(self._app_config))

    def update_app_config(self, values: dict[str, Any]) -> AppConfig:
        with self._lock:
            self._app_config = self._replace_dataclass(self._app_config, values)
            self._save()
            return self.get_app_config()

    def get_caption_config(self) -> CaptionConfig:
        with self._lock:
            return CaptionConfig(**asdict(self._caption_config))

    def update_caption_config(self, values: dict[str, Any]) -> CaptionConfig:
        with self._lock:
            self._caption_config = self._replace_dataclass(self._caption_config, values)
            self._save()
            return self.get_caption_config()

    def public_caption_config(self) -> dict[str, Any]:
        config = asdict(self.get_caption_config())
        config["vlm_api_key"] = "configured" if config.get("vlm_api_key") else ""
        return config

    def _load(self) -> None:
        if not self.settings_path.exists():
            self._save()
            return

        try:
            raw_data = json.loads(self.settings_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return

        app_values = raw_data.get("app", {})
        caption_values = raw_data.get("caption", {})
        if isinstance(app_values, dict):
            self._app_config = self._replace_dataclass(self._app_config, app_values)
        if isinstance(caption_values, dict):
            self._caption_config = self._replace_dataclass(self._caption_config, caption_values)

    def _save(self) -> None:
        payload = {
            "app": asdict(self._app_config),
            "caption": asdict(self._caption_config),
        }
        tmp_path = self.settings_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        tmp_path.replace(self.settings_path)

    @staticmethod
    def _replace_dataclass(instance: Any, values: dict[str, Any]) -> Any:
        allowed_names = {field.name for field in fields(instance)}
        merged = asdict(instance)
        for key, value in values.items():
            if key not in allowed_names:
                continue
            merged[key] = value
        return type(instance)(**merged)

