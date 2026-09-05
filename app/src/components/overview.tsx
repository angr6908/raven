import { useMemo } from "react"
import { Coins, DollarSign, Gauge, Zap } from "lucide-react"
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  XAxis,
  YAxis,
} from "recharts"

import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from "@/components/ui/chart"
import type { ChartConfig } from "@/components/ui/chart.types"
import { ErrorBanner } from "@/components/error-banner"
import { Skeleton } from "@/components/ui/skeleton"
import { StatCard } from "@/components/stat-card"
import {
  type UsageRecord,
  aggregateUsageTotals,
  bucketizeUsage,
  formatCost,
  formatDuration,
  formatPercent,
  formatTokens,
} from "@/lib/api"

const chartConfig = {
  inputTokens: { label: "Input tokens", color: "var(--chart-2)" },
  outputTokens: { label: "Output tokens", color: "var(--chart-1)" },
  totalTokens: { label: "Total tokens", color: "var(--chart-4)" },
  cost: { label: "Cost", color: "var(--chart-5)" },
  requests: { label: "Requests", color: "var(--chart-2)" },
} satisfies ChartConfig

export function Overview({ records, error }: { records: UsageRecord[]; error?: string }) {
  const totals = useMemo(() => aggregateUsageTotals(records), [records])

  const avgTTFT = totals.ttftCount ? totals.ttftSum / totals.ttftCount : 0
  const avgLatency = totals.latCount ? totals.latSum / totals.latCount : 0
  const cacheRate = totals.input ? totals.cached / totals.input : 0

  const points = useMemo(() => bucketizeUsage(records), [records])

  if (records.length === 0) {
    return (
      <div className="grid gap-6">
        <ErrorBanner error={error} />
        <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
          {Array.from({ length: 4 }).map((_, i) => (
            <Card key={i}>
              <CardContent className="pt-6">
                <Skeleton className="h-4 w-24" />
                <Skeleton className="mt-3 h-8 w-20" />
              </CardContent>
            </Card>
          ))}
        </div>
      </div>
    )
  }

  return (
    <div className="grid gap-6">
      <ErrorBanner error={error} />

      {}
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        <StatCard
          icon={Coins}
          label="Total tokens"
          value={formatTokens(totals.total)}
          sub={`${formatTokens(totals.input)} in · ${formatTokens(
            totals.output
          )} out`}
        />
        <StatCard
          icon={Zap}
          label="Requests"
          value={String(totals.requests)}
          sub={`${totals.usedModels} model${totals.usedModels === 1 ? "" : "s"} used`}
        />
        <StatCard
          icon={DollarSign}
          label="Est. cost"
          value={formatCost(totals.cost)}
          badge={`${formatPercent(cacheRate)} cache hit rate`}
        />
        <StatCard
          icon={Gauge}
          label="Duration"
          value={formatDuration(avgLatency)}
          sub={`avg TTFT ${formatDuration(avgTTFT)}`}
        />
      </div>

      {}
      <Card>
        <CardHeader>
          <CardTitle>Token usage</CardTitle>
          <CardDescription>Input vs output tokens per hour</CardDescription>
        </CardHeader>
        <CardContent>
          <ChartContainer config={chartConfig} className="h-64">
            <AreaChart accessibilityLayer data={points} margin={{ left: 4, right: 8 }}>
              <CartesianGrid vertical={false} />
              <XAxis
                dataKey="label"
                tickLine={false}
                axisLine={false}
                minTickGap={24}
              />
              <YAxis
                tickLine={false}
                axisLine={false}
                tickFormatter={formatTokens}
                width={44}
              />
              <ChartTooltip
                content={<ChartTooltipContent indicator="line" />}
                cursor={false}
              />
              <Area
                dataKey="inputTokens"
                type="monotone"
                stroke="var(--color-inputTokens)"
                fill="var(--color-inputTokens)"
                fillOpacity={0.2}
                stackId="a"
                isAnimationActive={false}
              />
              <Area
                dataKey="outputTokens"
                type="monotone"
                stroke="var(--color-outputTokens)"
                fill="var(--color-outputTokens)"
                fillOpacity={0.35}
                stackId="a"
                isAnimationActive={false}
              />
            </AreaChart>
          </ChartContainer>
        </CardContent>
      </Card>

      {}
      <div className="grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Cost over time</CardTitle>
            <CardDescription>Estimated spend per hour (USD)</CardDescription>
          </CardHeader>
          <CardContent>
            <ChartContainer config={chartConfig} className="h-52">
              <BarChart accessibilityLayer data={points} margin={{ left: 4, right: 8 }}>
                <CartesianGrid vertical={false} />
                <XAxis
                  dataKey="label"
                  tickLine={false}
                  axisLine={false}
                  minTickGap={24}
                />
                <YAxis
                  tickLine={false}
                  axisLine={false}
                  width={44}
                  tickFormatter={(v) => `$${v}`}
                />
                <ChartTooltip
                  content={<ChartTooltipContent indicator="dashed" />}
                  cursor={false}
                />
                <Bar dataKey="cost" fill="var(--color-cost)" isAnimationActive={false} />
              </BarChart>
            </ChartContainer>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Requests per hour</CardTitle>
            <CardDescription>Successful + failed calls</CardDescription>
          </CardHeader>
          <CardContent>
            <ChartContainer config={chartConfig} className="h-52">
              <BarChart accessibilityLayer data={points} margin={{ left: 4, right: 8 }}>
                <CartesianGrid vertical={false} />
                <XAxis
                  dataKey="label"
                  tickLine={false}
                  axisLine={false}
                  minTickGap={24}
                />
                <YAxis
                  tickLine={false}
                  axisLine={false}
                  width={30}
                  allowDecimals={false}
                />
                <ChartTooltip
                  content={<ChartTooltipContent indicator="dashed" />}
                  cursor={false}
                />
                <Bar dataKey="requests" fill="var(--color-requests)" isAnimationActive={false} />
              </BarChart>
            </ChartContainer>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}