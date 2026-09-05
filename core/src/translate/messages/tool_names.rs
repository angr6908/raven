use serde_json::Value;
use std::collections::{HashMap, HashSet};

use crate::translate::ids::sha256_hex_prefix;

const LIMIT: usize = 64;

pub fn shorten_call_id_if_needed(id: &str) -> String {
    if id.len() <= LIMIT {
        return id.to_string();
    }
    let suffix = format!("_{}", sha256_hex_prefix(id, 8));
    let prefix_len = LIMIT.saturating_sub(suffix.len());
    if prefix_len == 0 {
        return suffix[suffix.len() - LIMIT..].to_string();
    }

    format!("{}{suffix}", truncate_on_boundary(id, prefix_len))
}

pub(crate) fn truncate_on_boundary(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

pub fn base_candidate(name: &str) -> String {
    if name.len() <= LIMIT {
        return name.to_string();
    }
    if name.starts_with("mcp__") {
        if let Some(idx) = name.rfind("__") {
            if idx > 0 {
                let cand = format!("mcp__{}", &name[idx + 2..]);
                return truncate_on_boundary(&cand, LIMIT).to_string();
            }
        }
    }
    truncate_on_boundary(name, LIMIT).to_string()
}

pub fn tool_names(req: &Value) -> Vec<String> {
    req.get("tools")
        .and_then(Value::as_array)
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(Value::as_str))
                .filter(|n| !n.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

pub fn build_short_name_map(names: &[String]) -> HashMap<String, String> {
    let mut used: HashSet<String> = HashSet::new();
    let mut map: HashMap<String, String> = HashMap::new();

    for name in names {
        let candidate = base_candidate(name);

        let unique = if !used.contains(&candidate) {
            candidate
        } else {
            let base = candidate;
            let mut chosen = None;
            for i in 1.. {
                let suffix = format!("_{i}");
                let allowed = LIMIT.saturating_sub(suffix.len());
                let tmp = format!("{}{suffix}", truncate_on_boundary(&base, allowed));
                if !used.contains(&tmp) {
                    chosen = Some(tmp);
                    break;
                }
            }
            chosen.unwrap_or(base)
        };

        used.insert(unique.clone());
        map.insert(name.clone(), unique);
    }
    map
}

pub fn reverse_short_name_map(original_request: &Value) -> HashMap<String, String> {
    build_short_name_map(&tool_names(original_request))
        .into_iter()
        .map(|(original, short)| (short, original))
        .collect()
}

pub fn resolve_tool_use_name(rev: &HashMap<String, String>, name: &str) -> String {
    rev.get(name).cloned().unwrap_or_else(|| name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_names_pass_through() {
        let map = build_short_name_map(&["read_file".to_string()]);
        assert_eq!(map["read_file"], "read_file");
    }

    #[test]
    fn long_mcp_names_keep_the_mcp_prefix_and_leaf() {
        let long = format!("mcp__{}__do_the_thing", "a".repeat(80));
        let map = build_short_name_map(&[long.clone()]);
        let short = &map[&long];
        assert!(short.starts_with("mcp__"));
        assert!(short.ends_with("do_the_thing"));
        assert!(short.len() <= 64);
    }

    #[test]
    fn collisions_get_numeric_suffixes() {
        let a = "x".repeat(70);
        let b = format!("{}y", "x".repeat(70));
        let map = build_short_name_map(&[a.clone(), b.clone()]);
        assert_ne!(map[&a], map[&b]);
        assert!(map[&b].len() <= 64);
    }

    #[test]
    fn call_ids_over_the_limit_are_hashed() {
        let id = "c".repeat(100);
        let short = shorten_call_id_if_needed(&id);
        assert_eq!(short.len(), 64);
        assert!(short.contains('_'));

        assert_eq!(short, shorten_call_id_if_needed(&id));
    }

    #[test]
    fn reverse_map_recovers_the_original_name() {
        let long = format!("mcp__{}__leaf", "b".repeat(80));
        let req = serde_json::json!({"tools": [{"name": long}]});
        let rev = reverse_short_name_map(&req);
        let short = build_short_name_map(&[long.clone()])[&long].clone();
        assert_eq!(resolve_tool_use_name(&rev, &short), long);
    }
}
