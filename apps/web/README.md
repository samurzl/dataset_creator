# Dataset Creator Web

Browser-hosted dataset authoring app for RunPod/Linux. It scans an input folder, previews media in the browser, exports crops/trims into `dataset.json` plus `positive/<n>.<ext>`, and can queue automatic captions after export.

## Run Locally

```bash
cd apps/web
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
PORT=7860 ./run_web.sh
```

Open `http://127.0.0.1:7860`.

## RunPod Port

The service binds to `0.0.0.0` and uses `PORT`, defaulting to `7860`.

```bash
PORT=3000 ./run_web.sh
```

Docker:

```bash
cd ../..
docker build -f apps/web/Dockerfile -t dataset-creator-web .
docker run --gpus all -p 3000:3000 \
  -e PORT=3000 \
  -e DATASET_CREATOR_INPUT_DIR=/workspace/input \
  -e DATASET_CREATOR_DATASET_DIR=/workspace/dataset \
  dataset-creator-web
```

## Automatic Captions

The export panel defaults to `Automatic`. Automatic exports write a row with `caption_status: "pending"` and enqueue the exported media. The background worker:

1. extracts the middle frame,
2. generates WD tags with the configured wd-tagger backend,
3. sends the full exported media plus tags to the configured VLM,
4. updates the row caption in `dataset.json`.

Caption jobs are persisted in `DATASET_CREATOR_STATE_DIR` or `~/.dataset_creator_web`.

## WD Tagger

Default backend:

```bash
WD_TAGGER_BACKEND=wd14
WD_TAGGER_MODEL_REPO=SmilingWolf/wd-swinv2-tagger-v3
```

The first automatic job downloads the ONNX model and tag CSV through Hugging Face. To use an existing wd-tagger command instead:

```bash
WD_TAGGER_BACKEND=command
WD_TAGGER_COMMAND='python /workspace/wd-tagger/tag.py --image {image}'
```

The command should print comma- or newline-separated tags.

## VLM Provider

Use an HTTP endpoint:

```bash
VLM_PROVIDER=http
VLM_HTTP_URL=http://127.0.0.1:8001/caption
VLM_MODEL=qwen-video-or-your-model
VLM_API_KEY=optional-token
```

The app posts multipart form data:

- `video`: the full exported clip or image,
- `prompt`: the LTX 2.3-aligned caption prompt,
- `tags`: JSON array of WD tags,
- `model`: optional model name.

The endpoint should return JSON with `caption`, `text`, or `output`, or plain text.

Use a command provider:

```bash
VLM_PROVIDER=command
VLM_COMMAND='python /workspace/caption_clip.py --video {video} --prompt-file {prompt_file} --tags-file {tags_file}'
```

For development only, `VLM_PROVIDER=mock` writes a placeholder caption that should be reviewed before training.
