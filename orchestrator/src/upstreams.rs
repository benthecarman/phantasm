//! The set of configured upstream model hosts and per-model routing.
//!
//! A deployment may run several backends at once — e.g. Ollama for a rotating
//! cast of small models plus vLLM pinned to one big model. Each configured
//! upstream ([`crate::config::UpstreamSpec`]) becomes one [`UpstreamEntry`]
//! here: its detected backend client, its own concurrency semaphore (separate
//! hosts are separate GPUs, so NFR-O2's bound is per-upstream), and the model
//! list used for routing.
//!
//! Routing is by model id: a request's (base) model is matched against each
//! entry's models in configuration order — the default upstream first, then
//! the `UPSTREAMS` extras — and the first upstream serving it wins. A model
//! nobody claims falls back to the default upstream, which preserves the
//! single-upstream behavior exactly and keeps a misconfigured model id
//! producing a normal upstream error rather than a routing error.
//!
//! Model lists come from config pins (`UPSTREAM_<NAME>_MODELS`) or from
//! startup probing, and probed lists are refreshed whenever the capabilities
//! snapshot re-probes (see [`crate::probe_capabilities`]) — so a freshly
//! `ollama pull`ed model starts routing correctly without a restart.

use std::sync::{Arc, RwLock};

use tokio::sync::Semaphore;
use url::Url;

use crate::ollama::{UpstreamChatBackend, UpstreamKind};

/// One configured upstream: its detected backend, routing model list, and
/// concurrency bound.
pub struct UpstreamEntry {
    pub name: String,
    pub kind: UpstreamKind,
    pub base: Url,
    pub backend: UpstreamChatBackend,
    /// Bounds simultaneous in-flight generations on THIS upstream (NFR-O2).
    pub sem: Arc<Semaphore>,
    pub max_concurrency: usize,
    /// Optional per-model reasoning effort values advertised for models served
    /// by this upstream. Empty means unknown/not advertised.
    pub reasoning_efforts: Vec<String>,
    /// Config-pinned models; non-empty => authoritative, never re-probed.
    pinned_models: Vec<String>,
    /// Last probed model list (startup detection, then capability refreshes).
    probed_models: RwLock<Vec<String>>,
}

pub struct UpstreamEntryInit {
    pub name: String,
    pub kind: UpstreamKind,
    pub base: Url,
    pub backend: UpstreamChatBackend,
    pub max_concurrency: usize,
    pub reasoning_efforts: Vec<String>,
    pub pinned_models: Vec<String>,
    pub probed_models: Vec<String>,
}

impl UpstreamEntry {
    pub fn new(init: UpstreamEntryInit) -> Self {
        UpstreamEntry {
            name: init.name,
            kind: init.kind,
            base: init.base,
            backend: init.backend,
            sem: Arc::new(Semaphore::new(init.max_concurrency)),
            max_concurrency: init.max_concurrency,
            reasoning_efforts: init.reasoning_efforts,
            pinned_models: init.pinned_models,
            probed_models: RwLock::new(init.probed_models),
        }
    }

    /// The models this upstream serves: the config pin when set, else the last
    /// probed list.
    pub fn models(&self) -> Vec<String> {
        if !self.pinned_models.is_empty() {
            return self.pinned_models.clone();
        }
        self.probed_models.read().expect("poisoned").clone()
    }

    /// Whether the model list is config-pinned (and probing should be skipped).
    pub fn pinned(&self) -> bool {
        !self.pinned_models.is_empty()
    }

    /// Record a fresh probe result. Ignored for pinned entries.
    pub fn set_probed_models(&self, models: Vec<String>) {
        if self.pinned() {
            return;
        }
        *self.probed_models.write().expect("poisoned") = models;
    }

    fn serves(&self, model: &str) -> bool {
        if !self.pinned_models.is_empty() {
            return self.pinned_models.iter().any(|m| m == model);
        }
        self.probed_models
            .read()
            .expect("poisoned")
            .iter()
            .any(|m| m == model)
    }
}

/// All configured upstreams in routing-priority order (default first).
/// Never empty.
pub struct UpstreamSet {
    entries: Vec<UpstreamEntry>,
}

impl UpstreamSet {
    pub fn new(entries: Vec<UpstreamEntry>) -> Self {
        assert!(!entries.is_empty(), "UpstreamSet requires >= 1 upstream");
        UpstreamSet { entries }
    }

    pub fn entries(&self) -> &[UpstreamEntry] {
        &self.entries
    }

    /// The default upstream (the flat `UPSTREAM_*` config) — the fallback for
    /// models no upstream claims.
    pub fn primary(&self) -> &UpstreamEntry {
        &self.entries[0]
    }

    /// Pick the upstream serving `model` (the resolved BASE model — research
    /// mode suffixes are stripped before routing). First claimant in config
    /// order wins; unclaimed models fall back to the default upstream.
    pub fn route(&self, model: &str) -> &UpstreamEntry {
        self.entries
            .iter()
            .find(|e| e.serves(model))
            .unwrap_or(self.primary())
    }

    /// For each entry (same order as [`Self::entries`]), the models it
    /// actually serves after first-claimant-wins dedup — the same precedence
    /// as [`Self::route`], so the advertised union built from this is exactly
    /// what routes. Duplicate ids within one entry's list collapse too.
    pub fn claimed_models(&self) -> Vec<Vec<String>> {
        let mut seen = std::collections::HashSet::new();
        self.entries
            .iter()
            .map(|entry| {
                entry
                    .models()
                    .into_iter()
                    .filter(|id| seen.insert(id.clone()))
                    .collect()
            })
            .collect()
    }

    /// First upstream of the given kind, e.g. the native Ollama instance the
    /// dashboard's VRAM panel should ask about.
    pub fn first_of_kind(&self, kind: UpstreamKind) -> Option<&UpstreamEntry> {
        self.entries.iter().find(|e| e.kind == kind)
    }

    /// Attach the metrics registry to every backend (called once at startup,
    /// before the set is shared).
    pub fn attach_metrics(&mut self, metrics: Arc<crate::metrics::Metrics>) {
        for entry in &mut self.entries {
            entry.backend.attach_metrics(metrics.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ollama::OllamaClient;

    fn entry(name: &str, pinned: &[&str], probed: &[&str]) -> UpstreamEntry {
        let base: Url = "http://localhost:11434".parse().unwrap();
        let backend = UpstreamChatBackend::NativeOllama(OllamaClient::new(
            reqwest::Client::new(),
            base.clone(),
        ));
        UpstreamEntry::new(UpstreamEntryInit {
            name: name.into(),
            kind: UpstreamKind::NativeOllama,
            base,
            backend,
            max_concurrency: 4,
            reasoning_efforts: vec![],
            pinned_models: pinned.iter().map(|s| s.to_string()).collect(),
            probed_models: probed.iter().map(|s| s.to_string()).collect(),
        })
    }

    #[test]
    fn routes_by_model_with_config_order_priority() {
        let set = UpstreamSet::new(vec![
            entry("default", &[], &["small", "shared"]),
            entry("vllm", &["big", "shared"], &[]),
        ]);
        assert_eq!(set.route("small").name, "default");
        assert_eq!(set.route("big").name, "vllm");
        // Both claim "shared": the earlier (default) upstream wins.
        assert_eq!(set.route("shared").name, "default");
        // Unclaimed models fall back to the default upstream.
        assert_eq!(set.route("unknown").name, "default");
    }

    #[test]
    fn claimed_models_match_routing() {
        let set = UpstreamSet::new(vec![
            entry("default", &[], &["small", "shared", "small"]),
            entry("vllm", &["big", "shared"], &[]),
        ]);
        // First claimant wins, intra-entry duplicates collapse.
        assert_eq!(set.claimed_models(), [vec!["small", "shared"], vec!["big"]]);
        // The invariant probe_capabilities relies on: every claimed id routes
        // back to the entry that claims it.
        for (entry, ids) in set.entries().iter().zip(set.claimed_models()) {
            for id in ids {
                assert!(std::ptr::eq(set.route(&id), entry), "{id} routes elsewhere");
            }
        }
    }

    #[test]
    fn pinned_models_ignore_probe_updates() {
        let set = UpstreamSet::new(vec![
            entry("default", &[], &[]),
            entry("vllm", &["big"], &[]),
        ]);
        set.entries()[1].set_probed_models(vec!["other".into()]);
        assert_eq!(set.entries()[1].models(), ["big"]);
        assert_eq!(set.route("other").name, "default");

        // An unpinned entry's probe refresh does change routing.
        set.entries()[0].set_probed_models(vec!["fresh".into()]);
        assert_eq!(set.route("fresh").name, "default");
        assert_eq!(set.entries()[0].models(), ["fresh"]);
    }
}
