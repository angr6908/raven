#!/usr/bin/env bun
// Generate a Codex model catalog covering every model raven serves.
//
// Codex keeps model metadata (context window, compaction limit, reasoning
// levels, base instructions) in a catalog keyed by model slug. A slug it does
// not recognise — which is every `model@Provider` alias raven serves — falls
// back to generic defaults and prints:
//
//   Model metadata for `X` not found. Defaulting to fallback metadata; this
//   can degrade performance and cause issues.
//
// Codex reads a replacement catalog from the `model_catalog_json` config key.
// This builds one: it lifts Codex's own catalog out of the binary (so the
// native models keep working, and so raven's entries inherit real base
// instructions instead of invented ones), then clones a template entry per
// model in raven's /v1/models, overriding only what raven actually knows.
//
// The catalog is written inside this repo and nothing outside it is touched —
// point Codex at it per launch, so no global config is involved:
//
//   bun scripts/codex-model-catalog.mjs
//   codex -c model_catalog_json=<repo>/data/codex-models.json ...
//
// Re-run after adding a provider or model. `--out` overrides the location, and
// `--default-context <tokens>` sets the window for models the panel has not
// given one (the launcher passes its own fallback, so a /model switch inside a
// session compacts where the launch would have).

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from "node:fs"
import { homedir } from "node:os"
import path from "node:path"

const CATALOG_START = '{\n  "models": [\n    {\n      "slug"'
const DEFAULT_TEMPLATE = "gpt-5.6-terra"

const args = new Map()
for (let i = 2; i < process.argv.length; i += 2) {
  args.set(process.argv[i].replace(/^--/, ""), process.argv[i + 1])
}

const root = path.dirname(import.meta.dir)
const template = args.get("template") ?? DEFAULT_TEMPLATE
const baseUrl = args.get("base-url") ?? "http://127.0.0.1:3458/v1"
const out = args.get("out") ?? path.join(root, "data", "codex-models.json")
const providersPath = args.get("providers") ?? path.join(root, "data", "providers.json")
// Window for a model the panel left unconfigured. Unset (or 0) means "fall
// back to whatever /v1/models advertises".
const defaultContext = Number(args.get("default-context") ?? 0)

/** The real codex executable — the npm shim on PATH is a tiny wrapper. */
function findCodex() {
  const candidates = [
    args.get("codex"),
    path.join(
      homedir(),
      ".bun/install/global/node_modules/@openai/codex-darwin-arm64",
      "vendor/aarch64-apple-darwin/bin/codex",
    ),
    Bun.which("codex"),
  ].filter(Boolean)
  for (const candidate of candidates) {
    if (existsSync(candidate) && statSync(candidate).size > 50_000_000) return candidate
  }
  throw new Error("codex binary not found; pass --codex <path>")
}

/** Pull the catalog JSON that Codex embeds in its own binary. */
function extractBuiltinCatalog(binary) {
  const data = readFileSync(binary)
  const start = data.indexOf(CATALOG_START)
  if (start < 0) {
    throw new Error("no embedded catalog in this codex build; its layout may have changed")
  }
  const QUOTE = 34, BACKSLASH = 92, OPEN = 123, CLOSE = 125
  let depth = 0, inString = false, escaped = false, end = -1
  for (let i = start; i < data.length; i++) {
    const byte = data[i]
    if (escaped) { escaped = false; continue }
    if (inString) {
      if (byte === BACKSLASH) escaped = true
      else if (byte === QUOTE) inString = false
      continue
    }
    if (byte === QUOTE) inString = true
    else if (byte === OPEN) depth++
    else if (byte === CLOSE && --depth === 0) { end = i + 1; break }
  }
  if (end < 0) throw new Error("embedded catalog is not brace-balanced")
  return JSON.parse(data.subarray(start, end).toString("utf8"))
}

/** alias → the effort levels its provider entry declares, when it declares any. */
function declaredEfforts() {
  let providers
  try {
    providers = JSON.parse(readFileSync(providersPath, "utf8"))
  } catch {
    return new Map()
  }
  const efforts = new Map()
  for (const provider of providers) {
    for (const model of provider.models ?? []) {
      const alias = model.alias ?? model.name
      const levels = model.thinking?.levels
      if (alias && levels) efforts.set(alias, levels.map((l) => String(l).toLowerCase()))
    }
  }
  return efforts
}

/**
 * The context window to write for a model — the figure Codex sizes /context
 * against and compacts at, never a cap on the request.
 *
 * `max_context_length` is published by raven only for a model whose panel entry
 * carries a context window, so it is the configured truth. `context_length` is
 * always present (it falls back to a 1M ceiling for anything unconfigured),
 * which is why the launcher's `--default-context` is preferred over it: a model
 * nobody has configured should compact where the launch itself would, not at a
 * guessed ceiling.
 */
function contextWindowFor(model) {
  for (const candidate of [
    model.max_context_length,
    defaultContext,
    model.context_length,
  ]) {
    if (Number.isInteger(candidate) && candidate > 0) return candidate
  }
  return undefined
}

function buildEntry(base, model, efforts) {
  const entry = structuredClone(base)
  entry.slug = model.id
  entry.display_name = model.display_name || model.id
  entry.description = `Served by raven (${model.owned_by ?? "provider"}).`

  const context = contextWindowFor(model)
  if (context) {
    entry.context_window = context
    entry.max_context_window = context
    // Codex compacts at this many tokens; keep the template's headroom ratio.
    entry.auto_compact_token_limit = Math.max(Math.floor(context * 0.75), 1)
  }

  // Keep only the presets this model actually offers, so Codex's effort picker
  // cannot select one the upstream rejects. Unknown → leave the template's.
  const presets = entry.supported_reasoning_levels ?? []
  if (efforts?.length && presets.length) {
    const kept = presets.filter((p) => efforts.includes(String(p.effort ?? "").toLowerCase()))
    if (kept.length) {
      entry.supported_reasoning_levels = kept
      if (!efforts.includes(String(entry.default_reasoning_level ?? "").toLowerCase())) {
        entry.default_reasoning_level = kept[0].effort
      }
    }
  }
  entry.visibility = "list"
  delete entry.upgrade
  delete entry.availability_nux
  return entry
}

const keyFile = path.join(root, ".raven-key")
const apiKey = args.get("api-key") ?? (existsSync(keyFile) ? readFileSync(keyFile, "utf8").trim() : "")

const catalog = extractBuiltinCatalog(findCodex())
const builtin = new Map(catalog.models.map((m) => [m.slug, m]))
if (!builtin.has(template)) {
  throw new Error(`template ${template} not in this codex build; have: ${[...builtin.keys()].join(", ")}`)
}

const response = await fetch(`${baseUrl.replace(/\/$/, "")}/models`, {
  headers: { "x-api-key": apiKey },
})
if (!response.ok) throw new Error(`raven /models returned ${response.status}; is it running?`)
const models = (await response.json()).data ?? []
if (models.length === 0) throw new Error("raven returned no models")

const efforts = declaredEfforts()
const entries = [...catalog.models]
for (const model of models) {
  // A native slug: Codex's own metadata is authoritative.
  if (builtin.has(model.id)) continue
  entries.push(buildEntry(builtin.get(template), model, efforts.get(model.id)))
}

mkdirSync(path.dirname(out), { recursive: true })
writeFileSync(out, JSON.stringify({ models: entries }, null, 2))
console.log(`wrote ${out}: ${catalog.models.length} built-in + ${entries.length - catalog.models.length} raven models`)
console.log(`use it with:  codex -c model_catalog_json=${out} ...`)
