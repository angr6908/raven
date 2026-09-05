import { useCallback, useEffect, useRef, useState } from "react"
import {
  PRICES_SAVED_EVENT,
  USAGE_STREAM_URL,
  type UsageRecord,
  getUsageRecords,
  recordEndTimeMs,
} from "@/lib/api"

const MAX_RECORDS = 2000

const recordKey = (r: UsageRecord) => r.request_id || r.timestamp

export function useUsageLive() {
  const [records, setRecords] = useState<UsageRecord[]>([])
  const clear = useCallback(() => {
    setRecords([])
  }, [])
  const [error, setError] = useState<string>()
  const esRef = useRef<EventSource | null>(null)
  const reconnectTimer = useRef<number | null>(null)

  const fetchSnapshot = useCallback(async (reprice = false) => {
    try {
      const data = await getUsageRecords()
      setRecords((prev) => {
        if (prev.length === 0) return data
        const fresh = new Map(data.map((r) => [recordKey(r), r]))
        let changed = false
        const merged = prev.map((r) => {
          const server = reprice ? fresh.get(recordKey(r)) : undefined
          if (server) changed = true
          return server ?? r
        })
        const seen = new Set(prev.map(recordKey))
        for (const r of data) {
          if (!seen.has(recordKey(r))) {
            merged.push(r)
            changed = true
          }
        }
        if (!changed) return prev
        merged.sort((a, b) => recordEndTimeMs(b) - recordEndTimeMs(a))
        return merged.slice(0, MAX_RECORDS)
      })
      return true
    } catch (e) {
      setError(e instanceof Error ? e.message : "failed to fetch usage")
      return false
    }
  }, [])

  useEffect(() => {
    const onPricesSaved = () => {
      void fetchSnapshot(true)
    }
    window.addEventListener(PRICES_SAVED_EVENT, onPricesSaved)
    return () => window.removeEventListener(PRICES_SAVED_EVENT, onPricesSaved)
  }, [fetchSnapshot])

  useEffect(() => {
    let closed = false
    let snapshotPending = false
    let fallbackTimer: number | null = null

    function syncSnapshot() {
      if (closed || snapshotPending) return
      snapshotPending = true
      void fetchSnapshot().finally(() => {
        snapshotPending = false
      })
    }

    function connect() {
      if (closed) return
      const es = new EventSource(USAGE_STREAM_URL)
      esRef.current = es
      if (fallbackTimer !== null) window.clearTimeout(fallbackTimer)
      fallbackTimer = window.setTimeout(syncSnapshot, 250)

      es.onopen = () => {
        if (fallbackTimer !== null) {
          window.clearTimeout(fallbackTimer)
          fallbackTimer = null
        }
        setError(undefined)
        syncSnapshot()
        if (reconnectTimer.current) {
          window.clearTimeout(reconnectTimer.current)
          reconnectTimer.current = null
        }
      }

      const onRecord = (e: MessageEvent) => {
        try {
          const rec = JSON.parse(e.data) as UsageRecord
          if (!rec) return
          setRecords((prev) => {
            const key = recordKey(rec)
            if (prev.some((r) => recordKey(r) === key)) return prev
            const next = [rec, ...prev]
            if (next.length > MAX_RECORDS) next.length = MAX_RECORDS
            return next
          })
        } catch {
        }
      }

      es.addEventListener("record", onRecord as EventListener)

      es.onmessage = (e) => {
        try {
          const msg = JSON.parse(e.data) as { type?: string; data?: unknown }
          if (msg.type === "record" && msg.data) {
            onRecord(e)
          }
        } catch {
        }
      }

      es.onerror = () => {
        es.close()
        if (!closed && reconnectTimer.current === null) {
          reconnectTimer.current = window.setTimeout(() => {
            reconnectTimer.current = null
            connect()
          }, 3000)
        }
      }
    }

    connect()

    return () => {
      closed = true
      if (reconnectTimer.current) window.clearTimeout(reconnectTimer.current)
      if (fallbackTimer !== null) window.clearTimeout(fallbackTimer)
      esRef.current?.close()
      esRef.current = null
    }
  }, [fetchSnapshot])

  return { records, error, clear }
}
