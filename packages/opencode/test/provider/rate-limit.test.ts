import { describe, expect, test } from "bun:test"
import { ProviderRateLimit } from "../../src/provider/rate-limit"

const headers = (init?: Record<string, string>) => new Headers(init)

describe("provider.rateLimit.retryHint", () => {
  test("reads retry-after-ms", () => {
    expect(ProviderRateLimit.retryHint(headers({ "retry-after-ms": "1500" }))).toBe(1500)
  })

  test("reads retry-after seconds", () => {
    expect(ProviderRateLimit.retryHint(headers({ "retry-after": "30" }))).toBe(30_000)
  })

  test("reads retry-after http dates", () => {
    const now = Date.now()
    const hint = ProviderRateLimit.retryHint(headers({ "retry-after": new Date(now + 20_000).toUTCString() }), now)
    expect(hint).toBeGreaterThanOrEqual(19_000)
    expect(hint).toBeLessThanOrEqual(20_000)
  })

  test("reports a zero hint rather than swallowing it", () => {
    expect(ProviderRateLimit.retryHint(headers({ "retry-after-ms": "0" }))).toBe(0)
    expect(ProviderRateLimit.retryHint(headers({ "retry-after": "0" }))).toBe(0)
  })

  test("ignores unusable values", () => {
    expect(ProviderRateLimit.retryHint(headers())).toBeUndefined()
    expect(ProviderRateLimit.retryHint(headers({ "retry-after": "soon" }))).toBeUndefined()
    const now = Date.now()
    expect(ProviderRateLimit.retryHint(headers({ "retry-after": new Date(now - 5_000).toUTCString() }), now)).toBe(
      undefined,
    )
  })
})

describe("provider.rateLimit.gate", () => {
  test("a 429 with a zero hint still parks requests for the floor", () => {
    const gate = new ProviderRateLimit.Gate({ minDelay: 1_000 })
    gate.observe(429, headers({ "retry-after-ms": "0" }), () => 0)
    expect(gate.cooldownRemaining).toBeGreaterThan(900)
  })

  test("a 429 with no hint falls back to the cooldown", () => {
    const gate = new ProviderRateLimit.Gate({ cooldown: 4_000 })
    gate.observe(429, headers(), () => 0)
    expect(gate.cooldownRemaining).toBeGreaterThan(3_800)
    expect(gate.cooldownRemaining).toBeLessThanOrEqual(4_000)
  })

  test("honours a long hint up to maxCooldown", () => {
    const gate = new ProviderRateLimit.Gate({ maxCooldown: 10_000 })
    gate.observe(429, headers({ "retry-after": "600" }), () => 0)
    expect(gate.cooldownRemaining).toBeLessThanOrEqual(10_000)
    expect(gate.cooldownRemaining).toBeGreaterThan(9_000)
  })

  test("jitter only ever extends the wait", () => {
    const low = new ProviderRateLimit.Gate({ cooldown: 1_000 })
    low.observe(429, headers(), () => 0)
    const high = new ProviderRateLimit.Gate({ cooldown: 1_000 })
    high.observe(429, headers(), () => 1)
    expect(low.cooldownRemaining).toBeLessThanOrEqual(high.cooldownRemaining)
    expect(high.cooldownRemaining).toBeGreaterThan(1_000)
  })

  test("keeps the longest cooldown when throttled repeatedly", () => {
    const gate = new ProviderRateLimit.Gate({})
    gate.observe(429, headers({ "retry-after": "10" }), () => 0)
    const long = gate.cooldownRemaining
    gate.observe(429, headers({ "retry-after": "1" }), () => 0)
    expect(gate.cooldownRemaining).toBeGreaterThanOrEqual(long - 50)
  })

  test("ignores statuses that are not throttling", () => {
    const gate = new ProviderRateLimit.Gate({})
    gate.observe(200, headers({ "retry-after": "60" }))
    gate.observe(400, headers({ "retry-after": "60" }))
    expect(gate.cooldownRemaining).toBe(0)
  })

  // Overload statuses are the retry policy's business; a shared cooldown would
  // make a transient blip cost every concurrent request.
  test("leaves overload statuses to the retry policy", () => {
    for (const status of [500, 502, 503, 529]) {
      const gate = new ProviderRateLimit.Gate({ cooldown: 2_000 })
      gate.observe(status, headers({ "retry-after": "60" }), () => 0)
      expect(gate.cooldownRemaining).toBe(0)
    }
  })

  test("holds a request until the cooldown expires", async () => {
    const gate = new ProviderRateLimit.Gate({ cooldown: 120 })
    gate.observe(429, headers(), () => 0)
    const start = Date.now()
    const release = await gate.acquire()
    release()
    expect(Date.now() - start).toBeGreaterThanOrEqual(100)
  })

  // The point of the gate: one 429 backs off every concurrent caller, not just
  // the one that saw it.
  test("a cooldown set mid-wait extends callers already waiting", async () => {
    const gate = new ProviderRateLimit.Gate({ cooldown: 100 })
    gate.observe(429, headers(), () => 0)
    const start = Date.now()
    const pending = gate.acquire()
    setTimeout(() => gate.observe(429, headers({ "retry-after-ms": "250" }), () => 0), 20)
    const release = await pending
    release()
    expect(Date.now() - start).toBeGreaterThanOrEqual(250)
  })

  test("caps in-flight requests at maxConcurrent", async () => {
    const gate = new ProviderRateLimit.Gate({ maxConcurrent: 1 })
    const first = await gate.acquire()
    let secondAcquired = false
    const second = gate.acquire().then((release) => {
      secondAcquired = true
      return release
    })
    await Bun.sleep(20)
    expect(secondAcquired).toBe(false)
    first()
    ;(await second)()
    expect(secondAcquired).toBe(true)
  })

  test("releasing twice does not free an extra slot", async () => {
    const gate = new ProviderRateLimit.Gate({ maxConcurrent: 1 })
    const release = await gate.acquire()
    release()
    release()
    const held = await gate.acquire()
    let extra = false
    void gate.acquire().then(() => {
      extra = true
    })
    await Bun.sleep(20)
    expect(extra).toBe(false)
    held()
  })

  test("acquire rejects when the request is aborted mid-cooldown", async () => {
    const gate = new ProviderRateLimit.Gate({ cooldown: 5_000 })
    gate.observe(429, headers(), () => 0)
    const ctl = new AbortController()
    const pending = gate.acquire(ctl.signal)
    setTimeout(() => ctl.abort(), 10)
    await expect(pending).rejects.toThrow()
  })

  test("acquire rejects when the request is aborted waiting for a slot", async () => {
    const gate = new ProviderRateLimit.Gate({ maxConcurrent: 1 })
    const held = await gate.acquire()
    const ctl = new AbortController()
    const pending = gate.acquire(ctl.signal)
    setTimeout(() => ctl.abort(), 10)
    await expect(pending).rejects.toThrow()
    held()
  })

  test("disabled gates neither park nor queue", async () => {
    const gate = new ProviderRateLimit.Gate({ disabled: true, cooldown: 5_000, maxConcurrent: 1 })
    gate.observe(429, headers({ "retry-after": "60" }))
    expect(gate.cooldownRemaining).toBe(0)
    const start = Date.now()
    await gate.acquire()
    await gate.acquire()
    expect(Date.now() - start).toBeLessThan(50)
  })

  test("gates are shared per provider and reconfigurable", () => {
    ProviderRateLimit.reset()
    const first = ProviderRateLimit.gate("azure", { cooldown: 1_000 })
    expect(ProviderRateLimit.gate("azure")).toBe(first)
    expect(ProviderRateLimit.gate("litellm")).not.toBe(first)

    first.observe(429, headers(), () => 0)
    const parked = first.cooldownRemaining
    expect(parked).toBeGreaterThan(0)
    // Reconfiguring must not discard a cooldown that is already in force.
    ProviderRateLimit.gate("azure", { cooldown: 9_000 })
    expect(first.cooldownRemaining).toBeGreaterThan(parked - 50)
    ProviderRateLimit.reset()
  })
})
