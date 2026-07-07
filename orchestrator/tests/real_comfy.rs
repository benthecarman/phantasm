//! Opt-in end-to-end smoke tests against a real ComfyUI instance.
//!
//! These tests are ignored by default because they submit real image jobs to the
//! configured ComfyUI backend. They deliberately bypass upstream chat models and
//! call the image tool directly so failures isolate to workflow injection,
//! ComfyUI websocket/progress handling, and image delivery.

use std::sync::{Arc, Mutex};

use base64::Engine;
use image::ImageEncoder;
use phantasm_orchestrator::config::Config;
use phantasm_orchestrator::openai::types::{FunctionCall, MessageContent, RawArguments, ToolCall};
use phantasm_orchestrator::orchestrator::tools::TurnContext;
use phantasm_orchestrator::orchestrator::TurnEvent;
use phantasm_orchestrator::tools::{image_edit, image_gen};
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

fn env_u64(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

fn tool_message_text(content: Option<MessageContent>) -> String {
    match content {
        Some(MessageContent::Text(text)) => text,
        Some(MessageContent::Parts(parts)) => serde_json::to_string(&parts).unwrap_or_default(),
        None => String::new(),
    }
}

fn solid_png_b64(width: u32, height: u32) -> String {
    let img = image::RgbaImage::from_pixel(width, height, image::Rgba([210, 30, 30, 255]));
    let mut bytes = Vec::new();
    image::codecs::png::PngEncoder::new(&mut bytes)
        .write_image(img.as_raw(), width, height, image::ExtendedColorType::Rgba8)
        .expect("encode test PNG");
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

#[tokio::test]
#[ignore = "requires a real ComfyUI instance and configured generation workflow"]
async fn real_comfy_image_generation_e2e() {
    let cfg = Config::from_env().expect("load ComfyUI test config from environment");
    assert!(
        cfg.image_gen_usable(),
        "image generation must be enabled with COMFYUI_GEN_WORKFLOW and COMFYUI_GEN_PROMPT"
    );

    let http = phantasm_orchestrator::build_http_client().expect("build HTTP client");
    let prompt = std::env::var("COMFY_E2E_PROMPT")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "a small red square, simple integration test image".into());
    let width = env_u64("COMFY_E2E_WIDTH", 512);
    let height = env_u64("COMFY_E2E_HEIGHT", 512);
    let seed = env_u64("COMFY_E2E_SEED", 12345);

    let args = json!({
        "prompt": prompt,
        "width": width,
        "height": height,
        "seed": seed
    });
    let call = ToolCall {
        id: Some("call_real_comfy_e2e".into()),
        kind: "function".into(),
        function: FunctionCall {
            name: "image_generation".into(),
            arguments: RawArguments::Obj(args),
        },
    };

    let (tx, mut rx) = mpsc::channel(256);
    let events = Arc::new(Mutex::new(Vec::new()));
    let event_sink = Arc::clone(&events);
    let drain = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            event_sink.lock().expect("events lock").push(event);
        }
    });

    let outcome = image_gen::run(
        &cfg,
        &http,
        &call,
        "call_real_comfy_e2e",
        &TurnContext::default(),
        &tx,
        &CancellationToken::new(),
    )
    .await;
    drop(tx);
    drain.await.expect("event drain task");

    let tool_text = tool_message_text(outcome.message.content);
    assert!(
        !outcome.is_error,
        "image_generation tool failed: {tool_text}"
    );

    let markdown = outcome
        .append_to_answer
        .expect("image_generation should append rendered markdown");
    assert!(
        markdown.starts_with("![generated](data:image/"),
        "expected inline image markdown, got prefix: {}",
        markdown.chars().take(80).collect::<String>()
    );

    let events = events.lock().expect("events lock");
    assert!(
        events
            .iter()
            .any(|event| matches!(event, TurnEvent::Status(_))),
        "expected at least one status event, got {events:?}"
    );

    let data_uri = markdown
        .strip_prefix("![generated](data:")
        .and_then(|s| s.strip_suffix(')'))
        .expect("markdown should contain a data URI");
    let (mime, b64) = data_uri
        .split_once(";base64,")
        .expect("data URI should be base64 encoded");
    assert!(
        matches!(
            mime,
            "image/png" | "image/jpeg" | "image/webp" | "image/gif"
        ),
        "unexpected image MIME type: {mime}"
    );
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .expect("image payload should be base64");
    assert!(!bytes.is_empty(), "generated image payload was empty");

    let json_summary: Value = json!({
        "mime": mime,
        "bytes": bytes.len(),
        "events": events.len()
    });
    eprintln!("real ComfyUI image generation passed: {json_summary}");
}

#[tokio::test]
#[ignore = "requires a real ComfyUI instance and configured edit workflow"]
async fn real_comfy_image_edit_e2e() {
    let cfg = Config::from_env().expect("load ComfyUI test config from environment");
    assert!(
        cfg.image_edit_usable(),
        "image editing must be enabled with COMFYUI_EDIT_WORKFLOW, COMFYUI_EDIT_PROMPT, and COMFYUI_EDIT_IMAGE"
    );

    let http = phantasm_orchestrator::build_http_client().expect("build HTTP client");
    let prompt = std::env::var("COMFY_E2E_EDIT_PROMPT")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "make the square blue while keeping the same simple composition".into());
    let seed = env_u64("COMFY_E2E_EDIT_SEED", 12345);

    let call = ToolCall {
        id: Some("call_real_comfy_edit_e2e".into()),
        kind: "function".into(),
        function: FunctionCall {
            name: "image_edit".into(),
            arguments: RawArguments::Obj(json!({
                "prompt": prompt,
                "seed": seed
            })),
        },
    };

    let (tx, mut rx) = mpsc::channel(256);
    let events = Arc::new(Mutex::new(Vec::new()));
    let event_sink = Arc::clone(&events);
    let drain = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            event_sink.lock().expect("events lock").push(event);
        }
    });

    let ctx = TurnContext {
        input_images: vec![solid_png_b64(512, 512)],
        ..Default::default()
    };
    let outcome = image_edit::run(
        &cfg,
        &http,
        &call,
        "call_real_comfy_edit_e2e",
        &ctx,
        &tx,
        &CancellationToken::new(),
    )
    .await;
    drop(tx);
    drain.await.expect("event drain task");

    let tool_text = tool_message_text(outcome.message.content);
    assert!(!outcome.is_error, "image_edit tool failed: {tool_text}");

    let markdown = outcome
        .append_to_answer
        .expect("image_edit should append rendered markdown");
    assert!(
        markdown.starts_with("![edited](data:image/"),
        "expected inline edited image markdown, got prefix: {}",
        markdown.chars().take(80).collect::<String>()
    );

    let events = events.lock().expect("events lock");
    assert!(
        events
            .iter()
            .any(|event| matches!(event, TurnEvent::Status(_))),
        "expected at least one status event, got {events:?}"
    );

    let data_uri = markdown
        .strip_prefix("![edited](data:")
        .and_then(|s| s.strip_suffix(')'))
        .expect("markdown should contain a data URI");
    let (mime, b64) = data_uri
        .split_once(";base64,")
        .expect("data URI should be base64 encoded");
    assert!(
        matches!(
            mime,
            "image/png" | "image/jpeg" | "image/webp" | "image/gif"
        ),
        "unexpected image MIME type: {mime}"
    );
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64)
        .expect("image payload should be base64");
    assert!(!bytes.is_empty(), "edited image payload was empty");

    let json_summary: Value = json!({
        "mime": mime,
        "bytes": bytes.len(),
        "events": events.len()
    });
    eprintln!("real ComfyUI image edit passed: {json_summary}");
}
