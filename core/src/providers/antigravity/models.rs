use serde_json::{json, Value};
use std::collections::BTreeMap;

use crate::translate::gemini::Thinking;

pub struct Route {
    pub id: &'static str,
    pub display_name: &'static str,
    pub off: &'static str,
    pub low: &'static str,
    pub medium: &'static str,
    pub high: &'static str,
    pub context_length: i64,
    pub max_output_tokens: i64,
    pub levels: &'static [&'static str],
}

const LOW_MEDIUM_HIGH: &[&str] = &["low", "medium", "high"];
const LOW_HIGH: &[&str] = &["low", "high"];
const HIGH_ONLY: &[&str] = &["high"];
const MEDIUM_ONLY: &[&str] = &["medium"];

pub const ROUTES: &[Route] = &[
    Route {
        id: "gemini-3.8-flash",
        display_name: "Gemini 3.8 Flash",
        off: "gemini-3.8-flash-low",
        low: "gemini-3.8-flash-low",
        medium: "gemini-3.8-flash-medium",
        high: "gemini-3.8-flash-high",
        context_length: 1_048_576,
        max_output_tokens: 65_536,
        levels: LOW_MEDIUM_HIGH,
    },
    Route {
        id: "gemini-3.7-flash",
        display_name: "Gemini 3.7 Flash",
        off: "gemini-3.7-flash-low",
        low: "gemini-3.7-flash-low",
        medium: "gemini-3.7-flash-medium",
        high: "gemini-3.7-flash-high",
        context_length: 1_048_576,
        max_output_tokens: 65_536,
        levels: LOW_MEDIUM_HIGH,
    },
    Route {
        id: "gemini-3.6-flash",
        display_name: "Gemini 3.6 Flash",
        off: "gemini-3.6-flash-low",
        low: "gemini-3.6-flash-low",
        medium: "gemini-3.6-flash-medium",
        high: "gemini-3.6-flash-high",
        context_length: 1_048_576,
        max_output_tokens: 65_536,
        levels: LOW_MEDIUM_HIGH,
    },
    Route {
        id: "gemini-3.5-flash",
        display_name: "Gemini 3.5 Flash",
        off: "gemini-3.5-flash-extra-low",
        low: "gemini-3.5-flash-extra-low",
        medium: "gemini-3.5-flash-low",
        high: "gemini-3-flash-agent",
        context_length: 1_048_576,
        max_output_tokens: 65_536,
        levels: LOW_MEDIUM_HIGH,
    },
    Route {
        id: "gemini-3.1-pro",
        display_name: "Gemini 3.1 Pro",
        off: "gemini-3.1-pro-low",
        low: "gemini-3.1-pro-low",
        medium: "gemini-3.1-pro-low",
        high: "gemini-pro-agent",
        context_length: 1_048_576,
        max_output_tokens: 65_535,
        levels: LOW_HIGH,
    },
    Route {
        id: "claude-sonnet-4-6",
        display_name: "Claude Sonnet 4.6",
        off: "claude-sonnet-4-6",
        low: "claude-sonnet-4-6",
        medium: "claude-sonnet-4-6",
        high: "claude-sonnet-4-6",
        context_length: 200_000,
        max_output_tokens: 64_000,
        levels: HIGH_ONLY,
    },
    Route {
        id: "claude-opus-4-6",
        display_name: "Claude Opus 4.6",
        off: "claude-opus-4-6-thinking",
        low: "claude-opus-4-6-thinking",
        medium: "claude-opus-4-6-thinking",
        high: "claude-opus-4-6-thinking",
        context_length: 250_000,
        max_output_tokens: 64_000,
        levels: HIGH_ONLY,
    },
    Route {
        id: "gpt-oss-120b",
        display_name: "GPT-OSS 120B",
        off: "gpt-oss-120b-medium",
        low: "gpt-oss-120b-medium",
        medium: "gpt-oss-120b-medium",
        high: "gpt-oss-120b-medium",
        context_length: 131_072,
        max_output_tokens: 32_768,
        levels: MEDIUM_ONLY,
    },
];

const MODEL_ENUMS: &[(&str, &str)] = &[
    ("gemini-3.8-flash", "MODEL_PLACEHOLDER_M318"),
    ("gemini-3.8-flash-high", "MODEL_PLACEHOLDER_M318"),
    ("gemini-3.8-flash-medium", "MODEL_PLACEHOLDER_M319"),
    ("gemini-3.8-flash-low", "MODEL_PLACEHOLDER_M320"),
    ("gemini-3.8-flash-tiered", "MODEL_PLACEHOLDER_M322"),
    ("gemini-3.7-flash", "MODEL_PLACEHOLDER_M298"),
    ("gemini-3.7-flash-high", "MODEL_PLACEHOLDER_M298"),
    ("gemini-3.7-flash-medium", "MODEL_PLACEHOLDER_M299"),
    ("gemini-3.7-flash-low", "MODEL_PLACEHOLDER_M300"),
    ("gemini-3.7-flash-tiered", "MODEL_PLACEHOLDER_M301"),
    ("gemini-3.6-flash", "MODEL_PLACEHOLDER_M71"),
    ("gemini-3.6-flash-high", "MODEL_PLACEHOLDER_M71"),
    ("gemini-3.6-flash-medium", "MODEL_PLACEHOLDER_M72"),
    ("gemini-3.6-flash-low", "MODEL_PLACEHOLDER_M73"),
    ("gemini-3.6-flash-tiered", "MODEL_PLACEHOLDER_M196"),
    ("gemini-3.5-flash", "MODEL_PLACEHOLDER_M20"),
    ("gemini-3.5-flash-extra-low", "MODEL_PLACEHOLDER_M187"),
    ("gemini-3.5-flash-low", "MODEL_PLACEHOLDER_M20"),
    ("gemini-3-flash-agent", "MODEL_PLACEHOLDER_M84"),
    ("gemini-3.1-pro", "MODEL_PLACEHOLDER_M36"),
    ("gemini-3.1-pro-low", "MODEL_PLACEHOLDER_M36"),
    ("gemini-3.1-pro-high", "MODEL_PLACEHOLDER_M37"),
    ("gemini-pro-agent", "MODEL_PLACEHOLDER_M16"),
    ("claude-sonnet-4-6", "MODEL_PLACEHOLDER_M35"),
    ("claude-opus-4-6", "MODEL_PLACEHOLDER_M26"),
    ("claude-opus-4-6-thinking", "MODEL_PLACEHOLDER_M26"),
    ("gpt-oss-120b", "MODEL_OPENAI_GPT_OSS_120B_MEDIUM"),
    ("gpt-oss-120b-medium", "MODEL_OPENAI_GPT_OSS_120B_MEDIUM"),
];

pub fn route(model: &str) -> Option<&'static Route> {
    ROUTES.iter().find(|route| route.id == model)
}

pub fn runtime_model(model: &str, effort: &str) -> String {
    let Some(route) = route(model) else {
        return model.to_string();
    };
    match effort.trim().to_ascii_lowercase().as_str() {
        "" | "none" | "off" => route.off,
        "minimal" | "low" => route.low,
        "medium" => route.medium,
        _ => route.high,
    }
    .to_string()
}

pub fn fallback_runtime_model(runtime: &str) -> Option<String> {
    for (from, to) in [
        ("gemini-3.8-flash-", "gemini-3.7-flash-"),
        ("gemini-3.7-flash-", "gemini-3.6-flash-"),
    ] {
        if let Some(rest) = runtime.strip_prefix(from) {
            return Some(format!("{to}{rest}"));
        }
    }
    match runtime {
        "gemini-3.8-flash" => Some("gemini-3.7-flash-low".to_string()),
        "gemini-3.7-flash" => Some("gemini-3.6-flash-low".to_string()),
        _ => None,
    }
}

pub fn max_output_tokens(runtime: &str) -> i64 {
    if let Some(route) = ROUTES
        .iter()
        .find(|route| [route.off, route.low, route.medium, route.high].contains(&runtime))
    {
        return route.max_output_tokens;
    }
    if runtime.starts_with("claude-") {
        return 64_000;
    }
    if runtime.starts_with("gpt-oss-") {
        return 32_768;
    }
    if runtime.starts_with("gemini-3.1-pro") || runtime == "gemini-pro-agent" {
        return 65_535;
    }
    if runtime.starts_with("gemini-") {
        return 65_536;
    }
    8_192
}

pub fn model_enum(runtime: &str) -> String {
    MODEL_ENUMS
        .iter()
        .find(|(id, _)| *id == runtime)
        .map(|(_, value)| value.to_string())
        .unwrap_or_default()
}

pub fn thinking(runtime: &str, effort: &str) -> Option<Thinking> {
    let effort = effort.trim().to_ascii_lowercase();
    let off = matches!(effort.as_str(), "" | "none" | "off");
    let high = matches!(effort.as_str(), "high" | "xhigh" | "max");
    let medium = effort == "medium";

    let budget = if runtime.starts_with("claude-") {
        1_024
    } else if runtime.starts_with("gpt-oss-") {
        8_192
    } else if runtime.starts_with("gemini-3.5-flash") || runtime == "gemini-3-flash-agent" {
        if high {
            10_000
        } else if medium {
            4_000
        } else {
            1_000
        }
    } else if runtime.starts_with("gemini-3.1-pro") || runtime == "gemini-pro-agent" {
        if high {
            10_001
        } else {
            1_001
        }
    } else if runtime.starts_with("gemini-") {
        if high {
            -1
        } else if medium {
            4_000
        } else {
            1_000
        }
    } else {
        return None;
    };

    Some(match off {
        true => Thinking {
            include_thoughts: false,
            budget: 0,
        },
        false => Thinking {
            include_thoughts: true,
            budget,
        },
    })
}

pub fn requires_thought_signature(runtime: &str) -> bool {
    let Some(rest) = runtime.strip_prefix("gemini-") else {
        return false;
    };
    let major: i64 = rest
        .split(|c: char| !c.is_ascii_digit())
        .next()
        .unwrap_or_default()
        .parse()
        .unwrap_or(3);
    major >= 3
}

pub fn legacy_tool_parameters(runtime: &str) -> bool {
    runtime.starts_with("claude-") || runtime.starts_with("gpt-oss-")
}

pub fn tool_call_ids(runtime: &str) -> bool {
    legacy_tool_parameters(runtime)
}

pub fn selectable_runtime_id(id: &str) -> bool {
    let lower = id.to_ascii_lowercase();
    let known = lower.starts_with("gemini-")
        || lower.starts_with("claude-")
        || lower.starts_with("gpt-oss-");
    known
        && !lower.contains(char::is_whitespace)
        && !lower.starts_with("chat_")
        && !lower.starts_with("tab_")
        && !lower.contains("image")
}

const SUFFIXES: &[(&str, &str)] = &[
    ("-extra-low", "low"),
    ("-extra-high", "high"),
    ("-thinking", "high"),
    ("-minimal", "low"),
    ("-medium", "medium"),
    ("-high", "high"),
    ("-low", "low"),
    ("-tiered", ""),
];

const ALIASES: &[(&str, &str, &str)] = &[
    ("gemini-3-flash-agent", "gemini-3.5-flash", "high"),
    ("gemini-pro-agent", "gemini-3.1-pro", "high"),
];

#[derive(Debug, Default, Clone)]
pub struct Discovered {
    pub id: String,
    pub display_name: String,
    pub levels: Vec<String>,
    pub remaining: Option<f64>,
    pub reset_at: String,
    pub provider: String,
}

pub fn group_catalog(models: &Value) -> Vec<Discovered> {
    let Some(entries) = models.as_object() else {
        return Vec::new();
    };
    let mut grouped: BTreeMap<String, Discovered> = BTreeMap::new();

    for (runtime, info) in entries {
        if !selectable_runtime_id(runtime) {
            continue;
        }
        if info.get("isInternal").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let (public, level) = public_id(runtime);
        let entry = grouped.entry(public.clone()).or_insert_with(|| Discovered {
            id: public.clone(),
            ..Discovered::default()
        });
        if entry.display_name.is_empty() {
            entry.display_name = base_display_name(info);
        }
        if !level.is_empty() && !entry.levels.iter().any(|found| found == level) {
            entry.levels.push(level.to_string());
        }
        if entry.provider.is_empty() {
            entry.provider = info
                .get("modelProvider")
                .or_else(|| info.get("apiProvider"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
        }
        let remaining = info
            .pointer("/quotaInfo/remainingFraction")
            .and_then(Value::as_f64);
        if let Some(remaining) = remaining {
            entry.remaining = Some(entry.remaining.map_or(remaining, |seen| seen.min(remaining)));
        }
        if entry.reset_at.is_empty() {
            entry.reset_at = info
                .pointer("/quotaInfo/resetTime")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
        }
    }

    let order = ["low", "medium", "high"];
    for entry in grouped.values_mut() {
        entry
            .levels
            .sort_by_key(|level| order.iter().position(|known| known == level).unwrap_or(9));
        if entry.display_name.is_empty() {
            entry.display_name = entry.id.clone();
        }
    }
    grouped.into_values().collect()
}

fn public_id(runtime: &str) -> (String, &'static str) {
    if let Some((_, public, level)) = ALIASES.iter().find(|(id, _, _)| *id == runtime) {
        return (public.to_string(), level);
    }
    for (suffix, level) in SUFFIXES {
        if let Some(base) = runtime.strip_suffix(suffix) {
            return (base.to_string(), level);
        }
    }
    (runtime.to_string(), "")
}

fn base_display_name(info: &Value) -> String {
    let raw = ["displayName", "label", "modelName"]
        .iter()
        .find_map(|key| info.get(*key).and_then(Value::as_str))
        .unwrap_or_default();
    match raw.split_once('(') {
        Some((base, _)) => base.trim().to_string(),
        None => raw.trim().to_string(),
    }
}

pub fn catalog_entries(discovered: &[Discovered]) -> Vec<Value> {
    let mut seen: Vec<&str> = Vec::new();
    let mut out: Vec<Value> = Vec::new();

    for route in ROUTES {
        let live = discovered.iter().find(|entry| entry.id == route.id);
        seen.push(route.id);
        out.push(entry_json(
            route.id,
            route.display_name,
            route.context_length,
            route.max_output_tokens,
            route.levels.iter().map(|level| level.to_string()).collect(),
            live,
        ));
    }
    for entry in discovered {
        if seen.contains(&entry.id.as_str()) {
            continue;
        }
        let levels = match entry.levels.is_empty() {
            true => vec!["high".to_string()],
            false => entry.levels.clone(),
        };
        out.push(entry_json(
            &entry.id,
            &entry.display_name,
            context_guess(&entry.id),
            max_output_tokens(&entry.id),
            levels,
            Some(entry),
        ));
    }
    out
}

fn context_guess(id: &str) -> i64 {
    route(id)
        .map(|route| route.context_length)
        .unwrap_or_else(|| match id {
            id if id.starts_with("gemini-") => 1_048_576,
            id if id.starts_with("claude-") => 200_000,
            _ => 131_072,
        })
}

fn entry_json(
    id: &str,
    display_name: &str,
    context_length: i64,
    max_output_tokens: i64,
    levels: Vec<String>,
    live: Option<&Discovered>,
) -> Value {
    let mut entry = json!({
        "id": id,
        "display_name": display_name,
        "owned_by": crate::state::accounts::Channel::Antigravity.as_str(),
        "context_length": context_length,
        "max_completion_tokens": max_output_tokens,
        "thinking": {"levels": levels},
    });
    if let Some(live) = live {
        if let Some(remaining) = live.remaining {
            entry["remaining_fraction"] = json!(remaining);
        }
        if !live.reset_at.is_empty() {
            entry["reset_at"] = json!(live.reset_at);
        }
        if !live.provider.is_empty() {
            entry["model_provider"] = json!(live.provider);
        }
    }
    entry
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effort_selects_the_advertised_runtime_variant() {
        assert_eq!(runtime_model("gemini-3.8-flash", ""), "gemini-3.8-flash-low");
        assert_eq!(
            runtime_model("gemini-3.8-flash", "medium"),
            "gemini-3.8-flash-medium"
        );
        assert_eq!(
            runtime_model("gemini-3.8-flash", "xhigh"),
            "gemini-3.8-flash-high"
        );
        assert_eq!(runtime_model("gemini-3.5-flash", "high"), "gemini-3-flash-agent");
        assert_eq!(runtime_model("gemini-3.1-pro", "high"), "gemini-pro-agent");
        assert_eq!(runtime_model("unknown-model", "high"), "unknown-model");
    }

    #[test]
    fn thinking_budgets_match_the_cli_wire_format() {
        assert_eq!(
            thinking("gemini-3.8-flash-high", "high"),
            Some(Thinking {
                include_thoughts: true,
                budget: -1
            })
        );
        assert_eq!(
            thinking("gemini-3.5-flash-low", "medium"),
            Some(Thinking {
                include_thoughts: true,
                budget: 4_000
            })
        );
        assert_eq!(
            thinking("claude-sonnet-4-6", "none"),
            Some(Thinking {
                include_thoughts: false,
                budget: 0
            })
        );
        assert_eq!(
            thinking("gemini-pro-agent", "high"),
            Some(Thinking {
                include_thoughts: true,
                budget: 10_001
            })
        );
    }

    #[test]
    fn only_gemini_3_and_newer_demand_thought_signatures() {
        assert!(requires_thought_signature("gemini-3.8-flash-low"));
        assert!(!requires_thought_signature("claude-sonnet-4-6"));
        assert!(!requires_thought_signature("gemini-2.5-pro"));
    }

    #[test]
    fn discovery_groups_runtime_variants_into_public_ids() {
        let raw = json!({
            "gemini-4.0-flash-low": {"displayName": "Gemini 4.0 Flash (Low)", "quotaInfo": {"remainingFraction": 0.5}},
            "gemini-4.0-flash-high": {"displayName": "Gemini 4.0 Flash (High)", "quotaInfo": {"remainingFraction": 0.25}},
            "chat_helper": {"displayName": "hidden"},
            "gemini-3-flash-agent": {"displayName": "Gemini 3.5 Flash (High)"},
            "gemini-internal-x": {"displayName": "x", "isInternal": true},
        });
        let grouped = group_catalog(&raw);
        let flash = grouped
            .iter()
            .find(|entry| entry.id == "gemini-4.0-flash")
            .expect("grouped by family");
        assert_eq!(flash.levels, ["low", "high"]);
        assert_eq!(flash.display_name, "Gemini 4.0 Flash");
        assert_eq!(flash.remaining, Some(0.25));
        assert!(grouped.iter().any(|entry| entry.id == "gemini-3.5-flash"));
        assert!(!grouped.iter().any(|entry| entry.id.starts_with("chat_")));
        assert!(!grouped.iter().any(|entry| entry.id == "gemini-internal-x"));
    }

    #[test]
    fn the_catalog_lists_static_routes_before_discovered_extras() {
        let discovered = group_catalog(&json!({
            "gemini-4.0-flash-low": {"displayName": "Gemini 4.0 Flash (Low)"},
        }));
        let entries = catalog_entries(&discovered);
        assert_eq!(entries[0]["id"], "gemini-3.8-flash");
        assert_eq!(entries[0]["thinking"]["levels"], json!(["low", "medium", "high"]));
        let extra = entries
            .iter()
            .find(|entry| entry["id"] == "gemini-4.0-flash")
            .expect("discovered model is offered");
        assert_eq!(extra["context_length"], 1_048_576);
    }
}
