import { useCallback, useEffect, useRef, useState } from "react"

type SaveState = "idle" | "saving" | "saved" | "error"

const SAVE_DEBOUNCE_MS = 600

export function useAutoSave<T>(
  value: T | undefined,
  {
    save,
    onSaved,
    onError,
  }: {
    save: (value: T) => Promise<void>
    onSaved?: () => void
    onError: (err: unknown) => void
  }
) {
  const [saveState, setSaveState] = useState<SaveState>("idle")
  const dirty = useRef(false)
  const timer = useRef<number | undefined>(undefined)

  useEffect(() => {
    if (value === undefined || !dirty.current) return
    setSaveState("saving")
    timer.current = window.setTimeout(async () => {
      try {
        await save(value)
        setSaveState("saved")
        dirty.current = false
        onSaved?.()
      } catch (err) {
        setSaveState("error")
        onError(err)
      }
    }, SAVE_DEBOUNCE_MS)
    return () => {
      if (timer.current) window.clearTimeout(timer.current)
    }
  }, [value, save, onSaved, onError])

  const markDirty = useCallback(() => {
    dirty.current = true
  }, [])

  const commitSaved = useCallback(() => {
    if (timer.current) window.clearTimeout(timer.current)
    dirty.current = false
    setSaveState("saved")
    onSaved?.()
  }, [onSaved])

  const failSave = useCallback(
    (err: unknown) => {
      setSaveState("error")
      onError(err)
    },
    [onError]
  )

  return { saveState, markDirty, commitSaved, failSave }
}
