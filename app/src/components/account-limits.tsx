import {
  type AccountLimits,
  formatCost,
  formatDateTime,
} from "@/lib/api"
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

