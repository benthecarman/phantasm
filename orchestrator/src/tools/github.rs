//! Read-only GitHub REST API tool. No cloning and no filesystem access.

use base64::Engine;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use url::Url;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;
use crate::tools::http_util;

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum GitHubOperation {
    SearchRepositories,
    SearchCode,
    GetFile,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GitHubArgs {
    pub operation: GitHubOperation,
    /// Search query for search_repositories or search_code.
    #[serde(default)]
    pub query: Option<String>,
    /// Repository owner for get_file.
    #[serde(default)]
    pub owner: Option<String>,
    /// Repository name for get_file.
    #[serde(default)]
    pub repo: Option<String>,
    /// File path inside the repository for get_file.
    #[serde(default)]
    pub path: Option<String>,
    /// Maximum search results, 1-10. Defaults to 5.
    #[serde(default)]
    pub limit: Option<u8>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(GitHubArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "github",
        "Read GitHub via the REST API: search repositories, search code, or fetch one repository file. No cloning or writes.",
        params,
    )
}

pub async fn run(
    cfg: &Config,
    http: &reqwest::Client,
    call: &ToolCall,
    call_id: &str,
    tx: &mpsc::Sender<TurnEvent>,
    cancel: &CancellationToken,
) -> ToolOutcome {
    let args: GitHubArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let _ = tx.send(TurnEvent::Status("checking GitHub…".into())).await;

    let result = tokio::select! {
        r = github(cfg, http, &args) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "github", text),
            append_to_answer: None,
        },
        Err(e) => {
            tracing::warn!(error = %e, "github failed");
            error_outcome(call_id, e)
        }
    }
}

async fn github(cfg: &Config, http: &reqwest::Client, args: &GitHubArgs) -> Result<String, String> {
    match args.operation {
        GitHubOperation::SearchRepositories => search_repositories(cfg, http, args).await,
        GitHubOperation::SearchCode => search_code(cfg, http, args).await,
        GitHubOperation::GetFile => get_file(cfg, http, args).await,
    }
}

async fn search_repositories(
    cfg: &Config,
    http: &reqwest::Client,
    args: &GitHubArgs,
) -> Result<String, String> {
    let query = required(&args.query, "query")?;
    let limit = args.limit.unwrap_or(5).clamp(1, 10).to_string();
    let url = cfg
        .github_base
        .join("/search/repositories")
        .map_err(|e| e.to_string())?;
    let resp: RepoSearchResponse = http_util::get_json(
        github_get(cfg, http, url).query(&[("q", query), ("per_page", &limit)]),
    )
    .await?;
    Ok(format_repo_results(query, &resp.items))
}

async fn search_code(
    cfg: &Config,
    http: &reqwest::Client,
    args: &GitHubArgs,
) -> Result<String, String> {
    let query = required(&args.query, "query")?;
    let limit = args.limit.unwrap_or(5).clamp(1, 10).to_string();
    let url = cfg
        .github_base
        .join("/search/code")
        .map_err(|e| e.to_string())?;
    let resp: CodeSearchResponse = http_util::get_json(
        github_get(cfg, http, url).query(&[("q", query), ("per_page", &limit)]),
    )
    .await?;
    Ok(format_code_results(query, &resp.items))
}

async fn get_file(
    cfg: &Config,
    http: &reqwest::Client,
    args: &GitHubArgs,
) -> Result<String, String> {
    let owner = required(&args.owner, "owner")?;
    let repo = required(&args.repo, "repo")?;
    let path = required(&args.path, "path")?;
    let url = repo_content_url(&cfg.github_base, owner, repo, path)?;
    let file: ContentResponse = http_util::get_json(github_get(cfg, http, url)).await?;
    if file.kind.as_deref() != Some("file") {
        return Err("requested path is not a file".into());
    }
    if file.size.unwrap_or(0) as usize > cfg.github_context_chars.saturating_mul(4) {
        return Err("file is too large for this tool".into());
    }
    let content = file.content.ok_or("file response has no content")?;
    let cleaned = content.lines().collect::<String>();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(cleaned.as_bytes())
        .map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(&bytes);
    let truncated: String = text.chars().take(cfg.github_context_chars).collect();
    Ok(format!(
        "GitHub file:\nrepo: {owner}/{repo}\npath: {path}\nurl: {}\n\n{truncated}",
        file.html_url.unwrap_or_default()
    ))
}

fn github_get(cfg: &Config, http: &reqwest::Client, url: Url) -> reqwest::RequestBuilder {
    let mut req = http
        .get(url)
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .header("X-GitHub-Api-Version", "2022-11-28");
    if let Some(token) = &cfg.github_token {
        req = req.bearer_auth(token);
    }
    req
}

fn repo_content_url(base: &Url, owner: &str, repo: &str, path: &str) -> Result<Url, String> {
    let mut url = base.join("/").map_err(|e| e.to_string())?;
    {
        let mut segments = url
            .path_segments_mut()
            .map_err(|_| "GitHub base URL cannot be a base".to_string())?;
        segments
            .push("repos")
            .push(owner)
            .push(repo)
            .push("contents");
        for part in path.split('/').filter(|p| !p.is_empty()) {
            segments.push(part);
        }
    }
    Ok(url)
}

fn required<'a>(value: &'a Option<String>, name: &str) -> Result<&'a str, String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("missing required `{name}`"))
}

fn format_repo_results(query: &str, repos: &[RepoItem]) -> String {
    let mut out = format!("GitHub repository search results for \"{query}\":");
    if repos.is_empty() {
        out.push_str("\n(no results)");
        return out;
    }
    for (i, repo) in repos.iter().enumerate() {
        out.push_str(&format!(
            "\n{}. {} — {} stars — {}",
            i + 1,
            repo.full_name,
            repo.stargazers_count.unwrap_or_default(),
            repo.html_url
        ));
        if let Some(desc) = repo.description.as_deref().filter(|s| !s.is_empty()) {
            out.push_str(&format!("\n   {desc}"));
        }
    }
    out
}

fn format_code_results(query: &str, items: &[CodeItem]) -> String {
    let mut out = format!("GitHub code search results for \"{query}\":");
    if items.is_empty() {
        out.push_str("\n(no results)");
        return out;
    }
    for (i, item) in items.iter().enumerate() {
        out.push_str(&format!(
            "\n{}. {}/{} — {}",
            i + 1,
            item.repository.full_name,
            item.path,
            item.html_url
        ));
    }
    out
}

#[derive(Debug, Deserialize)]
struct RepoSearchResponse {
    #[serde(default)]
    items: Vec<RepoItem>,
}

#[derive(Debug, Deserialize)]
struct RepoItem {
    full_name: String,
    html_url: String,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    stargazers_count: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct CodeSearchResponse {
    #[serde(default)]
    items: Vec<CodeItem>,
}

#[derive(Debug, Deserialize)]
struct CodeItem {
    path: String,
    html_url: String,
    repository: CodeRepo,
}

#[derive(Debug, Deserialize)]
struct CodeRepo {
    full_name: String,
}

#[derive(Debug, Deserialize)]
struct ContentResponse {
    #[serde(default, rename = "type")]
    kind: Option<String>,
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    html_url: Option<String>,
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(call_id, "github", format!("github failed: {detail}")),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_content_url_with_encoded_segments() {
        let base = Url::parse("https://api.github.com").unwrap();
        let url = repo_content_url(&base, "openai", "codex", "a path/file.rs").unwrap();
        assert_eq!(
            url.as_str(),
            "https://api.github.com/repos/openai/codex/contents/a%20path/file.rs"
        );
    }
}
