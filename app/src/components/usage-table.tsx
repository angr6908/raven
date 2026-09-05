import { type ColumnDef } from "@tanstack/react-table"

import { type DataTableFeatures } from "@/components/data-table"
import { Badge } from "@/components/ui/badge"
import { Dash } from "@/components/dash"
import {
  DurationWithTtft,
  ModelName,
  TokensWithCache,
} from "@/components/table-cells"
import {
  type UsageModelAgg,
  type UsageRecord,
  formatCost,
  formatDateTime,
  formatPercent,
  formatTokens,
  recordEndTimeMs,
  resolveModelDisplay,
  tpsFor,
  usageCacheRead,
  usageInputTotal,
  usageOutputTotal,
  usageStatus,
} from "@/lib/api"

export type ProviderIndex = Map<string, string[]>

export function usageRequestColumns(
  providerIndex: ProviderIndex
): ColumnDef<DataTableFeatures, UsageRecord>[] {
  return [
  {
    id: "time",
    accessorFn: recordEndTimeMs,
    header: "Time",
    cell: ({ getValue }) => (
      <span className="whitespace-nowrap text-muted-foreground">
        {formatDateTime(new Date(getValue() as number).toISOString())}
      </span>
    ),
  },
  {
    id: "model",
    accessorFn: (r) => r.alias || r.model,
    header: "Model",
    meta: { cellClassName: "max-w-52" },
    cell: ({ row }) => {
      const key = row.original.alias || row.original.model
      const { short } = resolveModelDisplay(key, providerIndex)
      return <ModelName name={short} />
    },
  },
  {
    id: "provider",
    header: "Provider",
    cell: ({ row }) => {
      const key = row.original.alias || row.original.model
      const { provider } = resolveModelDisplay(key, providerIndex)
      return provider ? (
        <Badge variant="outline">{provider}</Badge>
      ) : (
        <Dash />
      )
    },
  },
  {
    id: "status",
    accessorFn: (r) => usageStatus(r),
    header: "Status",
    cell: ({ getValue }) => {
      const status = getValue() as number
      return (
        <Badge variant={status < 400 ? "default" : "destructive"}>
          {status}
        </Badge>
      )
    },
  },
  {
    id: "effort",
    accessorKey: "reasoning_effort",
    header: "Effort",
    cell: ({ getValue }) => {
      const effort = getValue() as string | undefined
      return effort ? <Badge variant="secondary">{effort}</Badge> : <Dash />
    },
  },
  {
    id: "input",
    accessorFn: (r) => usageInputTotal(r),
    header: "Input",
    meta: { align: "right" },
    cell: ({ getValue, row }) => (
      <TokensWithCache
        total={getValue() as number}
        cached={usageCacheRead(row.original)}
      />
    ),
  },
  {
    id: "cache_rate",
    accessorFn: (r) => {
      const total = usageInputTotal(r)
      return total > 0 ? usageCacheRead(r) / total : 0
    },
    header: "Cache hit",
    meta: { align: "right" },
    cell: ({ getValue }) => {
      const rate = getValue() as number
      return rate > 0 ? formatPercent(rate) : <Dash />
    },
  },
  {
    id: "output",
    accessorFn: (r) => usageOutputTotal(r),
    header: "Output",
    meta: { align: "right" },
    cell: ({ getValue }) => formatTokens(getValue() as number),
  },
  {
    id: "latency",
    accessorKey: "latency_ms",
    header: "Duration",
    meta: { align: "right" },
    cell: ({ getValue, row }) => {
      const r = row.original
      const ttft = r.ttft_ms > 0 && r.ttft_ms <= r.latency_ms ? r.ttft_ms : 0
      return <DurationWithTtft ms={getValue() as number} ttftMs={ttft} />
    },
  },
  {
    id: "tps",
    accessorFn: (r) => tpsFor(usageOutputTotal(r), r.latency_ms) ?? 0,
    header: "TPS",
    meta: { align: "right" },
    cell: ({ getValue }) => {
      const v = getValue() as number
      return v > 0 ? v.toFixed(1) : <Dash />
    },
  },
  {
    id: "cost",
    accessorKey: "cost_usd",
    header: "Cost",
    meta: { align: "right" },
    cell: ({ getValue }) => {
      const cost = getValue() as number
      return cost > 0 ? formatCost(cost) : <Dash />
    },
  },
  ]
}

export function usageModelColumns(providerIndex: ProviderIndex): ColumnDef<DataTableFeatures, UsageModelAgg>[] {
  return [
  {
    id: "model",
    accessorKey: "model",
    header: "Model",
    meta: { cellClassName: "max-w-52" },
    cell: ({ getValue }) => {
      const key = String(getValue())
      const { short } = resolveModelDisplay(key, providerIndex)
      return <ModelName name={short} />
    },
  },
  {
    id: "provider",
    header: "Provider",
    cell: ({ row }) => {
      const { provider } = resolveModelDisplay(row.original.model, providerIndex)
      return provider ? (
        <Badge variant="outline">{provider}</Badge>
      ) : (
        <Dash />
      )
    },
  },
  {
    id: "success_rate",
    accessorFn: (r) =>
      r.requests > 0 ? (r.requests - r.errors) / r.requests : 0,
    header: "Success",
    meta: { align: "right" },
    cell: ({ getValue }) => {
      const rate = getValue() as number
      return formatPercent(rate)
    },
  },
  {
    id: "input",
    accessorKey: "input",
    header: "Input",
    meta: { align: "right" },
    cell: ({ getValue, row }) => (
      <TokensWithCache
        total={getValue() as number}
        cached={row.original.cached}
      />
    ),
  },
  {
    id: "cache_rate",
    accessorFn: (r) => (r.input ? r.cached / r.input : 0),
    header: "Cache hit",
    meta: { align: "right" },
    cell: ({ getValue }) => {
      const rate = getValue() as number
      return rate > 0 ? formatPercent(rate) : <Dash />
    },
  },
  {
    id: "output",
    accessorKey: "output",
    header: "Output",
    meta: { align: "right" },
    cell: ({ getValue }) => formatTokens(getValue() as number),
  },
  {
    id: "avg_latency",
    accessorKey: "latSum",
    header: "Avg duration",
    meta: { align: "right" },
    cell: ({ row }) => {
      const { ok, ttftOk, latSum, ttftSum } = row.original
      if (!ok) return <Dash />
      return (
        <DurationWithTtft
          ms={latSum / ok}
          ttftMs={ttftOk ? ttftSum / ttftOk : 0}
        />
      )
    },
  },
  {
    id: "avg_tps",
    accessorKey: "tpsSum",
    header: "Avg TPS",
    meta: { align: "right" },
    cell: ({ row }) =>
      row.original.ok ? (
        (row.original.tpsSum / row.original.ok).toFixed(1)
      ) : (
        <Dash />
      ),
  },
  {
    id: "cost",
    accessorKey: "cost",
    header: "Cost",
    meta: { align: "right" },
    cell: ({ getValue }) => formatCost(getValue() as number),
  },
  ]
}
