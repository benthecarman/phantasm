//! Shared ComfyUI plumbing for the image-generation and image-edit tools.
//!
//! Both tools build an API-format workflow graph (a `serde_json::Value` keyed by
//! node ID) by injecting their inputs into configured nodes, then hand it to
//! [`run_workflow`], which: opens the progress WebSocket *first* (so no early
//! frames are missed), submits via `POST /prompt`, relays progress to the app as
//! `x_status`, and returns the finished image bytes. When the backend offers the
//! `SaveImageWebsocket` node the image streams straight back over that same WS
//! (no temp file, no extra round trips); otherwise it falls back to fetching from
//! `/history` + `/view`. Either way the bytes are handed up for the caller to
//! deliver (inline base64 `data:` URI, or persisted to the blob store).
//!
//! The edit tool additionally needs the user's image available to ComfyUI first;
//! [`upload_temp_image`] handles that via `POST /upload/image` with
//! `type=temp`, then references it as an annotated `LoadImage` path.

use std::collections::HashSet;
use std::time::{Duration, Instant};

use base64::Engine;
use futures_util::StreamExt;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use url::Url;

use crate::config::{Config, NodeInput};
use crate::orchestrator::TurnEvent;
use crate::tools::http_util;

// The progress phases surfaced to the app as `x_status`, in order. `DOWNLOADING`
// is emitted twice — first as an indeterminate `Status`, then as the label on the
// determinate `Progress` bar — so the label must match across both for the pill
// to read as one continuous phase. Naming them keeps that pair in lockstep.
//
// `LOADING_MODEL` covers the pre-sampling stretch (checkpoint into VRAM, CLIP and
// VAE encode) where ComfyUI emits no progress frames; it is deliberately distinct
// from `GENERATING` so the indeterminate heartbeat and the determinate sampling
// bar read as two phases rather than the same label stuttering. `FINISHING` is the
// mirror on the back end: VAE decode + save run after sampling hits 100% but emit
// no progress, so the bar would otherwise sit frozen at 100% — this labels the
// tail as active instead.
/// Raw-body cap for the `/history/<id>` JSON. A prompt's history holds node
/// outputs and metadata (not image bytes), but complex workflows can make it
/// large — so it gets a roomier cap than the shared JSON default.
const HISTORY_BODY_CAP: usize = 8 * 1024 * 1024;

const STATUS_QUEUED: &str = "queued…";
const STATUS_LOADING_MODEL: &str = "loading model…";
const STATUS_GENERATING: &str = "generating image…";
const STATUS_FINISHING: &str = "finishing up…";
const STATUS_RETRIEVING: &str = "retrieving image…";
const STATUS_DOWNLOADING: &str = "downloading image…";

/// Whether this ComfyUI exposes the `SaveImageWebsocket` node, probed once and
/// cached for the process. When present, finished images stream straight back
/// over the progress WS — no temp file written, no `/history` lookup + `/view`
/// download afterwards. When absent (or the probe errors) we fall back to the
/// `PreviewImage` + fetch path. A transient probe failure latches the fallback
/// until restart, which is harmless: the fetch path is fully functional.
static WS_DELIVERY: tokio::sync::OnceCell<bool> = tokio::sync::OnceCell::const_new();

async fn ws_image_delivery(cfg: &Config, http: &reqwest::Client) -> bool {
    *WS_DELIVERY
        .get_or_init(|| async {
            let url = http_util::join_base(&cfg.comfy_base, "/object_info/SaveImageWebsocket");
            // `/object_info/<node>` returns `{ "<node>": {…schema…} }` when the
            // node exists, an empty object otherwise.
            let supported = match http.get(url).send().await {
                Ok(r) if r.status().is_success() => r
                    .json::<Value>()
                    .await
                    .map(|v| v.get("SaveImageWebsocket").is_some())
                    .unwrap_or(false),
                _ => false,
            };
            tracing::debug!(supported, "probed ComfyUI SaveImageWebsocket support");
            supported
        })
        .await
}

/// Tells ComfyUI to abandon a submitted prompt, freeing the GPU. Best-effort:
/// errors are ignored — this runs on a cancellation/cleanup path where there is
/// no caller left to surface them to.
///
/// `POST /interrupt` is **global**: it aborts whatever prompt ComfyUI is
/// currently executing, not a specific one. It is only sent when `executing`
/// says OUR prompt had started running (per the WS `executing`/`progress`
/// frames) — firing it for a still-queued prompt would kill someone else's
/// generation. The `POST /queue {delete:[id]}` removal is scoped to our
/// prompt id and is always safe, so it is always issued.
async fn interrupt_comfy(
    comfy_base: &Url,
    http: &reqwest::Client,
    prompt_id: &str,
    executing: bool,
) {
    if executing {
        let _ = http
            .post(http_util::join_base(comfy_base, "/interrupt"))
            .send()
            .await;
    }
    let _ = http
        .post(http_util::join_base(comfy_base, "/queue"))
        .json(&serde_json::json!({ "delete": [prompt_id] }))
        .send()
        .await;
    tracing::info!(prompt_id, executing, "interrupted ComfyUI generation");
}

/// Whether our prompt has begun executing, given the progress phase marker
/// `last_pct` (see [`run_workflow`]): `-2` means nothing seen yet (queued at
/// most), and every later phase (`-1`, `0..=100`, `101`) is only entered off
/// an `executing` frame checked against our prompt id, or a `progress` frame
/// (which ComfyUI addresses to the submitting client). Gates the global
/// `/interrupt` in [`interrupt_comfy`].
fn execution_started(last_pct: i64) -> bool {
    last_pct > -2
}

/// Drop guard that interrupts a submitted-but-unfinished ComfyUI prompt. The
/// turn-level tool `select!` (and the image tool's own) cancel a backgrounded or
/// stopped generation by *dropping* the `run_workflow` future — so the only
/// reliable place to tell ComfyUI to stop is here, on drop. Without it the GPU
/// job runs on orphaned. `prompt_id` is the live state: `Some` once submitted,
/// cleared to `None` on success (so a normal completion fires no pointless
/// interrupt) or by drop (so the spawned interrupt fires at most once).
struct InterruptOnDrop {
    comfy_base: Url,
    http: reqwest::Client,
    prompt_id: Option<String>,
    /// Whether our prompt was seen executing (vs. still queued). Decides if the
    /// drop may send the global `/interrupt` or only the scoped queue delete.
    executing: bool,
}

impl Drop for InterruptOnDrop {
    fn drop(&mut self) {
        let Some(prompt_id) = self.prompt_id.take() else {
            return; // never submitted, or completed — nothing to interrupt
        };
        let executing = self.executing;
        // Drop is synchronous, so the interrupt is spawned detached. Guard on a
        // live runtime: during shutdown the drop can run with no runtime, where
        // `tokio::spawn` would panic. Then the process is exiting anyway, so the
        // GPU job is the OS/ComfyUI's problem, not a panic-in-Drop → abort.
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let comfy_base = self.comfy_base.clone();
        let http = self.http.clone();
        handle.spawn(async move {
            interrupt_comfy(&comfy_base, &http, &prompt_id, executing).await;
        });
    }
}

/// Inject `value` into `workflow[target.node]["inputs"][target.key]`.
pub fn set_input(workflow: &mut Value, target: &NodeInput, value: Value) -> Result<(), String> {
    let inputs = workflow
        .get_mut(&target.node)
        .ok_or_else(|| format!("node {} not found in workflow", target.node))?
        .get_mut("inputs")
        .ok_or_else(|| format!("node {} has no inputs", target.node))?;
    let obj = inputs.as_object_mut().ok_or("inputs is not an object")?;
    obj.insert(target.key.clone(), value);
    Ok(())
}

/// Upload raw image bytes into ComfyUI's temp folder so a `LoadImage` node can
/// reference them without placing user attachments in ComfyUI's durable input
/// library. Returns an annotated filename like `foo.png [temp]` (ComfyUI's
/// `LoadImage` resolves `[temp]` via `folder_paths.get_annotated_filepath`).
pub async fn upload_temp_image(
    cfg: &Config,
    http: &reqwest::Client,
    bytes: Vec<u8>,
    filename: &str,
) -> Result<String, String> {
    let url = http_util::join_base(&cfg.comfy_base, "/upload/image");
    let part = reqwest::multipart::Part::bytes(bytes)
        .file_name(filename.to_string())
        .mime_str("image/png")
        .map_err(|e| e.to_string())?;
    let form = reqwest::multipart::Form::new()
        .part("image", part)
        .text("type", "temp")
        .text("overwrite", "true");
    let resp = http
        .post(url)
        .multipart(form)
        .send()
        .await
        .map_err(|e| format!("backend unreachable: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("ComfyUI rejected upload ({status}): {body}"));
    }
    let v: Value = resp.json().await.map_err(|e| e.to_string())?;
    let name = v
        .get("name")
        .and_then(|n| n.as_str())
        .ok_or_else(|| "upload response missing name".to_string())?;
    Ok(temp_image_ref(
        name,
        v.get("subfolder").and_then(|s| s.as_str()).unwrap_or(""),
    ))
}

/// Submit a fully-prepared workflow, relay progress, and return the produced
/// image as raw bytes plus its content type. The caller decides delivery —
/// inline base64 data URI, or persist to the blob store and hand back a URL.
pub async fn run_workflow(
    cfg: &Config,
    http: &reqwest::Client,
    mut workflow: Value,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<(Vec<u8>, String), String> {
    // Prefer streaming the result back over the WS we already hold open; fall
    // back to the temp-file + `/history` + `/view` path when the node is absent.
    let ws_delivery = ws_image_delivery(cfg, http).await;
    if ws_delivery {
        force_ws_outputs(&mut workflow);
    } else {
        force_temporary_outputs(&mut workflow);
    }

    let client_id = uuid::Uuid::new_v4().simple().to_string();

    // Open the progress WS *before* submitting so we never miss early frames.
    let ws_url = ws_url(cfg, &client_id)?;
    let (mut ws, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .map_err(|e| format!("cannot open ComfyUI websocket: {e}"))?;

    // From here on, if this future is dropped (turn cancelled / app stopped) or
    // we bail on timeout/error, tell ComfyUI to abandon the prompt so the GPU is
    // freed instead of running the generation orphaned.
    let mut interrupt = InterruptOnDrop {
        comfy_base: cfg.comfy_base.clone(),
        http: http.clone(),
        prompt_id: None,
        executing: false,
    };

    // Submit the workflow.
    let prompt_url = http_util::join_base(&cfg.comfy_base, "/prompt");
    let submit = serde_json::json!({ "prompt": workflow, "client_id": client_id });
    let resp = http
        .post(prompt_url)
        .json(&submit)
        .send()
        .await
        .map_err(|e| format!("backend unreachable: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("ComfyUI rejected workflow ({status}): {body}"));
    }
    let submit_resp: Value = resp.json().await.map_err(|e| e.to_string())?;
    let prompt_id = submit_resp
        .get("prompt_id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "ComfyUI did not return a prompt_id".to_string())?
        .to_string();
    interrupt.prompt_id = Some(prompt_id.clone());

    // Submitted but not yet dequeued: until ComfyUI starts the graph (model load
    // can take seconds) there are no progress frames, so announce the wait rather
    // than leaving the app frozen on the caller's "preparing…"/"uploading…" status.
    let _ = tx.send(TurnEvent::Status(STATUS_QUEUED.into())).await;

    // Timing breakdown for diagnosing where the post-submit wall-clock goes:
    // queue+execute (here) vs history lookup vs byte download (in `fetch_image`).
    let submit_at = Instant::now();

    // Consume progress until completion / timeout. `last_pct` is a phase marker:
    // -2 = nothing seen yet, -1 = execution started (loading-model heartbeat sent),
    // 0..=100 = determinate sampling progress, 101 = post-sampling (finishing-up
    // heartbeat sent).
    let cap = cfg.comfy_max_image_bytes;
    let deadline = tokio::time::sleep(Duration::from_secs(cfg.comfy_timeout_s));
    tokio::pin!(deadline);
    let mut last_pct: i64 = -2;
    // Image streamed over the socket (WS-delivery mode). The last frame wins: the
    // terminal `SaveImageWebsocket` node runs after any KSampler preview frames.
    let mut ws_image: Option<(Vec<u8>, String)> = None;
    // Execution-phase milestones (elapsed since submit), for the timing breakdown:
    // first determinate progress = queue + model load done; finishing = sampling
    // done, post-processing begun.
    let mut first_progress_at: Option<Duration> = None;
    let mut finishing_at: Option<Duration> = None;
    loop {
        tokio::select! {
            _ = &mut deadline => return Err("image generation timed out".into()),
            msg = ws.next() => match msg {
                Some(Ok(Message::Text(txt))) => {
                    let prev_pct = last_pct;
                    let done = match handle_ws_message(&txt, &prompt_id, &mut last_pct, tx).await {
                        Ok(done) => done,
                        Err(e) => {
                            // ComfyUI has already completed this prompt with a
                            // backend-side error; do not let the drop guard send
                            // a global interrupt that could hit the next prompt.
                            interrupt.prompt_id = None;
                            return Err(e);
                        }
                    };
                    // Once our prompt is seen executing, a drop/bail-out may use
                    // the global /interrupt (before that, only the queue delete).
                    interrupt.executing = execution_started(last_pct);
                    if first_progress_at.is_none() && prev_pct < 0 && (0..=100).contains(&last_pct) {
                        first_progress_at = Some(submit_at.elapsed());
                    }
                    if finishing_at.is_none() && last_pct == 101 {
                        finishing_at = Some(submit_at.elapsed());
                    }
                    if done == Some(true) {
                        break;
                    }
                }
                Some(Ok(Message::Binary(b))) if ws_delivery => {
                    if let Some(img) = parse_ws_image(&b, cap) {
                        ws_image = Some(img);
                    }
                }
                Some(Ok(Message::Close(_))) | None => break,
                Some(Ok(_)) => {} // pings / previews (non-WS-delivery) — ignore
                Some(Err(e)) => return Err(format!("websocket error: {e}")),
            }
        }
    }
    drop(ws);

    // Generation finished (or the WS closed): the result is now in hand (streamed
    // over the WS) or waiting in ComfyUI's history, so disarm the guard. A
    // timeout/WS-error bails earlier with it still armed, freeing the GPU.
    interrupt.prompt_id = None;

    // Break the opaque execute window into queue+load / sampling / finishing tail
    // so we can tell whether the wall-clock is model residency vs raw sampling.
    let execute_elapsed = submit_at.elapsed();
    let sampling_ms = match (first_progress_at, finishing_at) {
        (Some(start), Some(end)) => Some(end.saturating_sub(start).as_millis()),
        _ => None,
    };
    let tail_ms = finishing_at.map(|f| execute_elapsed.saturating_sub(f).as_millis());
    tracing::debug!(
        execute_ms = execute_elapsed.as_millis() as u64,
        queue_load_ms = ?first_progress_at.map(|d| d.as_millis()),
        sampling_ms = ?sampling_ms,
        tail_ms = ?tail_ms,
        ws_delivery,
        "comfy workflow finished (submit → execution-complete)"
    );

    // WS-delivery: the bytes already arrived over the socket — no temp file, no
    // `/history`, no `/view`. SaveImageWebsocket leaves nothing in history, so a
    // missing frame is a hard error rather than a silent fall-through to fetch.
    if ws_delivery {
        return match ws_image {
            Some((bytes, mime)) => {
                tracing::debug!(bytes = bytes.len(), "image delivered over websocket");
                Ok((bytes, mime))
            }
            None => Err("no image received over ComfyUI websocket".into()),
        };
    }

    // Fallback path: locate the produced image in ComfyUI's history, then download.
    let _ = tx.send(TurnEvent::Status(STATUS_RETRIEVING.into())).await;
    fetch_image(cfg, http, &prompt_id, tx).await
}

/// A file artifact emitted by a configured workflow output node.
pub struct WorkflowArtifact {
    pub bytes: Vec<u8>,
    pub mime: String,
    pub filename: String,
}

#[derive(Clone, Copy)]
enum ArtifactKind {
    Audio,
    Video,
}

impl ArtifactKind {
    fn name(self) -> &'static str {
        match self {
            Self::Audio => "audio",
            Self::Video => "video",
        }
    }
}

struct ArtifactRunOptions<'a> {
    output_nodes: &'a [String],
    timeout_s: u64,
    max_bytes: usize,
    kind: ArtifactKind,
}

/// Run a configured audio workflow and retrieve its single temporary artifact.
/// Durable saver nodes are rewritten to `PreviewAudio` before submission so
/// prompts do not accumulate in ComfyUI's output library.
pub async fn run_audio_workflow(
    cfg: &Config,
    http: &reqwest::Client,
    mut workflow: Value,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<WorkflowArtifact, String> {
    let selected = cfg
        .comfy_audio_output
        .as_deref()
        .ok_or("COMFYUI_AUDIO_OUTPUT is not configured")?;
    let output_nodes = force_temporary_audio_outputs(&mut workflow, selected)?;
    let options = ArtifactRunOptions {
        output_nodes: &output_nodes,
        timeout_s: cfg.comfy_audio_timeout_s,
        max_bytes: cfg.comfy_max_audio_bytes,
        kind: ArtifactKind::Audio,
    };
    let mut artifacts = run_artifact_workflow(cfg, http, workflow, tx, &options).await?;
    artifacts
        .pop()
        .ok_or_else(|| "audio workflow produced no artifact".into())
}

/// Run a configured video workflow and retrieve its selected file artifact.
/// Known output nodes are switched to temporary delivery when they expose such
/// a setting; the rest of the graph is passed through unchanged.
pub async fn run_video_workflow(
    cfg: &Config,
    http: &reqwest::Client,
    mut workflow: Value,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<WorkflowArtifact, String> {
    let selected = cfg
        .comfy_video_output
        .as_deref()
        .ok_or("COMFYUI_VIDEO_OUTPUT is not configured")?;
    let output_nodes = prepare_video_output(&mut workflow, selected)?;
    let options = ArtifactRunOptions {
        output_nodes: &output_nodes,
        timeout_s: cfg.comfy_video_timeout_s,
        max_bytes: cfg.comfy_max_video_bytes,
        kind: ArtifactKind::Video,
    };
    let mut artifacts = run_artifact_workflow(cfg, http, workflow, tx, &options).await?;
    artifacts
        .pop()
        .ok_or_else(|| "video workflow produced no artifact".into())
}

async fn run_artifact_workflow(
    cfg: &Config,
    http: &reqwest::Client,
    workflow: Value,
    tx: &mpsc::Sender<TurnEvent>,
    options: &ArtifactRunOptions<'_>,
) -> Result<Vec<WorkflowArtifact>, String> {
    let client_id = uuid::Uuid::new_v4().simple().to_string();
    let ws_url = ws_url(cfg, &client_id)?;
    let (mut ws, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .map_err(|e| format!("cannot open ComfyUI websocket: {e}"))?;
    let mut interrupt = InterruptOnDrop {
        comfy_base: cfg.comfy_base.clone(),
        http: http.clone(),
        prompt_id: None,
        executing: false,
    };
    let resp = http
        .post(http_util::join_base(&cfg.comfy_base, "/prompt"))
        .json(&serde_json::json!({"prompt": workflow, "client_id": client_id}))
        .send()
        .await
        .map_err(|e| format!("backend unreachable: {e}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("ComfyUI rejected workflow ({status}): {body}"));
    }
    let submitted: Value = resp.json().await.map_err(|e| e.to_string())?;
    let prompt_id = submitted
        .get("prompt_id")
        .and_then(Value::as_str)
        .ok_or_else(|| "ComfyUI did not return a prompt_id".to_string())?
        .to_string();
    interrupt.prompt_id = Some(prompt_id.clone());
    let _ = tx.send(TurnEvent::Status(STATUS_QUEUED.into())).await;

    let deadline = tokio::time::sleep(Duration::from_secs(options.timeout_s));
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            _ = &mut deadline => return Err(format!("ComfyUI {} workflow timed out", options.kind.name())),
            msg = ws.next() => match msg {
                Some(Ok(Message::Text(txt))) => {
                    let Ok(event) = serde_json::from_str::<Value>(&txt) else { continue };
                    let kind = event.get("type").and_then(Value::as_str).unwrap_or("");
                    let data = event.get("data");
                    let same_prompt = data
                        .and_then(|d| d.get("prompt_id"))
                        .and_then(Value::as_str)
                        == Some(prompt_id.as_str());
                    match kind {
                        "execution_start" if same_prompt => {
                            interrupt.executing = true;
                            let _ = tx.send(TurnEvent::Status(format!("generating {}…", options.kind.name()))).await;
                        }
                        "progress" => {
                            let value = data.and_then(|d| d.get("value")).and_then(Value::as_f64);
                            let max = data.and_then(|d| d.get("max")).and_then(Value::as_f64);
                            if let (Some(value), Some(max)) = (value, max) {
                                if max > 0.0 {
                                    let _ = tx.send(TurnEvent::Progress {
                                        status: format!("generating {}…", options.kind.name()),
                                        progress: (value / max).clamp(0.0, 1.0),
                                    }).await;
                                }
                            }
                        }
                        "execution_success" if same_prompt => break,
                        "execution_error" if same_prompt => {
                            interrupt.prompt_id = None;
                            return Err(format_execution_error(data));
                        }
                        "execution_interrupted" if same_prompt => {
                            interrupt.prompt_id = None;
                            return Err("ComfyUI execution interrupted".into());
                        }
                        "executing" if same_prompt && data.and_then(|d| d.get("node")).is_some_and(Value::is_null) => break,
                        _ => {}
                    }
                }
                Some(Ok(Message::Close(_))) | None => break,
                Some(Ok(_)) => {}
                Some(Err(e)) => return Err(format!("websocket error: {e}")),
            }
        }
    }
    drop(ws);
    interrupt.prompt_id = None;
    let _ = tx
        .send(TurnEvent::Status("retrieving artifacts…".into()))
        .await;
    fetch_artifacts(cfg, http, &prompt_id, tx, options).await
}

async fn fetch_artifacts(
    cfg: &Config,
    http: &reqwest::Client,
    prompt_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    options: &ArtifactRunOptions<'_>,
) -> Result<Vec<WorkflowArtifact>, String> {
    let history: Value = http_util::send_json(
        http.get(http_util::join_base(
            &cfg.comfy_base,
            &format!("/history/{prompt_id}"),
        )),
        Duration::from_secs(options.timeout_s),
        HISTORY_BODY_CAP,
    )
    .await?;
    let outputs = history
        .get(prompt_id)
        .and_then(|v| v.get("outputs"))
        .and_then(Value::as_object)
        .ok_or_else(|| "ComfyUI history contained no outputs".to_string())?;
    let mut refs = Vec::new();
    for node_id in options.output_nodes {
        let Some(node) = outputs.get(node_id) else {
            continue;
        };
        collect_file_refs(node, &mut refs);
    }
    let mut seen = HashSet::new();
    refs.retain(|file| {
        seen.insert((
            file.filename.clone(),
            file.subfolder.clone(),
            file.kind.clone(),
        ))
    });
    if refs.is_empty() {
        return Err("selected output nodes produced no retrievable artifacts".into());
    }
    if refs.len() != 1 {
        return Err(format!(
            "{} output produced {} artifacts; exactly one is required",
            options.kind.name(),
            refs.len()
        ));
    }
    let mut artifacts = Vec::with_capacity(refs.len());
    for file in refs {
        let resp = http
            .get(http_util::join_base(&cfg.comfy_base, "/view"))
            .query(&[
                ("filename", file.filename.as_str()),
                ("subfolder", file.subfolder.as_str()),
                ("type", file.kind.as_str()),
            ])
            .timeout(Duration::from_secs(options.timeout_s))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if !resp.status().is_success() {
            return Err(format!(
                "cannot retrieve ComfyUI artifact ({})",
                resp.status()
            ));
        }
        let mime = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("application/octet-stream")
            .to_string();
        if let Some(len) = resp.content_length() {
            if len as usize > options.max_bytes {
                return Err(format!("artifact too large ({len} bytes)"));
            }
        }
        let mut bytes = Vec::new();
        let mut stream = resp.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| e.to_string())?;
            if bytes.len() + chunk.len() > options.max_bytes {
                return Err("artifact exceeded byte cap".into());
            }
            bytes.extend_from_slice(&chunk);
        }
        let _ = tx
            .send(TurnEvent::Status("storing artifacts…".into()))
            .await;
        artifacts.push(WorkflowArtifact {
            bytes,
            mime,
            filename: file.filename,
        });
    }
    Ok(artifacts)
}

fn force_temporary_audio_outputs(
    workflow: &mut Value,
    selected: &str,
) -> Result<Vec<String>, String> {
    let nodes = workflow
        .as_object_mut()
        .ok_or("audio workflow must be an API-format object keyed by node id")?;
    let mut outputs = Vec::new();
    for (id, node) in nodes {
        let Some(obj) = node.as_object_mut() else {
            continue;
        };
        let class = obj.get("class_type").and_then(Value::as_str).unwrap_or("");
        if !matches!(
            class,
            "PreviewAudio" | "SaveAudio" | "SaveAudioAdvanced" | "SaveAudioMP3" | "SaveAudioOpus"
        ) {
            continue;
        }
        obj.insert("class_type".into(), Value::String("PreviewAudio".into()));
        let inputs = obj
            .get_mut("inputs")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| format!("audio output node {id} has invalid inputs"))?;
        inputs.retain(|key, _| key == "audio");
        if !inputs.contains_key("audio") {
            return Err(format!("audio output node {id} is missing its audio input"));
        }
        outputs.push(id.clone());
    }
    if !outputs.iter().any(|id| id == selected) {
        return Err(format!(
            "COMFYUI_AUDIO_OUTPUT node {selected} is not a PreviewAudio/SaveAudio output"
        ));
    }
    Ok(vec![selected.to_string()])
}

fn prepare_video_output(workflow: &mut Value, selected: &str) -> Result<Vec<String>, String> {
    let nodes = workflow
        .as_object_mut()
        .ok_or("video workflow must be an API-format object keyed by node id")?;
    let node = nodes
        .get_mut(selected)
        .and_then(Value::as_object_mut)
        .ok_or_else(|| format!("COMFYUI_VIDEO_OUTPUT node {selected} does not exist"))?;
    // VideoHelperSuite can emit directly into ComfyUI's temp directory. Other
    // output implementations remain untouched and are retrieved generically
    // from the selected node's history entry.
    if node.get("class_type").and_then(Value::as_str) == Some("VHS_VideoCombine") {
        let inputs = node
            .get_mut("inputs")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| format!("video output node {selected} has invalid inputs"))?;
        inputs.insert("save_output".into(), Value::Bool(false));
    }
    Ok(vec![selected.to_string()])
}

fn collect_file_refs(value: &Value, out: &mut Vec<ImageRef>) {
    match value {
        Value::Array(items) => items.iter().for_each(|v| collect_file_refs(v, out)),
        Value::Object(obj) => {
            if let Some(filename) = obj.get("filename").and_then(Value::as_str) {
                out.push(ImageRef {
                    filename: filename.to_string(),
                    subfolder: obj
                        .get("subfolder")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    kind: obj
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("temp")
                        .to_string(),
                });
                return;
            }
            obj.values().for_each(|v| collect_file_refs(v, out));
        }
        _ => {}
    }
}

/// Encode produced bytes as a `data:<mime>;base64,…` URI (inline delivery).
pub fn to_data_uri(bytes: &[u8], mime: &str) -> String {
    let b64 = base64::engine::general_purpose::STANDARD.encode(bytes);
    format!("data:{mime};base64,{b64}")
}

fn temp_image_ref(name: &str, subfolder: &str) -> String {
    let path = if subfolder.is_empty() {
        name.to_string()
    } else {
        format!("{subfolder}/{name}")
    };
    format!("{path} [temp]")
}

/// Convert durable built-in image output nodes into temp previews. This lets
/// ComfyUI expose the image through `/history` + `/view` without writing it to
/// the durable output library. Custom workflows may still use `SaveImage`; the
/// orchestrator rewrites it at submission time so the privacy boundary does not
/// depend on every workflow author remembering to use `PreviewImage`.
fn force_temporary_outputs(workflow: &mut Value) {
    let Some(nodes) = workflow.as_object_mut() else {
        return;
    };
    for node in nodes.values_mut() {
        let Some(obj) = node.as_object_mut() else {
            continue;
        };
        if obj.get("class_type").and_then(Value::as_str) == Some("SaveImage") {
            obj.insert("class_type".into(), Value::String("PreviewImage".into()));
            if let Some(inputs) = obj.get_mut("inputs").and_then(Value::as_object_mut) {
                inputs.remove("filename_prefix");
            }
        }
    }
}

/// Rewrite built-in output nodes to `SaveImageWebsocket`, which streams the
/// finished image straight back over the progress WS instead of writing a temp
/// file we then locate (`/history`) and download (`/view`). Both `SaveImage` and
/// `PreviewImage` feed the same `images` input the WS node expects, so swapping
/// the `class_type` (and dropping the now-irrelevant `filename_prefix`) is enough.
/// Used in place of [`force_temporary_outputs`] when the backend advertises it.
fn force_ws_outputs(workflow: &mut Value) {
    let Some(nodes) = workflow.as_object_mut() else {
        return;
    };
    for node in nodes.values_mut() {
        let Some(obj) = node.as_object_mut() else {
            continue;
        };
        let class = obj.get("class_type").and_then(Value::as_str);
        if class == Some("SaveImage") || class == Some("PreviewImage") {
            obj.insert(
                "class_type".into(),
                Value::String("SaveImageWebsocket".into()),
            );
            if let Some(inputs) = obj.get_mut("inputs").and_then(Value::as_object_mut) {
                inputs.remove("filename_prefix");
            }
        }
    }
}

/// Parse a ComfyUI binary WS frame carrying an image into `(bytes, mime)`. Layout:
/// `[u32 BE event type][u32 BE image format][raw image bytes]`, where event 1 is
/// `PREVIEW_IMAGE` and format 1 = JPEG, 2 = PNG. Frames that are truncated, of a
/// different event type, empty, or whose payload exceeds `cap` yield `None`.
fn parse_ws_image(frame: &[u8], cap: usize) -> Option<(Vec<u8>, String)> {
    const PREVIEW_IMAGE: u32 = 1;
    let event = u32::from_be_bytes(frame.get(0..4)?.try_into().ok()?);
    if event != PREVIEW_IMAGE {
        return None;
    }
    let format = u32::from_be_bytes(frame.get(4..8)?.try_into().ok()?);
    let payload = frame.get(8..)?;
    if payload.is_empty() || payload.len() > cap {
        return None;
    }
    let mime = if format == 1 {
        "image/jpeg"
    } else {
        "image/png"
    };
    Some((payload.to_vec(), mime.to_string()))
}

/// Returns `Some(true)` when generation for our prompt completed.
async fn handle_ws_message(
    txt: &str,
    prompt_id: &str,
    last_pct: &mut i64,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<Option<bool>, String> {
    let v: Value = match serde_json::from_str(txt) {
        Ok(v) => v,
        Err(_) => return Ok(None),
    };
    let Some(kind) = v.get("type").and_then(Value::as_str) else {
        return Ok(None);
    };
    let data = v.get("data");
    match kind {
        "progress" => {
            let Some(value) = data.and_then(|d| d.get("value")).and_then(Value::as_i64) else {
                return Ok(None);
            };
            let Some(max) = data
                .and_then(|d| d.get("max"))
                .and_then(Value::as_i64)
                .filter(|m| *m > 0)
            else {
                return Ok(None);
            };
            let pct = (value * 100 / max).clamp(0, 100);
            // Once we've advanced to the finishing phase (101), ignore a trailing
            // full-progress frame: ComfyUI sometimes emits a final value==max after
            // the post-sampling node has already started, which would otherwise
            // bounce the pill from "finishing up…" back to a frozen "generating
            // image…" 100% for the last second. A genuinely new pass (hires-fix
            // second sampler) restarts at a low pct, so it still falls through and
            // resumes the determinate bar.
            if *last_pct == 101 && pct >= 100 {
                return Ok(Some(false));
            }
            if pct != *last_pct {
                *last_pct = pct;
                let _ = tx
                    .send(TurnEvent::Progress {
                        status: STATUS_GENERATING.into(),
                        progress: pct as f64 / 100.0,
                    })
                    .await;
            }
            Ok(Some(false))
        }
        "executing" => {
            let Some(data) = data else {
                return Ok(None);
            };
            let node_is_null = data.get("node").map(|n| n.is_null()).unwrap_or(false);
            let same_prompt = data.get("prompt_id").and_then(|p| p.as_str()) == Some(prompt_id);
            // `node: null` for our prompt signals completion (older ComfyUI).
            if node_is_null {
                return Ok(Some(same_prompt));
            }
            if same_prompt && *last_pct == -2 {
                // First sign of execution, before any determinate progress (-2
                // start): emit a one-time heartbeat so the pre-sampling stretch
                // (model load, CLIP/VAE encode) shows movement instead of a frozen
                // "queued…". Advancing to -1 marks it sent; once `progress` frames
                // flow, the determinate "generating image…" bar takes over.
                *last_pct = -1;
                let _ = tx
                    .send(TurnEvent::Status(STATUS_LOADING_MODEL.into()))
                    .await;
            } else if same_prompt && (0..=100).contains(&*last_pct) {
                // A node is still running after sampling reported progress — VAE
                // decode / save — which emit no progress frames, so the bar would
                // otherwise sit frozen at 100%. Switch to an indeterminate
                // "finishing up…" so the tail reads as active. 101 marks it sent; a
                // later sampler (e.g. hires fix) resuming `progress` frames cleanly
                // overrides it back to the determinate bar.
                *last_pct = 101;
                let _ = tx.send(TurnEvent::Status(STATUS_FINISHING.into())).await;
            }
            Ok(Some(false))
        }
        // Newer ComfyUI signals completion with `execution_success` instead of an
        // `executing` frame carrying `node: null`. Honor both so generation
        // doesn't run to `comfy_timeout_s` on those versions.
        "execution_success" => {
            let same_prompt = data
                .and_then(|d| d.get("prompt_id"))
                .and_then(Value::as_str)
                == Some(prompt_id);
            Ok(Some(same_prompt))
        }
        "execution_error" => {
            let same_prompt = data
                .and_then(|d| d.get("prompt_id"))
                .and_then(Value::as_str)
                == Some(prompt_id);
            if same_prompt {
                Err(format_execution_error(data))
            } else {
                Ok(Some(false))
            }
        }
        "execution_interrupted" => {
            let same_prompt = data
                .and_then(|d| d.get("prompt_id"))
                .and_then(Value::as_str)
                == Some(prompt_id);
            if same_prompt {
                Err("ComfyUI execution interrupted".into())
            } else {
                Ok(Some(false))
            }
        }
        _ => Ok(Some(false)),
    }
}

fn format_execution_error(data: Option<&Value>) -> String {
    let node = data
        .and_then(|d| d.get("node_id"))
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty());
    let node_type = data
        .and_then(|d| d.get("node_type"))
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty());
    let exception_type = data
        .and_then(|d| d.get("exception_type"))
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty());
    let message = data
        .and_then(|d| d.get("exception_message"))
        .and_then(Value::as_str)
        .map(clean_error_message)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown error".into());

    let mut out = String::from("ComfyUI execution failed");
    match (node, node_type) {
        (Some(node), Some(node_type)) => out.push_str(&format!(" at node {node} ({node_type})")),
        (Some(node), None) => out.push_str(&format!(" at node {node}")),
        (None, Some(node_type)) => out.push_str(&format!(" in {node_type}")),
        (None, None) => {}
    }
    out.push_str(": ");
    if let Some(exception_type) = exception_type {
        out.push_str(exception_type);
        out.push_str(": ");
    }
    out.push_str(&message);
    out
}

fn clean_error_message(raw: &str) -> String {
    const MAX: usize = 500;
    let compact = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= MAX {
        return compact;
    }
    format!("{}...", compact.chars().take(MAX).collect::<String>())
}

async fn fetch_image(
    cfg: &Config,
    http: &reqwest::Client,
    prompt_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
) -> Result<(Vec<u8>, String), String> {
    let history_at = Instant::now();
    let hist_url = http_util::join_base(&cfg.comfy_base, &format!("/history/{prompt_id}"));
    // Deadlined + capped via the shared helper. History entries carry node
    // outputs and metadata for the whole prompt, so allow well beyond the
    // default JSON cap — still bounded.
    let hist: Value = http_util::send_json(
        http.get(hist_url),
        Duration::from_secs(cfg.comfy_timeout_s),
        HISTORY_BODY_CAP,
    )
    .await?;

    let image = find_first_image(&hist, prompt_id)
        .ok_or_else(|| "no image in ComfyUI output".to_string())?;
    let history_ms = history_at.elapsed().as_millis();

    let download_at = Instant::now();
    let view_url = http_util::join_base(&cfg.comfy_base, "/view");
    let resp = http
        .get(view_url)
        .query(&[
            ("filename", image.filename.as_str()),
            ("subfolder", image.subfolder.as_str()),
            ("type", image.kind.as_str()),
        ])
        .timeout(Duration::from_secs(cfg.comfy_timeout_s))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let mime = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("image/png")
        .to_string();
    let cap = cfg.comfy_max_image_bytes;
    // Known body length, if usable for a determinate bar (absent on chunked/gzip).
    let total = resp.content_length().map(|l| l as usize).filter(|l| *l > 0);
    // Fast reject on an advertised oversized body before streaming it.
    if let Some(len) = total {
        if len > cap {
            return Err(format!("image too large ({len} bytes > {cap} cap)"));
        }
    }
    // …then transfer the bytes: a distinct step from the history lookup. When the
    // body length is known this is a determinate bar; otherwise it stays an
    // indeterminate "downloading…" heartbeat (no number to report).
    let _ = tx.send(TurnEvent::Status(STATUS_DOWNLOADING.into())).await;
    // Stream-accumulate so a missing/lying Content-Length can't blow past the cap.
    let mut bytes = Vec::new();
    let mut stream = resp.bytes_stream();
    let mut last_pct: i64 = -1;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        if bytes.len() + chunk.len() > cap {
            return Err(format!("image exceeds {cap} byte cap"));
        }
        bytes.extend_from_slice(&chunk);
        if let Some(total) = total {
            let pct = (bytes.len() * 100 / total).min(100) as i64;
            if pct != last_pct {
                last_pct = pct;
                let _ = tx
                    .send(TurnEvent::Progress {
                        status: STATUS_DOWNLOADING.into(),
                        progress: pct as f64 / 100.0,
                    })
                    .await;
            }
        }
    }
    tracing::debug!(
        history_ms = history_ms as u64,
        download_ms = download_at.elapsed().as_millis() as u64,
        bytes = bytes.len(),
        "retrieved comfy image (history lookup → byte download)"
    );
    Ok((bytes, mime))
}

struct ImageRef {
    filename: String,
    subfolder: String,
    kind: String,
}

fn find_first_image(history: &Value, prompt_id: &str) -> Option<ImageRef> {
    let outputs = history.get(prompt_id)?.get("outputs")?.as_object()?;
    for node in outputs.values() {
        if let Some(images) = node.get("images").and_then(|i| i.as_array()) {
            if let Some(img) = images.first() {
                return Some(ImageRef {
                    filename: img.get("filename")?.as_str()?.to_string(),
                    subfolder: img
                        .get("subfolder")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    kind: img
                        .get("type")
                        .and_then(|v| v.as_str())
                        .unwrap_or("output")
                        .to_string(),
                });
            }
        }
    }
    None
}

/// The progress WebSocket URL: the configured base (any path prefix included)
/// with `/ws` appended, the scheme switched to ws/wss, and the client id as
/// the query. Rebuilding from host+port alone dropped a reverse-proxy path
/// prefix on the base URL.
fn ws_url(cfg: &Config, client_id: &str) -> Result<String, String> {
    let mut url = http_util::join_base(&cfg.comfy_base, "/ws");
    let scheme = if cfg.comfy_base.scheme() == "https" {
        "wss"
    } else {
        "ws"
    };
    url.set_scheme(scheme)
        .map_err(|_| format!("cannot derive a websocket URL from {}", cfg.comfy_base))?;
    url.set_query(Some(&format!("clientId={client_id}")));
    Ok(url.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_input_inserts_into_node() {
        let target = NodeInput::parse("6.text").unwrap();
        let mut wf = serde_json::json!({
            "6": { "class_type": "CLIPTextEncode", "inputs": { "text": "", "clip": ["4", 1] } }
        });
        set_input(&mut wf, &target, Value::String("a cat".into())).unwrap();
        assert_eq!(wf["6"]["inputs"]["text"], "a cat");
    }

    #[test]
    fn set_input_errors_on_missing_node() {
        let target = NodeInput::parse("99.text").unwrap();
        let mut wf = serde_json::json!({ "6": { "inputs": {} } });
        assert!(set_input(&mut wf, &target, Value::Null).is_err());
    }

    #[test]
    fn finds_image_in_history() {
        let hist = serde_json::json!({
            "pid": { "outputs": { "9": { "images": [
                {"filename": "out.png", "subfolder": "", "type": "output"}
            ]}}}
        });
        let img = find_first_image(&hist, "pid").unwrap();
        assert_eq!(img.filename, "out.png");
        assert_eq!(img.kind, "output");
    }

    #[test]
    fn collects_nested_file_refs() {
        let value = serde_json::json!({
            "images": [{"filename":"a.png","subfolder":"","type":"temp"}],
            "gifs": [{"filename":"b.mp4","subfolder":"v","type":"temp"}]
        });
        let mut refs = Vec::new();
        collect_file_refs(&value, &mut refs);
        assert_eq!(refs.len(), 2);
        let mut names: Vec<_> = refs.into_iter().map(|r| r.filename).collect();
        names.sort();
        assert_eq!(names, ["a.png", "b.mp4"]);
    }

    #[test]
    fn rewrites_configured_audio_saver_to_temporary_preview() {
        let mut workflow = serde_json::json!({
            "9": {
                "class_type": "SaveAudioAdvanced",
                "inputs": {
                    "audio": ["8", 0],
                    "filename_prefix": "audio/output",
                    "format": "mp3",
                    "quality": "V0"
                }
            }
        });
        assert_eq!(
            force_temporary_audio_outputs(&mut workflow, "9").unwrap(),
            ["9"]
        );
        assert_eq!(workflow["9"]["class_type"], "PreviewAudio");
        assert_eq!(
            workflow["9"]["inputs"],
            serde_json::json!({"audio":["8",0]})
        );
    }

    #[test]
    fn switches_vhs_video_output_to_temporary_delivery() {
        let mut workflow = serde_json::json!({
            "12": {
                "class_type": "VHS_VideoCombine",
                "inputs": {
                    "images": ["8", 0],
                    "format": "video/h264-mp4",
                    "save_output": true
                }
            }
        });
        assert_eq!(prepare_video_output(&mut workflow, "12").unwrap(), ["12"]);
        assert_eq!(workflow["12"]["inputs"]["save_output"], false);
    }

    #[test]
    fn accepts_generic_selected_video_output() {
        let mut workflow = serde_json::json!({
            "12": {"class_type":"CustomVideoSaver","inputs":{"video":["8",0]}}
        });
        assert_eq!(prepare_video_output(&mut workflow, "12").unwrap(), ["12"]);
    }

    #[test]
    fn temp_image_ref_marks_comfy_temp_folder() {
        assert_eq!(temp_image_ref("in.png", ""), "in.png [temp]");
        assert_eq!(temp_image_ref("in.png", "turns"), "turns/in.png [temp]");
    }

    #[test]
    fn force_temporary_outputs_rewrites_save_image() {
        let mut wf = serde_json::json!({
            "9": {
                "class_type": "SaveImage",
                "inputs": { "filename_prefix": "phantasm", "images": ["8", 0] }
            },
            "8": {
                "class_type": "VAEDecode",
                "inputs": { "samples": ["3", 0] }
            }
        });

        force_temporary_outputs(&mut wf);

        assert_eq!(wf["9"]["class_type"], "PreviewImage");
        assert_eq!(wf["9"]["inputs"]["images"], serde_json::json!(["8", 0]));
        assert!(wf["9"]["inputs"].get("filename_prefix").is_none());
        assert_eq!(wf["8"]["class_type"], "VAEDecode");
    }

    #[test]
    fn force_ws_outputs_rewrites_save_and_preview() {
        let mut wf = serde_json::json!({
            "9": { "class_type": "SaveImage", "inputs": { "filename_prefix": "phantasm", "images": ["8", 0] } },
            "10": { "class_type": "PreviewImage", "inputs": { "images": ["8", 0] } },
            "8": { "class_type": "VAEDecode", "inputs": { "samples": ["3", 0] } },
        });

        force_ws_outputs(&mut wf);

        assert_eq!(wf["9"]["class_type"], "SaveImageWebsocket");
        assert_eq!(wf["10"]["class_type"], "SaveImageWebsocket");
        // The image wiring survives; the now-irrelevant prefix is dropped.
        assert_eq!(wf["9"]["inputs"]["images"], serde_json::json!(["8", 0]));
        assert!(wf["9"]["inputs"].get("filename_prefix").is_none());
        // Non-output nodes are untouched.
        assert_eq!(wf["8"]["class_type"], "VAEDecode");
    }

    #[test]
    fn parse_ws_image_reads_header_and_payload() {
        let cap = 1 << 20;
        // event=1 (PREVIEW_IMAGE), format=2 (PNG), then the bytes.
        let mut png = vec![0, 0, 0, 1, 0, 0, 0, 2];
        png.extend_from_slice(b"\x89PNG-data");
        let (bytes, mime) = parse_ws_image(&png, cap).unwrap();
        assert_eq!(bytes, b"\x89PNG-data");
        assert_eq!(mime, "image/png");

        // format=1 → JPEG.
        let jpeg = [vec![0, 0, 0, 1, 0, 0, 0, 1], b"jpegbytes".to_vec()].concat();
        assert_eq!(parse_ws_image(&jpeg, cap).unwrap().1, "image/jpeg");
    }

    #[test]
    fn parse_ws_image_rejects_bad_frames() {
        let cap = 1 << 20;
        // Too short for the 8-byte header.
        assert!(parse_ws_image(&[0, 0, 0, 1], cap).is_none());
        // Header present but no payload.
        assert!(parse_ws_image(&[0, 0, 0, 1, 0, 0, 0, 2], cap).is_none());
        // Wrong event type (not PREVIEW_IMAGE).
        let other = [vec![0, 0, 0, 9, 0, 0, 0, 2], b"x".to_vec()].concat();
        assert!(parse_ws_image(&other, cap).is_none());
        // Payload exceeds the cap.
        let big = [vec![0, 0, 0, 1, 0, 0, 0, 2], b"abcd".to_vec()].concat();
        assert!(parse_ws_image(&big, 3).is_none());
    }

    #[tokio::test]
    async fn execution_success_marks_completion() {
        let (tx, _rx) = mpsc::channel(4);
        let mut last = -1;
        let msg = r#"{"type":"execution_success","data":{"prompt_id":"pid"}}"#;
        assert_eq!(
            handle_ws_message(msg, "pid", &mut last, &tx).await,
            Ok(Some(true))
        );
        // A success frame for a different prompt must not end our wait.
        let other = r#"{"type":"execution_success","data":{"prompt_id":"nope"}}"#;
        assert_eq!(
            handle_ws_message(other, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
    }

    #[tokio::test]
    async fn execution_error_returns_backend_cause() {
        let (tx, _rx) = mpsc::channel(4);
        let mut last = -1;
        let msg = r#"{"type":"execution_error","data":{
            "prompt_id":"pid",
            "node_id":"6",
            "node_type":"CLIPTextEncode",
            "exception_type":"RuntimeError",
            "exception_message":"VRAM grow failed: 263192576 bytes\n",
            "current_inputs":{"text":["do not include this prompt"]}
        }}"#;

        let err = handle_ws_message(msg, "pid", &mut last, &tx)
            .await
            .expect_err("same-prompt execution_error must fail");
        assert_eq!(
            err,
            "ComfyUI execution failed at node 6 (CLIPTextEncode): RuntimeError: VRAM grow failed: 263192576 bytes"
        );
        assert!(
            !err.contains("do not include"),
            "tool errors must not leak prompt/input content"
        );

        let other = msg.replace("\"prompt_id\":\"pid\"", "\"prompt_id\":\"other\"");
        assert_eq!(
            handle_ws_message(&other, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
    }

    #[tokio::test]
    async fn executing_emits_one_presampling_heartbeat() {
        let (tx, mut rx) = mpsc::channel(4);
        // -2 is the start sentinel: nothing seen yet.
        let mut last = -2;
        let frame = r#"{"type":"executing","data":{"node":"3","prompt_id":"pid"}}"#;

        // First non-null executing frame for our prompt → one heartbeat, not done.
        assert_eq!(
            handle_ws_message(frame, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
        assert!(matches!(rx.try_recv(), Ok(TurnEvent::Status(s)) if s == STATUS_LOADING_MODEL));

        // Subsequent executing frames stay quiet (heartbeat already advanced to -1).
        assert_eq!(
            handle_ws_message(frame, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn executing_after_sampling_emits_finishing_once() {
        let (tx, mut rx) = mpsc::channel(4);
        // Sampling already reported determinate progress (bar near 100%).
        let mut last = 100;
        let frame = r#"{"type":"executing","data":{"node":"9","prompt_id":"pid"}}"#;

        // A node still running after sampling (VAE decode/save) → "finishing up…".
        assert_eq!(
            handle_ws_message(frame, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
        assert!(matches!(rx.try_recv(), Ok(TurnEvent::Status(s)) if s == STATUS_FINISHING));

        // Further post-sampling nodes stay quiet (advanced to 101).
        assert_eq!(
            handle_ws_message(frame, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn trailing_full_progress_after_finishing_is_ignored() {
        let (tx, mut rx) = mpsc::channel(4);
        // Already in the finishing phase.
        let mut last = 101;

        // A trailing value==max frame must not bounce the pill back to "generating".
        let full = r#"{"type":"progress","data":{"value":20,"max":20}}"#;
        assert_eq!(
            handle_ws_message(full, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
        assert_eq!(last, 101); // unchanged
        assert!(rx.try_recv().is_err()); // no event emitted

        // But a genuinely new low-progress pass (hires fix) resumes the bar.
        let low = r#"{"type":"progress","data":{"value":2,"max":20}}"#;
        assert_eq!(
            handle_ws_message(low, "pid", &mut last, &tx).await,
            Ok(Some(false))
        );
        assert_eq!(last, 10);
        assert!(matches!(
            rx.try_recv(),
            Ok(TurnEvent::Progress { progress, .. }) if (progress - 0.10).abs() < 1e-9
        ));
    }

    #[tokio::test]
    async fn foreign_executing_frame_does_not_mark_our_prompt_started() {
        let (tx, _rx) = mpsc::channel(4);
        let mut last = -2;
        // Another turn's prompt starts executing: ours is still queued, so the
        // drop guard must NOT be allowed to fire the global /interrupt (that
        // would abort the other turn's generation).
        let other = r#"{"type":"executing","data":{"node":"3","prompt_id":"other"}}"#;
        let _ = handle_ws_message(other, "pid", &mut last, &tx).await;
        assert!(!execution_started(last));

        // Our own executing frame flips it: the interrupt is now about us.
        let ours = r#"{"type":"executing","data":{"node":"3","prompt_id":"pid"}}"#;
        let _ = handle_ws_message(ours, "pid", &mut last, &tx).await;
        assert!(execution_started(last));
    }

    #[tokio::test]
    async fn progress_frames_mark_execution_started() {
        let (tx, _rx) = mpsc::channel(8);
        let mut last = -2;
        assert!(!execution_started(last), "queued-only must not interrupt");
        let progress = r#"{"type":"progress","data":{"value":1,"max":20}}"#;
        let _ = handle_ws_message(progress, "pid", &mut last, &tx).await;
        assert!(execution_started(last));
    }

    #[tokio::test]
    async fn executing_null_node_marks_completion() {
        let (tx, _rx) = mpsc::channel(4);
        let mut last = -2;
        let done = r#"{"type":"executing","data":{"node":null,"prompt_id":"pid"}}"#;
        assert_eq!(
            handle_ws_message(done, "pid", &mut last, &tx).await,
            Ok(Some(true))
        );
    }

    #[test]
    fn ws_url_uses_ws_scheme_and_port() {
        let cfg = crate::config::tests_support::minimal();
        let url = ws_url(&cfg, "abc").unwrap();
        assert_eq!(url, "ws://localhost:8188/ws?clientId=abc");
    }

    #[test]
    fn ws_url_preserves_base_path_prefix() {
        let mut cfg = crate::config::tests_support::minimal();
        cfg.comfy_base = "https://gpu.example/comfy".parse().unwrap();
        let url = ws_url(&cfg, "abc").unwrap();
        assert_eq!(url, "wss://gpu.example/comfy/ws?clientId=abc");
    }
}
