import { useCallback, useEffect, useState } from "react"
import { ChevronDown, Plus, Trash2 } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent } from "@/components/ui/card"
import { Switch } from "@/components/ui/switch"
import { Input } from "@/components/ui/input"
import { Button } from "@/components/ui/button"
import { ErrorBanner } from "@/components/error-banner"
import { Skeleton } from "@/components/ui/skeleton"
import { ModelZone, smartDefault } from "@/components/model-zone"
import { ManagedZoneCards } from "@/components/managed-zones"
import { useAutoSave } from "@/hooks/use-auto-save"
import { cn, errorMessage } from "@/lib/utils"
import {
  type ProviderEntry,
  blankProviderEntry,
  fetchProviderModels,
  getProviders,
  isManagedZone,
  saveProviders,
} from "@/lib/api"

const blankProvider = (): ProviderEntry => ({
  ...blankProviderEntry("openai"),
  "api-key-entries": [{ "api-key": "" }],
})

const KIND_LABELS = {
  openai: "OpenAI-compatible endpoint",
  responses: "OpenAI Responses endpoint",
} as const

const KIND_BADGES = {
  openai: "openai",
  responses: "responses",
} as const

type ProviderKind = keyof typeof KIND_LABELS

const SAVE_STATUS = {
  idle: { label: "", dot: "" },
  saving: { label: "Saving…", dot: "animate-pulse bg-amber-500" },
  saved: { label: "Saved — raven reloaded", dot: "bg-emerald-500" },
  error: { label: "Save failed", dot: "bg-destructive" },
} as const

export function ProvidersView({ onSaved }: { onSaved?: () => void }) {
  const [providers, setProviders] = useState<ProviderEntry[]>()
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string>()
  useEffect(() => {
    let cancelled = false
    getProviders()
      .then((data) => {
        if (!cancelled) setProviders(data)
      })
      .catch((err) => {
        if (!cancelled) setError(errorMessage(err, "Failed to load providers"))
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [])

  const save = useCallback(
    (list: ProviderEntry[]) =>
      saveProviders(
        list.map((p) => ({
          ...p,
          models: p.models.map((m) =>
            m.alias === "" ? { ...m, alias: undefined } : m
          ),
        }))
      ),
    []
  )
  const onSaveError = useCallback(
    (err: unknown) => setError(errorMessage(err, "Failed to save providers")),
    []
  )
  const { saveState, markDirty } = useAutoSave(providers, {
    save,
    onSaved,
    onError: onSaveError,
  })

  const mutate = useCallback(
    (change: (prev: ProviderEntry[]) => ProviderEntry[]) => {
      markDirty()
      setProviders((prev) => change(prev ?? []))
    },
    [markDirty]
  )

  const updateProvider = useCallback(
    (index: number, change: (p: ProviderEntry) => ProviderEntry) =>
      mutate((prev) =>
        prev.map((p, i) => (i === index ? change({ ...p }) : p))
      ),
    [mutate]
  )

  const editZone = useCallback(
    (
      match: (p: ProviderEntry) => boolean,
      blank: () => ProviderEntry,
      change: (p: ProviderEntry) => ProviderEntry
    ) =>
      mutate((prev) => {
        const index = prev.findIndex(match)
        if (index < 0) return [...prev, change(blank())]
        return prev.map((p, i) => (i === index ? change({ ...p }) : p))
      }),
    [mutate]
  )

  const addProvider = useCallback(
    () => mutate((prev) => [blankProvider(), ...prev]),
    [mutate]
  )

  const removeProvider = useCallback(
    (index: number) => mutate((prev) => prev.filter((_, i) => i !== index)),
    [mutate]
  )

  if (loading) {
    return (
      <div className="grid grid-cols-[minmax(0,1fr)] gap-6">
        {Array.from({ length: 3 }).map((_, i) => (
          <Card key={i} size="sm">
            <CardContent className="pt-6">
              <Skeleton className="h-5 w-40" />
              <Skeleton className="mt-2 h-3.5 w-64" />
            </CardContent>
          </Card>
        ))}
      </div>
    )
  }

  const list = providers ?? []

  const endpointProviders = list
    .map((provider, index) => ({ provider, index }))
    .filter(({ provider }) => !isManagedZone(provider))

  return (
    <div className="grid grid-cols-[minmax(0,1fr)] gap-6">
      <ErrorBanner error={error} />

      <SaveStatus state={saveState} />

      <h2 className="text-sm font-medium">Managed channels</h2>

      <ManagedZoneCards providers={list} editZone={editZone} />

      <div className="flex items-center justify-between">
        <h2 className="text-sm font-medium">API key providers</h2>
        <Button variant="outline" size="sm" onPress={addProvider}>
          <Plus className="size-3.5" />
          Add provider
        </Button>
      </div>

      {endpointProviders.length === 0 ? (
        <Card size="sm" className="border-dashed">
          <CardContent className="pt-6 text-sm text-muted-foreground">
            No API key providers configured. Add one to route models through an
            OpenAI-compatible or Responses endpoint.
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-3">
          {endpointProviders.map(({ provider, index }) => (
            <ProviderCard
              key={index}
              index={index}
              provider={provider}
              onChange={(change) => updateProvider(index, change)}
              onRemove={() => removeProvider(index)}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function SaveStatus({
  state,
}: {
  state: keyof typeof SAVE_STATUS
}) {
  if (state === "idle") return null
  const status = SAVE_STATUS[state]
  return (
    <span
      className={cn(
        "flex h-6 shrink-0 items-center justify-self-end gap-1.5 text-xs",
        state === "error" ? "text-destructive" : "text-muted-foreground"
      )}
    >
      <span className={cn("size-1.5 rounded-full", status.dot)} />
      {status.label}
    </span>
  )
}

function ProviderCard({
  index,
  provider,
  onChange,
  onRemove,
}: {
  index: number
  provider: ProviderEntry
  onChange: (change: (p: ProviderEntry) => ProviderEntry) => void
  onRemove: () => void
}) {
  const [open, setOpen] = useState(provider.name === "")
  const kind = (provider.kind ?? "openai") as ProviderKind
  const models = provider.models
  const keys = provider["api-key-entries"]

  const update = (fields: Partial<ProviderEntry>) =>
    onChange((p) => smartDefault(p, { ...p, ...fields }))

  const setApiKey = (index: number, key: string) =>
    onChange((p) => ({
      ...p,
      "api-key-entries": p["api-key-entries"].map((entry, i) =>
        i === index ? { ...entry, "api-key": key } : entry
      ),
    }))

  const addApiKey = () =>
    onChange((p) => ({
      ...p,
      "api-key-entries": [...p["api-key-entries"], { "api-key": "" }],
    }))

  const removeApiKey = (index: number) =>
    onChange((p) => ({
      ...p,
      "api-key-entries": p["api-key-entries"].filter((_, i) => i !== index),
    }))

  return (
    <Card size="sm" className={cn("min-w-0 py-0", provider.disabled && "opacity-70")}>
      <div className="flex items-center gap-2 px-3 py-2.5">
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          aria-label={`Toggle provider ${provider.name || "unnamed"}`}
          className="flex min-w-0 flex-1 items-center gap-2 text-left outline-none focus-visible:ring-1 focus-visible:ring-ring/50"
        >
          <ChevronDown
            className={cn(
              "size-4 shrink-0 text-muted-foreground transition-transform",
              !open && "-rotate-90"
            )}
          />
          <div className="grid min-w-0 flex-1 gap-0.5">
            <div className="flex items-center gap-2">
              <span className="truncate font-mono text-sm">
                {provider.name || (
                  <span className="text-muted-foreground">unnamed</span>
                )}
              </span>
              <Badge variant="outline" className="text-muted-foreground">
                {KIND_BADGES[kind]}
              </Badge>
              {provider.disabled ? (
                <Badge variant="outline" className="text-muted-foreground">
                  off
                </Badge>
              ) : null}
            </div>
            <span className="truncate font-mono text-[11px] text-muted-foreground">
              {provider["base-url"] || "no base url"}
            </span>
          </div>
        </button>
        <span className="hidden shrink-0 font-mono text-xs text-muted-foreground md:inline">
          {models.length === 0
            ? "pass-through"
            : `${models.length} model${models.length === 1 ? "" : "s"}`}
          {keys.length > 0
            ? ` · ${keys.length} key${keys.length === 1 ? "" : "s"}`
            : ""}
        </span>
        <Switch
          aria-label={`Provider ${provider.name || "unnamed"} enabled`}
          isSelected={!provider.disabled}
          onChange={(on) => update({ disabled: !on })}
        >
          <span className="text-xs leading-none">Enabled</span>
        </Switch>
        <Button
          variant="outline"
          size="icon-xs"
          onPress={onRemove}
          aria-label={`Remove provider ${provider.name || "unnamed"}`}
          className="text-muted-foreground hover:text-destructive"
        >
          <Trash2 className="size-3.5 text-destructive" />
        </Button>
      </div>

      {open ? (
        <CardContent className="grid gap-4 border-t px-3 py-3">
          <div className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,2fr)_minmax(0,1.5fr)]">
            <label className="grid gap-1.5">
              <span className="text-xs font-medium text-muted-foreground">Name</span>
              <Input
                value={provider.name}
                onChange={(e) => update({ name: e.target.value })}
                placeholder="e.g. openrouter"
                className="h-8 font-mono text-sm"
                aria-label="Provider name"
              />
            </label>
            <label className="grid gap-1.5">
              <span className="text-xs font-medium text-muted-foreground">Base URL</span>
              <Input
                value={provider["base-url"]}
                onChange={(e) => update({ "base-url": e.target.value })}
                placeholder="https://api.example.com/v1"
                className="h-8 font-mono text-sm"
                aria-label="Provider base URL"
              />
            </label>
            <label className="grid gap-1.5">
              <span className="text-xs font-medium text-muted-foreground">Kind</span>
              <select
                value={provider.kind ?? "openai"}
                onChange={(e) => update({ kind: e.target.value as ProviderKind })}
                className="h-8 rounded-none border border-border bg-background px-2 font-mono text-xs"
                aria-label="Provider kind"
              >
                {(Object.keys(KIND_LABELS) as ProviderKind[]).map((k) => (
                  <option key={k} value={k}>
                    {KIND_LABELS[k]}
                  </option>
                ))}
              </select>
            </label>
          </div>

          <div className="grid gap-2">
            <div className="flex items-center justify-between">
              <span className="text-xs font-medium text-muted-foreground">API keys</span>
              <Button variant="outline" size="xs" onPress={addApiKey}>
                <Plus className="size-3" />
                Add key
              </Button>
            </div>
            {keys.length === 0 ? (
              <span className="text-xs text-muted-foreground/80">None.</span>
            ) : (
              keys.map((entry, i) => (
                <div key={i} className="flex items-center gap-2">
                  <Input
                    value={entry["api-key"]}
                    onChange={(e) => setApiKey(i, e.target.value)}
                    placeholder="sk-…"
                    className="h-7 font-mono text-xs"
                    aria-label={`API key ${i + 1}`}
                  />
                  <Button
                    variant="outline"
                    size="icon-xs"
                    onPress={() => removeApiKey(i)}
                    aria-label={`Remove API key ${i + 1}`}
                    className="text-muted-foreground hover:text-destructive"
                  >
                    <Trash2 className="size-3 text-destructive" />
                  </Button>
                </div>
              ))
            )}
          </div>

          <ModelZone
            entry={provider}
            aliasOwner={provider.name}
            fetchUpstream={async () =>
              (await fetchProviderModels(index)).map((m) => ({
                id: m.id,
                label: m.display_name || m.id,
                context: m.context_length,
              }))
            }
            emptyHint="No models — every upstream model is passed through."
            onChange={onChange}
          />
        </CardContent>
      ) : null}
    </Card>
  )
}
