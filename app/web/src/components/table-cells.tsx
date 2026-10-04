import { formatDuration, formatTokens } from "@/lib/api"

export function WithSuffix({
  main,
  extra,
}: {
  main: string
  extra?: string | null
}) {
  return (
    <>
      {main}
      {extra ? (
        <span className="ml-1 font-normal text-muted-foreground">
          · {extra}
        </span>
      ) : null}
    </>
  )
}

export function ModelName({ name }: { name: string }) {
  return (
    <span className="block max-w-52 truncate font-mono text-xs" title={name}>
      {name}
    </span>
  )
}

export function TokensWithCache({
  total,
  cached,
}: {
  total: number
  cached: number
}) {
  return (
    <WithSuffix
      main={formatTokens(total)}
      extra={cached > 0 ? `${formatTokens(cached)} cached` : null}
    />
  )
}

export function DurationWithTtft({
  ms,
  ttftMs,
}: {
  ms: number
  ttftMs: number
}) {
  return (
    <WithSuffix
      main={formatDuration(ms)}
      extra={ttftMs > 0 ? `${formatDuration(ttftMs)} first` : null}
    />
  )
}
