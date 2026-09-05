import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { type ColumnDef, type Row } from "@tanstack/react-table"
import {
  Broom,
  ChevronDown,
  ChevronRight,
  CloudDownload,
  Plus,
  Trash2,
  X,
} from "lucide-react"

import {
  type DataTableFeatures,
  DataTable,
  DataTableSearch,
} from "@/components/data-table"
import {
  Card,
  CardAction,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Switch } from "@/components/ui/switch"
import { cn, errorMessage } from "@/lib/utils"
import { ErrorBanner } from "@/components/error-banner"
import { useAutoSave } from "@/hooks/use-auto-save"
import {
  type ModelPrice,
  type PricesMap,
  type ProviderEntry,
  type UsageRecord,
  DEFAULT_PEAK_WINDOWS,
  fetchModelsDev,
  friendlyLookupError,
  getPrices,
  getProviders,
  savePrices,
} from "@/lib/api"

type RateField =
  | "input"
  | "output"
  | "cached"
  | "input_peak"
  | "output_peak"
  | "cached_peak"

const BASE_FIELDS: RateField[] = ["input", "output", "cached"]
const RATE_HEADERS: Record<string, string> = {
  input: "Input $/M",
  output: "Output $/M",
  cached: "Cached $/M",
}
const PEAK_FIELDS: RateField[] = BASE_FIELDS.map((f) => `${f}_peak` as RateField)

const blankPrice = (): ModelPrice => ({
  input: 0,
  output: 0,
  cached: 0,
  input_peak: 0,
  output_peak: 0,
  cached_peak: 0,
})

let cachedPrices: PricesMap | null = null
let cachedRecordModels: string[] | null = null

function hasPeak(p: ModelPrice): boolean {
  return (
    PEAK_FIELDS.some((field) => (p[field] ?? 0) > 0) ||
    (p.peak_windows?.length ?? 0) > 0
  )
}

function uniqueByLower(names: string[]): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const name of names) {
    const key = name.toLowerCase()
    if (name && !seen.has(key)) {
      seen.add(key)
      out.push(name)
    }
  }
  return out
}

function priceMapKey(prices: PricesMap, model: string): string {
  const lower = model.toLowerCase()
  for (const k of Object.keys(prices)) {
    if (k.toLowerCase() === lower) return k
  }
  return lower
}

function priceKeyIndex(prices: PricesMap): Map<string, string> {
  const index = new Map<string, string>()
  for (const k of Object.keys(prices)) {
    const lower = k.toLowerCase()
    if (!index.has(lower)) index.set(lower, k)
  }
  return index
}

const actionIcon =
  "inline-flex size-6 shrink-0 items-center justify-center text-muted-foreground/70 transition-colors hover:bg-muted hover:text-foreground"

interface PriceRow {
  model: string
  price: ModelPrice
  peak: boolean
  priced: boolean
  inLog: boolean
}

export function PricingView({ records }: { records: UsageRecord[] }) {
  const [prices, setPrices] = useState<PricesMap>(cachedPrices ?? {})
  const [recordModels, setRecordModels] = useState<string[]>(cachedRecordModels ?? [])
  const [modelFilter, setModelFilter] = useState("")
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [loading, setLoading] = useState(cachedPrices === null)
  const [error, setError] = useState<string>()
  const pricesRef = useRef(prices)

  useEffect(() => {
    let cancelled = false
    async function init() {
      try {
        const [priceData, providers] = await Promise.all([
          getPrices(),
          getProviders().catch(() => [] as ProviderEntry[]),
        ])
        if (cancelled) return
        setPrices(priceData)
        cachedPrices = priceData
        const models = uniqueByLower([
          ...records.map((r: UsageRecord) => r.alias || r.model),
          ...providers.flatMap((p: ProviderEntry) =>
            p.models.map((m) => m.alias || m.name)
          ),
        ])
        setRecordModels(models)
        cachedRecordModels = models
      } catch (err) {
        if (!cancelled) setError(errorMessage(err, "Failed to load prices"))
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    void init()
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    pricesRef.current = prices
  }, [prices])

  const onSaveError = useCallback(
    (err: unknown) => setError(errorMessage(err, "Failed to save prices")),
    []
  )
  const { saveState, markDirty, commitSaved, failSave } = useAutoSave(prices, {
    save: savePrices,
    onError: onSaveError,
  })

  const setField = useCallback(
    (model: string, field: RateField, value: number) => {
      markDirty()
      setPrices((prev) => {
        const key = priceMapKey(prev, model)
        const current = { ...(prev[key] ?? blankPrice()) }
        if (Number.isNaN(value)) {
          delete current[field]
        } else {
          current[field] = value
        }
        return { ...prev, [key]: current }
      })
    },
    [markDirty]
  )

  const updatePrice = useCallback(
    (model: string, change: (price: ModelPrice) => ModelPrice) => {
      markDirty()
      setPrices((prev) => {
        const key = priceMapKey(prev, model)
        return {
          ...prev,
          [key]: change({ ...(prev[key] ?? blankPrice()) }),
        }
      })
    },
    [markDirty]
  )

  const toggleExpanded = useCallback((model: string) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(model)) next.delete(model)
      else next.add(model)
      return next
    })
  }, [])

  const togglePeak = useCallback(
    (model: string, on: boolean) => {
      updatePrice(model, (price) => {
        if (!on) {
          delete price.input_peak
          delete price.output_peak
          delete price.cached_peak
          delete price.peak_windows
          return price
        }
        for (const field of BASE_FIELDS) {
          const peakField = `${field}_peak` as RateField
          if (!((price[peakField] ?? 0) > 0)) {
            price[peakField] = (price[field] ?? 0) * 2
          }
        }
        if (!price.peak_windows?.length) {
          price.peak_windows = DEFAULT_PEAK_WINDOWS.map((w) => [...w] as [number, number])
        }
        return price
      })
      setExpanded((prev) => {
        const next = new Set(prev)
        if (on) next.add(model)
        else next.delete(model)
        return next
      })
    },
    [updatePrice]
  )

  const updateWindows = useCallback(
    (
      model: string,
      change: (windows: [number, number][]) => [number, number][]
    ) => {
      updatePrice(model, (price) => {
        price.peak_windows = change(price.peak_windows ?? [])
        return price
      })
    },
    [updatePrice]
  )

  const addWindow = useCallback(
    (model: string) => updateWindows(model, (w) => [...w, [1, 4]]),
    [updateWindows]
  )

  const removeWindow = useCallback(
    (model: string, index: number) =>
      updateWindows(model, (w) => w.filter((_, i) => i !== index)),
    [updateWindows]
  )

  const editWindow = useCallback(
    (model: string, index: number, pos: 0 | 1, value: number) =>
      updateWindows(model, (w) => {
        if (!w[index]) return w
        if (Number.isNaN(value)) return w.filter((_, i) => i !== index)
        const next = w.map((win) => [...win] as [number, number])
        next[index][pos] = value
        return next
      }),
    [updateWindows]
  )

  const removeModel = useCallback((model: string) => {
    markDirty()
    setExpanded((prev) => {
      const next = new Set(prev)
      next.delete(model)
      return next
    })
    setPrices((prev) => {
      const next = { ...prev }
      delete next[priceMapKey(prev, model)]
      return next
    })
  }, [markDirty])

  const [fetchingModels, setFetchingModels] = useState<Set<string>>(new Set())
  const [fetchNote, setFetchNote] = useState<string>()

  const fetchPrice = useCallback(async (model: string): Promise<"ok" | "empty" | "error"> => {
    setFetchingModels((prev) => new Set(prev).add(model))
    setFetchNote(undefined)
    try {
      const lookup = await fetchModelsDev(model)
      if (
        lookup.input === null &&
        lookup.output === null &&
        lookup.cache_read === null
      ) {
        return "empty"
      }
      markDirty()
      setPrices((prev) => {
        const key = priceMapKey(prev, model)
        const current = { ...(prev[key] ?? blankPrice()) }
        if (lookup.input !== null) current.input = lookup.input
        if (lookup.output !== null) current.output = lookup.output
        if (lookup.cache_read !== null) current.cached = lookup.cache_read
        if (lookup.peak_input != null) current.input_peak = lookup.peak_input
        if (lookup.peak_output != null) current.output_peak = lookup.peak_output
        if (lookup.peak_cache_read != null) current.cached_peak = lookup.peak_cache_read
        if (
          lookup.peak_input != null &&
          !(current.peak_windows?.length ?? 0)
        ) {
          current.peak_windows = DEFAULT_PEAK_WINDOWS.map(
            (w: [number, number]) => [...w] as [number, number]
          )
        }
        return { ...prev, [key]: current }
      })
      return "ok"
    } catch (err) {
      return friendlyLookupError(err, `pricing for ${model}`)
        .startsWith("Not found")
        ? "empty"
        : "error"
    } finally {
      setFetchingModels((prev) => {
        const next = new Set(prev)
        next.delete(model)
        return next
      })
    }
  }, [markDirty])

  const allRows: PriceRow[] = useMemo(() => {
    const logModelSet = new Set(recordModels.map((m) => m.toLowerCase()))
    const keyIndex = priceKeyIndex(prices)
    const rows = uniqueByLower([
      ...recordModels,
      ...Object.keys(prices),
    ]).map((model) => {
      const lower = model.toLowerCase()
      const price = prices[keyIndex.get(lower) ?? lower] ?? blankPrice()
      return {
        model,
        price,
        peak: hasPeak(price),
        priced: (price.input ?? 0) > 0 || (price.output ?? 0) > 0,
        inLog: logModelSet.has(lower),
      }
    })
    rows.sort((a, b) => a.model.localeCompare(b.model))
    return rows
  }, [recordModels, prices])

  const unpricedCount = useMemo(
    () => allRows.filter((r) => !r.priced && r.inLog).length,
    [allRows]
  )

  const deletableModels = useMemo(
    () => allRows.filter((r) => !r.inLog).map((r) => r.model),
    [allRows]
  )

  const sweepDeletable = useCallback(() => {
    markDirty()
    setExpanded(new Set())
    setPrices((prev) => {
      const doomed = new Set(deletableModels.map((m) => priceMapKey(prev, m)))
      if (!doomed.size) return prev
      const next: PricesMap = {}
      for (const [key, price] of Object.entries(prev)) {
        if (!doomed.has(key)) next[key] = price
      }
      return next
    })
  }, [deletableModels, markDirty])

  const [fetchingAll, setFetchingAll] = useState(false)
  const fetchAll = useCallback(async () => {
    setFetchingAll(true)
    setFetchNote(undefined)
    const names = allRows.map((r) => r.model)
    let ok = 0
    let empty = 0
    let error = 0
    const merged: PricesMap = {} as PricesMap
    await Promise.all(
      names.map(async (model) => {
        const lookup = await fetchModelsDev(model).catch(() => null)
        if (!lookup) {
          error += 1
          return
        }
        if (lookup.input === null && lookup.output === null && lookup.cache_read === null) {
          empty += 1
          return
        }
        ok += 1
        const key = priceMapKey(pricesRef.current, model)
        const current: ModelPrice = { ...(merged[key] ?? blankPrice()) }
        if (lookup.input !== null) current.input = lookup.input
        if (lookup.output !== null) current.output = lookup.output
        if (lookup.cache_read !== null) current.cached = lookup.cache_read
        if (lookup.peak_input != null) current.input_peak = lookup.peak_input
        if (lookup.peak_output != null) current.output_peak = lookup.peak_output
        if (lookup.peak_cache_read != null) current.cached_peak = lookup.peak_cache_read
        if (lookup.peak_input != null && !(current.peak_windows?.length ?? 0)) {
          current.peak_windows = DEFAULT_PEAK_WINDOWS.map((w: [number, number]) => [...w] as [number, number])
        }
        merged[key] = current
      })
    )
    if (ok > 0) {
      markDirty()
      const next = { ...pricesRef.current, ...merged }
      pricesRef.current = next
      setPrices(next)
      try {
        await savePrices(next)
        commitSaved()
      } catch (err) {
        failSave(err)
      }
    }
    const parts = [`${ok} priced`]
    if (empty > 0) parts.push(`${empty} not on models.dev`)
    if (error > 0) parts.push(`${error} failed`)
    setFetchNote(
      `Fetched ${names.length} models from models.dev — ${parts.join(", ")}.`
    )
    setFetchingAll(false)
  }, [allRows, markDirty, commitSaved, failSave])

  const rateInput = useCallback(
    (model: string, price: ModelPrice, field: RateField) => (
      <Input
        type="number"
        min="0"
        step="0.01"
        value={price[field] ?? 0}
        onChange={(e) => setField(model, field, Number(e.target.value) || 0)}
        aria-label={`${field} price per 1M tokens for ${model}`}
        className="h-6 w-full min-w-0 border-transparent bg-transparent px-1 text-right font-mono text-xs tabular-nums hover:border-input focus-visible:border-input"
      />
    ),
    [setField]
  )

  const hourInput = useCallback(
    (
      model: string,
      windows: [number, number][],
      index: number,
      pos: 0 | 1
    ) => (
      <Input
        type="number"
        min="0"
        max="23"
        step="1"
        value={windows[index]?.[pos] ?? ""}
        placeholder={pos === 0 ? "1" : "4"}
        onChange={(e) => {
          const v = e.target.value
          editWindow(model, index, pos, v === "" ? Number.NaN : Number(v))
        }}
        aria-label={`Peak ${pos === 0 ? "start" : "end"} hour ${index + 1} for ${model}`}
        className="h-6 w-9 px-0.5 text-center font-mono text-xs tabular-nums"
      />
    ),
    [editWindow]
  )

  const columns = useMemo<ColumnDef<DataTableFeatures, PriceRow>[]>(() => [
    {
      id: "model",
      accessorKey: "model",
      header: "Model",
      meta: { cellClassName: "w-full min-w-44" },
      cell: ({ row }) => {
        const r = row.original
        const open = r.peak && expanded.has(r.model)
        return (
          <div className="flex min-w-0 items-center gap-1">
            {}
            {r.peak ? (
              <button
                type="button"
                onClick={() => toggleExpanded(r.model)}
                aria-expanded={open}
                aria-label={`${open ? "Hide" : "Edit"} peak pricing for ${r.model}`}
                className="-ml-0.5 inline-flex size-5 shrink-0 items-center justify-center text-muted-foreground/60 transition-colors hover:bg-muted hover:text-foreground"
              >
                {open ? (
                  <ChevronDown className="size-3.5" />
                ) : (
                  <ChevronRight className="size-3.5" />
                )}
              </button>
            ) : (
              <span className="size-5 shrink-0" aria-hidden />
            )}
            <span
              className={cn(
                "min-w-0 truncate font-mono text-xs",
                !r.priced && r.inLog && "text-amber-600 dark:text-amber-500"
              )}
              title={r.model}
            >
              {r.model}
            </span>
          </div>
        )
      },
    },
    ...BASE_FIELDS.map(
      (field): ColumnDef<DataTableFeatures, PriceRow> => ({
        id: field,
        accessorFn: (r) => r.price[field] ?? 0,
        header: RATE_HEADERS[field],
        meta: { align: "right" },
        cell: ({ row }) =>
          rateInput(row.original.model, row.original.price, field),
      })
    ),
    {
      id: "peak",
      accessorFn: (r) => (r.peak ? 1 : 0),
      header: "Peak",
      meta: { align: "right" },
      cell: ({ row }) => {
        const r = row.original
        return (
          <div className="flex justify-end">
            <Switch
              aria-label={`Peak pricing ${r.peak ? "on" : "off"} for ${r.model}`}
              isSelected={r.peak}
              onChange={(on) => togglePeak(r.model, on)}
            />
          </div>
        )
      },
    },
    {
      id: "fetch",
      header: () => (
        <button
          type="button"
          disabled={fetchingAll}
          onClick={() => void fetchAll()}
          aria-label="Fetch prices for all models from models.dev"
          title="Fetch all prices from models.dev"
          className={cn(
            "inline-flex size-6 items-center justify-center text-muted-foreground transition-colors hover:bg-muted hover:text-foreground",
            fetchingAll && "text-primary"
          )}
        >
          <CloudDownload
            className={cn("size-3.5", fetchingAll && "animate-pulse")}
          />
        </button>
      ),
      enableSorting: false,
      meta: { align: "right", cellClassName: "w-8" },
      cell: ({ row }) => {
        const r = row.original
        return (
          <button
            type="button"
            disabled={fetchingModels.has(r.model) || fetchingAll}
            onClick={() => void fetchPrice(r.model)}
            aria-label={`Fetch price for ${r.model} from models.dev`}
            title="Fetch price from models.dev"
            className={actionIcon}
          >
            <CloudDownload
              className={cn(
                "size-3.5",
                (fetchingModels.has(r.model) || fetchingAll) &&
                  "animate-pulse text-primary"
              )}
            />
          </button>
        )
      },
    },
    {
      id: "actions",
      header: () =>
        deletableModels.length === 0 ? null : (
          <button
            type="button"
            onClick={sweepDeletable}
            aria-label={`Remove all ${deletableModels.length} unused price rows`}
            title={`Remove all ${deletableModels.length} unused price rows`}
            className={cn(actionIcon, "hover:text-destructive")}
          >
            <Broom className="size-3.5" />
          </button>
        ),
      enableSorting: false,
      meta: { align: "right", cellClassName: "w-8" },
      cell: ({ row }) => {
        const r = row.original
        if (r.inLog) return null
        return (
          <button
            type="button"
            onClick={() => removeModel(r.model)}
            aria-label={`Remove price for ${r.model}`}
            title="Remove model"
            className={cn(actionIcon, "hover:text-destructive")}
          >
            <Trash2 className="size-3.5" />
          </button>
        )
      },
    },
  ], [
    expanded,
    toggleExpanded,
    rateInput,
    togglePeak,
    fetchingAll,
    fetchAll,
    fetchingModels,
    fetchPrice,
    deletableModels,
    sweepDeletable,
    removeModel,
  ])

  const renderExpandedRow = useCallback((row: Row<DataTableFeatures, PriceRow>) => {
    const r = row.original
    const windows = r.price.peak_windows ?? []
    return {
      model: (
        <div className="flex max-w-full flex-wrap items-center gap-x-2 gap-y-1 py-0.5 pl-5">
          <span className="shrink-0 text-[10px] uppercase tracking-wide text-muted-foreground/80">
            Peak windows UTC
          </span>
          <div className="flex flex-wrap items-center gap-1">
          {windows.map((_, i) => (
            <span key={i} className="inline-flex items-center gap-0.5">
              {hourInput(r.model, windows, i, 0)}
              <span className="text-[10px] leading-none text-muted-foreground">
                –
              </span>
              {hourInput(r.model, windows, i, 1)}
              <button
                type="button"
                onClick={() => removeWindow(r.model, i)}
                aria-label={`Remove peak window ${i + 1} for ${r.model}`}
                className="text-muted-foreground/60 hover:text-destructive"
              >
                <X className="size-3" />
              </button>
            </span>
          ))}
          <button
            type="button"
            onClick={() => addWindow(r.model)}
            aria-label={`Add peak window for ${r.model}`}
            className="text-muted-foreground/60 hover:text-foreground"
          >
            <Plus className="size-3.5" />
          </button>
          </div>
        </div>
      ),
      input: rateInput(r.model, r.price, "input_peak"),
      output: rateInput(r.model, r.price, "output_peak"),
      cached: rateInput(r.model, r.price, "cached_peak"),
    }
  }, [hourInput, removeWindow, addWindow, rateInput])

  if (loading) {
    return (
      <p className="py-10 text-center text-sm text-muted-foreground">
        Loading prices…
      </p>
    )
  }

  return (
    <div className="grid gap-4">
      <ErrorBanner error={error} />

      {}
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle>Model prices</CardTitle>
          <CardAction>
            <DataTableSearch
              value={modelFilter}
              onChange={setModelFilter}
              placeholder="Filter models…"
              className="w-56"
            />
          </CardAction>
        </CardHeader>
        <CardContent>
          <DataTable
            columns={columns}
            data={allRows}
            searchKey="model"
            searchPlaceholder="Filter models…"
            tableLabel="Model prices"
            searchValue={modelFilter}
            onSearchChange={setModelFilter}
            enablePagination={false}
            getRowCanExpand={(row) => row.original.peak}
            getIsRowExpanded={(row) => expanded.has(row.original.model)}
            renderExpandedRow={renderExpandedRow}
          />
        </CardContent>
      </Card>

      {}
      <div className="flex h-6 items-center gap-2 text-sm">
        {fetchNote ? (
          <span className="text-muted-foreground">{fetchNote}</span>
        ) : saveState === "saving" ? (
          <span className="text-muted-foreground">Saving…</span>
        ) : saveState === "saved" ? (
          <span className="text-muted-foreground">Saved — costs updated.</span>
        ) : saveState === "error" ? (
          <span className="text-destructive">Save failed.</span>
        ) : (
          <span className="text-muted-foreground">
            Changes save automatically · USD per 1M tokens ·{" "}
            {unpricedCount > 0
              ? `${unpricedCount} model${unpricedCount === 1 ? "" : "s"} in use without prices`
              : "all used models priced"}
          </span>
        )}
      </div>
    </div>
  )
}