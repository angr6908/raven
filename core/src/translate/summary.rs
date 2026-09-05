use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SummaryMode {
    Unspecified,
    Disabled,
    Enabled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SummaryConfig {
    pub mode: SummaryMode,
    pub detail: String,
}

impl Default for SummaryConfig {
    fn default() -> Self {
        Self {
            mode: SummaryMode::Unspecified,
            detail: String::new(),
        }
    }
}

impl SummaryConfig {
    fn enabled(detail: &str) -> Self {
        Self {
            mode: SummaryMode::Enabled,
            detail: detail.to_string(),
        }
    }

    fn disabled() -> Self {
        Self {
            mode: SummaryMode::Disabled,
            detail: String::new(),
        }
    }

    pub fn or_visible_default(&self) -> Self {
        match self.mode {
            SummaryMode::Unspecified => Self::enabled("auto"),
            _ => self.clone(),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.mode == SummaryMode::Enabled
    }

    pub fn from_chat_effort(effort: &str) -> Self {
        match lower(effort).as_str() {
            "" => Self::default(),
            "none" => Self::disabled(),
            _ => Self::enabled("auto"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SummaryFormat {
    Claude,

    Responses,
}

fn lower(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

fn at<'a>(body: &'a Value, path: &str) -> Option<&'a Value> {
    let mut node = body;
    for segment in path.split('.') {
        node = node.get(segment)?;
    }
    Some(node)
}

fn responses_config(body: &Value, path: &str) -> Option<SummaryConfig> {
    match at(body, path)? {
        Value::Null => Some(SummaryConfig::disabled()),
        Value::String(raw) => match lower(raw).as_str() {
            detail @ ("auto" | "concise" | "detailed") => Some(SummaryConfig::enabled(detail)),

            "none" => Some(SummaryConfig::disabled()),
            _ => None,
        },
        _ => None,
    }
}

fn claude_config(body: &Value, path: &str) -> Option<SummaryConfig> {
    match lower(at(body, path)?.as_str()?).as_str() {
        "summarized" => Some(SummaryConfig::enabled("auto")),
        "omitted" => Some(SummaryConfig::disabled()),
        _ => None,
    }
}

fn claude_thinking_accepts_display(body: &Value) -> bool {
    let thinking = body.get("thinking").filter(|t| t.is_object());
    let Some(thinking) = thinking else {
        return false;
    };
    match lower(thinking.get("type").and_then(Value::as_str).unwrap_or("")).as_str() {
        "adaptive" | "auto" => true,
        "enabled" => match thinking.get("budget_tokens").and_then(Value::as_i64) {
            None => true,
            Some(budget) => budget == -1 || budget > 0,
        },
        _ => false,
    }
}

pub fn extract(body: &Value, format: SummaryFormat) -> SummaryConfig {
    match format {
        SummaryFormat::Responses => responses_config(body, "reasoning.summary")
            .or_else(|| responses_config(body, "reasoning.generate_summary"))
            .unwrap_or_default(),
        SummaryFormat::Claude => {
            if !claude_thinking_accepts_display(body) {
                return SummaryConfig::default();
            }
            claude_config(body, "thinking.display").unwrap_or_default()
        }
    }
}

fn parent_mut<'a>(
    body: &'a mut Value,
    path: &str,
) -> Option<(&'a mut serde_json::Map<String, Value>, String)> {
    let (parents, leaf) = path
        .rsplit_once('.')
        .map(|(p, l)| (p, l.to_string()))
        .unwrap_or(("", path.to_string()));
    let mut node = body;
    if !parents.is_empty() {
        for segment in parents.split('.') {
            if !node.get(segment).map(Value::is_object).unwrap_or(false) {
                node.as_object_mut()?.insert(segment.to_string(), json!({}));
            }
            node = node.get_mut(segment)?;
        }
    }
    Some((node.as_object_mut()?, leaf))
}

fn set(body: &mut Value, path: &str, value: Value) {
    if let Some((parent, leaf)) = parent_mut(body, path) {
        parent.insert(leaf, value);
    }
}

fn remove(body: &mut Value, path: &str) {
    let (parents, leaf) = match path.rsplit_once('.') {
        Some((p, l)) => (p, l),
        None => ("", path),
    };
    let mut node = body;
    for segment in parents.split('.').filter(|s| !s.is_empty()) {
        match node.get_mut(segment) {
            Some(next) => node = next,
            None => return,
        }
    }
    if let Some(object) = node.as_object_mut() {
        object.remove(leaf);
    }
}

pub fn apply(body: &mut Value, format: SummaryFormat, config: &SummaryConfig) {
    if config.mode == SummaryMode::Unspecified {
        return;
    }
    let enabled = config.is_enabled();
    match format {
        SummaryFormat::Claude => {
            if !claude_thinking_accepts_display(body) {
                return;
            }
            set(
                body,
                "thinking.display",
                json!(if enabled { "summarized" } else { "omitted" }),
            );
        }
        SummaryFormat::Responses => {
            if enabled {
                set(
                    body,
                    "reasoning.summary",
                    json!(normalized_detail(&config.detail)),
                );
                remove(body, "reasoning.generate_summary");
                return;
            }

            remove(body, "reasoning.summary");
            remove(body, "reasoning.generate_summary");
            if at(body, "reasoning")
                .map(|r| r.as_object().is_some_and(|o| o.is_empty()))
                .unwrap_or(false)
            {
                remove(body, "reasoning");
            }
        }
    }
}

pub fn relay(
    client: &Value,
    client_format: SummaryFormat,
    upstream: &mut Value,
    upstream_format: SummaryFormat,
) {
    apply(
        upstream,
        upstream_format,
        &extract(client, client_format).or_visible_default(),
    );
}

fn normalized_detail(detail: &str) -> &'static str {
    match lower(detail).as_str() {
        "concise" => "concise",
        "detailed" => "detailed",
        _ => "auto",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_display_is_the_intent() {
        let summarized = json!({"thinking": {"type": "adaptive", "display": "summarized"}});
        assert_eq!(
            extract(&summarized, SummaryFormat::Claude).mode,
            SummaryMode::Enabled
        );
        let omitted = json!({"thinking": {"type": "adaptive", "display": "omitted"}});
        assert_eq!(
            extract(&omitted, SummaryFormat::Claude).mode,
            SummaryMode::Disabled
        );

        let bare = json!({"thinking": {"type": "adaptive"}, "output_config": {"effort": "high"}});
        assert_eq!(
            extract(&bare, SummaryFormat::Claude).mode,
            SummaryMode::Unspecified
        );
    }

    #[test]
    fn claude_display_on_disabled_thinking_is_not_an_intent() {
        let body = json!({"thinking": {"type": "disabled", "display": "summarized"}});
        assert_eq!(
            extract(&body, SummaryFormat::Claude).mode,
            SummaryMode::Unspecified
        );
        let zero_budget =
            json!({"thinking": {"type": "enabled", "budget_tokens": 0, "display": "summarized"}});
        assert_eq!(
            extract(&zero_budget, SummaryFormat::Claude).mode,
            SummaryMode::Unspecified
        );
    }

    #[test]
    fn responses_summary_is_an_explicit_opt_in() {
        let effort_only = json!({"reasoning": {"effort": "high"}});
        assert_eq!(
            extract(&effort_only, SummaryFormat::Responses).mode,
            SummaryMode::Unspecified
        );
        let auto = json!({"reasoning": {"effort": "high", "summary": "auto"}});
        assert_eq!(
            extract(&auto, SummaryFormat::Responses).mode,
            SummaryMode::Enabled
        );
        let detailed = json!({"reasoning": {"summary": "detailed"}});
        assert_eq!(
            extract(&detailed, SummaryFormat::Responses).detail,
            "detailed"
        );
        let null = json!({"reasoning": {"effort": "high", "summary": null}});
        assert_eq!(
            extract(&null, SummaryFormat::Responses).mode,
            SummaryMode::Disabled
        );
    }

    #[test]
    fn silence_resolves_to_visible() {
        let codex = json!({"reasoning": {"effort": "medium"}});
        let mut responses = json!({"reasoning": {"effort": "medium"}});
        relay(
            &codex,
            SummaryFormat::Responses,
            &mut responses,
            SummaryFormat::Responses,
        );
        assert_eq!(responses["reasoning"]["summary"], json!("auto"));
    }

    #[test]
    fn responses_summary_is_written_and_removed() {
        let mut on = json!({"reasoning": {"effort": "high"}});
        apply(
            &mut on,
            SummaryFormat::Responses,
            &SummaryConfig::enabled("detailed"),
        );
        assert_eq!(on["reasoning"]["summary"], json!("detailed"));

        let mut off = json!({"reasoning": {"effort": "high", "summary": "auto"}});
        apply(
            &mut off,
            SummaryFormat::Responses,
            &SummaryConfig::disabled(),
        );
        assert!(off["reasoning"].get("summary").is_none());
        assert_eq!(off["reasoning"]["effort"], json!("high"));

        let mut empty = json!({"reasoning": {"summary": "auto"}});
        apply(
            &mut empty,
            SummaryFormat::Responses,
            &SummaryConfig::disabled(),
        );
        assert!(empty.get("reasoning").is_none());
    }

    #[test]
    fn claude_upstream_display_needs_active_thinking() {
        let mut active = json!({"thinking": {"type": "enabled", "budget_tokens": 2048}});
        apply(
            &mut active,
            SummaryFormat::Claude,
            &SummaryConfig::enabled("auto"),
        );
        assert_eq!(active["thinking"]["display"], json!("summarized"));

        let mut disabled = json!({"thinking": {"type": "disabled"}});
        let before = disabled.clone();
        apply(
            &mut disabled,
            SummaryFormat::Claude,
            &SummaryConfig::enabled("auto"),
        );
        assert_eq!(disabled, before);
    }

    #[test]
    fn an_absent_intent_writes_nothing() {
        let mut codex = json!({"reasoning": {"effort": "high"}});
        apply(
            &mut codex,
            SummaryFormat::Responses,
            &extract(
                &json!({"thinking": {"type": "adaptive"}, "output_config": {"effort": "high"}}),
                SummaryFormat::Claude,
            ),
        );
        assert!(codex["reasoning"].get("summary").is_none());
    }
}
