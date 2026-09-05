import { errorMessage } from "@/lib/utils"

export interface Health {
  status: string
  detail?: string
  version: string
  api: string
}

export interface UsageRecord {
  id: string
  timestamp: string
  account: string
  model: string
  upstream_model: string
  stream: boolean
  status: number
  error?: string
  input_tokens: number
  output_tokens: number
  cached_tokens: number
  total_tokens: number
  cache_read_rate: number
  latency_ms: number
  ttft_ms: number
  reasoning_effort?: string
  finish_reason: string
  cost_usd: number
  provider?: string
  alias?: string
  request_id?: string
  token_breakdown?: UsageTokenBreakdown | null
}

interface UsageTokenBreakdown {
  input: { total_tokens: number; cache_read_tokens: number; cache_write_tokens: number }
  output: { total_tokens: number }
}


export type AccountProvider =
  | "commandcode"
  | "workbuddy"

export interface Account {
  name: string
  provider: AccountProvider
  key: string
  session_token?: string
  workbuddy_uid?: string
  workbuddy_nickname?: string
  disabled?: boolean
}

export interface AccountList {
  accounts: Account[]
}

export interface AccountLimits {
  name: string
  provider?: AccountProvider
  plan?: string
  monthly_credits: number
  monthly_cap: number
  five_hour_cap: number
  five_hour_used: number
  five_hour_reset_at: number
  weekly_cap: number
  weekly_used: number
  weekly_reset_at: number
  purchased_credits?: number
  source: "live" | "stored"
  fetched_at?: string
}

export interface AllLimits {
  accounts: AccountLimits[]
}

const API_BASE = "/api"

async function fetchJSON<T>(path: string, signal?: AbortSignal): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, { signal })
  if (!res.ok) {
    throw new Error(`${path}: HTTP ${res.status}`)
  }
  return (await res.json()) as T
}

export async function getHealth(signal?: AbortSignal): Promise<Health> {
  return fetchJSON<Health>("/health", signal)
}

export async function getAccounts(signal?: AbortSignal): Promise<AccountList> {
  return fetchJSON<AccountList>("/accounts", signal)
}

export async function getAllLimits(signal?: AbortSignal): Promise<AllLimits> {
  return fetchJSON<AllLimits>("/limits/all", signal)
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  return sendJSON<T>(path, "POST", body)
}

async function putJSON<T>(path: string, body: unknown): Promise<T> {
  return sendJSON<T>(path, "PUT", body)
}

async function sendJSON<T>(path: string, method: string, body: unknown): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    const text = await res.text().catch(() => "")
    throw new Error(`${path}: HTTP ${res.status}${text ? `: ${text}` : ""}`)
  }
  return (await res.json()) as T
}

export async function addAccount(input: {
  name: string
  provider?: AccountProvider
  key?: string
  session_token?: string
}): Promise<{ ok: boolean; name: string }> {
  return postJSON("/accounts", input)
}

export async function editAccount(input: {
  name: string
  new_name?: string
  key?: string
  session_token?: string
  disabled?: boolean
}): Promise<{ ok: boolean; name: string }> {
  return postJSON("/accounts/edit", input)
}

export async function removeAccount(
  name: string
): Promise<{ ok: boolean; name: string }> {
  const res = await fetch(`${API_BASE}/accounts?name=${encodeURIComponent(name)}`, {
    method: "DELETE",
  })
  if (!res.ok) {
    const text = await res.text().catch(() => "")
    throw new Error(`DELETE /accounts: HTTP ${res.status}${text ? `: ${text}` : ""}`)
  }
  return (await res.json()) as { ok: boolean; name: string }
}


interface WorkbuddyAccountStatus {
  uid: string
  nickname?: string
  credits: number
  cooling: boolean
  cool_kind?: string
  cool_remaining_sec?: number
  reason?: string
  disabled: boolean
  success_count?: number
  err_count?: number
}

export interface WorkbuddyStatus {
  accounts: WorkbuddyAccountStatus[]
  total: number
  healthy: number
  cooling: number
  disabled: number
}

export async function getWorkbuddyStatus(
  signal?: AbortSignal
): Promise<WorkbuddyStatus> {
  return fetchJSON<WorkbuddyStatus>("/workbuddy/status", signal)
}

export interface WorkbuddyLocalCredential {
  found: boolean
  source?: string
  uid?: string
  nickname?: string
  domain?: string
  auth_json?: string
  searched?: string[]
}

export async function readWorkbuddyLocal(
  signal?: AbortSignal
): Promise<WorkbuddyLocalCredential> {
  return fetchJSON<WorkbuddyLocalCredential>("/accounts/workbuddy/local", signal)
}

export async function addWorkbuddyAccount(
  authJson: string
): Promise<{ ok: boolean; name: string; uid: string; nickname: string }> {
  return postJSON("/accounts/workbuddy", { auth_json: authJson })
}

export async function refreshWorkbuddy(): Promise<WorkbuddyStatus> {
  return postJSON("/workbuddy/refresh", {})
}

export interface WorkbuddyOAuthStart {
  session: string
  url: string
}

export async function startWorkbuddyOAuth(
  signal?: AbortSignal
): Promise<WorkbuddyOAuthStart> {
  return fetchJSON<WorkbuddyOAuthStart>("/oauth/workbuddy/start", signal)
}

export interface WorkbuddyOAuthStatus {
  done: boolean
  success: boolean
  uid?: string
  nickname?: string
  error?: string
  url?: string
}

export async function getWorkbuddyOAuthStatus(
  session: string,
  signal?: AbortSignal
): Promise<WorkbuddyOAuthStatus> {
  return fetchJSON<WorkbuddyOAuthStatus>(
    `/oauth/workbuddy/status?session=${encodeURIComponent(session)}`,
    signal
  )
}


export interface ModelPrice {
  input: number
  output: number
  cached: number
  input_peak?: number
  output_peak?: number
  cached_peak?: number
  peak_windows?: [number, number][]
}

export interface PricesMap {
  [model: string]: ModelPrice
}

export const DEFAULT_PEAK_WINDOWS: [number, number][] = [
  [1, 4],
  [6, 10],
]

export async function getPrices(signal?: AbortSignal): Promise<PricesMap> {
  const data = await fetchJSON<{ prices: PricesMap }>("/prices", signal)
  return data.prices ?? {}
}

export const PRICES_SAVED_EVENT = "raven:prices-saved"

export async function savePrices(prices: PricesMap): Promise<void> {
  await postJSON<{ ok: boolean }>("/prices", prices)
  window.dispatchEvent(new Event(PRICES_SAVED_EVENT))
}


export async function fetchEffortLevels(signal?: AbortSignal): Promise<string[]> {
  const data = await fetchJSON<{ levels: string[] }>("/effort-levels", signal)
  return data.levels ?? []
}


export interface ModelsDevLookup {
  source: string
  input: number | null
  output: number | null
  cache_read: number | null
  cache_write: number | null
  efforts: string[]
  context?: number | null
  peak_input?: number | null
  peak_output?: number | null
  peak_cache_read?: number | null
}

export function stripModelVendorAndProvider(model: string): string {
  let name = model.trim()
  const at = name.lastIndexOf("@")
  if (at > 0) name = name.slice(0, at)
  const slash = name.lastIndexOf("/")
  if (slash >= 0 && slash < name.length - 1) name = name.slice(slash + 1)
  return name
}

export async function fetchModelsDev(
  model: string,
  signal?: AbortSignal
): Promise<ModelsDevLookup> {
  const name = stripModelVendorAndProvider(model)
  return fetchJSON<ModelsDevLookup>(
    `/models-dev?model=${encodeURIComponent(name)}`,
    signal
  )
}

export function friendlyLookupError(err: unknown, what: string): string {
  const text = err instanceof Error ? err.message : String(err)
  if (/HTTP 404/.test(text)) {
    return `Not found on models.dev — no ${what}. Check the upstream model name.`
  }
  return errorMessage(err, `Failed to fetch ${what}`)
}


export function formatContextWindow(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return ""
  if (n % 1_000_000 === 0) return `${n / 1_000_000}M`
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2).replace(/\.?0+$/, "")}M`
  if (n >= 1_000) return `${Math.round(n / 1_000)}K`
  return String(n)
}

export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(2)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}

export function formatPercent(ratio: number): string {
  return `${(ratio * 100).toFixed(0)}%`
}

export function tpsFor(outputTokens: number, latencyMs: number): number | null {
  if (!latencyMs || latencyMs <= 0) return null
  return outputTokens / (latencyMs / 1000)
}

export function formatCost(usd: number): string {
  if (usd === 0) return "$0.00"
  if (usd < 0.01) return `$${usd.toFixed(4)}`
  return `$${usd.toFixed(2)}`
}

export function formatDuration(ms: number): string {
  if (ms <= 0) return "—"
  if (ms < 1000) return `${Math.max(1, Math.round(ms))}ms`
  return `${(ms / 1000).toFixed(2)}s`
}

export function formatDateTime(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ""
  return d.toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  })
}

function hourBucketISO(ts: string): string {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return ts.slice(0, 13)
  d.setUTCMinutes(0, 0, 0)
  return d.toISOString()
}

function hourBucketLabel(ts: string): string {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return ""
  return d.toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
  })
}


export const USAGE_STREAM_URL = "/api/usage/stream"

export async function getUsageRecords(signal?: AbortSignal): Promise<UsageRecord[]> {
  const data = await fetchJSON<{ data: UsageRecord[] }>("/usage", signal)
  return data.data ?? []
}

export async function clearUsage(): Promise<void> {
  const res = await fetch(`${API_BASE}/usage`, { method: "DELETE" })
  if (!res.ok) {
    const text = await res.text().catch(() => "")
    throw new Error(`DELETE /usage: HTTP ${res.status}${text ? `: ${text}` : ""}`)
  }
}



interface ProviderThinkingSupport {
  levels?: string[]
  min?: number
  max?: number
  "zero-allowed"?: boolean
  "dynamic-allowed"?: boolean
  [extra: string]: unknown
}

export interface ProviderModelDef {
  name: string
  alias?: string
  thinking?: ProviderThinkingSupport
  "max-context-length"?: number
  [extra: string]: unknown
}

export interface ProviderEntry {
  name: string
  disabled: boolean
  kind?: "openai" | "responses" | "workbuddy" | "commandcode"
  "base-url": string
  project?: string
  "api-key-entries": { "api-key": string; "proxy-url"?: string }[]
  models: ProviderModelDef[]
}

export function blankProviderEntry(
  kind: NonNullable<ProviderEntry["kind"]>,
  name = ""
): ProviderEntry {
  return {
    name,
    disabled: false,
    kind,
    "base-url": "",
    "api-key-entries": [],
    models: [],
  }
}

export function isManagedZone(p: ProviderEntry): boolean {
  return p.kind === "workbuddy" || p.kind === "commandcode"
}

export async function getProviders(signal?: AbortSignal): Promise<ProviderEntry[]> {
  const data = await fetchJSON<ProviderEntry[]>("/providers", signal)
  return data.map((p) => ({
    ...p,
    name: p.name ?? "",
    disabled: p.disabled ?? false,
    kind: p.kind ?? "openai",
    "base-url": p["base-url"] ?? "",
    "api-key-entries": p["api-key-entries"] ?? [],
    models: p.models ?? [],
  }))
}

export async function saveProviders(providers: ProviderEntry[]): Promise<void> {
  await putJSON<{ ok: boolean }>("/providers", providers)
}

export interface UpstreamCatalogModel {
  id: string
  display_name?: string
  context_length?: number
}

export async function fetchProviderModels(
  index: number,
  signal?: AbortSignal
): Promise<UpstreamCatalogModel[]> {
  const data = await fetchJSON<{
    models: string[]
    entries?: UpstreamCatalogModel[]
  }>(`/providers/models?index=${index}`, signal)
  if (data.entries?.length) return data.entries
  return (data.models ?? []).map((id) => ({ id }))
}

export interface ZoneModel {
  id: string
  display_name: string
  context_length?: number
  max_completion_tokens?: number
  efforts?: string[]
}

export async function fetchZoneModels(
  kind: "workbuddy" | "commandcode",
  signal?: AbortSignal
): Promise<ZoneModel[]> {
  const data = await fetchJSON<{ models: ZoneModel[] }>(
    `/providers/${kind}/models`,
    signal
  )
  return data.models ?? []
}

function costTokens(r: UsageRecord): {
  input: number
  output: number
  cached: number
} {
  return {
    input: r.token_breakdown?.input?.total_tokens ?? r.input_tokens,
    output: r.token_breakdown?.output?.total_tokens ?? r.output_tokens,
    cached: r.token_breakdown?.input?.cache_read_tokens ?? r.cached_tokens,
  }
}

export function recordEndTimeMs(r: UsageRecord): number {
  const start = new Date(r.timestamp).getTime()
  return Number.isNaN(start) ? 0 : start + r.latency_ms
}


export function buildProviderModelIndex(
  providers: ProviderEntry[]
): Map<string, string[]> {
  const index = new Map<string, string[]>()
  for (const p of providers) {
    if (!p.name.trim()) continue
    for (const m of p.models) {
      for (const key of [m.alias, m.name]) {
        const k = key?.trim().toLowerCase()
        if (!k) continue
        const names = index.get(k)
        if (!names) {
          index.set(k, [p.name])
        } else if (!names.includes(p.name)) {
          names.push(p.name)
        }
      }
    }
  }
  return index
}

export function resolveModelDisplay(
  modelKey: string,
  index: Map<string, string[]>
): { provider: string | null; short: string } {
  const short = stripModelVendorAndProvider(modelKey)
  const names = index.get(modelKey.trim().toLowerCase())
  return { provider: names?.length === 1 ? names[0] : null, short }
}

export function usageStatus(r: UsageRecord): number {
  return r.status
}

export function usageCacheRead(r: UsageRecord): number {
  return r.token_breakdown?.input?.cache_read_tokens ?? r.cached_tokens
}
export function usageInputTotal(r: UsageRecord): number {
  return r.token_breakdown?.input?.total_tokens ?? r.input_tokens
}
export function usageOutputTotal(r: UsageRecord): number {
  return r.token_breakdown?.output?.total_tokens ?? r.output_tokens
}

export interface UsageModelAgg {
  model: string
  provider: string
  requests: number
  errors: number
  input: number
  output: number
  cached: number
  total: number
  cost: number
  latSum: number
  ok: number
  ttftSum: number
  ttftOk: number
  tpsSum: number
}

export function aggregateUsageByModel(records: UsageRecord[]): UsageModelAgg[] {
  const map = new Map<string, UsageModelAgg>()
  for (const r of records) {
    const key = r.alias || r.model
    let m = map.get(key)
    if (!m) {
      m = {
        model: key,
        provider: r.provider ?? "",
        requests: 0,
        errors: 0,
        input: 0,
        output: 0,
        cached: 0,
        total: 0,
        cost: 0,
        latSum: 0,
        ok: 0,
        ttftSum: 0,
        ttftOk: 0,
        tpsSum: 0,
      }
      map.set(key, m)
    }
    m.requests += 1
    if (r.status >= 400) m.errors += 1
    m.input += usageInputTotal(r)
    m.output += usageOutputTotal(r)
    m.cached += usageCacheRead(r)
    m.total += r.total_tokens
    m.cost += r.cost_usd
    if (r.status < 400) {
      m.ok += 1
      m.latSum += r.latency_ms
      if (r.ttft_ms > 0 && r.ttft_ms <= r.latency_ms) {
        m.ttftSum += r.ttft_ms
        m.ttftOk += 1
      }
      m.tpsSum += tpsFor(r.output_tokens, r.latency_ms) ?? 0
    }
  }
  return Array.from(map.values()).sort((a, b) => b.total - a.total)
}

export interface UsagePoint {
  timestamp: string
  label: string
  inputTokens: number
  outputTokens: number
  totalTokens: number
  cost: number
  requests: number
}

export function bucketizeUsage(records: UsageRecord[]): UsagePoint[] {
  const buckets = new Map<string, UsagePoint>()
  for (const r of records) {
    const ts = hourBucketISO(r.timestamp)
    let b = buckets.get(ts)
    if (!b) {
      b = {
        timestamp: ts,
        label: hourBucketLabel(ts),
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
        cost: 0,
        requests: 0,
      }
      buckets.set(ts, b)
    }
    const { input, output } = costTokens(r)
    b.inputTokens += input
    b.outputTokens += output
    b.totalTokens += r.total_tokens
    b.cost += r.cost_usd
    b.requests += 1
  }
  return Array.from(buckets.values()).sort((a, b) =>
    a.timestamp.localeCompare(b.timestamp)
  )
}

export interface UsageTotals {
  input: number
  output: number
  cached: number
  total: number
  cost: number
  requests: number
  ttftSum: number
  ttftCount: number
  latSum: number
  latCount: number
  tpsSum: number
  usedModels: number
}

export function aggregateUsageTotals(records: UsageRecord[]): UsageTotals {
  const models = new Set<string>()
  const acc: UsageTotals = {
    input: 0,
    output: 0,
    cached: 0,
    total: 0,
    cost: 0,
    requests: 0,
    ttftSum: 0,
    ttftCount: 0,
    latSum: 0,
    latCount: 0,
    tpsSum: 0,
    usedModels: 0,
  }
  for (const r of records) {
    models.add(r.alias || r.model)
    const { input, output, cached } = costTokens(r)
    acc.input += input
    acc.output += output
    acc.cached += cached
    acc.total += r.total_tokens
    acc.cost += r.cost_usd
    acc.requests += 1
    if (r.status < 400) {
      if (r.ttft_ms > 0 && r.ttft_ms <= r.latency_ms) {
        acc.ttftSum += r.ttft_ms
        acc.ttftCount += 1
      }
      acc.latSum += r.latency_ms
      acc.latCount += 1
      acc.tpsSum += tpsFor(r.output_tokens, r.latency_ms) ?? 0
    }
  }
  acc.usedModels = models.size
  return acc
}
