import { useCallback, useEffect, useState } from "react"

import { AppShell } from "@/components/app-shell"
import { NAV, type PanelPage } from "@/components/nav"
import { Overview } from "@/components/overview"
import { Accounts } from "@/components/accounts"
import { UsageView } from "@/components/usage"
import { ProvidersView } from "@/components/providers"
import { PricingView } from "@/components/pricing"
import {
  type AccountLimits,
  type AccountList,
  type Health,
  type ProviderEntry,
  getAccounts,
  getAllLimits,
  getHealth,
  getProviders,
} from "@/lib/api"
import { useUsageLive } from "@/hooks/use-usage"

const POLL_MS = 15_000

function pageFromHash(): PanelPage {
  const hash = window.location.hash.replace(/^#\/?/, "")
  return NAV.some((n) => n.id === hash) ? (hash as PanelPage) : "overview"
}

export default function App() {
  const [page, setPage] = useState<PanelPage>(pageFromHash)
  const [health, setHealth] = useState<Health>()
  const [accounts, setAccounts] = useState<AccountList>({
    accounts: [],
  })
  const [limits, setLimits] = useState<AccountLimits[]>()
  const [providers, setProviders] = useState<ProviderEntry[]>([])
  const usage = useUsageLive()

  useEffect(() => {
    const onHash = () => setPage(pageFromHash())
    window.addEventListener("hashchange", onHash)
    return () => window.removeEventListener("hashchange", onHash)
  }, [])

  const navigate = useCallback((p: PanelPage) => {
    setPage(p)
    window.location.hash = p === "overview" ? "" : `/${p}`
  }, [])

  const refreshConfig = useCallback(() => {
    void getProviders()
      .then(setProviders)
      .catch(() => {})
  }, [])

  const load = useCallback(async () => {
    const requests: Promise<unknown>[] = [
      getHealth()
        .then(setHealth)
        .catch(() => setHealth(undefined)),
    ]
    if (page === "accounts") {
      requests.push(
        getAccounts().then(setAccounts),
        getAllLimits().then((result) => setLimits(result.accounts))
      )
    }
    await Promise.allSettled(requests)
  }, [page])

  const reload = useCallback(() => {
    refreshConfig()
    void load()
  }, [refreshConfig, load])

  useEffect(() => {
    refreshConfig()
  }, [refreshConfig])

  useEffect(() => {
    void load()
    const id = window.setInterval(() => {
      void load()
    }, POLL_MS)
    return () => window.clearInterval(id)
  }, [load])

  return (
    <AppShell
      page={page}
      onNavigate={navigate}
      health={health}
    >
      {page === "overview" ? (
        <Overview records={usage.records} error={usage.error} />
      ) : page === "usage" ? (
        <UsageView
          records={usage.records}
          providers={providers}
          onCleared={usage.clear}
        />
      ) : page === "accounts" ? (
        <Accounts
          accounts={accounts.accounts}
          limits={limits}
          onChanged={reload}
        />
      ) : page === "models" ? (
        <ProvidersView onSaved={refreshConfig} />
      ) : page === "pricing" ? (
        <PricingView records={usage.records} />
      ) : null}
    </AppShell>
  )
}