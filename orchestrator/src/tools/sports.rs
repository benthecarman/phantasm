//! Sports scores and schedules backed by ESPN's public scoreboard API. No API
//! key and no persistence.

use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::config::Config;
use crate::openai::types::ToolCall;
use crate::orchestrator::tools::{tool_envelope, ToolOutcome};
use crate::orchestrator::TurnEvent;
use crate::tools::http_util;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SportsArgs {
    /// Which league's games to look up.
    pub league: League,
    /// Day to fetch, as `YYYY-MM-DD`. Omit for the current scoreboard (today's
    /// games, or the current week for weekly leagues like the NFL).
    #[serde(default)]
    pub date: Option<String>,
    /// Optional case-insensitive team-name filter, e.g. "Lakers". Only games
    /// involving a matching team are returned.
    #[serde(default)]
    pub team: Option<String>,
}

/// Leagues we expose, mapped to ESPN's `{sport}/{league}` path segments. Kept as
/// an enum so the model is offered a closed set rather than guessing slugs.
///
/// The JSON schema advertises the canonical `snake_case` names (via the
/// `JsonSchema` derive and the serde rename), but deserialization is deliberately
/// lenient: models tend to send "MLB", "baseball", "premier league", etc. We
/// normalize and match a broad alias table rather than reject (see
/// [`League::from_alias`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum League {
    Nfl,
    CollegeFootball,
    Nba,
    WNba,
    MensCollegeBasketball,
    Mlb,
    Nhl,
    /// Association football — English Premier League.
    PremierLeague,
    /// Association football — Spanish La Liga.
    LaLiga,
    /// Association football — UEFA Champions League.
    ChampionsLeague,
    /// Association football — US Major League Soccer.
    Mls,
}

impl League {
    /// ESPN scoreboard path segments: `(sport, league)`.
    fn path(self) -> (&'static str, &'static str) {
        match self {
            League::Nfl => ("football", "nfl"),
            League::CollegeFootball => ("football", "college-football"),
            League::Nba => ("basketball", "nba"),
            League::WNba => ("basketball", "wnba"),
            League::MensCollegeBasketball => ("basketball", "mens-college-basketball"),
            League::Mlb => ("baseball", "mlb"),
            League::Nhl => ("hockey", "nhl"),
            League::PremierLeague => ("soccer", "eng.1"),
            League::LaLiga => ("soccer", "esp.1"),
            League::ChampionsLeague => ("soccer", "uefa.champions"),
            League::Mls => ("soccer", "usa.1"),
        }
    }

    fn label(self) -> &'static str {
        match self {
            League::Nfl => "NFL",
            League::CollegeFootball => "College Football",
            League::Nba => "NBA",
            League::WNba => "WNBA",
            League::MensCollegeBasketball => "Men's College Basketball",
            League::Mlb => "MLB",
            League::Nhl => "NHL",
            League::PremierLeague => "Premier League",
            League::LaLiga => "La Liga",
            League::ChampionsLeague => "Champions League",
            League::Mls => "MLS",
        }
    }

    /// Resolve whatever the model sent to a league, generously. The input is
    /// normalized to lowercase alphanumerics (so "Premier League", "premier-league",
    /// and "premierleague" all collapse to the same key) before matching a broad
    /// alias table that covers common abbreviations, full names, and — for the
    /// leagues where it is unambiguous — the bare sport name.
    fn from_alias(raw: &str) -> Option<League> {
        let key = normalize_key(raw);
        let league = match key.as_str() {
            // American football
            "nfl" | "football" | "americanfootball" | "profootball" | "nationalfootballleague" => {
                League::Nfl
            }
            "collegefootball" | "cfb" | "ncaaf" | "ncaafootball" | "ncaafb" | "collegefb" => {
                League::CollegeFootball
            }

            // Basketball
            "nba" | "basketball" | "probasketball" | "nationalbasketballassociation" => League::Nba,
            "wnba" | "womensnba" | "womensbasketball" | "womensnationalbasketballassociation" => {
                League::WNba
            }
            "menscollegebasketball"
            | "ncaab"
            | "ncaam"
            | "ncaamb"
            | "cbb"
            | "collegebasketball"
            | "marchmadness"
            | "ncaamensbasketball" => League::MensCollegeBasketball,

            // Baseball
            "mlb" | "baseball" | "probaseball" | "majorleaguebaseball" => League::Mlb,

            // Hockey
            "nhl" | "hockey" | "icehockey" | "prohockey" | "nationalhockeyleague" => League::Nhl,

            // Soccer / association football. Bare "soccer"/"football" is ambiguous
            // across these leagues, so it is intentionally not mapped here.
            "premierleague"
            | "epl"
            | "pl"
            | "englishpremierleague"
            | "eng1"
            | "barclayspremierleague" => League::PremierLeague,
            "laliga" | "esp1" | "spanishlaliga" | "laligasantander" | "primeradivision" => {
                League::LaLiga
            }
            "championsleague" | "ucl" | "uefachampionsleague" | "uefachampions" | "uefacl" => {
                League::ChampionsLeague
            }
            "mls" | "majorleaguesoccer" | "usa1" | "usmls" => League::Mls,

            _ => return None,
        };
        Some(league)
    }
}

/// Lowercase and strip everything that isn't an ASCII letter or digit, so
/// punctuation, spacing, and case never matter when matching league aliases.
fn normalize_key(raw: &str) -> String {
    raw.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

impl<'de> Deserialize<'de> for League {
    fn deserialize<D>(deserializer: D) -> Result<League, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let raw = String::deserialize(deserializer)?;
        League::from_alias(&raw).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "unknown league `{raw}`; try one of: nfl, college_football, nba, wnba, \
                 mens_college_basketball, mlb, nhl, premier_league, la_liga, \
                 champions_league, mls"
            ))
        })
    }
}

pub fn schema() -> Value {
    let params = serde_json::to_value(schemars::schema_for!(SportsArgs))
        .unwrap_or_else(|_| serde_json::json!({"type": "object"}));
    tool_envelope(
        "sports",
        "Get scores, live status, and schedules for a sports league. Returns the \
         current scoreboard by default, or a specific day's games when a date is given.",
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
    crate::tools::run_simple(
        "sports",
        call,
        call_id,
        tx,
        cancel,
        |_: &SportsArgs| "checking scores…".into(),
        |args| async move { scoreboard(cfg, http, &args).await },
    )
    .await
}

async fn scoreboard(
    cfg: &Config,
    http: &reqwest::Client,
    args: &SportsArgs,
) -> Result<String, String> {
    let (sport, league) = args.league.path();
    let url = http_util::join_base(
        &cfg.espn_base,
        &format!("/apis/site/v2/sports/{sport}/{league}/scoreboard"),
    );

    let mut req = http
        .get(url)
        .header(reqwest::header::USER_AGENT, &cfg.tool_user_agent);
    if let Some(date) = args.date.as_deref() {
        req = req.query(&[("dates", compact_date(date)?)]);
    }

    let resp: ScoreboardResponse = http_util::get_json(req).await?;

    Ok(format_scoreboard(args, &resp))
}

/// ESPN's `dates` query wants `YYYYMMDD`; the model gives us `YYYY-MM-DD`.
fn compact_date(date: &str) -> Result<String, String> {
    let parts: Vec<&str> = date.split('-').collect();
    if let [y, m, d] = parts[..] {
        if y.len() == 4
            && m.len() == 2
            && d.len() == 2
            && [y, m, d]
                .iter()
                .all(|p| p.bytes().all(|b| b.is_ascii_digit()))
        {
            return Ok(format!("{y}{m}{d}"));
        }
    }
    Err(format!("date must be YYYY-MM-DD, got `{date}`"))
}

fn format_scoreboard(args: &SportsArgs, resp: &ScoreboardResponse) -> String {
    let filter = args
        .team
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let games: Vec<&Event> = resp
        .events
        .iter()
        .filter(|e| match filter {
            Some(f) => e.involves_team(f),
            None => true,
        })
        .collect();

    if games.is_empty() {
        return match filter {
            Some(f) => format!("No {} games found matching `{f}`.", args.league.label()),
            None => format!("No {} games scheduled.", args.league.label()),
        };
    }

    let mut out = format!("{} scoreboard:", args.league.label());
    for event in games {
        out.push('\n');
        out.push_str(&event.summary());
    }
    out
}

#[derive(Debug, Deserialize)]
struct ScoreboardResponse {
    #[serde(default)]
    events: Vec<Event>,
}

#[derive(Debug, Deserialize)]
struct Event {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    competitions: Vec<Competition>,
    #[serde(default)]
    status: Option<Status>,
}

impl Event {
    fn competitors(&self) -> &[Competitor] {
        self.competitions
            .first()
            .map(|c| c.competitors.as_slice())
            .unwrap_or(&[])
    }

    fn involves_team(&self, needle: &str) -> bool {
        let needle = needle.to_lowercase();
        self.competitors().iter().any(|c| {
            c.team
                .as_ref()
                .map(|t| t.display_name.to_lowercase().contains(&needle))
                .unwrap_or(false)
        })
    }

    fn summary(&self) -> String {
        let competitors = self.competitors();
        // Home team is listed first by ESPN; render as "Away at Home" with scores.
        let home = competitors
            .iter()
            .find(|c| c.home_away.as_deref() == Some("home"));
        let away = competitors
            .iter()
            .find(|c| c.home_away.as_deref() == Some("away"));

        let matchup = match (away, home) {
            (Some(a), Some(h)) => format!(
                "{} {} at {} {}",
                a.name(),
                a.score.as_deref().unwrap_or("-"),
                h.name(),
                h.score.as_deref().unwrap_or("-")
            ),
            _ => self
                .name
                .clone()
                .unwrap_or_else(|| "unknown matchup".into()),
        };

        let state = self
            .status
            .as_ref()
            .and_then(|s| s.type_.as_ref())
            .and_then(|t| t.detail.clone())
            .unwrap_or_else(|| "scheduled".into());

        format!("- {matchup} ({state})")
    }
}

#[derive(Debug, Deserialize)]
struct Competition {
    #[serde(default)]
    competitors: Vec<Competitor>,
}

#[derive(Debug, Deserialize)]
struct Competitor {
    #[serde(rename = "homeAway", default)]
    home_away: Option<String>,
    #[serde(default)]
    score: Option<String>,
    #[serde(default)]
    team: Option<Team>,
}

impl Competitor {
    fn name(&self) -> &str {
        self.team
            .as_ref()
            .map(|t| t.display_name.as_str())
            .unwrap_or("unknown")
    }
}

#[derive(Debug, Deserialize)]
struct Team {
    #[serde(rename = "displayName", default)]
    display_name: String,
}

#[derive(Debug, Deserialize)]
struct Status {
    #[serde(rename = "type", default)]
    type_: Option<StatusType>,
}

#[derive(Debug, Deserialize)]
struct StatusType {
    /// Human-readable status, e.g. "Final", "7:30 PM ET", "2nd Quarter".
    #[serde(default)]
    detail: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn league_paths_are_stable() {
        assert_eq!(League::Nfl.path(), ("football", "nfl"));
        assert_eq!(League::PremierLeague.path(), ("soccer", "eng.1"));
    }

    #[test]
    fn canonical_snake_case_names_parse() {
        // Every label the schema advertises must round-trip back to its league.
        for (name, league) in [
            ("nfl", League::Nfl),
            ("college_football", League::CollegeFootball),
            ("nba", League::Nba),
            ("wnba", League::WNba),
            ("mens_college_basketball", League::MensCollegeBasketball),
            ("mlb", League::Mlb),
            ("nhl", League::Nhl),
            ("premier_league", League::PremierLeague),
            ("la_liga", League::LaLiga),
            ("champions_league", League::ChampionsLeague),
            ("mls", League::Mls),
        ] {
            assert_eq!(League::from_alias(name), Some(league), "for `{name}`");
        }
    }

    #[test]
    fn lenient_aliases_parse() {
        // Casing, spacing, punctuation, abbreviations, and bare sport names.
        assert_eq!(League::from_alias("MLB"), Some(League::Mlb));
        assert_eq!(League::from_alias("baseball"), Some(League::Mlb));
        assert_eq!(
            League::from_alias("Premier League"),
            Some(League::PremierLeague)
        );
        assert_eq!(League::from_alias("epl"), Some(League::PremierLeague));
        assert_eq!(League::from_alias("EPL"), Some(League::PremierLeague));
        assert_eq!(League::from_alias("ncaaf"), Some(League::CollegeFootball));
        assert_eq!(
            League::from_alias("March Madness"),
            Some(League::MensCollegeBasketball)
        );
        assert_eq!(League::from_alias("ice hockey"), Some(League::Nhl));
        assert_eq!(League::from_alias("Major League Soccer"), Some(League::Mls));
    }

    #[test]
    fn unknown_league_is_rejected() {
        assert_eq!(League::from_alias("quidditch"), None);
        assert_eq!(League::from_alias(""), None);
    }

    #[test]
    fn deserializes_alias_through_args() {
        let args: SportsArgs =
            serde_json::from_str(r#"{"league": "MLB"}"#).expect("MLB should parse");
        assert_eq!(args.league, League::Mlb);
    }

    #[test]
    fn compacts_iso_date() {
        assert_eq!(compact_date("2026-06-29").unwrap(), "20260629");
        assert!(compact_date("June 29").is_err());
        assert!(compact_date("2026-6-29").is_err());
    }

    fn event(away: &str, away_score: &str, home: &str, home_score: &str, detail: &str) -> Event {
        Event {
            name: Some(format!("{away} at {home}")),
            competitions: vec![Competition {
                competitors: vec![
                    Competitor {
                        home_away: Some("home".into()),
                        score: Some(home_score.into()),
                        team: Some(Team {
                            display_name: home.into(),
                        }),
                    },
                    Competitor {
                        home_away: Some("away".into()),
                        score: Some(away_score.into()),
                        team: Some(Team {
                            display_name: away.into(),
                        }),
                    },
                ],
            }],
            status: Some(Status {
                type_: Some(StatusType {
                    detail: Some(detail.into()),
                }),
            }),
        }
    }

    #[test]
    fn formats_away_at_home_with_scores_and_status() {
        let e = event("Lakers", "102", "Celtics", "99", "Final");
        assert_eq!(e.summary(), "- Lakers 102 at Celtics 99 (Final)");
    }

    #[test]
    fn team_filter_matches_case_insensitively() {
        let e = event("Lakers", "102", "Celtics", "99", "Final");
        assert!(e.involves_team("lakers"));
        assert!(e.involves_team("CELT"));
        assert!(!e.involves_team("Heat"));
    }

    #[test]
    fn empty_scoreboard_reports_no_games() {
        let args = SportsArgs {
            league: League::Nba,
            date: None,
            team: None,
        };
        let resp = ScoreboardResponse { events: vec![] };
        assert_eq!(format_scoreboard(&args, &resp), "No NBA games scheduled.");
    }

    #[test]
    fn unmatched_filter_reports_no_match() {
        let args = SportsArgs {
            league: League::Nba,
            date: None,
            team: Some("Heat".into()),
        };
        let resp = ScoreboardResponse {
            events: vec![event("Lakers", "102", "Celtics", "99", "Final")],
        };
        assert_eq!(
            format_scoreboard(&args, &resp),
            "No NBA games found matching `Heat`."
        );
    }
}
