FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV HOST=0.0.0.0
ENV PORT=7860

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        ffmpeg \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY apps/web/requirements.txt /app/apps/web/requirements.txt
RUN python3 -m pip install --no-cache-dir --upgrade pip \
    && python3 -m pip install --no-cache-dir -r /app/apps/web/requirements.txt

COPY apps/web /app/apps/web
WORKDIR /app/apps/web

EXPOSE 7860
CMD ["bash", "-lc", "python3 -m uvicorn web_dataset_creator.main:app --host ${HOST} --port ${PORT}"]

