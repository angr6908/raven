import { useEffect, useState } from "react"
import { Plus, Trash2, X } from "lucide-react"

import { Input } from "@/components/ui/input"
import { Button } from "@/components/ui/button"
import { Switch } from "@/components/ui/switch"
import { cn, errorMessage } from "@/lib/utils"
import {
  type ProviderEntry,
  type ProviderModelDef,
  fetchEffortLevels,
  fetchModelsDev,
  formatContextWindow,
  friendlyLookupError,
  stripModelVendorAndProvider,
} from "@/lib/api"

const FALLBACK_EFFORT_LEVELS: readonly string[] = [
  "none",
  "minimal",
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
]

let effortLevelsCache: readonly string[] | null = null
let effortLevelsPromise: Promise<readonly string[]> | null = null

function loadEffortLevels(): Promise<readonly string[]> {
  if (effortLevelsCache) return Promise.resolve(effortLevelsCache)
  if (!effortLevelsPromise) {
    effortLevelsPromise = fetchEffortLevels()
      .then((levels) => {
        if (levels.length === 0) throw new Error("empty effort-levels")
        effortLevelsCache = levels
        return levels
      })
      .catch(() => {
        effortLevelsPromise = null
        return FALLBACK_EFFORT_LEVELS
      })
  }
  return effortLevelsPromise
}

function useEffortLevels(): readonly string[] {
  const [levels, setLevels] = useState<readonly string[]>(
    () => effortLevelsCache ?? FALLBACK_EFFORT_LEVELS
  )
  useEffect(() => {
    if (effortLevelsCache) return
    let cancelled = false
    void loadEffortLevels().then((resolved) => {
      if (!cancelled) setLevels(resolved)
    })
    return () => {
      cancelled = true
    }
  }, [])
  return levels
}

function smartAliasFor(modelName: string, providerName: string): string {
  const base = stripModelVendorAndProvider(modelName)
  return `${base}@${providerName}`
}

export function smartDefault(
  old: ProviderEntry,
  next: ProviderEntry
): ProviderEntry {
  const name = next.name.trim()
  if (!name || next.models.length === 0) return next
  return {
    ...next,
    models: next.models.map((m, i) => {
      if (!m.name) return m
      const prev = old.models[i]
      const tracked =
        m.alias === undefined ||
        (prev !== undefined &&
          (prev.alias ?? "") !== "" &&
          m.alias === smartAliasFor(prev.name, old.name.trim()))
      return tracked ? { ...m, alias: smartAliasFor(m.name, name) } : m
    }),
  }
}

export interface UpstreamModel {
  id: string
  label: string
  context?: number
}

export function ModelZone({
  entry,
  aliasOwner,
  fetchUpstream,
  emptyHint,
  presetEfforts,
  onChange,
}: {
  entry?: ProviderEntry
  aliasOwner: string
  fetchUpstream?: () => Promise<UpstreamModel[]>
  emptyHint: string
  presetEfforts?: (modelName: string) => string[]
  onChange: (change: (p: ProviderEntry) => ProviderEntry) => void
}) {
  const models = entry?.models ?? []

  const smartAlias =
    models.length > 0 &&
    models.every((m) => !m.name || m.alias === smartAliasFor(m.name, aliasOwner))

  const toggleSmartAlias = (on: boolean) =>
    onChange((p) => ({
      ...p,
      models: on
        ? p.models.map((m) => ({ ...m, alias: smartAliasFor(m.name, aliasOwner) }))
        :
          p.models.map((m) =>
            m.alias === smartAliasFor(m.name, aliasOwner) ? { ...m, alias: "" } : m
          ),
    }))

  const setModel = (i: number, model: ProviderModelDef) =>
    onChange((p) =>
      smartDefault(p, {
        ...p,
        models: p.models.map((row, j) => (j === i ? model : row)),
      })
    )

  const removeModel = (i: number) =>
    onChange((p) => ({ ...p, models: p.models.filter((_, j) => j !== i) }))

  const addModel = () =>
    onChange((p) => smartDefault(p, { ...p, models: [...p.models, { name: "" }] }))

  const [fetchState, setFetchState] = useState<"idle" | "loading">("idle")
  const [fetchError, setFetchError] = useState<string>()
  const [upstream, setUpstream] = useState<UpstreamModel[]>([])
  const [picked, setPicked] = useState<Set<string>>(new Set())
  const [filter, setFilter] = useState("")

  const runFetch = async () => {
    if (!fetchUpstream) return
    setFetchState("loading")
    setFetchError(undefined)
    try {
      const list = await fetchUpstream()
      setUpstream(list)
      setPicked(new Set())
      setFilter("")
      if (list.length === 0) setFetchError("Upstream returned no models.")
    } catch (err) {
      setFetchError(errorMessage(err, "Failed to fetch models"))
    } finally {
      setFetchState("idle")
    }
  }

  const togglePicked = (id: string) =>
    setPicked((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  const addPicked = () => {
    const existing = new Set(models.map((m) => m.name.toLowerCase()))
    const fresh = upstream.filter(
      (m) => picked.has(m.id) && !existing.has(m.id.toLowerCase())
    )
    if (fresh.length === 0) return
    onChange((p) =>
      smartDefault(p, {
        ...p,
        models: [
          ...p.models,
          ...fresh.map((m) =>
            m.context && m.context > 0
              ? { name: m.id, "max-context-length": m.context }
              : { name: m.id }
          ),
        ],
      })
    )
    setPicked(new Set())
    setUpstream((prev) => prev.filter((m) => !fresh.includes(m)))
  }

  const closePicker = () => {
    setUpstream([])
    setPicked(new Set())
    setFilter("")
    setFetchError(undefined)
  }

  const visible = filter.trim()
    ? upstream.filter(
        (m) =>
          m.id.toLowerCase().includes(filter.trim().toLowerCase()) ||
          m.label.toLowerCase().includes(filter.trim().toLowerCase())
      )
    : upstream

  return (
    <div className="grid gap-2">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="text-xs font-medium text-muted-foreground">
          Models (name → alias · context window · effort levels)
        </span>
        <div className="flex items-center gap-2">
          <Switch
            aria-label={`Smart alias for ${aliasOwner}`}
            isSelected={smartAlias}
            onChange={toggleSmartAlias}
            isDisabled={models.length === 0 || !aliasOwner.trim()}
          >
            <span
              className="text-xs leading-none"
              title="Alias = model name without vendor prefix, plus @provider"
            >
              Smart alias
            </span>
          </Switch>
          {fetchUpstream ? (
            <Button
              variant="outline"
              size="xs"
              onPress={() => void runFetch()}
              isDisabled={fetchState === "loading"}
            >
              {fetchState === "loading" ? "Fetching…" : "Fetch models"}
            </Button>
          ) : null}
          <Button variant="outline" size="xs" onPress={addModel}>
            <Plus className="size-3" />
            Add model
          </Button>
        </div>
      </div>

      {fetchError ? (
        <span className="text-xs text-destructive">{fetchError}</span>
      ) : null}

      {upstream.length > 0 ? (
        <div className="grid gap-2 rounded-none border border-border/60 px-2 py-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <Input
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              placeholder={`Filter ${upstream.length} models…`}
              className="h-7 w-48 font-mono text-xs"
              aria-label="Filter fetched models"
            />
            <div className="flex items-center gap-2">
              <span className="font-mono text-xs text-muted-foreground">
                {picked.size} selected
              </span>
              <Button
                variant="default"
                size="xs"
                onPress={addPicked}
                isDisabled={picked.size === 0}
              >
                <Plus className="size-3" />
                Add {picked.size > 0 ? picked.size : ""} selected
              </Button>
              <Button
                variant="outline"
                size="icon-xs"
                onPress={closePicker}
                aria-label="Close model picker"
                className="text-muted-foreground hover:text-destructive"
              >
                <X className="size-3.5" />
              </Button>
            </div>
          </div>
          <div className="grid max-h-56 grid-cols-1 gap-x-4 gap-y-0.5 overflow-y-auto sm:grid-cols-2 lg:grid-cols-3">
            {visible.map((m) => {
              const alreadyRouted = models.some(
                (model) => model.name.toLowerCase() === m.id.toLowerCase()
              )
              return (
                <label
                  key={m.id}
                  className={cn(
                    "flex cursor-pointer items-center gap-1.5 py-0.5 font-mono text-[11px]",
                    alreadyRouted && "text-muted-foreground/50"
                  )}
                  title={
                    alreadyRouted
                      ? "Already added to this zone"
                      : m.label === m.id
                        ? m.id
                        : `${m.label} (${m.id})`
                  }
                >
                  <input
                    type="checkbox"
                    checked={picked.has(m.id)}
                    disabled={alreadyRouted}
                    onChange={() => togglePicked(m.id)}
                    className="size-3 accent-current"
                  />
                  <span className="truncate">{m.label}</span>
                </label>
              )
            })}
          </div>
        </div>
      ) : null}

      {models.length === 0 ? (
        <span className="text-xs text-muted-foreground/80">{emptyHint}</span>
      ) : (
        <div className="grid gap-1">
          {models.map((model, i) => (
            <ModelRow
              key={i}
              model={model}
              providerName={aliasOwner}
              aliasLocked={
                smartAlias && smartAliasFor(model.name, aliasOwner) === model.alias
              }
              presetEfforts={presetEfforts?.(model.name)}
              onChange={(m) => setModel(i, m)}
              onRemove={() => removeModel(i)}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function parseTokenCount(raw: string): number | undefined {
  const text = raw.trim().replace(/[,_\s]/g, "")
  if (!text) return undefined
  const match = /^(\d+(?:\.\d+)?)([km])?$/i.exec(text)
  if (!match) return undefined
  const scale = match[2]?.toLowerCase() === "m" ? 1_000_000 : match[2] ? 1_000 : 1
  const value = Math.round(Number(match[1]) * scale)
  return Number.isFinite(value) && value > 0 ? value : undefined
}

function withContext(
  model: ProviderModelDef,
  tokens: number | undefined
): ProviderModelDef {
  if (tokens === undefined) {
    const { ["max-context-length"]: _dropped, ...rest } = model
    return rest as ProviderModelDef
  }
  return { ...model, "max-context-length": tokens }
}

function withLevels(model: ProviderModelDef, next: string[]): ProviderModelDef {
  const thinking = { ...(model.thinking ?? {}) }
  if (next.length === 0) {
    if (
      (thinking.min ?? 0) > 0 ||
      (thinking.max ?? 0) > 0 ||
      thinking["zero-allowed"] ||
      thinking["dynamic-allowed"]
    ) {
      delete thinking.levels
    } else {
      return { ...model, thinking: undefined }
    }
  } else {
    thinking.levels = next
  }
  return {
    ...model,
    thinking: Object.keys(thinking).length > 0 ? thinking : undefined,
  }
}

function ModelRow({
  model,
  providerName,
  aliasLocked,
  presetEfforts,
  onChange,
  onRemove,
}: {
  model: ProviderModelDef
  providerName: string
  aliasLocked?: boolean
  presetEfforts?: string[]
  onChange: (m: ProviderModelDef) => void
  onRemove: () => void
}) {
  const effortLevels = useEffortLevels()
  const levels = model.thinking?.levels ?? []
  const context = model["max-context-length"]

  const setLevels = (next: string[]) => onChange(withLevels(model, next))

  const toggleLevel = (level: string) =>
    setLevels(
      levels.includes(level)
        ? levels.filter((l) => l !== level)
        : [...levels, level]
    )

  const knownSelected = levels.filter((l) => effortLevels.includes(l))
  const customLevels = levels.filter((l) => !effortLevels.includes(l))

  const [fetching, setFetching] = useState(false)
  const [note, setNote] = useState<string>()

  const fetchFromModelsDev = async () => {
    if (!model.name.trim()) return
    setFetching(true)
    setNote(undefined)
    try {
      const lookup = await fetchModelsDev(model.name.trim())
      const wantsEfforts = presetEfforts === undefined
      const fetchedContext = lookup.context ?? undefined
      const fetchedEfforts = wantsEfforts ? lookup.efforts : []
      if (fetchedContext === undefined && fetchedEfforts.length === 0) {
        setNote(
          `models.dev (${lookup.source}) lists no context window${
            wantsEfforts ? " or effort levels" : ""
          } for this model.`
        )
        return
      }
      let next = model
      if (fetchedEfforts.length > 0) {
        next = withLevels(next, [
          ...fetchedEfforts,
          ...customLevels.filter((l) => !fetchedEfforts.includes(l)),
        ])
      }
      if (fetchedContext !== undefined) {
        next = withContext(next, fetchedContext)
      }
      onChange(next)
      const got = [
        fetchedContext !== undefined
          ? `context ${formatContextWindow(fetchedContext)}`
          : "",
        fetchedEfforts.length > 0 ? "effort levels" : "",
      ].filter(Boolean)
      setNote(`${got.join(" + ")} from models.dev (${lookup.source})`)
    } catch (err) {
      setNote(friendlyLookupError(err, "context window"))
    } finally {
      setFetching(false)
    }
  }

  return (
    <div className="grid gap-1 rounded-none border border-border/60 px-2 py-1.5">
      <div className="flex items-center gap-2">
        <Input
          value={model.name}
          onChange={(e) => onChange({ ...model, name: e.target.value })}
          placeholder="upstream-model-name"
          className="h-7 flex-[2] font-mono text-xs"
          aria-label={`Model ${model.name || "name"}`}
        />
        <span className="text-xs text-muted-foreground">→</span>
        <span
          className="flex flex-1"
          title={aliasLocked ? "Managed by Smart alias — toggle it off to edit" : undefined}
        >
          <Input
            value={aliasLocked ? smartAliasFor(model.name, providerName) : model.alias ?? ""}
            disabled={aliasLocked}
            onChange={(e) => onChange({ ...model, alias: e.target.value })}
            placeholder="alias (optional)"
            className="h-7 flex-1 font-mono text-xs"
            aria-label={`Model ${model.name || "alias"} alias`}
          />
        </span>
        <Button
          variant="outline"
          size="xs"
          isDisabled={fetching || !model.name.trim()}
          onPress={() => void fetchFromModelsDev()}
          aria-label={`Fetch context window${
            presetEfforts === undefined ? " and effort levels" : ""
          } for ${model.name || "model"} from models.dev`}
        >
          {fetching ? "…" : "Fetch"}
        </Button>
        <Button
          variant="outline"
          size="icon-xs"
          onPress={onRemove}
          aria-label={`Remove model ${model.name || "row"}`}
          className="text-muted-foreground hover:text-destructive"
        >
          <Trash2 className="size-3 text-destructive" />
        </Button>
      </div>
      <div className="flex flex-wrap items-center gap-1.5">
        <span
          className="mr-1 text-xs text-muted-foreground"
          title="The window the client compacts against — never a cap on what raven forwards"
        >
          Context window:
        </span>
        <Input
          value={context === undefined ? "" : String(context)}
          onChange={(e) =>
            onChange(withContext(model, parseTokenCount(e.target.value)))
          }
          placeholder="e.g. 200k"
          inputMode="numeric"
          className="h-6 w-32 font-mono text-[11px]"
          aria-label={`Context window for ${model.name || "model"}`}
        />
        <span className="text-[11px] text-muted-foreground">
          {context !== undefined
            ? `${formatContextWindow(context)} · the client's auto-compact window on launch`
            : "unset — the client keeps the launcher's default auto-compact window"}
        </span>
      </div>
      {presetEfforts !== undefined ? (
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="mr-1 text-xs text-muted-foreground">Effort:</span>
          {presetEfforts.length === 0 ? (
            <span className="font-mono text-[11px] text-muted-foreground">—</span>
          ) : (
            presetEfforts.map((level) => (
              <span
                key={level}
                title="Preconfigured — pick the effort per request in your client"
                className="rounded-none border border-border bg-muted/40 px-1.5 py-0.5 font-mono text-[11px] leading-none text-muted-foreground"
              >
                {level}
              </span>
            ))
          )}
          <span className="text-[11px] text-muted-foreground">
            {presetEfforts.length > 0
              ? "· set per request by the client (reasoning_effort / thinking)"
              : "no reasoning control for this model"}
          </span>
        </div>
      ) : (
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="mr-1 text-xs text-muted-foreground">Effort:</span>
        {effortLevels.map((level) => {
          const selected = knownSelected.includes(level)
          return (
            <button
              key={level}
              type="button"
              onClick={() => toggleLevel(level)}
              aria-pressed={selected}
              aria-label={`${level} effort for ${model.name || "model"}`}
              className={cn(
                "rounded-none border px-1.5 py-0.5 font-mono text-[11px] leading-none transition-colors",
                selected
                  ? "border-primary/40 bg-primary/10 text-foreground"
                  : "border-border bg-background text-muted-foreground hover:text-foreground"
              )}
            >
              {level}
            </button>
          )
        })}
        {customLevels.length > 0 ? (
          <Input
            value={customLevels.join(",")}
            onChange={(e) =>
              setLevels([
                ...knownSelected,
                ...e.target.value
                  .split(",")
                  .map((s) => s.trim())
                  .filter(Boolean),
              ])
            }
            placeholder="custom…"
            className="h-6 w-28 font-mono text-[11px]"
            aria-label={`Custom effort levels for ${model.name || "model"}`}
          />
        ) : null}
      </div>
      )}
      {note ? (
        <span className="text-[11px] text-muted-foreground">{note}</span>
      ) : null}
    </div>
  )
}
