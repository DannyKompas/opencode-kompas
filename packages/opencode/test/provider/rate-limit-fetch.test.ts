import { afterEach, beforeEach, expect } from "bun:test"
import { createServer, type Server } from "node:http"
import { streamText } from "ai"
import { Effect, Layer } from "effect"
import { CrossSpawnSpawner } from "@opencode-ai/core/cross-spawn-spawner"
import { ProviderV2 } from "@opencode-ai/core/provider"
import { ModelV2 } from "@opencode-ai/core/model"
import { disposeAllInstances, provideTmpdirInstance } from "../fixture/fixture"
import { testEffect } from "../lib/effect"
import { testProviderConfig } from "../lib/test-provider"
import { Env } from "@/env"
import { Plugin } from "@/plugin"
import { Provider } from "@/provider/provider"
import { ProviderRateLimit } from "@/provider/rate-limit"

beforeEach(() => {
  ProviderRateLimit.reset()
})

afterEach(async () => {
  ProviderRateLimit.reset()
  await disposeAllInstances()
})

const it = testEffect(
  Layer.mergeAll(Provider.defaultLayer, Env.defaultLayer, Plugin.defaultLayer, CrossSpawnSpawner.defaultLayer),
)

// The bug this guards: Azure answers some 429s with a zero retry hint, and
// taking that literally turned the retry loop into ~900 requests in a minute,
// which kept the deployment throttled.
it.live("a 429 with a zero retry hint still holds back the next request", () =>
  Effect.gen(function* () {
    const server = yield* Effect.acquireRelease(
      Effect.promise(() => throttlingServer({ throttle: 1, headers: { "retry-after-ms": "0" } })),
      (server) => Effect.sync(() => server.server.close()),
    )

    yield* provideTmpdirInstance(
      () =>
        Effect.gen(function* () {
          const provider = yield* Provider.Service
          const model = yield* provider.getModel(ProviderV2.ID.make("test"), ModelV2.ID.make("test-model"))
          const language = yield* provider.getLanguage(model)

          // The provider says "retry immediately" and the SDK obliges, but the
          // gate makes the retry wait out the floor anyway.
          const start = Date.now()
          expect(yield* drain(language)).toBe("ok")
          expect(Date.now() - start).toBeGreaterThanOrEqual(300)
          expect(server.requests()).toBe(2)
        }),
      { config: providerConfig(server.url, { rateLimit: { minDelay: 300 } }) },
    )
  }),
)

it.live("a 429 with no retry hint falls back to the configured cooldown", () =>
  Effect.gen(function* () {
    const server = yield* Effect.acquireRelease(
      Effect.promise(() => throttlingServer({ throttle: 1 })),
      (server) => Effect.sync(() => server.server.close()),
    )

    yield* provideTmpdirInstance(
      () =>
        Effect.gen(function* () {
          const provider = yield* Provider.Service
          const model = yield* provider.getModel(ProviderV2.ID.make("test"), ModelV2.ID.make("test-model"))
          const language = yield* provider.getLanguage(model)

          const start = Date.now()
          expect(yield* drain(language)).toBe("ok")
          expect(Date.now() - start).toBeGreaterThanOrEqual(300)
          expect(server.requests()).toBe(2)
        }),
      { config: providerConfig(server.url, { rateLimit: { cooldown: 300 } }) },
    )
  }),
)

it.live("successful responses are never held back", () =>
  Effect.gen(function* () {
    const server = yield* Effect.acquireRelease(
      Effect.promise(() => throttlingServer({ throttle: 0 })),
      (server) => Effect.sync(() => server.server.close()),
    )

    yield* provideTmpdirInstance(
      () =>
        Effect.gen(function* () {
          const provider = yield* Provider.Service
          const model = yield* provider.getModel(ProviderV2.ID.make("test"), ModelV2.ID.make("test-model"))
          const language = yield* provider.getLanguage(model)

          const start = Date.now()
          expect(yield* drain(language)).toBe("ok")
          expect(yield* drain(language)).toBe("ok")
          expect(Date.now() - start).toBeLessThan(2_000)
        }),
      { config: providerConfig(server.url, { rateLimit: { cooldown: 5_000 } }) },
    )
  }),
)

it.live("maxConcurrent serializes streams to a low-quota deployment", () =>
  Effect.gen(function* () {
    const server = yield* Effect.acquireRelease(
      Effect.promise(() => throttlingServer({ throttle: 0, bodyDelay: 150 })),
      (server) => Effect.sync(() => server.server.close()),
    )

    yield* provideTmpdirInstance(
      () =>
        Effect.gen(function* () {
          const provider = yield* Provider.Service
          const model = yield* provider.getModel(ProviderV2.ID.make("test"), ModelV2.ID.make("test-model"))
          const language = yield* provider.getLanguage(model)

          expect(
            yield* Effect.promise(() =>
              Promise.all([textOf(language), textOf(language)]).then(() => server.maxInFlight()),
            ),
          ).toBe(1)
        }),
      { config: providerConfig(server.url, { rateLimit: { maxConcurrent: 1 } }) },
    )
  }),
)

/** Runs the model and returns its text, or "error" when the request failed. */
function drain(language: Parameters<typeof streamText>[0]["model"]) {
  return Effect.promise(async () => {
    const result = streamText({ model: language, onError() {}, messages: [{ role: "user", content: "hello" }] })
    let text = ""
    for await (const part of result.fullStream) {
      if (part.type === "error") return "error"
      if (part.type === "text-delta") text += part.text
    }
    return text
  })
}

async function textOf(language: Parameters<typeof streamText>[0]["model"]) {
  try {
    return await streamText({ model: language, onError() {}, messages: [{ role: "user", content: "hello" }] }).text
  } catch {
    return "error"
  }
}

function providerConfig(url: string, options: Record<string, unknown> = {}) {
  const config = testProviderConfig(url)
  return {
    ...config,
    provider: {
      test: {
        ...config.provider.test,
        options: { ...config.provider.test.options, ...options },
      },
    },
  }
}

/** Throttles the first `throttle` requests with a 429, then streams "ok". */
async function throttlingServer(input: {
  throttle: number
  headers?: Record<string, string>
  bodyDelay?: number
}): Promise<{ server: Server; url: string; requests: () => number; maxInFlight: () => number }> {
  let requests = 0
  let inFlight = 0
  let maxInFlight = 0

  const server = createServer((_, res) => {
    requests++
    if (requests <= input.throttle) {
      res.writeHead(429, { "content-type": "application/json", ...input.headers })
      res.end(JSON.stringify({ error: { message: "exceeded rate limit", code: "429" } }))
      return
    }

    inFlight++
    maxInFlight = Math.max(maxInFlight, inFlight)
    res.writeHead(200, { "content-type": "text/event-stream" })
    res.flushHeaders()
    setTimeout(() => {
      inFlight--
      res.end('data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n')
    }, input.bodyDelay ?? 0)
  })

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (!address || typeof address === "string") throw new Error("server did not bind to a TCP port")
  return {
    server,
    url: `http://127.0.0.1:${address.port}`,
    requests: () => requests,
    maxInFlight: () => maxInFlight,
  }
}
