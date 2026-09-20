#!/usr/bin/env bash
#
# Raven launcher.
#
# Pick a client (Claude Code / Codex / Grok) and a model, then
# launch it against the local raven proxy. Also usable from a terminal:
#
#   ./raven.sh                        interactive
#   r                                    launch the saved default combination directly (no pickers)
#   ./raven.sh claude kimi-k3         launch Claude Code on kimi-k3
#   ./raven.sh codex minimax-m3 high  launch Codex on minimax-m3, high effort
#   ./raven.sh grok muse-spark-1.2-contributor@Vercel high  launch grok on the proxy model (web search off)
#   ./raven.sh claude deepseek/deepseek-v4-flash-free  launch Claude Code on the OrcaRouter free model via the proxy
#   ./raven.sh codex openai/gpt-5.6-sol    launch Codex on GPT-5.6 Sol (OrcaRouter) via the proxy
#   ./raven.sh claude deepseek/deepseek-v4-flash-0731  launch Claude Code on the OpenRouter model via the proxy
#   ./raven.sh --dir ~/src/app …      run the client in that directory
#   ./raven.sh -m gpt-5.6-sol …       -m/--model also names the model
#   ./raven.sh codex resume           pick from every recorded session
#   ./raven.sh codex resume <id>      replay that session
#   ./raven.sh models                 list what the proxy is serving
#   ./raven.sh status|start|stop|restart|logs
#
# Effort is optional and is passed on only when named here — left out, the
# client starts at whatever it remembers, and switching it from inside the
# client sticks. The client always runs in the current directory unless --dir
# says otherwise, so run it from the project you want to target.
#
# Context window: the client is told the window configured for the picked model
# in the panel (Providers / Accounts → "Context window", one click from
# models.dev), and FALLBACK_CTX_WINDOW below for a model that has none. It only
# decides where the client's /context bar fills up and where auto-compaction
# fires — nothing here caps what raven forwards upstream.
#
# Default combination: typing 0 in the client or model picker walks through
# choosing a client + model and saves the pair to defaults.conf; a blank reply
# in either picker then launches that pair. RAVEN_DEFAULT_CLIENT and
# RAVEN_DEFAULT_MODEL env vars outrank the saved file on read.

set -euo pipefail

# Where the client will end up running. Captured before the cd below, so a
# terminal launch keeps the shell's own directory.
INVOKED_PWD="$PWD"

# How this script was invoked: the `r` symlink skips every picker and launches
# the saved default combination straight away. Captured before SELF resolves
# the symlink below back to this file.
INVOKED_AS="$(basename "$0")"

# Double-clicking starts in $HOME, so anchor to this file's directory. Symlinks
# are resolved first: invoked through one (e.g. ~/.local/bin/r), BASH_SOURCE
# is the link itself, and anchoring there would look for configs, auths and
# plugins next to the link instead of next to the real script.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *)  SELF="$(cd "$(dirname "$SELF")" && pwd)/$LINK" ;;
  esac
done
APP_DIR="$(cd "$(dirname "$SELF")" && pwd)"
cd "$APP_DIR"

PROXY_URL="${PROXY_URL:-http://127.0.0.1:3458}"
PROXY_KEY="${PROXY_KEY:-claude-code-local}"
# The wire format grok speaks to the proxy; see grok_real_home_anchor().
GROK_API_BACKEND="${GROK_API_BACKEND:-responses}"
SERVICE="com.raven"
PLIST="$HOME/Library/LaunchAgents/$SERVICE.plist"
LOG="$HOME/Library/Logs/raven/stderr.log"

# bun-installed clients (codex) land in ~/.bun/bin and release binaries in
# ~/.local/bin, which only .zshrc puts on PATH — Finder double-clicks never
# source it, so add both here explicitly.
case ":$PATH:" in
  *":$HOME/.bun/bin:"*) ;;
  *) [ -d "$HOME/.bun/bin" ] && PATH="$HOME/.bun/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;;
esac

# The default combination is the client + model a blank reply to the client and
# model pickers launches. Option 0 in either menu ("Set default combination")
# rewrites defaults.conf to a new pair and the launch continues with it. Env
# vars RAVEN_DEFAULT_CLIENT / RAVEN_DEFAULT_MODEL outrank the file on read.
DEFAULTS="$APP_DIR/defaults.conf"

load_defaults() {
  DEF_CLIENT="${RAVEN_DEFAULT_CLIENT:-}"
  DEF_MODEL="${RAVEN_DEFAULT_MODEL:-}"
  [ -f "$DEFAULTS" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      client) if [ -n "$value" ]; then DEF_CLIENT="$value"; fi ;;
      model)  if [ -n "$value" ]; then DEF_MODEL="$value"; fi ;;
    esac
  done < "$DEFAULTS"
  # Env vars outrank the file.
  DEF_CLIENT="${RAVEN_DEFAULT_CLIENT:-$DEF_CLIENT}"
  DEF_MODEL="${RAVEN_DEFAULT_MODEL:-$DEF_MODEL}"
}

# The context window a client is told to compact against when the panel has
# not configured one for the picked model. It is an auto-compact/`/context`
# figure only — nothing here caps what raven forwards upstream. A model that
# *does* carry a window in the panel (Providers / Accounts → "Context window",
# fetchable from models.dev) overrides this per client; see model_window().
FALLBACK_CTX_WINDOW=200000

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

# When launched from Finder there is no terminal to read the error, so hold the
# window open instead of vanishing on failure.
INTERACTIVE_LAUNCH=0
[ -t 0 ] && [ $# -gt 0 ] || INTERACTIVE_LAUNCH=1

die() {
  printf '\033[31merror:\033[0m %s\n' "$*" >&2
  if [ "$INTERACTIVE_LAUNCH" = 1 ]; then
    printf '\nPress return to close.'
    read -r _ || true
  fi
  exit 1
}

# --------------------------------------------------------------- options -----
WORKDIR="${RAVEN_WORKDIR:-}"
MODEL_OPT=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dir) [ $# -ge 2 ] || die "--dir needs a path"; WORKDIR="$2"; shift 2 ;;
    --dir=*)  WORKDIR="${1#--dir=}"; shift ;;
    -m|--model) [ $# -ge 2 ] || die "--model needs a model id"; MODEL_OPT="$2"; shift 2 ;;
    --model=*) MODEL_OPT="${1#--model=}"; shift ;;
    *)        ARGS+=("$1"); shift ;;
  esac
done
set -- ${ARGS+"${ARGS[@]}"}
# An explicit model outranks both the positional slot and one recovered from a
# resumed session, so "-m foo … resume <id>" reads as "foo". The merge happens
# in the pickers block below, after "resume" has been detected in the
# positional model slot.

# ---------------------------------------------------------------- service ----
case "${1:-}" in
  status)  launchctl print "gui/$(id -u)/$SERVICE" | grep -E 'state|pid'; exit ;;
  stop)    launchctl bootout "gui/$(id -u)/$SERVICE"; exit ;;
  start)   launchctl bootstrap "gui/$(id -u)" "$PLIST"; exit ;;
  restart) launchctl kickstart -k "gui/$(id -u)/$SERVICE"; exit ;;
  logs)    tail -f "$LOG"; exit ;;
esac

# ------------------------------------------------------------ model lookup ---
# Ask raven what it is serving, so the picker stays in sync with the catalog.
fetch_models() {
  curl -fsS -m 10 "$PROXY_URL/v1/models" -H "Authorization: Bearer $PROXY_KEY" 2>/dev/null
}

# Emits "id<TAB>group" per line, chat-capable models only.
# $1 = client (blank when just listing).
parse_models() {
  ruby -rjson -e '
    client = ARGV[0]
    groups = {
      "openai" => "Codex / OpenAI",
      "CommandCode" => "Command Code",
      "antigravity" => "Antigravity",
    }
    skip = /\A(gpt-image-|codex-auto-review)/
    # Codex already serves its own OAuth models natively, so there is no point
    # offering them here.
    redundant = ->(m) { client == "codex" && m["owned_by"] == "openai" }
    seen = {}
    JSON.parse($stdin.read)["data"]
      .reject { |m| m["id"] =~ skip }
      .reject { |m| redundant.call(m) }
      .select { |m| (seen[m["id"]] ? false : (seen[m["id"]] = true)) }
      .sort_by { |m| [(groups.keys.index(m["owned_by"]) || 99), groups[m["owned_by"]] || m["owned_by"], m["id"]] }
      .each { |m| puts "#{m["id"]}\t#{groups[m["owned_by"]] || m["owned_by"]}" }
  ' "$1"
}

MODELS_RAW=""
# The catalog JSON behind MODELS_RAW, kept so the per-model window lookups
# below need no second request.
MODELS_JSON=""
load_models() {
  [ -n "$MODELS_RAW" ] && return
  local raw
  if ! raw="$(fetch_models)"; then
    # Offer to start the service rather than dead-ending on a connection error.
    printf '\033[33mraven proxy not reachable at %s\033[0m\n' "$PROXY_URL"
    read -r -p "start it now? [Y/n]: " yn
    case "${yn:-y}" in
      [Yy]*) launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || true
             sleep 3
             raw="$(fetch_models)" || die "still not reachable — check: $0 logs" ;;
      *) die "proxy is not running" ;;
    esac
  fi
  MODELS_JSON="$raw"
  MODELS_RAW="$(printf '%s' "$raw" | parse_models "${1:-}")"
  [ -n "$MODELS_RAW" ] || die "proxy returned no usable models"
}

print_models() {
  printf '%s\n' "$MODELS_RAW" | awk -F'\t' -v numbered="$1" '
    $2 != last { printf "\n\033[1m%s\033[0m\n", $2; last = $2 }
    numbered   { printf "  %2d) %s\n", NR, $1; next }
               { printf "  %s\n", $1 }'
}

# Is a model id in the proxy's live list? (First column of MODELS_RAW.)
model_served() {
  printf '%s\n' "$MODELS_RAW" | cut -f1 | grep -Fxq -- "$1"
}

# A blank model reply means "the saved default, else the native DeepSeek id".
# Dies only when the proxy serves neither.
resolve_default_model() {
  if model_served "$DEF_MODEL"; then
    MODEL="$DEF_MODEL"
  elif model_served 'deepseek/deepseek-v4-flash'; then
    MODEL='deepseek/deepseek-v4-flash'
  else
    die "no model selected"
  fi
}

# The context window the panel configured for a model, or empty when it did
# not configure one. raven publishes `max_context_length` on /v1/models for
# exactly the models whose entry carries a "Context window" — `context_length`
# is always present (it falls back to a 1M ceiling), so only the explicit field
# can tell a real setting from that fallback. $1 = model id.
#
# This is an auto-compaction figure for the client, never a request limit: it
# decides where /context fills up and where the client compacts, and raven keeps
# forwarding whatever the client sends either way.
model_window() {
  [ -n "$MODELS_JSON" ] || return 0
  printf '%s' "$MODELS_JSON" | ruby -rjson -e '
    id = ARGV[0]
    data = (JSON.parse($stdin.read)["data"] rescue []) || []
    entry = data.find { |m| m["id"] == id } or exit
    win = entry["max_context_length"]
    puts win if win.is_a?(Integer) && win > 0
  ' "$1" 2>/dev/null
}

# The same lookup with the fallback applied — always a usable number.
# $1 = model id.
model_window_or_fallback() {
  local win
  win="$(model_window "$1")"
  printf '%s' "${win:-$FALLBACK_CTX_WINDOW}"
}

# "id<TAB>window" for every model in $1 (comma-separated) that has a window
# configured in the panel. Models without one are omitted: grok inherits their
# window from the catalog it fetches (raven advertises `context_window` there),
# and writing a guess into its per-model pin would outrank that.
model_windows() {
  local ids="$1"
  [ -z "$ids" ] && return 0
  [ -n "$MODELS_JSON" ] || return 0
  printf '%s' "$MODELS_JSON" | ruby -rjson -e '
    ids = ARGV[0].split(",")
    data = (JSON.parse($stdin.read)["data"] rescue []) || []
    windows = {}
    data.each do |m|
      win = m["max_context_length"]
      windows[m["id"]] = win if win.is_a?(Integer) && win > 0
    end
    ids.each { |id| puts [id, windows[id]].join("\t") if windows[id] }
  ' "$ids" 2>/dev/null
}

# grok keeps its model config in per-model [model."<id>"] tables. A proxy model
# without one has no API key of its own, so grok falls back to session auth and
# opens the OAuth/device login welcome screen instead of talking to the endpoint
# the catalog names. Pinning the model to the proxy key makes every launch (and
# every in-session /model switch) use the Bearer key the proxy accepts.
#
# The pin also names the wire format. Grok speaks three (chat_completions,
# responses, messages) and the proxy serves all three, but only the Responses
# API carries a turn whole: reasoning replays as its own item with the
# `encrypted_content` blob that upstream Claude and Gemini models require to
# accept a signed thought back, a response schema stays on the wire instead of
# being demoted to a synthetic tool call, and the prompt-cache key survives (on
# the other two grok cannot send one at all, so its recap/side calls stop
# sharing the parent turn's cache). The proxy's /v1/models catalog advertises
# `api_backend: responses` for the same reason; the pin states it outright so
# the choice does not depend on which build of the proxy answers.
#
# Every grok launch runs with the real ~/.grok home; this is what keeps it
# proxy-routed. The endpoint key and per-model tables are added only when
# missing (idempotent and append-only), grok preserves [model.*] tables it
# did not write itself, and a key the user configured manually is left
# alone. The [models] default is synced to the launcher's chosen model so
# a bare `grok` from a terminal launches the same proxy default instead of
# dropping into the OAuth welcome screen. Pins also carry the context window
# configured for the model in the panel, which is what grok compacts against
# ("[model.<id>].context_window"; without one grok assumes 200K for a model it
# does not know). $1 = comma-separated model ids, $2 = default model.
grok_real_home_anchor() {
  local ids="$1" def_model="$2" cfg="$HOME/.grok/config.toml"
  [ -n "$ids" ] || return 0
  mkdir -p "$(dirname "$cfg")"
  [ -f "$cfg" ] || : > "$cfg"
  # "id=window" pairs for the models the panel gave a window to; the rest keep
  # whatever the fetched catalog says.
  local windows
  windows="$(model_windows "$ids" | awk -F'\t' '{printf "%s%s=%s", sep, $1, $2; sep=","}')"
  ruby -rset -e '
    path, base, key, backend, ids, def_model, windows = ARGV
    windows = windows.to_s.split(",").map { |pair|
      id, win = pair.split("=", 2)
      [id, win] if id && win && !win.empty?
    }.compact.to_h
    ids = ids.split(",").reject(&:empty?)
    lines = (File.read(path) rescue "").lines
    text  = lines.join
    have  = ->(re) { lines.any? { |l| l =~ re } }
    out   = lines.dup
    insert_after = ->(header_re, body) {
      done = false
      out  = out.flat_map do |line|
        if !done && line =~ header_re
          done = true
          [line, body]
        else
          line
        end
      end
    }
    # Point plain grok at the proxy catalog, API-key auth instead of session
    # (OAuth) auth.
    #
    # A stale value here is worse than none: `[endpoints]` in the file outranks
    # GROK_MODELS_BASE_URL (grok reads the env var only as the default for a
    # field the file omits), so a leftover URL from an older proxy port silently
    # wins over the one this launch exports. grok then cannot fetch a catalog at
    # all, falls back to whatever `models_cache.json` still holds, and every
    # model it offers comes from the [model.*] pins below — entries that carry no
    # effort menu and no real context window, which is what "current model does
    # not support reasoning effort" means.
    #
    # So a loopback URL (this proxy, on whatever port it used to run) is
    # rewritten to the current one, while a genuinely remote endpoint is left
    # alone: that is a deliberate choice by whoever set it, not our leftovers.
    base_line = "models_base_url = \"#{base}\"\n"
    existing = out.index { |l| l =~ /^\s*models_base_url\s*=/ }
    if existing
      current = out[existing][/=\s*"([^"]*)"/, 1].to_s
      loopback = current.start_with?("http://127.0.0.1", "http://localhost")
      out[existing] = base_line if loopback && current != base
    elsif have.call(/^\s*\[endpoints\]\s*$/)
      insert_after.call(/^\s*\[endpoints\]\s*$/, base_line)
    else
      out << "[endpoints]\n#{base_line}"
    end
    # Every served model gets a pin, so none of them falls into the OAuth
    # welcome when picked in a bare grok session.
    ids.each do |id|
      next if have.call(/^\s*\[model\.\s*"#{Regexp.escape(id)}"\s*\]\s*$/)
      pin = "[model.\"#{id}\"]\napi_key = \"#{key}\"\napi_backend = \"#{backend}\"\n"
      pin += "context_window = #{windows[id]}\n" if windows[id]
      out << pin
    end
    # Bring pins written by an earlier launcher onto the current wire format.
    # Only tables holding the proxy key are ours to rewrite: a table the user
    # keyed themselves is their choice, and one pointing at another endpoint
    # would be broken by it. A pin that never named a backend gets one: the grok
    # default for an unnamed backend is chat_completions, not what we want.
    #
    # One line per element first: the pins appended above (and the [endpoints]
    # block) are single multi-line strings, and the split below keys on a line
    # being nothing but a table header.
    out = out.join.lines
    blocks = []
    out.each do |line|
      if line =~ /^\s*\[[^\]]+\]\s*$/ || blocks.empty?
        blocks << [line]
      else
        blocks.last << line
      end
    end
    # A pin raven wrote for a model the proxy no longer serves is dropped.
    #
    # A [model.*] table is itself a catalog entry: grok adds one for every pin,
    # whether or not the fetched catalog knows the id. A leftover pin therefore
    # shows up in the picker as a model that cannot be reached, and — having no
    # catalog entry to inherit from — carries no effort menu and the default
    # context window. Only pins holding the proxy key are ours to drop.
    served = ids.to_set
    ours = lambda do |block|
      block.first =~ /^\s*\[model\.[^\]]*\]\s*$/ &&
        block.any? { |l| l =~ /^\s*api_key\s*=\s*"#{Regexp.escape(key)}"\s*$/ }
    end
    blocks.reject! do |block|
      next false unless ours.call(block)
      id = block.first[/\[model\.\s*"?([^"\]]*?)"?\s*\]/, 1].to_s
      !served.include?(id)
    end
    blocks.each do |block|
      next unless ours.call(block)
      idx = block.index { |l| l =~ /^\s*api_backend\s*=/ }
      if idx
        block[idx] = "api_backend = \"#{backend}\"\n"
      else
        block.insert(1, "api_backend = \"#{backend}\"\n")
      end
      # Keep the compaction window in step with the panel. A pin outranks the
      # fetched catalog, so a window we wrote for a model the panel has since
      # cleared is dropped rather than left to outrank the catalog with a
      # stale number.
      id  = block.first[/\[model\.\s*"?([^"\]]*?)"?\s*\]/, 1].to_s
      at  = block.index { |l| l =~ /^\s*context_window\s*=/ }
      win = windows[id]
      if win
        line = "context_window = #{win}\n"
        at ? block[at] = line : block.insert(1, line)
      elsif at
        block.delete_at(at)
      end
    end
    out = blocks.flatten
    # Keep the default model in step with the launcher defaults.conf.
    set_default = lambda do |m|
      idx = out.index { |l| l =~ /^\s*\[models\]\s*$/ }
      unless idx
        out << "[models]\ndefault = \"#{m}\"\n"
        next
      end
      replaced = false
      (idx + 1...out.length).each do |i|
        break if i > idx && out[i] =~ /^\s*\[/
        if out[i] =~ /^\s*default\s*=/
          out[i] = "default = \"#{m}\"\n"
          replaced = true
          break
        end
      end
      out.insert(idx + 1, "default = \"#{m}\"\n") unless replaced
    end
    set_default.call(def_model)
    File.write(path, out.join) unless out.join == text
  ' "$cfg" "$PROXY_URL/v1" "$PROXY_KEY" "$GROK_API_BACKEND" "$ids" "$def_model" "$windows"
}

# The API key for the proxy is written into a file only the launcher can read,
# and models.yml references it via a `!cmd` that re-reads it on every launch —
# so the generated store never carries a copy of the secret, and a fresh key is
# picked up without a rewrite. $1 is the comma-separated model list to publish.
KEYFILE="${PROXY_KEY_FILE:-$APP_DIR/.raven-key}"
write_keyfile() {
  umask 077
  printf '%s\n' "$PROXY_KEY" > "$KEYFILE"
}

# Codex records the settings a session ran under, and its resume picker hides
# sessions whose cwd is not the current one. Recovering cwd/model/effort from the
# rollout means resuming by id needs neither --dir nor the model retyped, and the
# launcher's own routing still decides proxy-vs-direct from the model list.
# Emits "cwd<TAB>model<TAB>effort"; empty when no session matches.
session_meta() {
  local f
  f="$(find "$HOME/.codex/sessions" -name "*$1*.jsonl" -print -quit 2>/dev/null)"
  [ -n "$f" ] || return 0
  ruby -rjson -e '
    File.foreach(ARGV[0]).first(20).each do |line|
      j = JSON.parse(line) rescue next
      s = j.dig("payload", "thread_settings") or next
      print [s["cwd"], s["model"], s["reasoning_effort"]].join("\t")
      exit
    end' "$f" 2>/dev/null || true
}

# Walk the client and model pickers to choose a new default combination, persist
# it to defaults.conf, and set CLIENT/MODEL so the launch continues with it.
edit_defaults() {
  # The client menu. A blank reply keeps a client that is already default.
  bold "Edit default"
  echo "  Pick a client:"
  echo "  1) Claude Code"
  echo "  2) Codex"
  echo "  3) grok"
  echo
  read -r -p "client [${DEF_CLIENT:-1}]: " reply
  case "${reply:-$DEF_CLIENT}" in
    1|claude|claude-code) CLIENT=claude ;;
    2|codex)              CLIENT=codex ;;
    3|grok|grok-cli)      CLIENT=grok ;;
    *) die "unknown client: $reply" ;;
  esac
  echo

  # The model menu, from the proxy's live list. A blank reply keeps the current
  # default model (or the DeepSeek fallback when none is set yet).
  load_models "$CLIENT"
  print_models 1
  echo
  count=$(printf '%s\n' "$MODELS_RAW" | wc -l | tr -d ' ')
  read -r -p "model [${DEF_MODEL:-deepseek/deepseek-v4-flash}]: " pick
  if [ -z "$pick" ]; then
    if model_served "$DEF_MODEL"; then
      MODEL="$DEF_MODEL"
    else
      MODEL='deepseek/deepseek-v4-flash'
    fi
  else
    case "$pick" in
      *[!0-9]*) MODEL="$pick" ;;
      *) [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ] || die "pick out of range: $pick"
         MODEL=$(printf '%s\n' "$MODELS_RAW" | sed -n "${pick}p" | cut -f1) ;;
    esac
  fi
  # Store the pair. Writing the file is what makes the defaults sticky: a blank
  # reply in the client/model pickers of a later launch uses it.
  printf 'client=%s\nmodel=%s\n' "$CLIENT" "$MODEL" > "$DEFAULTS"
  DEF_CLIENT="$CLIENT"
  DEF_MODEL="$MODEL"
  # Keep a bare `grok` in step with the saved pair: the real ~/.grok config
  # gets the endpoint, pins and default model, so plain `grok` launches it.
  if [ "$CLIENT" = grok ]; then
    grok_real_home_anchor "$MODEL" "$MODEL"
  fi
  printf '\033[2m   default saved: %s on %s\033[0m\n' "$CLIENT" "$MODEL"
  # Editing the default is its own action: save and stop, don't launch.
  exit 0
}

if [ "${1:-}" = "models" ]; then
  load_models ""; print_models 0; echo; exit
fi

# -m/--model is absorbed above; the positional slots shift accordingly.
CLIENT="${1:-}"
MODEL="${MODEL:-${2:-}}"
EFFORT="${3:-}"

# ------------------------------------------------------------- working dir ---
# The client inherits whatever directory it is launched from, so this is the
# project it will be working on.
tilde() { printf '%s' "${1/#$HOME/~}"; }

# Resolve a possibly ~-prefixed path; fails if it is not a directory.
resolve_dir() {
  local p="${1/#\~/$HOME}"
  [ -n "$p" ] || return 1
  (cd "$p" 2>/dev/null && pwd)
}

# ----------------------------------------------------------------- pickers ---
# "resume" is recognized in the positional model slot ($2) — "resume" there
# means replay, so the id lands in the effort slot ($3):
#   … codex resume              picker over every session (--all), not just this cwd
#   … codex resume <id> [effort]  replay that session; model and cwd come from it
RESUME=""
if [ "${2:-}" = resume ]; then
  RESUME="${EFFORT:-picker}"
  EFFORT="${4:-}"
  MODEL=""
fi
# Merge an explicit -m/--model into the model slot now that "resume" has been
# detected. It outranks both the positional model and one recovered from the
# resumed session.
MODEL="${MODEL_OPT:-$MODEL}"

# Load the saved default combination before any picker, so a blank reply and
# the "0" entries can consult it. Done here (after the client match) even though
# the interactive client menu only runs when not given on the command line —
# edit_defaults() relies on DEF_CLIENT/DEF_MODEL having been read already.
load_defaults

# Initialized here because the model picker below consults it even when the
# interactive client menu never ran — a command-line client (`… codex resume`)
# would otherwise die on the unset variable under `set -u`.
BLANK_CLIENT=""
# The bare `r` command (the `r` symlink in ~/.local/bin)
# skips every picker and launches the saved default combination — the default
# client on the default model — the same thing a blank reply in both pickers
# picks. Named arguments still win: `r claude kimi-k3` behaves exactly like the
# full invocation.
case "$INVOKED_AS" in
  r) if [ -z "$CLIENT" ] && [ -z "$MODEL" ] && [ -z "$MODEL_OPT" ] && [ -z "$RESUME" ]; then
  CLIENT="${DEF_CLIENT:-claude}"
  BLANK_CLIENT=1
fi ;;
esac

if [ -z "$CLIENT" ]; then
  echo
  bold "Raven"
  echo "  0) Edit Default"
  echo "  1) Claude Code"
  echo "  2) Codex"
  echo "  3) grok"
  echo
  read -r -p "client [${DEF_CLIENT:-1}]: " reply
  # A blank reply means "use the saved default". Remember that so the model
  # picker can be skipped entirely — one Enter then launches the default
  # combination instead of asking again for the model.
  BLANK_CLIENT=""
  [ -z "$reply" ] && BLANK_CLIENT=1
  case "${reply:-${DEF_CLIENT:-1}}" in
    0) edit_defaults ;;
    1|claude|claude-code)        CLIENT=claude ;;
    2|codex)                     CLIENT=codex ;;
    3|grok)                      CLIENT=grok ;;
    *) die "unknown client: $reply" ;;
  esac
fi

case "$CLIENT" in
  claude|claude-code)                CLIENT=claude ;;
  codex)                             CLIENT=codex ;;
  grok|grok-cli)                     CLIENT=grok ;;
  *) die "unknown client: $CLIENT (expected 'claude', 'codex' or 'grok')" ;;
esac

# Resuming a known id: recover what the session ran under, so only an explicit
# --dir or effort argument overrides it. The model still goes through the usual
# validation below, which catches a session whose model is no longer served.
if [ -n "$RESUME" ] && [ "$RESUME" != picker ] && [ "$CLIENT" = codex ]; then
  META="$(session_meta "$RESUME")"
  [ -n "$META" ] || die "no recorded session matching: $RESUME"
  [ -n "$WORKDIR" ] || WORKDIR="$(printf '%s' "$META" | cut -f1)"
  # An explicit -m/--model already decided the model; the session's is only a
  # fallback for a bare "resume <id>".
  [ -n "$MODEL" ] || MODEL="$(printf '%s' "$META" | cut -f2)"
  [ -n "$EFFORT" ] || EFFORT="$(printf '%s' "$META" | cut -f3)"
fi

# Every model is served by raven, so a named model still has to be in the
# proxy's list.
load_models "$CLIENT"

if [ -z "$MODEL" ] && [ -z "$BLANK_CLIENT" ]; then
  # Blank reply launches the saved default combination.
  # The default shown is what was saved, or the native DeepSeek V4 Flash id
  # when nothing has been saved yet.
  echo
  print_models 1
  echo
  count=$(printf '%s\n' "$MODELS_RAW" | wc -l | tr -d ' ')
  read -r -p "model [${DEF_MODEL:-deepseek/deepseek-v4-flash}]: " pick
  if [ -z "$pick" ]; then
    # Enter uses the saved/current default if it is being served, else the
    # native DeepSeek V4 Flash id.
    resolve_default_model
  else
    case "$pick" in
      *[!0-9]*) MODEL="$pick" ;;    # allow typing the name directly
      *) [ "$pick" -ge 1 ] && [ "$pick" -le "$count" ] || die "pick out of range: $pick"
         MODEL=$(printf '%s\n' "$MODELS_RAW" | sed -n "${pick}p" | cut -f1) ;;
    esac
  fi
fi
# The client picker was answered with a blank reply, so the model picker was
# skipped (one Enter = launch the saved default). Resolve the model the same
# way a blank reply in the model picker would have.
if [ -z "$MODEL" ] && [ "$BLANK_CLIENT" = 1 ]; then
  resolve_default_model
fi
# A named model still has to be served by the proxy.
printf '%s\n' "$MODELS_RAW" | cut -f1 | grep -qx -- "$MODEL" \
  || die "model '$MODEL' is not served by the proxy — see: $0 models"

# Nothing under ~/Downloads is ever a project, so a claude launch from the home
# directory would land in a folder of downloads. Send it to ~/Downloads instead;
# an explicit --dir and every other client still get the invoked directory.
if [ -z "$WORKDIR" ] && [ "$CLIENT" = claude ] && [ "$INVOKED_PWD" = "$HOME" ]; then
  [ -d "$HOME/Downloads" ] && WORKDIR="$HOME/Downloads"
fi

# Never asked for: the shell's own directory is almost always the project, and
# --dir covers the rest. A Finder double-click has no better answer than $HOME.
[ -n "$WORKDIR" ] || WORKDIR="$INVOKED_PWD"
# Keep the original spelling around: the assignment below blanks WORKDIR on
# failure, and the error should still name what was asked for.
WANTED_DIR="$WORKDIR"
WORKDIR="$(resolve_dir "$WORKDIR")" || die "not a directory: $WANTED_DIR"

# ------------------------------------------------------------ workspace trust ---
# Claude Code's "Accessing workspace / Is this a project you trust?" interstitial
# is gated on a per-directory flag in ~/.claude.json — global config, not a
# settings.json key — and nothing on the command line silences it:
# --dangerously-skip-permissions only skips permission prompts, and -p skips the
# dialog only because a non-interactive run has nobody to ask. So a launcher has
# to write the flag the dialog itself would have written.
#
# Two entries:
#   "/"        everything that is not inside a repository. The gate walks up from
#              the working directory and stops at a repo root, so "/" covers
#              ~/Downloads and the like but never a repo.
#   <repo root> the repository the launch is pointed at — the root, not the
#              working directory inside it: a nested repo is a boundary, and the
#              root is the key Claude Code records when you accept the dialog
#              interactively.
#
# Only ever adds the key. A malformed config may hold something other than an
# object where the entries go, so anything else found there is left untouched;
# breaking ~/.claude.json would cost the user far more than this dialog.
TRUST_HOME="${HOME:-}"
if [ "$CLIENT" = claude ] && [ -n "$TRUST_HOME" ] && [ -d "$TRUST_HOME" ]; then
  TRUST_JSON="$TRUST_HOME/.claude.json"
  TRUST_DIR="$(dirname "$TRUST_JSON")"
  # --show-toplevel prints the main checkout for a worktree, which is the key
  # Claude Code resolves there too. Outside a repository it fails, leaving the
  # "/" entry to cover the directory.
  TRUST_ROOT="$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$TRUST_ROOT" ]; then
    TRUST_ROOT="$(resolve_dir "$TRUST_ROOT")" || TRUST_ROOT=""
  fi
  if [ -w "$TRUST_DIR" ] && { [ ! -e "$TRUST_JSON" ] || [ -w "$TRUST_JSON" ]; }; then
    TRUST_NEW="$(mktemp "$TRUST_DIR/.claude.json.XXXXXX")" || TRUST_NEW=""
    if [ -n "$TRUST_NEW" ]; then
      # Ruby and not jq: ruby -i renames the new file over the old one, so a
      # session reading the config while this runs sees either whole version,
      # never a truncated one. `mv` in the shell would work too, but the write
      # and the replace are one step here.
      if ! TRUST_JSON="$TRUST_JSON" TRUST_NEW="$TRUST_NEW" TRUST_ROOT="$TRUST_ROOT" ruby -rjson -e '
        path, out, root = ENV.values_at("TRUST_JSON", "TRUST_NEW", "TRUST_ROOT")
        config = begin
          JSON.parse(File.read(path))
        rescue Errno::ENOENT
          {}
        rescue JSON::ParserError
          nil
        end
        if config.is_a?(Hash)
          projects = config["projects"]
          projects = config["projects"] = {} unless projects.is_a?(Hash)
          # "" if git is unavailable, which projects[""] would never match.
          [root, "/"].reject { |key| key.to_s.empty? }.each do |key|
            entry = projects[key]
            entry = projects[key] = {} unless entry.is_a?(Hash)
            entry["hasTrustDialogAccepted"] = true
          end
          File.write(out, JSON.pretty_generate(config) + "\n")
          File.rename(out, path)
        end
      '; then
        echo "raven: could not record workspace trust in $TRUST_JSON" >&2
      fi
      /bin/rm -f "$TRUST_NEW"
    fi
  fi
fi

# Effort is passed only when it was actually asked for. Every client treats the
# flag as a setting for the whole session, so defaulting it here would pin the
# session to that level and quietly outrank anything switched to later from
# inside the client.

# ------------------------------------------------------------------ launch ---
case "$CLIENT" in
  claude)   CLIENT_NAME='Claude Code' ;;
  codex)    CLIENT_NAME=Codex ;;
  grok)     CLIENT_NAME=Grok ;;
esac

printf '\n\033[1m→ %s\033[0m on \033[1m%s\033[0m%s\n' \
  "$CLIENT_NAME" "$MODEL" "${EFFORT:+ (effort: $EFFORT)}"
printf '\033[2m   in %s\033[0m\n\n' "$(tilde "$WORKDIR")"

cd "$WORKDIR"

if [ "$CLIENT" = claude ]; then
  # Claude Code speaks the Messages API natively. Every model goes through
  # raven, which translates Chat Completions/Responses ↔ Messages as needed.
  SLOT_MODEL="$MODEL"
  unset ANTHROPIC_API_KEY
  export ANTHROPIC_BASE_URL="$PROXY_URL"
  export ANTHROPIC_AUTH_TOKEN="$PROXY_KEY"

  # Pass the real model ID to Claude Code and keep subagents on the same model.
  export CLAUDE_CODE_SUBAGENT_MODEL="$SLOT_MODEL"
  export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1
  # Default every model slot to the chosen model, so /model jumps and background
  # tasks don't fall back to a built-in id this route can't serve.
  export ANTHROPIC_DEFAULT_OPUS_MODEL="$SLOT_MODEL"
  export ANTHROPIC_DEFAULT_SONNET_MODEL="$SLOT_MODEL"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL="$SLOT_MODEL"
  # xhigh and max are offered only for a model Claude Code knows supports them,
  # and for an unknown id that decision falls back to the provider — which is
  # never first-party once ANTHROPIC_BASE_URL points at the proxy. So both got
  # filtered out of the request whatever the picker said. Declaring the
  # capabilities on each slot is what removes that filter.
  SLOT_CAPS=effort,max_effort,xhigh_effort,adaptive_thinking,context_management
  export ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES="$SLOT_CAPS"
  export ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES="$SLOT_CAPS"
  export ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES="$SLOT_CAPS"
  # Claude Code assumes an unknown translated model has a 200K context window.
  # Tell it the real one, so /context fills up and auto-compact fires where the
  # model actually runs out — the window configured for this model in the panel
  # when there is one, the launcher fallback otherwise. Nothing here limits the
  # request: it is purely where the client compacts.
  #
  # A configured window wins even for a claude-* slug (the user set it for
  # exactly this route); without one, Claude Code's own metadata for such a
  # slug beats a blanket default, so only translated models are told.
  CONFIGURED_WINDOW="$(model_window "$SLOT_MODEL")"
  CONTEXT_WINDOW="${CONFIGURED_WINDOW:-$FALLBACK_CTX_WINDOW}"
  if [ -n "$CONTEXT_WINDOW" ]; then
    if [ -n "$CONFIGURED_WINDOW" ] || [[ "$SLOT_MODEL" != claude-* ]]; then
      export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CONTEXT_WINDOW"
    fi
    if [ "$CONTEXT_WINDOW" -le 1000000 ]; then
      export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CONTEXT_WINDOW"
    fi
  fi
  # OpenRouter caps the attribution header at 2K and rejects larger ones; keep it
  # off on every route so nothing depends on it.
  export CLAUDE_CODE_ATTRIBUTION_HEADER=0
  set -- --model "$SLOT_MODEL"
  # Claude Code's hosted WebSearch tool is not usable by translated, non-Claude
  # models: calls complete with zero searches/results and encourage pointless
  # retry loops. Remove the tool from those sessions entirely. Claude-family
  # models retain the normal Claude Code web-search behavior.
  if [[ "$SLOT_MODEL" != claude-* || "$SLOT_MODEL" == *@* ]]; then
    set -- "$@" --disallowedTools WebSearch
  fi
  if [ -n "$RESUME" ]; then
    if [ "$RESUME" = picker ]; then set -- "$@" --resume; else set -- "$@" --resume "$RESUME"; fi
  fi
  if [ -n "$EFFORT" ]; then
    set -- "$@" --effort "$EFFORT"
  fi
  exec claude "$@"
elif [ "$CLIENT" = grok ]; then
  # Grok is pointed at the proxy's OpenAI Responses endpoint
  # (api_backend = "responses"), which is the wire format its own models are
  # served over and the only one of the three that carries a whole turn — see
  # grok_real_home_anchor() for what the other two drop. Auth is a plain Bearer
  # API key either way. It runs with the real ~/.grok home: the anchor below
  # pins the endpoint and every served model (the backend + the proxy key) into
  # ~/.grok/config.toml, so this launch and a bare `grok` from a terminal both
  # talk to the proxy instead of the xAI OAuth welcome screen. No per-launch
  # runtime home is created.
  export GROK_MODELS_BASE_URL="$PROXY_URL/v1"
  export XAI_API_KEY="$PROXY_KEY"

  # Every launch starts from the proxy's live catalog, never a remembered one.
  # grok caches the fetched model list in ~/.grok/models_cache.json for five
  # minutes, so without this a model or effort level changed in the panel would
  # not show up until the cache aged out. It is a cache and nothing else: grok
  # refetches it from the endpoint below, one request to localhost.
  /bin/rm -f "$HOME/.grok/models_cache.json"

  # Keep the real ~/.grok config in step with the proxy catalog: the
  # endpoint base URL and per-model api_key pins are appended only when
  # missing (existing keys are never overwritten, so a manually set PIN is
  # left alone), and the default model is synced to the launcher's choice.
  # Idempotent, so a bare `grok` stays proxy-routed too.
  grok_real_home_anchor "$(printf '%s\n' "$MODELS_RAW" | cut -f1 | paste -sd, -)" "$MODEL"

  # The proxy's /v1/models list is what Grok catalogues from
  # GROK_MODELS_BASE_URL, so the picked alias/id maps straight onto --model.
  set -- --model "$MODEL"

  # Web search is disabled for grok sessions: the proxy's translated models
  # cannot drive Grok's hosted search, and it is wanted off regardless.
  set -- "$@" --disable-web-search

  # grok's embedded "Tool search" (search_tool) discovers MCP/integration tool
  # schemas; the proxy's translated models don't need it. --disallowed-tools
  # search_tool drops it from the callable set (verified: the tool no longer
  # appears; DISABLE_EMBEDDED_SEARCH_TOOLS alone did not remove it in 1.0.5).
  set -- "$@" --disallowed-tools search_tool

  if [ -n "$EFFORT" ]; then
    # Grok's canonical effort levels (none..max) match the thinking levels
    # config.yaml declares, so the same effort slot used by the other clients
    # maps straight onto --reasoning-effort (alias: --effort).
    set -- "$@" --reasoning-effort "$EFFORT"
  fi
  # grok splits resume like the other clients: a bare --resume continues the
  # most recent session for this directory, --resume <id> names a session.
  if [ -n "$RESUME" ]; then
    if [ "$RESUME" = picker ]; then set -- "$@" --resume; else set -- "$@" --resume "$RESUME"; fi
  fi
  exec grok "$@"
else
  # Codex speaks the Responses API natively. Every model goes through raven,
  # which translates the Responses API to the appropriate upstream protocol
  # (Command Code /alpha/generate for Command Code models, Antigravity
  # v1internal:streamGenerateContent for Antigravity models, and Chat
  # Completions / Responses for openai-compatibility providers).
  export RAVEN_API_KEY="$PROXY_KEY"
  set -- \
    -c model_provider=raven \
    -c model_providers.raven.name=Raven \
    -c "model_providers.raven.base_url=$PROXY_URL/v1" \
    -c model_providers.raven.wire_api=responses \
    -c model_providers.raven.env_key=RAVEN_API_KEY \
    -c model_providers.raven.request_max_retries=20 \
    -c model_providers.raven.stream_max_retries=20 \
    -m "$MODEL"
  # The window Codex compacts against: the one configured for this model in
  # the panel, else the launcher fallback. `model_context_window` overrides the
  # catalog entry for the model this session starts on; the catalog below
  # carries the same numbers for every other model, so an in-session /model
  # switch lands on the right window too.
  CONTEXT_WINDOW="$(model_window_or_fallback "$MODEL")"
  set -- "$@" -c "model_context_window=$CONTEXT_WINDOW"
  # Codex only has metadata for its own model slugs, so every `model@Provider`
  # alias falls back to generic defaults and warns. Rebuild the catalog from
  # whatever the proxy is serving right now so a model added since the last
  # launch is covered, then point Codex at it for this run only — nothing in
  # ~/.codex is touched. A failure here is not worth blocking a launch over:
  # the last good catalog is used if one exists, otherwise Codex just warns.
  CODEX_CATALOG="$APP_DIR/data/codex-models.json"
  if command -v bun >/dev/null 2>&1; then
    bun "$APP_DIR/scripts/codex-model-catalog.mjs" \
      --base-url "$PROXY_URL/v1" --api-key "$PROXY_KEY" --out "$CODEX_CATALOG" \
      --default-context "$FALLBACK_CTX_WINDOW" \
      >/dev/null 2>&1 || echo "raven: could not refresh the Codex model catalog; using the last one" >&2
  fi
  if [ -s "$CODEX_CATALOG" ]; then
    set -- "$@" -c "model_catalog_json=$CODEX_CATALOG"
  fi
  if [ -n "$EFFORT" ]; then
    set -- "$@" -c "model_reasoning_effort=$EFFORT"
  fi
  # The subcommand has to lead, so the overrides above are prefixed rather than
  # appended. --all drops the picker's cwd filter, which is what hides sessions
  # started from another directory.
  if [ -n "$RESUME" ]; then
    if [ "$RESUME" = picker ]; then set -- resume --all "$@"; else set -- resume "$RESUME" "$@"; fi
  fi
  exec codex "$@"
fi
