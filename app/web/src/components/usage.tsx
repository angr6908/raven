import { useMemo, useState } from "react"

import { Card, CardAction, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { DataTable, DataTableSearch } from "@/components/data-table"
import { TableCell, TableRow } from "@/components/ui/table"
import { Button } from "@/components/ui/button"
import {
  type ProviderEntry,
  type UsageRecord,
  aggregateUsageByModel,
  aggregateUsageTotals,
  buildProviderModelIndex,
  clearUsage,
  formatCost,
  formatDuration,
  formatPercent,
  formatTokens,
} from "@/lib/api"
import {
  usageModelColumns,
  usageRequestColumns,
} from "@/components/usage-table"
import { WithSuffix } from "@/components/table-cells"

export function UsageView({
  records,
  providers,
  onCleared,
}: {
  records: UsageRecord[]
  providers: ProviderEntry[]
  onCleared: () => void
}) {
  const [requestFilter, setRequestFilter] = useState("")
  const [clearing, setClearing] = useState(false)
  const [clearError, setClearError] = useState<string>()

  const handleClear = async () => {
    setClearing(true)
    setClearError(undefined)
    try {
      await clearUsage()
      setClearing(false)
      onCleared()
    } catch (err) {
      setClearing(false)
      setClearError(err instanceof Error ? err.message : "Failed to clear")
    }
  }
  const providerIndex = useMemo(() => buildProviderModelIndex(providers), [providers])

  const byModel = useMemo(() => aggregateUsageByModel(records), [records])

  const totals = useMemo(() => {
    const t = aggregateUsageTotals(records)
    const ok = t.latCount
    return {
      ...t,
      duration: ok ? formatDuration(t.latSum / ok) : "—",
      ttft: t.ttftCount ? formatDuration(t.ttftSum / t.ttftCount) : null,
      tps: ok ? (t.tpsSum / ok).toFixed(1) : "—",
      cacheRate: t.input ? formatPercent(t.cached / t.input) : "—",
      successRate: t.requests ? formatPercent(ok / t.requests) : "—",
    }
  }, [records])

  const modelColumns = useMemo(() => usageModelColumns(providerIndex), [providerIndex])
  const requestColumns = useMemo(
    () => usageRequestColumns(providerIndex),
    [providerIndex]
  )

  return (
    <div className="grid gap-6">
      <Card className="min-w-0">
        <CardHeader>
          <CardTitle>Usage by model</CardTitle>
        </CardHeader>
        <CardContent>
          <DataTable
            columns={modelColumns}
            data={byModel}
            tableLabel="Usage by model"
            hidePaginationOnSinglePage
            footer={
              <TableRow className="font-semibold border-t-2 border-foreground/20">
                <TableCell>Total</TableCell>
                <TableCell />
                <TableCell className="text-right tabular-nums">{totals.successRate}</TableCell>
                <TableCell className="text-right tabular-nums">
                  <WithSuffix
                    main={formatTokens(totals.input)}
                    extra={
                      totals.cached > 0
                        ? `${formatTokens(totals.cached)} cached`
                        : null
                    }
                  />
                </TableCell>
                <TableCell className="text-right tabular-nums">{totals.cacheRate}</TableCell>
                <TableCell className="text-right tabular-nums">{formatTokens(totals.output)}</TableCell>
                <TableCell className="text-right tabular-nums whitespace-nowrap">
                  <WithSuffix
                    main={totals.duration}
                    extra={totals.ttft ? `${totals.ttft} first` : null}
                  />
                </TableCell>
                <TableCell className="text-right tabular-nums">{totals.tps}</TableCell>
                <TableCell className="text-right tabular-nums">{formatCost(totals.cost)}</TableCell>
              </TableRow>
            }
          />
        </CardContent>
      </Card>

      <Card className="min-w-0">
        <CardHeader>
          <CardTitle>Request log</CardTitle>
          <CardAction>
            <div className="flex items-center gap-2">
              {clearError ? (
                <span className="text-xs text-destructive">{clearError}</span>
              ) : null}
              <Button
                variant="outline"
                size="sm"
                className="h-7 px-2 text-xs"
                isDisabled={records.length === 0 || clearing}
                onPress={() => void handleClear()}
              >
                {clearing ? "Clearing…" : "Clear"}
              </Button>
              <DataTableSearch
                value={requestFilter}
                onChange={setRequestFilter}
                placeholder="Filter by model…"
                className="w-56"
              />
            </div>
          </CardAction>
        </CardHeader>
        <CardContent>
          <DataTable
            columns={requestColumns}
            data={records}
            searchKey="model"
            searchPlaceholder="Filter by model…"
            tableLabel="Request log"
            searchValue={requestFilter}
            onSearchChange={setRequestFilter}
          />
        </CardContent>
      </Card>
    </div>
  )
}
