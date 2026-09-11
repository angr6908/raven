# Raven

One LaunchAgent (`com.raven`, KeepAlive) runs one process: the Rust proxy
`core/raven`, which serves the OpenAI-compatible API *and* the built panel on
`:3458`. State lives in `data/` (`accounts.json` 0600, `usage.jsonl`,
`prices.json`).

- `/v1/...`, `/health` — clients
- `/api/...` — panel (same origin), served from `app/dist`
- `:3459` — dev only: `cd app && bun run dev` (Vite, proxies `/api` → :3458)
- `:51121` — loopback, bound only while an Antigravity Google sign-in is in
  flight (OAuth callback); a new sign-in replaces the previous listener

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

## Launcher

`launcher/` is a native macOS 27 SwiftUI app (Swift 6.4, Observation, Liquid
Glass) that lists a provider's models and launches Claude Code or Codex against
one in Terminal. Its config lives in `~/.raven/config.json`.

Needs Command Line Tools for Xcode 27 (`softwareupdate --list`), no Xcode.

```bash
cd launcher && swift build -c release && scripts/make-app.sh   # → build/Raven.app
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

The 27.0 SDK declares `@State` as a compiler macro whose plugin ships only
inside Xcode, so the launcher keeps all view state in `@Observable` objects and
uses no `@State`. The same applies to Swift Testing's `@Test`, hence the
explicit plugin path above.

## When nothing comes up

1. `plutil -lint ~/Library/LaunchAgents/com.raven.plist`
2. `tail -50 ~/Library/Logs/raven/stderr.log` — missing binary, bad auth file,
   port conflict, `panel: no index.html`
3. `lsof -nP -iTCP:3458 -sTCP:LISTEN` — port free?
4. `launchctl kickstart -k gui/$(id -u)/com.raven`
5. Still exiting: `launchctl print gui/$(id -u)/com.raven` → `last exit code`
