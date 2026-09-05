import { useEffect, useState } from "react"
import { ChevronDown } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Card, CardContent } from "@/components/ui/card"
import { Switch } from "@/components/ui/switch"
import { ModelZone, type UpstreamModel } from "@/components/model-zone"
import { cn } from "@/lib/utils"
import {
  type ProviderEntry,
  blankProviderEntry,
  fetchZoneModels,
} from "@/lib/api"

const isCommandCode = (p: ProviderEntry) => p.kind === "commandcode"

function findZones(list: ProviderEntry[]) {
  const commandCodeIndex = list.findIndex(isCommandCode)
  return {
    commandcode: commandCodeIndex >= 0 ? list[commandCodeIndex] : undefined,
    workbuddy: list.find((p) => p.kind === "workbuddy"),
  }
}

export type ZoneEditor = (
  match: (p: ProviderEntry) => boolean,
  blank: () => ProviderEntry,
  change: (p: ProviderEntry) => ProviderEntry
) => void

export function ManagedZoneCards({
  providers,
  editZone,
}: {
  providers: ProviderEntry[]
  editZone: ZoneEditor
}) {
  const { commandcode } = findZones(providers)

  return (
    <div className="grid gap-3">
      <ZoneCard
        title="Command Code"
        match={isCommandCode}
        blank={() => blankProviderEntry("commandcode", "CommandCode")}
        entry={commandcode}
        aliasOwner={commandcode?.name || "CommandCode"}
        description="The curated Command Code catalog — these aliases are exactly what raven publishes to launchers on /v1/models. Shared by every Command Code account; unlisted model ids still route by name."
        fetchUpstream={async () =>
          (await fetchZoneModels("commandcode")).map((m) => ({
            id: m.id,
            label: m.display_name || m.id,
          }))
        }
        emptyHint="No models pinned — fetch the catalog and pick, or add a row by hand."
        editZone={editZone}
      />
      <ZoneCard
        title="WorkBuddy"
        match={(p) => p.kind === "workbuddy"}
        blank={() => blankProviderEntry("workbuddy", "workbuddy")}
        entry={providers.find((p) => p.kind === "workbuddy")}
        aliasOwner="workbuddy"
        description="One catalog for every WorkBuddy account — the credentials are a pool that rotates and fails over, so the models are not tied to a single sign-in. Fetching pulls the live catalog through whichever account answers first (with the static CN table as a fallback). Turning this off disables the whole WorkBuddy channel."
        fetchUpstream={async () =>
          (await fetchZoneModels("workbuddy")).map((m) => ({
            id: m.id,
            label: m.display_name || m.id,
            context: m.context_length,
          }))
        }
        emptyHint="No models pinned — fetch the upstream catalog and pick, or add a row by hand. Unlisted workbuddy ids still route by name."
        editZone={editZone}
      />
    </div>
  )
}

function ZoneCard({
  title,
  match,
  blank,
  entry,
  aliasOwner,
  description,
  fetchUpstream,
  emptyHint,
  presetEfforts,
  onOpen,
  editZone,
  onChangeTransform,
}: {
  title: string
  match: (p: ProviderEntry) => boolean
  blank: () => ProviderEntry
  entry?: ProviderEntry
  aliasOwner: string
  description: string
  fetchUpstream?: () => Promise<UpstreamModel[]>
  emptyHint: string
  presetEfforts?: (modelName: string) => string[]
  onOpen?: () => void
  editZone: ZoneEditor
  onChangeTransform?: (p: ProviderEntry) => ProviderEntry
}) {
  const [open, setOpen] = useState(false)
  const models = entry?.models ?? []
  const enabled = !(entry?.disabled ?? false)

  useEffect(() => {
    if (open) onOpen?.()
  }, [open, onOpen])

  return (
    <Card size="sm" className={cn("min-w-0 py-0", !enabled && "opacity-70")}>
      <div className="flex items-center gap-2 px-3 py-2.5">
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          aria-label={`Toggle ${title} models`}
          className="flex min-w-0 flex-1 items-center gap-2 text-left outline-none focus-visible:ring-1 focus-visible:ring-ring/50"
        >
          <ChevronDown
            className={cn(
              "size-4 shrink-0 text-muted-foreground transition-transform",
              !open && "-rotate-90"
            )}
          />
          <div className="grid min-w-0 flex-1 gap-0.5">
            <div className="flex items-center gap-2">
              <span className="truncate text-sm font-medium">{title}</span>
              {enabled ? null : (
                <Badge variant="outline" className="text-muted-foreground">
                  off
                </Badge>
              )}
            </div>
            <span className="truncate text-xs text-muted-foreground">
              {models.length === 0
                ? "no models pinned — pass-through"
                : `${models.length} model${models.length === 1 ? "" : "s"} pinned`}
            </span>
          </div>
        </button>
        <span className="hidden shrink-0 font-mono text-xs text-muted-foreground sm:inline">
          {models.length === 0 ? "pass-through" : `${models.length} pinned`}
        </span>
        <Switch
          aria-label={`${title} models enabled`}
          isSelected={enabled}
          onChange={(on) =>
            editZone(match, blank, (p) => ({ ...p, disabled: !on }))
          }
        >
          <span className="text-xs leading-none">Enabled</span>
        </Switch>
      </div>

      {open ? (
        <CardContent className="grid gap-3 border-t px-3 py-3">
          <p className="text-xs/relaxed text-muted-foreground">{description}</p>
          <ModelZone
            entry={entry}
            aliasOwner={aliasOwner}
            fetchUpstream={fetchUpstream}
            emptyHint={emptyHint}
            presetEfforts={presetEfforts}
            onChange={(change) =>
              editZone(match, blank, (p) =>
                onChangeTransform
                  ? onChangeTransform(change(p))
                  : change(p)
              )
            }
          />
        </CardContent>
      ) : null}
    </Card>
  )
}

