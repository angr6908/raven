use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Local};

use super::auth::Auth;
use super::client::{Client, ErrKind};
use super::pool::Pool;

const CHECKIN_HOURS: [u32; 2] = [9, 21];
const KEEPALIVE_HOURS: [u32; 1] = [22];

fn next_fire(
    now: chrono::DateTime<chrono::Local>,
    hours: &[u32],
) -> chrono::DateTime<chrono::Local> {
    use chrono::TimeZone;
    let mut earliest: Option<chrono::DateTime<chrono::Local>> = None;
    for h in hours {
        let naive = now.date_naive().and_hms_opt(*h, 0, 0).expect("valid time");
        let mut t = chrono::Local
            .from_local_datetime(&naive)
            .earliest()
            .unwrap_or(now);
        if t <= now {
            t = t + chrono::Duration::days(1);
        }
        earliest = Some(match earliest {
            Some(e) => e.min(t),
            None => t,
        });
    }
    earliest.unwrap_or(now + chrono::Duration::days(1))
}

pub async fn run_checkin_now(pool: &Arc<Pool>, client: &Client) {
    for st in pool.list() {
        if st.disabled {
            continue;
        }
        let Some(auth) = pool.auth_by_uid(&st.uid) else {
            continue;
        };

        let snapshot = auth.lock().unwrap().clone();
        if snapshot.refresh_token.is_empty() {
            continue;
        }
        if let Err(err) = client.daily_checkin(&snapshot).await {
            eprintln!("checkin {}: {err}", st.uid);
        }
        let remain = match client.user_resource(&snapshot).await {
            Ok(remain) => remain,
            Err(err) => {
                eprintln!("user-resource {}: {err}", st.uid);
                continue;
            }
        };
        pool.reenable_if_credits(&st.uid, remain);
    }
}

pub async fn run_keepalive_now(
    pool: &Arc<Pool>,
    client: &Client,
    save_auth: &(dyn Fn(&Auth) + Send + Sync),
) {
    for st in pool.list() {
        if st.disabled {
            continue;
        }
        let Some(auth) = pool.auth_by_uid(&st.uid) else {
            continue;
        };
        let has_refresh = !auth.lock().unwrap().refresh_token.is_empty();
        if !has_refresh {
            continue;
        }
        if let Err(err) = client.refresh_token(&auth).await {
            eprintln!("keepalive {}: {err}", st.uid);
            let kind = match &err {
                super::client::Error { kind, .. } => *kind,
            };
            if kind == ErrKind::SessionDead {
                pool.disable(&st.uid, "12153 session dead");
            }
            continue;
        }
        let snapshot = auth.lock().unwrap().clone();
        save_auth(&snapshot);
    }
}

const SLEEP_CHUNK: Duration = Duration::from_secs(60);

fn last_fired(now: DateTime<Local>, hours: &[u32]) -> Option<DateTime<Local>> {
    use chrono::TimeZone;
    let mut latest: Option<DateTime<Local>> = None;
    for h in hours {
        let naive = now.date_naive().and_hms_opt(*h, 0, 0)?;
        let mut t = chrono::Local.from_local_datetime(&naive).earliest()?;
        if t > now {
            t -= chrono::Duration::days(1);
        }
        latest = Some(latest.map_or(t, |l| l.max(t)));
    }
    latest
}

fn take_due(last_run: &mut Option<i64>, fired: DateTime<Local>) -> bool {
    let ts = fired.timestamp();
    if last_run.is_some_and(|t| t >= ts) {
        return false;
    }
    *last_run = Some(ts);
    true
}

pub async fn run_loop(
    pool: Arc<Pool>,
    client: Client,
    save_auth: Arc<dyn Fn(&Auth) + Send + Sync>,
) {
    let mut all_hours: Vec<u32> = Vec::new();
    all_hours.extend_from_slice(&CHECKIN_HOURS);
    all_hours.extend_from_slice(&KEEPALIVE_HOURS);

    let mut last_checkin: Option<i64> = None;
    let mut last_keepalive: Option<i64> = None;

    loop {
        let now = chrono::Local::now();
        let next = next_fire(now, &all_hours);
        let delay = (next - now)
            .to_std()
            .unwrap_or(SLEEP_CHUNK)
            .min(SLEEP_CHUNK);
        tokio::time::sleep(delay).await;

        let now = chrono::Local::now();
        if let Some(f) = last_fired(now, &CHECKIN_HOURS) {
            if take_due(&mut last_checkin, f) {
                run_checkin_now(&pool, &client).await;
            }
        }
        if let Some(f) = last_fired(now, &KEEPALIVE_HOURS) {
            if take_due(&mut last_keepalive, f) {
                run_keepalive_now(&pool, &client, save_auth.as_ref()).await;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Local, TimeZone};

    fn at(h: u32, m: u32) -> DateTime<Local> {
        Local
            .with_ymd_and_hms(2026, 9, 2, h, m, 0)
            .single()
            .unwrap()
    }

    #[test]
    fn last_fired_picks_todays_latest_past_instant() {
        assert_eq!(last_fired(at(10, 30), &CHECKIN_HOURS), Some(at(9, 0)));

        assert_eq!(last_fired(at(22, 30), &CHECKIN_HOURS), Some(at(21, 0)));

        assert_eq!(
            last_fired(at(8, 0), &CHECKIN_HOURS),
            Local.with_ymd_and_hms(2026, 9, 1, 21, 0, 0).single()
        );
        assert_eq!(last_fired(at(23, 0), &KEEPALIVE_HOURS), Some(at(22, 0)));
    }

    #[test]
    fn take_due_claims_each_instant_once() {
        let mut last: Option<i64> = None;

        assert!(take_due(&mut last, at(9, 0)));

        assert!(!take_due(&mut last, at(9, 0)));

        assert!(take_due(&mut last, at(21, 0)));
        assert!(!take_due(&mut last, at(21, 0)));
    }

    #[test]
    fn sleep_chunk_bounds_the_monotonic_sleep() {
        let now = at(23, 59);
        let next = next_fire(now, &[9, 21, 22]);
        let unbounded = (next - now).to_std().unwrap();
        assert!(unbounded > SLEEP_CHUNK * 2);
        assert_eq!(unbounded.min(SLEEP_CHUNK), SLEEP_CHUNK);
    }
}
