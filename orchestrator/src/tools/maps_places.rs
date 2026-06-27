//! Place search backed by Nominatim (geocoding) + Overpass (POI search).
//! Read-only and stateless.
//!
//! Two modes, chosen by whether `near` is provided:
//! - **With `near`** (the common "restaurants near X" case): geocode the
//!   location with Nominatim to a point, then ask Overpass for POIs of the
//!   requested category within `radius_m`, ordered by distance. Nominatim alone
//!   is a geocoder, not a POI engine — free text like "good restaurant near 200
//!   Congress Ave Austin TX" returns nothing, so category-near-location queries
//!   must go through Overpass.
//! - **Without `near`**: a plain Nominatim search, i.e. locate a named
//!   place/address ("Eiffel Tower", "200 Congress Ave Austin").

use std::collections::HashMap;

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::{ChatMessage, ToolCall};
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct MapsPlacesArgs {
    /// What to look for. For a nearby search pass a plain category or term such
    /// as "restaurant", "coffee", "pizza", "pharmacy", "hardware store" — do
    /// NOT include adjectives ("good", "best", "cheap") or the location here.
    /// Without `near`, this is treated as a place/address to locate, e.g.
    /// "Eiffel Tower" or "200 Congress Ave Austin".
    pub query: String,
    /// Location to search around, e.g. "downtown Austin" or "200 Congress Ave,
    /// Austin TX". When set, results are POIs near this location ordered by
    /// distance. Omit to just geocode `query` itself. Must be a real place name
    /// or address — for "near me"/"nearby" requests, get the user's location with
    /// get_current_location first and pass its city/place here, never "me".
    #[serde(default)]
    pub near: Option<String>,
    /// Optional cuisine to narrow a food search to, e.g. "thai", "pizza",
    /// "sushi", "mexican". Use this for "thai near me"-style queries: set
    /// `query` to "restaurant" and `cuisine` to "thai". Only applies to nearby
    /// (`near`) searches.
    #[serde(default)]
    pub cuisine: Option<String>,
    /// Search radius in meters around `near`. Defaults to 1500, max 25000.
    #[serde(default)]
    pub radius_m: Option<u32>,
    /// Maximum results to return, 1-10. Defaults to 5.
    #[serde(default)]
    pub limit: Option<u8>,
    /// Optional ISO country code to bias geocoding, e.g. "us".
    #[serde(default)]
    pub country_code: Option<String>,
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(MapsPlacesArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "maps_places",
        "Find places and points of interest. To search for businesses near a location \
         (e.g. \"restaurants near downtown Austin\"), put a plain category in `query` \
         (\"restaurant\", \"coffee\", \"pharmacy\") and the location in `near`; results come \
         back ordered by distance. To find food of a specific cuisine (\"thai near me\"), \
         set `query` to \"restaurant\" and `cuisine` to the cuisine (\"thai\"). To locate a \
         single named place or address, set just `query`. When the user refers to where \
         they are (\"near me\", \"nearby\", \"around here\") and you don't already know their \
         location, call get_current_location first, then pass the city or place it returns \
         as `near` — do not pass \"me\" or \"here\" as `near`. Returns names, categories, \
         addresses, distances, and coordinates.",
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
    let args: MapsPlacesArgs = match call.function.arguments.parse() {
        Ok(a) => a,
        Err(e) => return error_outcome(call_id, format!("invalid arguments: {e}")),
    };
    let status = if args.near_location().is_some() {
        "searching nearby places…"
    } else {
        "searching places…"
    };
    let _ = tx.send(TurnEvent::Status(status.into())).await;

    let result = tokio::select! {
        r = search(cfg, http, &args) => r,
        _ = cancel.cancelled() => return error_outcome(call_id, "cancelled".into()),
    };

    match result {
        Ok(text) => ToolOutcome {
            message: ChatMessage::tool_result(call_id, "maps_places", text),
            append_to_answer: None,
        },
        Err(e) => {
            tracing::warn!(error = %e, "maps_places failed");
            error_outcome(call_id, e)
        }
    }
}

impl MapsPlacesArgs {
    /// The `near` location, trimmed, or `None` if absent/blank.
    fn near_location(&self) -> Option<&str> {
        self.near
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
    }

    fn country(&self) -> Option<&str> {
        self.country_code
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
    }

    fn cuisine_filter(&self) -> Option<&str> {
        self.cuisine
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
    }
}

async fn search(
    cfg: &Config,
    http: &reqwest::Client,
    args: &MapsPlacesArgs,
) -> Result<String, String> {
    let query = args.query.trim();
    if query.is_empty() {
        return Err("query is empty".into());
    }
    match args.near_location() {
        Some(near) => search_nearby(cfg, http, args, query, near).await,
        None => {
            let limit = args.limit.unwrap_or(5).clamp(1, 10);
            let places = nominatim_search(cfg, http, query, args.country(), limit).await?;
            Ok(format_places(query, &places))
        }
    }
}

// ---- Nearby (geocode + Overpass) -------------------------------------------

async fn search_nearby(
    cfg: &Config,
    http: &reqwest::Client,
    args: &MapsPlacesArgs,
    term: &str,
    near: &str,
) -> Result<String, String> {
    // 1. Geocode the location to a single point.
    let hits = nominatim_search(cfg, http, near, args.country(), 1).await?;
    let Some(center) = hits.first() else {
        return Ok(format!("Couldn't find a location matching \"{near}\"."));
    };
    let (lat, lon) = match (center.lat.parse::<f64>(), center.lon.parse::<f64>()) {
        (Ok(lat), Ok(lon)) => (lat, lon),
        _ => return Err(format!("location \"{near}\" had no usable coordinates")),
    };

    // 2. Ask Overpass for POIs of the category within the radius.
    let radius = args.radius_m.unwrap_or(1500).clamp(100, 25_000);
    let limit = args.limit.unwrap_or(5).clamp(1, 10) as usize;
    let oq = build_overpass_query(term, args.cuisine_filter(), lat, lon, radius);
    let elements = overpass(cfg, http, &oq).await?;

    Ok(format_nearby(
        term,
        &center.display_name,
        &elements,
        lat,
        lon,
        radius,
        limit,
    ))
}

/// Build an OverpassQL union. Maps common category words to OSM tags, and always
/// also matches the raw term against `name`/`cuisine` (and, for unmapped terms,
/// `amenity`/`shop`/`leisure`/`tourism`) so specific cuisines and business names
/// still surface. When `cuisine` is given, the search is narrowed to food venues
/// of that cuisine instead.
fn build_overpass_query(
    term: &str,
    cuisine: Option<&str>,
    lat: f64,
    lon: f64,
    radius_m: u32,
) -> String {
    let around = format!("around:{radius_m},{lat},{lon}");
    let mut clauses: Vec<String> = Vec::new();

    if let Some(cuisine) = cuisine {
        // Cuisine search: anything tagged with the cuisine (subsumes the
        // category — cuisine tags are food-specific), plus food venues whose
        // name matches the cuisine but that lack a cuisine tag (e.g. "Thai
        // Spice"), without pulling in non-food matches like "Thai Massage".
        let cre = escape_overpass_regex(cuisine);
        clauses.push(format!("nwr({around})[\"cuisine\"~\"{cre}\",i];"));
        clauses.push(format!(
            "nwr({around})[\"amenity\"~\"^(restaurant|fast_food|cafe|bar|pub)$\"][\"name\"~\"{cre}\",i];"
        ));
        return format!(
            "[out:json][timeout:25];({});out center tags 80;",
            clauses.join("")
        );
    }

    let re = escape_overpass_regex(term.trim());
    let mapped = category_tags(term);
    for filt in &mapped {
        clauses.push(format!("nwr({around}){filt};"));
    }
    if mapped.is_empty() {
        for key in ["amenity", "shop", "leisure", "tourism"] {
            clauses.push(format!("nwr({around})[\"{key}\"~\"{re}\",i];"));
        }
    }
    clauses.push(format!("nwr({around})[\"cuisine\"~\"{re}\",i];"));
    clauses.push(format!("nwr({around})[\"name\"~\"{re}\",i];"));

    format!(
        "[out:json][timeout:25];({});out center tags 80;",
        clauses.join("")
    )
}

/// Map a free-text category to concrete OSM tag filters. Empty => unmapped (the
/// caller falls back to generic regex matching on the term).
fn category_tags(term: &str) -> Vec<&'static str> {
    let t = term.to_lowercase();
    let has = |kw: &str| t.contains(kw);
    if has("restaurant") || has("food") || has("dinner") || has("lunch") || has("eat") {
        vec![
            "[\"amenity\"=\"restaurant\"]",
            "[\"amenity\"=\"fast_food\"]",
        ]
    } else if has("coffee") || has("cafe") || has("café") || has("espresso") {
        vec!["[\"amenity\"=\"cafe\"]"]
    } else if has("bar") || has("pub") || has("brewery") || has("drink") {
        vec!["[\"amenity\"=\"bar\"]", "[\"amenity\"=\"pub\"]"]
    } else if has("hotel") || has("motel") || has("lodging") || has("hostel") {
        vec![
            "[\"tourism\"=\"hotel\"]",
            "[\"tourism\"=\"motel\"]",
            "[\"tourism\"=\"hostel\"]",
        ]
    } else if has("gas") || has("fuel") || has("petrol") {
        vec!["[\"amenity\"=\"fuel\"]"]
    } else if has("pharmacy") || has("drugstore") || has("chemist") {
        vec!["[\"amenity\"=\"pharmacy\"]"]
    } else if has("hospital") || has("emergency room") {
        vec!["[\"amenity\"=\"hospital\"]"]
    } else if has("grocery") || has("supermarket") {
        vec!["[\"shop\"=\"supermarket\"]"]
    } else if has("bank") {
        vec!["[\"amenity\"=\"bank\"]"]
    } else if has("atm") {
        vec!["[\"amenity\"=\"atm\"]"]
    } else if has("parking") {
        vec!["[\"amenity\"=\"parking\"]"]
    } else if has("park") {
        vec!["[\"leisure\"=\"park\"]"]
    } else if has("gym") || has("fitness") {
        vec!["[\"leisure\"=\"fitness_centre\"]"]
    } else {
        vec![]
    }
}

async fn overpass(
    cfg: &Config,
    http: &reqwest::Client,
    query: &str,
) -> Result<Vec<OverpassElement>, String> {
    let url = cfg
        .overpass_base
        .join("/api/interpreter")
        .map_err(|e| e.to_string())?;
    let resp: OverpassResponse = http
        .post(url)
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
        .form(&[("data", query)])
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())?;
    Ok(resp.elements)
}

fn format_nearby(
    term: &str,
    center_name: &str,
    elements: &[OverpassElement],
    lat: f64,
    lon: f64,
    radius_m: u32,
    limit: usize,
) -> String {
    // Resolve each element to a coordinate, compute distance, drop the
    // coordinate-less ones, then dedup node/way duplicates that share a name and
    // an (approximate) location.
    let mut ranked: Vec<(f64, &OverpassElement)> = elements
        .iter()
        .filter_map(|e| {
            e.coord()
                .map(|(elat, elon)| (haversine_m(lat, lon, elat, elon), e))
        })
        .collect();
    ranked.sort_by(|a, b| a.0.total_cmp(&b.0));

    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut out = format!("Places matching \"{term}\" near {center_name} (within {radius_m} m):");
    let mut shown = 0usize;
    for (dist, e) in &ranked {
        let name = e.name().unwrap_or("(unnamed)");
        let (elat, elon) = e.coord().unwrap();
        let dedup_key = format!("{}@{:.4},{:.4}", name.to_lowercase(), elat, elon);
        if !seen.insert(dedup_key) {
            continue;
        }
        out.push_str(&format!(
            "\n{}. {} — {}",
            shown + 1,
            name,
            fmt_distance(*dist)
        ));
        if let Some(cat) = e.category() {
            out.push_str(&format!("; {cat}"));
        }
        if let Some(addr) = e.address() {
            out.push_str(&format!("; {addr}"));
        }
        if let Some(hours) = e.tags.get("opening_hours") {
            out.push_str(&format!("; hours: {hours}"));
        }
        if let Some(site) = e
            .tags
            .get("website")
            .or_else(|| e.tags.get("contact:website"))
        {
            out.push_str(&format!("; {site}"));
        }
        out.push_str(&format!("; ({elat}, {elon})"));
        shown += 1;
        if shown >= limit {
            break;
        }
    }
    if shown == 0 {
        out.push_str("\n(no results — try a broader category or a larger radius_m)");
    }
    out
}

fn fmt_distance(m: f64) -> String {
    if m < 1000.0 {
        format!("{} m away", m.round() as u64)
    } else {
        format!("{:.1} km away", m / 1000.0)
    }
}

/// Great-circle distance in meters between two lat/lon points.
fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dlon / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().asin()
}

/// Escape regex metacharacters (and quote/backslash) so a raw term can be safely
/// embedded inside an OverpassQL `["key"~"…",i]` filter.
fn escape_overpass_regex(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 4);
    for c in s.chars() {
        if matches!(
            c,
            '\\' | '"'
                | '.'
                | '+'
                | '*'
                | '?'
                | '('
                | ')'
                | '|'
                | '['
                | ']'
                | '{'
                | '}'
                | '^'
                | '$'
        ) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

// ---- Nominatim geocoding ----------------------------------------------------

async fn nominatim_search(
    cfg: &Config,
    http: &reqwest::Client,
    query: &str,
    country: Option<&str>,
    limit: u8,
) -> Result<Vec<PlaceResult>, String> {
    let limit = limit.clamp(1, 10).to_string();
    let url = cfg
        .nominatim_base
        .join("/search")
        .map_err(|e| e.to_string())?;
    let mut req = http
        .get(url)
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent)
        .query(&[
            ("q", query),
            ("format", "jsonv2"),
            ("addressdetails", "1"),
            ("limit", &limit),
        ]);
    if let Some(country) = country {
        req = req.query(&[("countrycodes", country)]);
    }
    req.send()
        .await
        .map_err(|e| e.to_string())?
        .json()
        .await
        .map_err(|e| e.to_string())
}

fn format_places(query: &str, places: &[PlaceResult]) -> String {
    let mut out = format!("Place search results for \"{query}\":");
    if places.is_empty() {
        out.push_str("\n(no results)");
        return out;
    }
    for (i, p) in places.iter().enumerate() {
        out.push_str(&format!(
            "\n{}. {} ({}, {})",
            i + 1,
            p.display_name,
            p.lat,
            p.lon
        ));
        if let Some(kind) = p.kind() {
            out.push_str(&format!(" — {kind}"));
        }
        if let Some(osm_type) = &p.osm_type {
            out.push_str(&format!(
                "; osm: {osm_type} {}",
                p.osm_id.unwrap_or_default()
            ));
        }
    }
    out
}

#[derive(Debug, Deserialize)]
struct PlaceResult {
    display_name: String,
    lat: String,
    lon: String,
    #[serde(default, rename = "class")]
    class_name: Option<String>,
    #[serde(default, rename = "type")]
    type_name: Option<String>,
    #[serde(default)]
    osm_type: Option<String>,
    #[serde(default)]
    osm_id: Option<u64>,
}

impl PlaceResult {
    fn kind(&self) -> Option<String> {
        match (&self.class_name, &self.type_name) {
            (Some(class), Some(kind)) => Some(format!("{class}/{kind}")),
            (Some(class), None) => Some(class.clone()),
            (None, Some(kind)) => Some(kind.clone()),
            _ => None,
        }
    }
}

// ---- Overpass response ------------------------------------------------------

#[derive(Debug, Deserialize)]
struct OverpassResponse {
    #[serde(default)]
    elements: Vec<OverpassElement>,
}

#[derive(Debug, Deserialize)]
struct OverpassElement {
    #[serde(default)]
    lat: Option<f64>,
    #[serde(default)]
    lon: Option<f64>,
    #[serde(default)]
    center: Option<LatLon>,
    #[serde(default)]
    tags: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
struct LatLon {
    lat: f64,
    lon: f64,
}

impl OverpassElement {
    /// Node coordinates, or the `out center` point for ways/relations.
    fn coord(&self) -> Option<(f64, f64)> {
        match (self.lat, self.lon) {
            (Some(lat), Some(lon)) => Some((lat, lon)),
            _ => self.center.as_ref().map(|c| (c.lat, c.lon)),
        }
    }

    fn name(&self) -> Option<&str> {
        self.tags
            .get("name")
            .map(String::as_str)
            .filter(|s| !s.is_empty())
    }

    /// Human-friendly category from the most specific tag present.
    fn category(&self) -> Option<String> {
        let label = self
            .tags
            .get("amenity")
            .or_else(|| self.tags.get("shop"))
            .or_else(|| self.tags.get("tourism"))
            .or_else(|| self.tags.get("leisure"))
            .map(|s| s.replace('_', " "));
        match (label, self.tags.get("cuisine")) {
            (Some(l), Some(c)) => Some(format!("{l} ({})", c.replace([';', '_'], " "))),
            (Some(l), None) => Some(l),
            (None, Some(c)) => Some(c.replace([';', '_'], " ")),
            (None, None) => None,
        }
    }

    /// Street address assembled from `addr:*` tags, if any.
    fn address(&self) -> Option<String> {
        let mut parts: Vec<String> = Vec::new();
        let street = match (
            self.tags.get("addr:housenumber"),
            self.tags.get("addr:street"),
        ) {
            (Some(n), Some(s)) => Some(format!("{n} {s}")),
            (None, Some(s)) => Some(s.clone()),
            _ => None,
        };
        if let Some(s) = street {
            parts.push(s);
        }
        if let Some(city) = self.tags.get("addr:city") {
            parts.push(city.clone());
        }
        (!parts.is_empty()).then(|| parts.join(", "))
    }
}

fn error_outcome(call_id: &str, detail: String) -> ToolOutcome {
    ToolOutcome {
        message: ChatMessage::tool_result(
            call_id,
            "maps_places",
            format!("maps_places failed: {detail}"),
        ),
        append_to_answer: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_empty_results() {
        let out = format_places("x", &[]);
        assert!(out.contains("(no results)"));
    }

    #[test]
    fn maps_restaurant_to_amenity_tags() {
        let tags = category_tags("restaurant");
        assert!(tags.iter().any(|t| t.contains("restaurant")));
        assert!(tags.iter().any(|t| t.contains("fast_food")));
    }

    #[test]
    fn unmapped_term_has_no_category_tags() {
        assert!(category_tags("artisanal mustard boutique").is_empty());
    }

    #[test]
    fn overpass_query_is_bounded_and_typed() {
        let q = build_overpass_query("coffee", None, 30.26, -97.74, 1500);
        assert!(q.contains("around:1500,30.26,-97.74"));
        assert!(q.contains("[\"amenity\"=\"cafe\"]"));
        assert!(q.contains("out center tags"));
    }

    #[test]
    fn overpass_query_escapes_regex_metachars() {
        let q = build_overpass_query("a+b(c)", None, 0.0, 0.0, 100);
        assert!(q.contains(r"a\+b\(c\)"));
    }

    #[test]
    fn cuisine_narrows_to_cuisine_tag_not_all_restaurants() {
        let q = build_overpass_query("restaurant", Some("thai"), 30.26, -97.74, 1500);
        // Must constrain by the cuisine tag...
        assert!(q.contains("[\"cuisine\"~\"thai\",i]"));
        // ...and a bare `amenity=restaurant` clause that would return *every*
        // restaurant must not appear.
        assert!(!q.contains("nwr(around:1500,30.26,-97.74)[\"amenity\"=\"restaurant\"];"));
        // Named-but-untagged food venues still match, gated to food amenities.
        assert!(q.contains(
            "[\"amenity\"~\"^(restaurant|fast_food|cafe|bar|pub)$\"][\"name\"~\"thai\",i]"
        ));
    }

    #[test]
    fn haversine_known_distance() {
        // ~1.5 km between two downtown Austin points; allow generous tolerance.
        let d = haversine_m(30.2646, -97.7447, 30.2700, -97.7600);
        assert!((1000.0..2500.0).contains(&d), "got {d}");
    }

    #[test]
    fn distance_formats_meters_then_km() {
        assert_eq!(fmt_distance(450.0), "450 m away");
        assert_eq!(fmt_distance(1500.0), "1.5 km away");
    }
}
