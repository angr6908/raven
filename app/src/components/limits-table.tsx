import { cn } from "@/lib/utils"

function Bar({ value, className }: { value: number; className?: string }) {
  return (
    <div className={cn("h-1 overflow-hidden rounded-none bg-muted", className)}>
      <div
        className="h-full rounded-none bg-primary"
        style={{ width: `${Math.min(100, Math.max(0, value))}%` }}
      />
    </div>
  )
}

export function LimitCell({
  primary,
  hint,
  progress,
  footer,
}: {
  primary: string
  hint?: string | null
  progress?: number | null
  footer?: string | null
}) {
  return (
    <div className="flex flex-col gap-1">
      <div className="whitespace-nowrap tabular-nums">
        {primary}
        {hint ? (
          <span className="text-xs font-normal text-muted-foreground">
            {" "}
            {hint}
          </span>
        ) : null}
      </div>
      {progress != null ? <Bar value={progress} className="w-24" /> : null}
      {footer ? (
        <span className="whitespace-nowrap text-[11px] text-muted-foreground">
          {footer}
        </span>
      ) : null}
    </div>
  )
}

