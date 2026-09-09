import type { ConfigProviderV1 } from "@opencode-ai/core/v1/config/provider"

// Session-level retry backoff is per-session, so two subagents streaming from
// the same low-quota deployment cannot back off together: each one discovers
// the 429 on its own and keeps probing while the other is already waiting. This
// gate lives underneath the provider fetch, where every request to a provider
// passes through, so a single 429 parks *all* of them until the deployment has
// had time to recover.

export const MIN_DELAY = 1_000
// Matches the session retry policy's initial delay. The cooldown is an absolute
// deadline rather than a sleep, so the two overlap instead of stacking: a lone
// request waits no longer than it did before, while concurrent ones are held.
// Deployments with tight quotas (Azure especially) may want this raised.
export const COOLDOWN = 2_000
export const MAX_COOLDOWN = 60_000
export const JITTER = 0.2

export type Options = {
  readonly disabled?: boolean | undefined
  readonly minDelay?: number | undefined
  readonly cooldown?: number | undefined
  readonly maxCooldown?: number | undefined
  readonly maxConcurrent?: number | undefined
}

// Only 429. Overload statuses (503/529) are transient blips that the session
// retry policy already spaces out well; parking every request behind a shared
// cooldown for those would make a one-off hiccup cost far more than it should.
const THROTTLED = new Set([429])

/**
 * Parses a retry hint out of response headers, in the order providers actually
 * populate them. Returns undefined when no header carries a usable value.
 */
export function retryHint(headers: Headers, now = Date.now()): number | undefined {
  const millis = headers.get("retry-after-ms")
  if (millis !== null) {
    const parsed = Number.parseFloat(millis)
    // A provider answering `retry-after-ms: 0` means "immediately", which is
    // never true of a deployment that just throttled us. Callers floor it.
    if (!Number.isNaN(parsed) && parsed >= 0) return parsed
  }

  const after = headers.get("retry-after")
  if (after === null) return undefined

  const seconds = Number.parseFloat(after)
  if (!Number.isNaN(seconds) && seconds >= 0) return seconds * 1000

  const date = Date.parse(after)
  if (!Number.isNaN(date) && date > now) return date - now
  return undefined
}

export class Gate {
  private until = 0
  private active = 0
  private readonly waiters = new Set<() => void>()

  constructor(private options: Options = {}) {}

  /** Applies fresh config without discarding an in-flight cooldown. */
  configure(options: Options) {
    this.options = options
    this.wake()
  }

  private get minDelay() {
    return this.options.minDelay ?? MIN_DELAY
  }

  /** Waits for the current cooldown and a concurrency slot. Resolves to a release function. */
  async acquire(signal?: AbortSignal | null): Promise<() => void> {
    if (this.options.disabled) return () => {}

    for (;;) {
      signal?.throwIfAborted()

      const wait = this.until - Date.now()
      // Re-check after sleeping rather than acquiring: another request may have
      // been throttled while we waited and pushed `until` further out.
      if (wait > 0) {
        await this.sleep(wait, signal)
        continue
      }

      const max = this.options.maxConcurrent
      if (max !== undefined && this.active >= max) {
        await this.vacancy(signal)
        continue
      }

      this.active++
      let released = false
      return () => {
        if (released) return
        released = true
        this.active--
        this.wake()
      }
    }
  }

  /**
   * Records a response. A throttled status parks every request on this
   * provider. Returns the cooldown applied, or undefined when nothing changed.
   */
  observe(status: number, headers: Headers, random = Math.random): number | undefined {
    if (this.options.disabled) return undefined
    if (!THROTTLED.has(status)) return undefined

    const hint = retryHint(headers)
    const base = hint === undefined ? (this.options.cooldown ?? COOLDOWN) : Math.max(hint, this.minDelay)
    const bounded = Math.min(base, this.options.maxCooldown ?? MAX_COOLDOWN)
    // Jitter is additive only: a provider-supplied hint is a floor we must not
    // undercut, and spreading arrivals past the reset boundary keeps concurrent
    // requests from stampeding the instant the window opens.
    const wait = Math.round(bounded * (1 + random() * JITTER))
    const next = Date.now() + wait
    if (next > this.until) this.until = next
    return wait
  }

  /** Milliseconds remaining on the current cooldown. Exposed for tests and logging. */
  get cooldownRemaining(): number {
    return Math.max(0, this.until - Date.now())
  }

  private wake() {
    const pending = [...this.waiters]
    this.waiters.clear()
    for (const resolve of pending) resolve()
  }

  private vacancy(signal?: AbortSignal | null) {
    return new Promise<void>((resolve, reject) => {
      const waiter = () => {
        signal?.removeEventListener("abort", onAbort)
        resolve()
      }
      const onAbort = () => {
        this.waiters.delete(waiter)
        reject(signal?.reason ?? new DOMException("Aborted", "AbortError"))
      }
      if (signal?.aborted) return onAbort()
      signal?.addEventListener("abort", onAbort, { once: true })
      this.waiters.add(waiter)
    })
  }

  private sleep(ms: number, signal?: AbortSignal | null) {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        signal?.removeEventListener("abort", onAbort)
        resolve()
      }, ms)
      const onAbort = () => {
        clearTimeout(timer)
        reject(signal?.reason ?? new DOMException("Aborted", "AbortError"))
      }
      if (signal?.aborted) return onAbort()
      signal?.addEventListener("abort", onAbort, { once: true })
    })
  }
}

// Keyed per provider rather than per deployment: the fetch wrapper sees the URL
// and body, not the resolved model, and providers that throttle one deployment
// are usually enforcing a resource-wide quota anyway.
const gates = new Map<string, Gate>()

export function gate(providerID: string, options?: ConfigProviderV1.RateLimit | undefined): Gate {
  const existing = gates.get(providerID)
  if (existing) {
    if (options) existing.configure(options)
    return existing
  }
  const created = new Gate(options ?? {})
  gates.set(providerID, created)
  return created
}

/** Drops all cached gates. Tests only. */
export function reset() {
  gates.clear()
}

export * as ProviderRateLimit from "./rate-limit"
