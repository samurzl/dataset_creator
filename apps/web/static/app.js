const state = {
  config: null,
  captionConfig: null,
  mediaItems: [],
  selectedIndex: -1,
  metadata: null,
  cropRect: null,
  captionMode: "automatic",
  loopCount: 1,
  includesAudio: true,
  selectionTimer: null,
};

const els = {
  connectionStatus: document.querySelector("#connectionStatus"),
  inputFolder: document.querySelector("#inputFolder"),
  datasetFolder: document.querySelector("#datasetFolder"),
  saveConfigButton: document.querySelector("#saveConfigButton"),
  refreshButton: document.querySelector("#refreshButton"),
  vlmProvider: document.querySelector("#vlmProvider"),
  vlmHttpUrl: document.querySelector("#vlmHttpUrl"),
  vlmModel: document.querySelector("#vlmModel"),
  vlmApiKey: document.querySelector("#vlmApiKey"),
  taggerBackend: document.querySelector("#taggerBackend"),
  saveCaptionConfigButton: document.querySelector("#saveCaptionConfigButton"),
  mediaCount: document.querySelector("#mediaCount"),
  mediaList: document.querySelector("#mediaList"),
  selectedTitle: document.querySelector("#selectedTitle"),
  selectedMeta: document.querySelector("#selectedMeta"),
  previousButton: document.querySelector("#previousButton"),
  nextButton: document.querySelector("#nextButton"),
  mediaFrame: document.querySelector("#mediaFrame"),
  emptyPreview: document.querySelector("#emptyPreview"),
  videoPreview: document.querySelector("#videoPreview"),
  imagePreview: document.querySelector("#imagePreview"),
  cropOverlay: document.querySelector("#cropOverlay"),
  videoControls: document.querySelector("#videoControls"),
  startFrame: document.querySelector("#startFrame"),
  startFrameValue: document.querySelector("#startFrameValue"),
  frameCount: document.querySelector("#frameCount"),
  playSelectionButton: document.querySelector("#playSelectionButton"),
  resetCropButton: document.querySelector("#resetCropButton"),
  cropLabel: document.querySelector("#cropLabel"),
  captionText: document.querySelector("#captionText"),
  automaticCaptionButton: document.querySelector("#automaticCaptionButton"),
  manualCaptionButton: document.querySelector("#manualCaptionButton"),
  loopRow: document.querySelector("#loopRow"),
  audioRow: document.querySelector("#audioRow"),
  includesAudio: document.querySelector("#includesAudio"),
  exportButton: document.querySelector("#exportButton"),
  exportMessage: document.querySelector("#exportMessage"),
  captionJobs: document.querySelector("#captionJobs"),
  datasetRows: document.querySelector("#datasetRows"),
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    ...options,
  });
  if (!response.ok) {
    let message = response.statusText;
    try {
      const payload = await response.json();
      message = payload.detail || message;
    } catch (_error) {
      message = await response.text();
    }
    throw new Error(message);
  }
  return response.json();
}

function setStatus(message, tone = "muted") {
  els.connectionStatus.textContent = message;
  els.connectionStatus.style.color = tone === "error" ? "var(--danger)" : "var(--muted)";
}

async function loadConfig() {
  state.config = await api("/api/config");
  els.inputFolder.value = state.config.input_folder || "";
  els.datasetFolder.value = state.config.dataset_folder || "";
  state.captionMode = state.config.default_caption_mode || "automatic";
  setCaptionMode(state.captionMode);
}

async function saveConfig() {
  const payload = {
    input_folder: els.inputFolder.value.trim(),
    dataset_folder: els.datasetFolder.value.trim(),
    default_caption_mode: state.captionMode,
  };
  state.config = await api("/api/config", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  await refreshAll();
}

async function loadCaptionConfig() {
  state.captionConfig = await api("/api/caption-config");
  els.vlmProvider.value = state.captionConfig.vlm_provider || "mock";
  els.vlmHttpUrl.value = state.captionConfig.vlm_http_url || "";
  els.vlmModel.value = state.captionConfig.vlm_model || "";
  els.vlmApiKey.value = "";
  els.vlmApiKey.placeholder = state.captionConfig.vlm_api_key ? "Configured" : "";
  els.taggerBackend.value = state.captionConfig.tagger_backend || "wd14";
}

async function saveCaptionConfig() {
  const payload = {
    vlm_provider: els.vlmProvider.value,
    vlm_http_url: els.vlmHttpUrl.value.trim(),
    vlm_model: els.vlmModel.value.trim(),
    tagger_backend: els.taggerBackend.value,
  };
  if (els.vlmApiKey.value.trim()) {
    payload.vlm_api_key = els.vlmApiKey.value.trim();
  }
  state.captionConfig = await api("/api/caption-config", {
    method: "POST",
    body: JSON.stringify(payload),
  });
  await loadCaptionConfig();
  setStatus("Caption settings saved");
}

async function refreshAll() {
  await Promise.all([loadMediaItems(), loadCaptionJobs(), loadDatasetRows()]);
}

async function loadMediaItems() {
  state.mediaItems = await api("/api/media");
  els.mediaCount.textContent = String(state.mediaItems.length);
  if (state.selectedIndex >= state.mediaItems.length) {
    state.selectedIndex = state.mediaItems.length - 1;
  }
  renderMediaList();
  if (state.selectedIndex >= 0) {
    await selectMedia(state.selectedIndex);
  } else if (state.mediaItems.length > 0) {
    await selectMedia(0);
  } else {
    clearSelection();
  }
}

function renderMediaList() {
  els.mediaList.replaceChildren();
  for (const [index, item] of state.mediaItems.entries()) {
    const button = document.createElement("button");
    button.className = `media-item${index === state.selectedIndex ? " active" : ""}`;
    button.type = "button";
    button.addEventListener("click", () => selectMedia(index));

    const name = document.createElement("span");
    name.className = "media-name";
    name.textContent = item.name;
    const kind = document.createElement("span");
    kind.className = "media-kind";
    kind.textContent = item.kind;
    button.append(name, kind);
    els.mediaList.append(button);
  }
}

async function selectMedia(index) {
  if (index < 0 || index >= state.mediaItems.length) {
    clearSelection();
    return;
  }
  stopSelectionPlayback();
  state.selectedIndex = index;
  state.cropRect = null;
  renderMediaList();

  const item = state.mediaItems[index];
  state.metadata = await api(`/api/media/${item.id}/metadata`);
  els.selectedTitle.textContent = item.name;
  els.selectedMeta.textContent = formatMetadata(state.metadata);
  els.mediaFrame.style.aspectRatio = `${Math.max(state.metadata.width, 1)} / ${Math.max(state.metadata.height, 1)}`;
  els.emptyPreview.hidden = true;
  els.cropOverlay.hidden = true;

  if (state.metadata.kind === "video") {
    els.imagePreview.hidden = true;
    els.imagePreview.removeAttribute("src");
    els.videoPreview.hidden = false;
    els.videoPreview.src = `/api/media/${item.id}/content`;
    els.videoControls.hidden = false;
    els.loopRow.hidden = false;
    els.audioRow.hidden = false;
    configureVideoSelection();
  } else {
    els.videoPreview.pause();
    els.videoPreview.hidden = true;
    els.videoPreview.removeAttribute("src");
    els.imagePreview.hidden = false;
    els.imagePreview.src = `/api/media/${item.id}/content`;
    els.videoControls.hidden = true;
    els.loopRow.hidden = true;
    els.audioRow.hidden = true;
  }
  updateCropLabel();
  updateNavigation();
}

function clearSelection() {
  state.selectedIndex = -1;
  state.metadata = null;
  state.cropRect = null;
  els.selectedTitle.textContent = "No Media Selected";
  els.selectedMeta.textContent = "";
  els.emptyPreview.hidden = false;
  els.videoPreview.hidden = true;
  els.videoPreview.removeAttribute("src");
  els.imagePreview.hidden = true;
  els.imagePreview.removeAttribute("src");
  els.videoControls.hidden = true;
  els.cropOverlay.hidden = true;
  updateNavigation();
}

function formatMetadata(metadata) {
  if (!metadata) return "";
  const dimensions = `${metadata.width} x ${metadata.height}`;
  if (metadata.kind === "image") return dimensions;
  const seconds = Number(metadata.duration_seconds || 0).toFixed(2);
  const audio = metadata.has_audio ? "audio" : "silent";
  return `${dimensions}, ${seconds}s, ${metadata.frame_count} frames at 16 fps, ${audio}`;
}

function configureVideoSelection() {
  const allowed = state.metadata.allowed_frame_counts || [];
  els.frameCount.replaceChildren();
  for (const value of allowed) {
    const option = document.createElement("option");
    option.value = String(value);
    option.textContent = String(value);
    els.frameCount.append(option);
  }
  const defaultFrames = allowed.at(-1) || 9;
  els.frameCount.value = String(defaultFrames);
  els.startFrame.min = "0";
  els.startFrame.value = "0";
  updateStartFrameMax();
  updateStartFrameOutput();
}

function updateStartFrameMax() {
  if (!state.metadata || state.metadata.kind !== "video") return;
  const frameCount = selectedFrameCount();
  const maxStart = Math.max(0, state.metadata.frame_count - frameCount);
  els.startFrame.max = String(maxStart);
  if (Number(els.startFrame.value) > maxStart) {
    els.startFrame.value = String(maxStart);
  }
}

function updateStartFrameOutput() {
  els.startFrameValue.textContent = els.startFrame.value;
  if (state.metadata?.kind === "video") {
    els.videoPreview.currentTime = Number(els.startFrame.value) / 16;
  }
}

function selectedFrameCount() {
  return Number(els.frameCount.value || 0);
}

function selectedMediaItem() {
  return state.mediaItems[state.selectedIndex] || null;
}

function updateNavigation() {
  els.previousButton.disabled = state.selectedIndex <= 0;
  els.nextButton.disabled = state.selectedIndex < 0 || state.selectedIndex >= state.mediaItems.length - 1;
  els.exportButton.disabled = state.selectedIndex < 0;
}

function setCaptionMode(mode) {
  state.captionMode = mode === "manual" ? "manual" : "automatic";
  els.automaticCaptionButton.classList.toggle("active", state.captionMode === "automatic");
  els.manualCaptionButton.classList.toggle("active", state.captionMode === "manual");
  els.captionText.disabled = state.captionMode === "automatic";
  els.captionText.placeholder = state.captionMode === "automatic" ? "Queued for automatic captioning" : "Manual caption";
}

function setLoopCount(value) {
  state.loopCount = Number(value);
  document.querySelectorAll("[data-loop-count]").forEach((button) => {
    button.classList.toggle("active", Number(button.dataset.loopCount) === state.loopCount);
  });
}

function updateCropLabel() {
  if (!state.metadata) {
    els.cropLabel.textContent = "Crop: unavailable";
    return;
  }
  if (!state.cropRect) {
    els.cropLabel.textContent = state.metadata.kind === "video" ? "Crop: full frame" : "Crop: full image";
    els.cropOverlay.hidden = true;
    return;
  }
  els.cropLabel.textContent = `Crop: ${state.cropRect.width} x ${state.cropRect.height} px`;
  const left = (state.cropRect.x / state.metadata.width) * 100;
  const top = (state.cropRect.y / state.metadata.height) * 100;
  const width = (state.cropRect.width / state.metadata.width) * 100;
  const height = (state.cropRect.height / state.metadata.height) * 100;
  Object.assign(els.cropOverlay.style, {
    left: `${left}%`,
    top: `${top}%`,
    width: `${width}%`,
    height: `${height}%`,
  });
  els.cropOverlay.hidden = false;
}

function startCropDrag(event) {
  if (!state.metadata || event.button !== 0) return;
  const rect = els.mediaFrame.getBoundingClientRect();
  const startX = clamp(event.clientX - rect.left, 0, rect.width);
  const startY = clamp(event.clientY - rect.top, 0, rect.height);

  function move(moveEvent) {
    const currentX = clamp(moveEvent.clientX - rect.left, 0, rect.width);
    const currentY = clamp(moveEvent.clientY - rect.top, 0, rect.height);
    const x = Math.min(startX, currentX);
    const y = Math.min(startY, currentY);
    const width = Math.abs(currentX - startX);
    const height = Math.abs(currentY - startY);
    if (width < 4 || height < 4) return;
    state.cropRect = {
      x: Math.floor((x / rect.width) * state.metadata.width),
      y: Math.floor((y / rect.height) * state.metadata.height),
      width: Math.max(1, Math.ceil((width / rect.width) * state.metadata.width)),
      height: Math.max(1, Math.ceil((height / rect.height) * state.metadata.height)),
    };
    updateCropLabel();
  }

  function up() {
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerup", up);
  }

  window.addEventListener("pointermove", move);
  window.addEventListener("pointerup", up);
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

function playSelection() {
  if (!state.metadata || state.metadata.kind !== "video") return;
  if (state.selectionTimer) {
    stopSelectionPlayback();
    return;
  }
  const startSeconds = Number(els.startFrame.value) / 16;
  const endSeconds = startSeconds + selectedFrameCount() / 16;
  els.videoPreview.currentTime = startSeconds;
  els.videoPreview.play();
  els.playSelectionButton.textContent = "Stop";
  state.selectionTimer = window.setInterval(() => {
    if (els.videoPreview.currentTime >= endSeconds) {
      els.videoPreview.currentTime = startSeconds;
      els.videoPreview.play();
    }
  }, 80);
}

function stopSelectionPlayback() {
  if (state.selectionTimer) {
    window.clearInterval(state.selectionTimer);
    state.selectionTimer = null;
  }
  els.playSelectionButton.textContent = "Play Selection";
  els.videoPreview.pause();
}

async function exportSelected() {
  const item = selectedMediaItem();
  if (!item || !state.metadata) return;
  els.exportMessage.textContent = "Exporting...";
  els.exportButton.disabled = true;
  const payload = {
    media_id: item.id,
    caption_mode: state.captionMode,
    manual_caption: state.captionMode === "manual" ? els.captionText.value : "",
    in_frame: state.metadata.kind === "video" ? Number(els.startFrame.value) : 0,
    frame_count: state.metadata.kind === "video" ? selectedFrameCount() : null,
    loop_count: state.loopCount,
    includes_audio: els.includesAudio.checked,
    crop_rect: state.cropRect,
  };
  try {
    const result = await api("/api/export", {
      method: "POST",
      body: JSON.stringify(payload),
    });
    els.exportMessage.textContent = result.caption_job ? `Queued ${result.media_path}` : `Saved ${result.media_path}`;
    if (state.captionMode === "manual") {
      els.captionText.value = "";
    }
    await Promise.all([loadCaptionJobs(), loadDatasetRows()]);
  } catch (error) {
    els.exportMessage.textContent = error.message;
    els.exportMessage.style.color = "var(--danger)";
  } finally {
    els.exportButton.disabled = false;
  }
}

async function loadCaptionJobs() {
  const payload = await api("/api/caption-jobs");
  els.captionJobs.replaceChildren();
  const jobs = payload.jobs || [];
  if (jobs.length === 0) {
    const empty = document.createElement("div");
    empty.className = "job-detail";
    empty.textContent = "No jobs";
    els.captionJobs.append(empty);
    return;
  }
  for (const job of jobs.slice().reverse()) {
    const item = document.createElement("div");
    item.className = "job-item";
    const title = document.createElement("div");
    title.className = "job-title";
    title.textContent = job.media_path;
    const status = document.createElement("div");
    status.className = `job-status status-${job.status}`;
    status.textContent = `${job.status} · attempts ${job.attempts}`;
    const detail = document.createElement("div");
    detail.className = "job-detail";
    detail.textContent = job.error || job.caption || (job.tags || []).join(", ");
    item.append(title, status, detail);
    if (job.status === "failed") {
      const retry = document.createElement("button");
      retry.type = "button";
      retry.textContent = "Retry";
      retry.addEventListener("click", () => retryJob(job.id));
      item.append(retry);
    }
    els.captionJobs.append(item);
  }
}

async function retryJob(jobId) {
  await api("/api/caption-jobs/retry", {
    method: "POST",
    body: JSON.stringify({ job_id: jobId }),
  });
  await loadCaptionJobs();
}

async function loadDatasetRows() {
  const payload = await api("/api/dataset");
  els.datasetRows.replaceChildren();
  const rows = payload.rows || [];
  if (rows.length === 0) {
    const empty = document.createElement("div");
    empty.className = "dataset-caption";
    empty.textContent = "No rows";
    els.datasetRows.append(empty);
    return;
  }
  for (const row of rows.slice().reverse().slice(0, 40)) {
    const item = document.createElement("div");
    item.className = "dataset-row";
    const path = document.createElement("div");
    path.className = "dataset-path";
    path.textContent = row.media_path;
    const caption = document.createElement("div");
    caption.className = "dataset-caption";
    caption.textContent = row.caption;
    item.append(path, caption);
    els.datasetRows.append(item);
  }
}

function bindEvents() {
  els.saveConfigButton.addEventListener("click", runAction(saveConfig));
  els.refreshButton.addEventListener("click", runAction(refreshAll));
  els.saveCaptionConfigButton.addEventListener("click", runAction(saveCaptionConfig));
  els.previousButton.addEventListener("click", () => selectMedia(state.selectedIndex - 1));
  els.nextButton.addEventListener("click", () => selectMedia(state.selectedIndex + 1));
  els.startFrame.addEventListener("input", updateStartFrameOutput);
  els.frameCount.addEventListener("change", () => {
    updateStartFrameMax();
    updateStartFrameOutput();
  });
  els.playSelectionButton.addEventListener("click", playSelection);
  els.resetCropButton.addEventListener("click", () => {
    state.cropRect = null;
    updateCropLabel();
  });
  els.mediaFrame.addEventListener("pointerdown", startCropDrag);
  els.automaticCaptionButton.addEventListener("click", () => setCaptionMode("automatic"));
  els.manualCaptionButton.addEventListener("click", () => setCaptionMode("manual"));
  document.querySelectorAll("[data-loop-count]").forEach((button) => {
    button.addEventListener("click", () => setLoopCount(button.dataset.loopCount));
  });
  els.exportButton.addEventListener("click", runAction(exportSelected));
}

function runAction(action) {
  return async () => {
    try {
      setStatus("Working...");
      await action();
      setStatus("Ready");
    } catch (error) {
      setStatus(error.message, "error");
    }
  };
}

async function boot() {
  bindEvents();
  setLoopCount(1);
  setCaptionMode("automatic");
  await loadConfig();
  await loadCaptionConfig();
  await refreshAll();
  window.setInterval(() => {
    loadCaptionJobs().catch(() => {});
    loadDatasetRows().catch(() => {});
  }, 4000);
}

boot().catch((error) => {
  setStatus(error.message, "error");
});

