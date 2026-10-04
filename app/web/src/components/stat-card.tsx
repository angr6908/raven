import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

export function StatCard({
  icon: Icon,
  label,
  value,
  sub,
  badge,
}: {
  icon: React.ComponentType<{ className?: string }>
  label: string
  value: string
  sub?: string
  badge?: string
}) {
  return (
    <Card>
      <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
        <CardTitle className="text-sm font-medium text-muted-foreground">
          {label}
        </CardTitle>
        <Icon className="size-4 text-muted-foreground" />
      </CardHeader>
      <CardContent>
        <div className="text-2xl font-semibold tabular-nums">{value}</div>
        {sub ? (
          <p className="text-xs text-muted-foreground">{sub}</p>
        ) : null}
        {badge ? (
          <Badge variant="outline" className="mt-2">
            {badge}
          </Badge>
        ) : null}
      </CardContent>
    </Card>
  )
}
