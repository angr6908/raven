# Raven

One LaunchAgent (`com.raven`, KeepAlive) runs one process: the Rust proxy
`core/raven`, which serves the OpenAI-compatible API *and* the built panel on
`:3458`. State lives in `data/` (`accounts.json` 0600, `usage.jsonl`,
`prices.json`).

- `/v1/...`, `/health` — clients
- `/api/...` — panel (same origin), served from `app/dist`
- `:3459` — dev only: `cd app && bun run dev` (Vite, proxies `/api` → :3458)

## Commands

| Task | Command |
| ---- | ------- |
| Restart | `launchctl kickstart -k gui/$(id -u)/com.raven` |
| State | `launchctl list \| grep com.raven` |
| Panel up | `curl -sI http://127.0.0.1:3458/` |
| Proxy up | `curl -s http://127.0.0.1:3458/health` |
| Logs | `tail -f ~/Library/Logs/raven/stderr.log` |
| Run by hand | `cd core && ./raven -working-dir .. -data-dir ../data` |

## Rebuild

Panel — live immediately, no restart:

```bash
cd app && bun run build      # bun install only after package.json changes
```

Proxy — replace the binary with a *fresh file* and re-sign, then restart:

```bash
cd core && cargo build --release
rm -f raven && cp target/release/raven raven && codesign -s - -f raven
launchctl kickstart -k gui/$(id -u)/com.raven
```

> Copying over the running binary in place leaves a stale cached code
> signature and launchd kills every start with `OS_REASON_CODESIGNING`.

## LaunchAgent

`~/Library/LaunchAgents/com.raven.plist` — install with
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.raven.plist`.
Keys: `Label` `com.raven`; `ProgramArguments`
`<repo>/core/raven -working-dir <repo> -data-dir <repo>/data`;
`WorkingDirectory` `<repo>`; `RunAtLoad`, `KeepAlive` true;
`ThrottleInterval` 10; `ProcessType` `Interactive`; std out/err to
`~/Library/Logs/raven/`. Paths must be absolute.

## When nothing comes up

1. `plutil -lint ~/Library/LaunchAgents/com.raven.plist`
2. `tail -50 ~/Library/Logs/raven/stderr.log` — missing binary, bad auth file,
   port conflict, `panel: no index.html`
3. `lsof -nP -iTCP:3458 -sTCP:LISTEN` — port free?
4. `launchctl kickstart -k gui/$(id -u)/com.raven`
5. Still exiting: `launchctl print gui/$(id -u)/com.raven` → `last exit code`
