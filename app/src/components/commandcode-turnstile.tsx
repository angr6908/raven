import { useEffect, useRef } from "react"

interface TurnstileApi {
  render: (
    container: HTMLElement,
    options: {
      sitekey: string
      callback: (token: string) => void
      "expired-callback": () => void
      "error-callback": () => void
    }
  ) => string
  remove: (widgetId: string) => void
}

declare global {
  interface Window {
    turnstile?: TurnstileApi
  }
}

const TURNSTILE_SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit"
const TURNSTILE_SITE_KEY = "0x4AAAAAACsMJCI5RCdba9TQ"
let scriptLoad: Promise<void> | undefined

function loadTurnstile(): Promise<void> {
  if (window.turnstile) return Promise.resolve()
  if (scriptLoad) return scriptLoad
  scriptLoad = new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${TURNSTILE_SCRIPT}"]`)
    const script = existing ?? document.createElement("script")
    const loaded = () => resolve()
    const failed = () => {
      scriptLoad = undefined
      reject(new Error("Turnstile failed to load"))
    }
    script.addEventListener("load", loaded, { once: true })
    script.addEventListener("error", failed, { once: true })
    if (!existing) {
      script.src = TURNSTILE_SCRIPT
      script.async = true
      script.defer = true
      document.head.append(script)
    }
  })
  return scriptLoad
}

export function CommandCodeTurnstile({
  onToken,
}: {
  onToken: (token: string) => void
}) {
  const container = useRef<HTMLDivElement>(null)
  const tokenHandler = useRef(onToken)

  useEffect(() => {
    tokenHandler.current = onToken
  }, [onToken])

  useEffect(() => {
    let widgetId: string | undefined
    let active = true
    const render = () => {
      if (!active || !container.current || !window.turnstile || widgetId) return
      widgetId = window.turnstile.render(container.current, {
        sitekey: TURNSTILE_SITE_KEY,
        callback: (token) => tokenHandler.current(token),
        "expired-callback": () => tokenHandler.current(""),
        "error-callback": () => tokenHandler.current(""),
      })
    }

    void loadTurnstile()
      .then(render)
      .catch(() => tokenHandler.current(""))

    return () => {
      active = false
      if (widgetId && window.turnstile) window.turnstile.remove(widgetId)
    }
  }, [])

  return <div ref={container} />
}
