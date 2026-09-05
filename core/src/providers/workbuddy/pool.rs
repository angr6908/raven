use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::auth::Auth;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CoolKind {
    #[default]
    CoolHard,
    CoolSoft,
    CoolErr,
}

impl CoolKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            CoolKind::CoolHard => "hard_credit",
            CoolKind::CoolSoft => "soft_rate",
            CoolKind::CoolErr => "error_threshold",
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub uid: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub nickname: String,
    pub credits: i64,
    pub cooling: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub cool_kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cool_remaining_sec: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub until: Option<i64>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub reason: String,
    pub disabled: bool,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub success_count: i64,
    #[serde(skip_serializing_if = "is_zero_i64")]
    pub err_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_success: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_err: Option<i64>,
}

fn is_zero_i64(v: &i64) -> bool {
    *v == 0
}

struct Entry {
    auth: Arc<Mutex<Auth>>,
    credits: i64,
    success_count: i64,
    err_count: i64,
    last_err: Option<i64>,
    last_success: Option<i64>,
    cool_kind: CoolKind,
    until: Option<i64>,
    disabled: bool,
    reason: String,
}

impl Entry {
    fn healthy(&self, now_unix: i64) -> bool {
        if self.disabled {
            return false;
        }
        if let Some(until) = self.until {
            if now_unix < until {
                return false;
            }
        }
        true
    }
}

pub use crate::translate::ids::now_unix_secs as now_unix;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct StateAccount {
    #[serde(default)]
    credits: i64,
    #[serde(default)]
    disabled: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    reason: String,
    #[serde(default)]
    until: Option<i64>,
    #[serde(default)]
    cool_kind: CoolKind,
    #[serde(default, skip_serializing_if = "is_zero_i64")]
    success_count: i64,
    #[serde(default, skip_serializing_if = "is_zero_i64")]
    err_count: i64,
    #[serde(default)]
    last_success: Option<i64>,
    #[serde(default)]
    last_err: Option<i64>,
}

#[derive(Default)]
struct PoolInner {
    by_uid: HashMap<String, Entry>,
    dirty: bool,

    snapshot_seq: u64,
}

pub struct Pool {
    inner: Mutex<PoolInner>,

    last_written: Mutex<u64>,
    state_fp: PathBuf,
}

const FLUSH_INTERVAL: Duration = Duration::from_secs(5);

fn empty_auth(uid: &str) -> Arc<Mutex<Auth>> {
    Arc::new(Mutex::new(Auth {
        access_token: String::new(),
        refresh_token: String::new(),
        expires_at: 0,
        domain: String::new(),
        uid: uid.to_string(),
        enterprise_id: String::new(),
        nickname: String::new(),
        account_name: uid.to_string(),
    }))
}

impl Pool {
    pub fn new(state_fp: PathBuf) -> Arc<Self> {
        let pool = Arc::new(Self {
            inner: Mutex::new(PoolInner::default()),
            last_written: Mutex::new(0),
            state_fp,
        });
        pool.load();
        {
            let spawn = Arc::clone(&pool);
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(FLUSH_INTERVAL).await;
                    spawn.flush_if_dirty();
                }
            });
        }
        pool
    }

    fn flush_if_dirty(&self) {
        let snapshot = {
            let mut inner = self.inner.lock().unwrap();
            if !inner.dirty {
                return;
            }
            inner.dirty = false;
            snapshot_locked(&mut inner)
        };
        self.write_snapshot(snapshot);
    }

    fn write_snapshot(&self, snapshot: Option<(u64, Vec<u8>)>) {
        let Some((seq, raw)) = snapshot else {
            return;
        };
        if self.state_fp.as_os_str().is_empty() {
            return;
        }
        let mut last = self.last_written.lock().unwrap();
        if seq <= *last {
            return;
        }
        if let Some(dir) = self.state_fp.parent() {
            let _ = fs::create_dir_all(dir);
        }
        let tmp = self.state_fp.with_extension("tmp");
        if fs::write(&tmp, &raw).is_err() {
            return;
        }
        if fs::rename(&tmp, &self.state_fp).is_ok() {
            *last = seq;
        }
    }

    pub fn flush(&self) {
        self.flush_if_dirty();
    }

    pub fn sync_to_auths(&self, auths: Vec<Arc<Mutex<Auth>>>) {
        let mut inner = self.inner.lock().unwrap();
        let mut seen: HashMap<String, Arc<Mutex<Auth>>> = HashMap::new();
        for auth in auths {
            let uid = auth.lock().unwrap().uid.clone();
            seen.insert(uid.clone(), auth);
            if let Some(existing) = inner.by_uid.get_mut(&uid) {
                existing.auth = seen[&uid].clone();
            } else {
                let auth = seen[&uid].clone();
                inner.by_uid.insert(
                    uid,
                    Entry {
                        auth,
                        credits: 0,
                        success_count: 0,
                        err_count: 0,
                        last_err: None,
                        last_success: None,
                        cool_kind: CoolKind::CoolHard,
                        until: None,
                        disabled: false,
                        reason: String::new(),
                    },
                );
            }
        }
        let mut changed = false;
        inner.by_uid.retain(|uid, _| {
            let keep = seen.contains_key(uid);
            changed |= !keep;
            keep
        });
        if !changed {
            return;
        }
        inner.dirty = true;
        let snapshot = snapshot_locked(&mut inner);
        drop(inner);
        self.write_snapshot(snapshot);
    }

    pub fn pick(&self) -> Option<Arc<Mutex<Auth>>> {
        self.pick_excluding(&HashMap::new())
    }

    pub fn pick_excluding(&self, tried: &HashMap<String, bool>) -> Option<Arc<Mutex<Auth>>> {
        let mut inner = self.inner.lock().unwrap();
        let now = now_unix();

        let mut cand_uids: Vec<String> = inner
            .by_uid
            .iter()
            .filter(|(uid, e)| !tried.contains_key(*uid) && e.healthy(now))
            .map(|(uid, _)| uid.clone())
            .collect();
        if cand_uids.is_empty() {
            return None;
        }
        cand_uids.sort_by(|a, b| {
            let ea = &inner.by_uid[a];
            let eb = &inner.by_uid[b];
            eb.credits.cmp(&ea.credits).then_with(|| a.cmp(b))
        });

        let chosen = &cand_uids[0];
        let entry = inner.by_uid.get_mut(chosen).expect("picked uid present");
        Some(entry.auth.clone())
    }

    pub fn cooldown(&self, uid: &str, kind: CoolKind, d: Duration, reason: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(e) = inner.by_uid.get_mut(uid) {
            e.until = Some(now_unix() + d.as_secs() as i64);
            e.cool_kind = kind;
            e.reason = reason.to_string();
            e.err_count = 0;
            inner.dirty = true;
        }
    }

    pub fn cooldown_until_tomorrow_4am(&self, uid: &str, reason: &str) {
        let until = next_day_4am();
        let d = until.saturating_sub(now_unix()).max(1) as u64;
        self.cooldown(uid, CoolKind::CoolHard, Duration::from_secs(d), reason);
    }

    pub fn disable(&self, uid: &str, reason: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(e) = inner.by_uid.get_mut(uid) {
            e.disabled = true;
            e.reason = reason.to_string();
            inner.dirty = true;
        }
    }

    pub fn reenable_if_credits(&self, uid: &str, remain: i64) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(e) = inner.by_uid.get_mut(uid) {
            e.credits = remain;
            if remain > 0 && !e.disabled {
                let now = now_unix();
                let breaker_active =
                    e.cool_kind == CoolKind::CoolErr && e.until.is_some_and(|u| u > now);
                if !breaker_active {
                    e.until = None;
                    e.cool_kind = CoolKind::CoolHard;
                    e.reason = String::new();
                    e.err_count = 0;
                }
            }
            inner.dirty = true;
        }
    }

    pub fn note_error(&self, uid: &str, threshold: i64, d: Duration) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(e) = inner.by_uid.get_mut(uid) {
            e.err_count += 1;
            e.last_err = Some(now_unix());
            if e.err_count >= threshold {
                e.until = Some(now_unix() + d.as_secs() as i64);
                e.cool_kind = CoolKind::CoolErr;
                e.reason = "consecutive errors".to_string();
                e.err_count = 0;
            }
            inner.dirty = true;
        }
    }

    pub fn note_success(&self, uid: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(e) = inner.by_uid.get_mut(uid) {
            e.success_count += 1;
            e.last_success = Some(now_unix());
            e.err_count = 0;
            inner.dirty = true;
        }
    }

    pub fn auth_by_uid(&self, uid: &str) -> Option<Arc<Mutex<Auth>>> {
        let inner = self.inner.lock().unwrap();
        inner.by_uid.get(uid).map(|e| e.auth.clone())
    }

    pub fn counts_detailed(&self) -> (usize, usize, usize, usize) {
        let inner = self.inner.lock().unwrap();
        let now = now_unix();
        let mut total = 0;
        let mut healthy = 0;
        let mut cooling = 0;
        let mut disabled = 0;
        for e in inner.by_uid.values() {
            total += 1;
            if e.disabled {
                disabled += 1;
            } else if e.until.is_some_and(|u| now < u) {
                cooling += 1;
            } else {
                healthy += 1;
            }
        }
        (total, healthy, cooling, disabled)
    }

    pub fn list(&self) -> Vec<Status> {
        let inner = self.inner.lock().unwrap();
        let mut uids: Vec<&String> = inner.by_uid.keys().collect();
        uids.sort();
        let now = now_unix();
        uids.into_iter()
            .map(|uid| status_of(uid, inner.by_uid.get(uid).expect("key present"), now))
            .collect()
    }

    fn load(&self) {
        let Ok(raw) = fs::read(&self.state_fp) else {
            return;
        };
        let Ok(sf) = serde_json::from_slice::<StateFile>(&raw) else {
            return;
        };
        let mut inner = self.inner.lock().unwrap();
        for (uid, s) in sf.accounts {
            inner.by_uid.insert(
                uid.clone(),
                Entry {
                    auth: empty_auth(&uid),
                    credits: s.credits,
                    disabled: s.disabled,
                    reason: s.reason,
                    until: s.until,
                    cool_kind: s.cool_kind,
                    success_count: s.success_count,
                    err_count: s.err_count,
                    last_err: s.last_err,
                    last_success: s.last_success,
                },
            );
        }
    }
}

#[derive(Serialize, Deserialize)]
struct StateFile {
    #[serde(default)]
    accounts: HashMap<String, StateAccount>,
}

fn snapshot_locked(inner: &mut PoolInner) -> Option<(u64, Vec<u8>)> {
    inner.snapshot_seq += 1;
    let accounts: HashMap<String, StateAccount> = inner
        .by_uid
        .iter()
        .map(|(uid, e)| {
            (
                uid.clone(),
                StateAccount {
                    credits: e.credits,
                    disabled: e.disabled,
                    reason: e.reason.clone(),
                    until: e.until,
                    cool_kind: e.cool_kind,
                    success_count: e.success_count,
                    err_count: e.err_count,
                    last_success: e.last_success,
                    last_err: e.last_err,
                },
            )
        })
        .collect();
    let raw = serde_json::to_vec_pretty(&StateFile { accounts }).ok()?;
    Some((inner.snapshot_seq, raw))
}

fn status_of(uid: &String, e: &Entry, now: i64) -> Status {
    let cooling = e.until.is_some_and(|u| now < u);
    let nickname = e.auth.lock().unwrap().nickname.clone();
    let mut st = Status {
        uid: uid.clone(),
        nickname,
        credits: e.credits,
        cooling,
        cool_kind: String::new(),
        cool_remaining_sec: None,
        until: None,
        reason: e.reason.clone(),
        disabled: e.disabled,
        success_count: e.success_count,
        err_count: e.err_count,
        last_success: e.last_success,
        last_err: e.last_err,
    };
    if cooling {
        if let Some(until) = e.until {
            let remaining = (until - now).max(0);
            st.cool_remaining_sec = Some(remaining);
            st.cool_kind = e.cool_kind.as_str().to_string();
            st.until = Some(until);
        }
    }
    st
}

fn next_day_4am() -> i64 {
    use chrono::TimeZone;
    let now = chrono::Local::now();
    let tomorrow = now.date_naive().succ_opt().unwrap_or(now.date_naive());
    let naive = tomorrow.and_hms_opt(4, 0, 0).expect("valid time");
    chrono::Local
        .from_local_datetime(&naive)
        .single()
        .map(|dt| dt.timestamp())
        .unwrap_or_else(|| now.timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn auth(uid: &str) -> Arc<Mutex<Auth>> {
        Arc::new(Mutex::new(Auth {
            access_token: String::new(),
            refresh_token: String::new(),
            expires_at: 0,
            domain: String::new(),
            uid: uid.to_string(),
            enterprise_id: String::new(),
            nickname: String::new(),
            account_name: uid.to_string(),
        }))
    }

    fn uid_of(auth: Arc<Mutex<Auth>>) -> String {
        auth.lock().unwrap().uid.clone()
    }

    #[tokio::test]
    async fn pick_drains_the_richest_account_until_it_exhausts() {
        let pool = Pool::new(PathBuf::new());
        pool.sync_to_auths(vec![auth("a"), auth("b")]);
        pool.reenable_if_credits("a", 100);
        pool.reenable_if_credits("b", 200);

        assert_eq!(uid_of(pool.pick().unwrap()), "b");
        assert_eq!(uid_of(pool.pick().unwrap()), "b");
        assert_eq!(uid_of(pool.pick().unwrap()), "b");

        pool.cooldown_until_tomorrow_4am("b", "余额不足");
        assert_eq!(uid_of(pool.pick().unwrap()), "a");

        let mut tried = HashMap::new();
        tried.insert("a".to_string(), true);
        assert!(pool.pick_excluding(&tried).is_none());
    }

    #[tokio::test]
    async fn equal_credits_drain_in_stable_uid_order() {
        let pool = Pool::new(PathBuf::new());
        pool.sync_to_auths(vec![auth("b"), auth("a")]);
        pool.reenable_if_credits("a", 50);
        pool.reenable_if_credits("b", 50);

        assert_eq!(uid_of(pool.pick().unwrap()), "a");
        assert_eq!(uid_of(pool.pick().unwrap()), "a");
    }

    #[tokio::test]
    async fn checkin_thaws_balance_and_rate_cooling() {
        let pool = Pool::new(PathBuf::new());
        pool.sync_to_auths(vec![auth("u1")]);

        pool.cooldown_until_tomorrow_4am("u1", "余额不足");
        pool.reenable_if_credits("u1", 500);
        let st = pool.list().remove(0);
        assert_eq!(st.credits, 500);
        assert!(
            !st.cooling,
            "hard-credit cooling must be thawed by check-in"
        );
        assert!(pool.pick().is_some());

        pool.cooldown(
            "u1",
            CoolKind::CoolSoft,
            Duration::from_secs(60),
            "429 rate limit",
        );
        pool.reenable_if_credits("u1", 480);
        assert!(
            pool.pick().is_some(),
            "soft-rate cooling must be thawed by check-in"
        );
    }

    #[tokio::test]
    async fn checkin_does_not_clear_error_cooling() {
        let pool = Pool::new(PathBuf::new());
        pool.sync_to_auths(vec![auth("u1")]);
        pool.cooldown_until_tomorrow_4am("u1", "余额不足");
        pool.cooldown(
            "u1",
            CoolKind::CoolErr,
            Duration::from_secs(600),
            "consecutive errors",
        );
        pool.reenable_if_credits("u1", 500);

        let st = pool.list().remove(0);
        assert_eq!(st.credits, 500, "credits still refresh on check-in");
        assert!(st.cooling, "error cooldown must survive check-in");
        assert_eq!(st.cool_kind, "error_threshold");
        assert!(
            pool.pick().is_none(),
            "account stays unpickable while error-cooled"
        );

        pool.cooldown(
            "u1",
            CoolKind::CoolErr,
            Duration::from_secs(0),
            "consecutive errors",
        );
        assert!(
            pool.pick().is_some(),
            "expired error cooldown is pickable again"
        );
    }
}
