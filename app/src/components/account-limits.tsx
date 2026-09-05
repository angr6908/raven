import { Clock } from "lucide-react"

import {
  type AccountLimits,
  type AntigravityQuotaAccount,
  formatCost,
  formatDateTime,
} from "@/lib/api"
import { Badge } from "@/components/ui/badge"
import { LimitCell } from "@/components/limits-table"
import { Dash } from "@/components/dash"


const DEFAULT_MONTHLY_CAP = 10

function pct(used: number, cap: number): number {
  if (cap <= 0) return 0
  return Math.min(100, (used / cap) * 100)
}

function remainingOfCap(
  used: number | null,
  cap: number | null,
  resetAt: number | null
): React.ReactNode {
  if (used == null || cap == null || cap <= 0) return <Dash />
  const remaining = Math.max(0, cap - used)
  return (
    <LimitCell
      primary={`${formatCost(remaining)} / ${formatCost(cap)}`}
      progress={pct(remaining, cap)}
      footer={
        resetAt && resetAt > 0
          ? `resets ${formatDateTime(new Date(resetAt).toISOString())}`
          : null
      }
    />
  )
}

export type UsagePeriod = "fiveHour" | "weekly" | "monthly"

export function CommandCodeUsageCell({
  limits,
  period,
}: {
  limits: AccountLimits
  period: UsagePeriod
}) {
  if (period === "fiveHour") {
    return remainingOfCap(
      limits.five_hour_used,
      limits.five_hour_cap,
      limits.five_hour_reset_at
    )
  }
  if (period === "weekly") {
    return remainingOfCap(
      limits.weekly_used,
      limits.weekly_cap,
      limits.weekly_reset_at
    )
  }
  if (limits.monthly_credits == null) return <Dash />
  const cap = limits.monthly_cap ?? DEFAULT_MONTHLY_CAP
  const remaining = Math.min(limits.monthly_credits, cap)
  return (
    <LimitCell
      primary={formatCost(remaining)}
      hint={limits.purchased_credits ? `+${formatCost(limits.purchased_credits)}` : null}
      progress={pct(remaining, cap)}
      footer={limits.monthly_cap == null ? `of ${formatCost(cap)}` : null}
    />
  )
}


function quotaPercent(fraction: number): string {
  const value = Math.max(0, Math.min(1, fraction)) * 100
  return `${value.toFixed(value < 10 && value > 0 ? 1 : 0)}%`
}


function quotaReset(resetTime?: string): string | null {
  if (!resetTime) return null
  const at = Date.parse(resetTime)
  if (!Number.isFinite(at)) return null
  const minutes = Math.round((at - Date.now()) / 60000)
  if (minutes <= 0) return "resets now"
  const days = Math.floor(minutes / (60 * 24))
  const hours = Math.floor((minutes % (60 * 24)) / 60)
  if (days > 0) return `resets in ${days}d${hours}h`
  if (hours > 0) return `resets in ${hours}h${minutes % 60}m`
  return `resets in ${minutes}m`
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

function quotaResetShort(resetTime?: string): string | null {
  const full = quotaReset(resetTime)
  if (!full) return null
  return full === "resets now" ? "now" : full.replace(/^resets\s+in\s+/, "")
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

  const reset = quotaResetShort(bucket.resetTime)
  return (
    <span className="whitespace-nowrap">
      <span className="tabular-nums">
        {quotaPercent(bucket.remainingFraction ?? 0)}
      </span>
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
