# Dataset Creator Monorepo

This repo now has two app targets:

- `apps/macos`: the original native macOS app for local dataset authoring.
- `apps/web`: a browser-hosted app intended for RunPod or another Linux host.

Both apps write the same flat dataset shape:

```json
[
  {
    "caption": "A detailed caption.",
    "media_path": "positive/1.mp4"
  }
]
```

Shared examples live in `examples/example_dataset`.

## macOS App

```bash
cd apps/macos
swift run VideoDatasetBrowser
```

Build the `.app` bundle:

```bash
cd apps/macos
scripts/build_app.sh
```

## Web App

```bash
cd apps/web
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
PORT=7860 ./run_web.sh
```

Open `http://<host>:7860` in your browser. The port is controlled by `PORT`.

For RunPod:

```bash
docker build -f apps/web/Dockerfile -t dataset-creator-web .
docker run --gpus all -p 7860:7860 \
  -e PORT=7860 \
  -e DATASET_CREATOR_INPUT_DIR=/workspace/input \
  -e DATASET_CREATOR_DATASET_DIR=/workspace/dataset \
  dataset-creator-web
```

See `apps/web/README.md` for automatic caption queue and VLM configuration.

