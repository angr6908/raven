import { Clock } from "lucide-react"

import { type AntigravityQuotaAccount } from "@/lib/api"
import { Badge } from "@/components/ui/badge"
import { Dash } from "@/components/dash"

function quotaPercent(fraction: number): string {
  const value = Math.max(0, Math.min(1, fraction)) * 100
  return `${value.toFixed(value < 10 && value > 0 ? 1 : 0)}%`
}

function quotaResetShort(resetTime?: string): string | null {
  if (!resetTime) return null
  const at = Date.parse(resetTime)
  if (!Number.isFinite(at)) return null
  const minutes = Math.round((at - Date.now()) / 60000)
  if (minutes <= 0) return "now"
  const days = Math.floor(minutes / (60 * 24))
  const hours = Math.floor((minutes % (60 * 24)) / 60)
  if (days > 0) return `${days}d${hours}h`
  if (hours > 0) return `${hours}h${minutes % 60}m`
  return `${minutes}m`
}

function QuotaValue({
  fraction,
  reset,
  title,
}: {
  fraction: number
  reset: string | null
  title: string
}) {
  return (
    <span className="whitespace-nowrap" title={title}>
      <span className="tabular-nums">{quotaPercent(fraction)}</span>
      {reset ? (
        <span
          className="ml-1.5 inline-flex items-center gap-0.5 align-middle text-[11px] font-normal normal-nums text-muted-foreground"
          title={reset === "now" ? "resets now" : `resets in ${reset}`}
        >
          <Clock className="size-3 shrink-0" aria-hidden="true" />
          {reset}
        </span>
      ) : null}
    </span>
  )
}

const WINDOW_ORDER = ["5h", "daily", "7d", "monthly"]
const GROUP_ORDER = ["Gemini", "Claude"]

function windowRank(window: string): number {
  const index = WINDOW_ORDER.indexOf(window)
  return index === -1 ? WINDOW_ORDER.length : index
}

function quotaWindow(label: string): string {
  if (/five[\s-]?hour/i.test(label)) return "5h"
  if (/weekly|week/i.test(label)) return "7d"
  if (/daily|day/i.test(label)) return "daily"
  if (/monthly|month/i.test(label)) return "monthly"
  return label.replace(/\s*limit\s*remaining\s*/i, "").trim() || "limit"
}

function quotaGroupName(label: string): string {
  const stripped = label.replace(/\s*models?\s*$/i, "").trim()
  const lead = stripped.split(/\s+and\s+/i)[0].trim()
  return lead || stripped || label
}

function groupRank(label: string): number {
  const index = GROUP_ORDER.indexOf(quotaGroupName(label))
  return index === -1 ? GROUP_ORDER.length : index
}

export interface QuotaColumn {
  key: string
  group: string
  window: string
  header: string
}

export function antigravityQuotaColumns(
  quotas: AntigravityQuotaAccount[]
): QuotaColumn[] {
  const seen = new Map<string, QuotaColumn>()
  for (const quota of quotas) {
    for (const group of quota.groups ?? []) {
      const full = group.displayName ?? ""
      for (const bucket of group.buckets ?? []) {
        const label = bucket.displayName || bucket.bucketId || "limit"
        const window = quotaWindow(label)
        const key = `${full}::${window}`
        if (!seen.has(key)) {
          seen.set(key, {
            key,
            group: full,
            window,
            header: `${quotaGroupName(full)} ${window}`,
          })
        }
      }
    }
  }
  return [...seen.values()].sort(
    (a, b) =>
      windowRank(a.window) - windowRank(b.window) ||
      groupRank(a.group) - groupRank(b.group) ||
      a.group.localeCompare(b.group)
  )
}

export function AntigravityQuotaCell({
  quota,
  column,
  first,
}: {
  quota?: AntigravityQuotaAccount
  column: QuotaColumn
  first: boolean
}) {
  if (!quota) return <Dash />
  if (quota.error) {
    return first ? (
      <Badge variant="secondary" title={quota.error}>
        unavailable
      </Badge>
    ) : (
      <Dash />
    )
  }

  const group = (quota.groups ?? []).find(
    (candidate) => (candidate.displayName ?? "") === column.group
  )
  const bucket = (group?.buckets ?? []).find(
    (candidate) =>
      quotaWindow(
        candidate.displayName || candidate.bucketId || "limit"
      ) === column.window
  )
  if (!bucket) return <Dash />

  return (
    <QuotaValue
      fraction={bucket.remainingFraction ?? 0}
      reset={quotaResetShort(bucket.resetTime)}
      title={column.header}
    />
  )
}
