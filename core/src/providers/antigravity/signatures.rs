use std::collections::HashMap;
use std::sync::Mutex;

const CAPACITY: usize = 512;

#[derive(Default)]
pub struct Signatures {
    entries: Mutex<(HashMap<String, String>, Vec<String>)>,
}

impl Signatures {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn remember(&self, tool_call_id: &str, signature: &str) {
        if tool_call_id.is_empty() || signature.is_empty() {
            return;
        }
        let Ok(mut entries) = self.entries.lock() else {
            return;
        };
        let (map, order) = &mut *entries;
        if map.insert(tool_call_id.to_string(), signature.to_string()).is_none() {
            order.push(tool_call_id.to_string());
        }
        while order.len() > CAPACITY {
            let oldest = order.remove(0);
            map.remove(&oldest);
        }
    }

    pub fn get(&self, tool_call_id: &str) -> Option<String> {
        self.entries
            .lock()
            .ok()
            .and_then(|entries| entries.0.get(tool_call_id).cloned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signatures_round_trip_by_tool_call_id() {
        let store = Signatures::new();
        store.remember("call_1", "c2ln");
        assert_eq!(store.get("call_1").as_deref(), Some("c2ln"));
        assert_eq!(store.get("call_2"), None);

        store.remember("", "x");
        store.remember("call_3", "");
        assert_eq!(store.get("call_3"), None);
    }

    #[test]
    fn the_store_evicts_the_oldest_entries() {
        let store = Signatures::new();
        for index in 0..(CAPACITY + 10) {
            store.remember(&format!("call_{index}"), "sig");
        }
        assert_eq!(store.get("call_0"), None);
        assert_eq!(store.get(&format!("call_{}", CAPACITY + 9)).as_deref(), Some("sig"));
    }
}
