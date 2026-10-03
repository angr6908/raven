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

## Shell commands

`raven.sh` at the repo root is the interactive launcher: pick a client (Claude
Code / Codex / grok) and a model, or name both inline. Typing `0` at the client
picker runs Edit Default, which saves a pair to `defaults.conf`; a later blank
reply launches it.

`raven` opens the pickers; `r` skips them and launches the pair in
`defaults.conf` directly — the same thing a blank reply in both pickers does.
Both take the script's arguments: `r codex minimax-m3 high`,
`raven --dir ~/src/app …`.

### Setup on a new machine

From the repo root — `~/.local/bin` must exist and be on `PATH`; a fresh macOS
ships with neither:

```bash
mkdir -p ~/.local/bin
ln -sf "$PWD/raven.sh" ~/.local/bin/raven
ln -sf "$PWD/raven.sh" ~/.local/bin/r
```

Then append the rc lines. zsh (the macOS default) needs both; bash only the
first, in `~/.bashrc`:

```zsh
export PATH="$HOME/.local/bin:$PATH"   # zsh: ~/.zshrc; bash: ~/.bashrc
alias r="$HOME/.local/bin/r"           # zsh only
```

`r` is also a zsh builtin (history redo), which outranks `PATH`, so zsh needs
an alias over the symlink — bash has no such builtin and resolves the symlink
straight off `PATH`. The alias must point at the symlink, never at `raven.sh`
itself: the script reads `$0` to tell `r` from `raven`. Open a new shell (or
source the rc file), and `raven` / `r` work.

A macOS login bash reads `~/.bash_profile` before `~/.bashrc`; if one exists,
put the `export PATH` line there instead.

## Launcher

`launcher/` is a native macOS 27 AppKit app (Swift 6.4, Observation, Liquid
Glass primitives) that is both launchers and panel in one binary: it launches
Claude Code or Codex against a chosen model, and ports the whole web panel —
Overview, Usage, Accounts, Models, Pricing — against the proxy's `/api/...`
routes. Config stays in `~/Documents/raven/data/config.json` (schema
unchanged, so `raven.sh` and the web panel keep sharing it).

Three sidebar groups — *Library* (All Models / Pinned / Recents), *Providers*,
*Panel* — over a single searchable list of every model across every provider,
so there is no "pick a provider first" step. *All Models* and *Pinned* group
by provider; a single provider groups by `owned_by`. The detail side swaps
child view controllers per destination; the bottom glass bar is the whole
launch action on launcher pages (selected model, client, folder, **Launch**,
⌘↩). Per-model settings (pin, context window) live in the row's context menu
and the Launch menu.

Reactivity is `@Observable` stores + `ObservationTracker`
(`withObservationTracking`, re-registered on the main actor, paused on
`viewWillDisappear`). Panel state lives in singletons: `UsageStore` (SSE
`/api/usage/stream`, 3 s reconnect, 15 s health poll), `AccountsStore` (15 s
poll while the page is visible), `ProvidersPanelStore` and `PricingStore`
(whole-doc PUT / bare-map POST behind a shared 600 ms `AutoSaveScheduler`);
saving prices calls `UsageStore.reprice()` since the server reprices at query
time. First paint comes from `panel-usage-cache.json` /
`panel-quota-cache.json` in the data dir. ⌘R reloads what you are looking at —
the active provider, or a fresh GET of the panel page; ⇧⌘R refreshes every
provider.

Build and test need only Command Line Tools for Xcode 27
(`softwareupdate --list`); `scripts/make-app.sh` additionally calls
`/Applications/Xcode.app`'s `actool` to compile `resources/AppIcon.icon`, so
bundling wants full Xcode.

```bash
cd launcher && swift build -c release && scripts/make-app.sh   # → build/Raven.app
swift test -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

The plugin path is for Swift Testing's `@Test` compiler macro. `Package.swift`
sets `defaultIsolation(MainActor.self)`, so types and `Task {}` bodies are
main-actor unless marked `nonisolated` — wire types, parsers and format
helpers are the `nonisolated` ones; every `@Observable` store is `@MainActor`.

`RAVEN_DATA_DIR` overrides `~/Documents/raven/data` (useful for trying the
first-launch flow against an empty directory).

## When nothing comes up

1. `plutil -lint ~/Library/LaunchAgents/com.raven.plist`
2. `tail -50 ~/Library/Logs/raven/stderr.log` — missing binary, bad auth file,
   port conflict, `panel: no index.html`
3. `lsof -nP -iTCP:3458 -sTCP:LISTEN` — port free?
4. `launchctl kickstart -k gui/$(id -u)/com.raven`
5. Still exiting: `launchctl print gui/$(id -u)/com.raven` → `last exit code`
