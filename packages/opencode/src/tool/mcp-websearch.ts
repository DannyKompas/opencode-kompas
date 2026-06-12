import { Duration, Effect, Schema } from "effect"
import { HttpClient, HttpClientRequest } from "effect/unstable/http"

export const EXA_URL = process.env.EXA_API_KEY
  ? `https://mcp.exa.ai/mcp?exaApiKey=${encodeURIComponent(process.env.EXA_API_KEY)}`
  : "https://mcp.exa.ai/mcp"
export const PARALLEL_URL = "https://search.parallel.ai/mcp"
export const BRAVE_URL = "https://api.search.brave.com/res/v1/web/search"
export const BRAVE_SEARCH_API_KEY = process.env.BRAVE_SEARCH_API_KEY

const McpResult = Schema.Struct({
  result: Schema.Struct({
    content: Schema.Array(
      Schema.Struct({
        type: Schema.String,
        text: Schema.String,
      }),
    ),
  }),
})

const decode = Schema.decodeUnknownEffect(Schema.fromJsonString(McpResult))

const parsePayload = (payload: string) =>
  Effect.gen(function* () {
    const trimmed = payload.trim()
    if (!trimmed.startsWith("{")) return undefined
    const data = yield* decode(trimmed)
    return data.result.content.find((item) => item.text)?.text
  })

export const parseResponse = Effect.fn("McpWebSearch.parseResponse")(function* (body: string) {
  const trimmed = body.trim()
  const direct = trimmed ? yield* parsePayload(trimmed) : undefined
  if (direct) return direct

  for (const line of body.split("\n")) {
    if (!line.startsWith("data: ")) continue
    const data = yield* parsePayload(line.substring(6))
    if (data) return data
  }
  return undefined
})

export const SearchArgs = Schema.Struct({
  query: Schema.String,
  type: Schema.String,
  numResults: Schema.Number,
  livecrawl: Schema.String,
  contextMaxCharacters: Schema.optional(Schema.Number),
})

export const ParallelSearchArgs = Schema.Struct({
  objective: Schema.String,
  search_queries: Schema.Array(Schema.String),
  session_id: Schema.optional(Schema.String),
  model_name: Schema.optional(Schema.String),
})

const McpRequest = <F extends Schema.Struct.Fields>(args: Schema.Struct<F>) =>
  Schema.Struct({
    jsonrpc: Schema.Literal("2.0"),
    id: Schema.Literal(1),
    method: Schema.Literal("tools/call"),
    params: Schema.Struct({
      name: Schema.String,
      arguments: args,
    }),
  })

export const call = <F extends Schema.Struct.Fields>(
  http: HttpClient.HttpClient,
  url: string,
  tool: string,
  args: Schema.Struct<F>,
  value: Schema.Struct.Type<F>,
  timeout: Duration.Input,
  headers?: Record<string, string>,
) =>
  Effect.gen(function* () {
    const request = yield* HttpClientRequest.post(url).pipe(
      HttpClientRequest.accept("application/json, text/event-stream"),
      HttpClientRequest.setHeaders(headers ?? {}),
      HttpClientRequest.schemaBodyJson(McpRequest(args))({
        jsonrpc: "2.0" as const,
        id: 1 as const,
        method: "tools/call" as const,
        params: { name: tool, arguments: value },
      }),
    )
    const response = yield* HttpClient.filterStatusOk(http)
      .execute(request)
      .pipe(
        Effect.timeoutOrElse({ duration: timeout, orElse: () => Effect.die(new Error(`${tool} request timed out`)) }),
      )
    const body = yield* response.text
    return yield* parseResponse(body)
  })

const BraveSearchResult = Schema.Struct({
  web: Schema.optional(
    Schema.Struct({
      results: Schema.Array(
        Schema.Struct({
          title: Schema.String,
          url: Schema.String,
          description: Schema.String,
        }),
      ),
    }),
  ),
})

export const callBrave = (
  http: HttpClient.HttpClient,
  query: string,
  count: number = 8,
) =>
  Effect.gen(function* () {
    const apiKey = process.env.BRAVE_SEARCH_API_KEY
    if (!apiKey) {
      return yield* Effect.fail(new Error("BRAVE_SEARCH_API_KEY not configured"))
    }

    const params = new URLSearchParams({
      q: query,
      count: String(count),
    })

    const request = yield* HttpClientRequest.get(`${BRAVE_URL}?${params}`).pipe(
      HttpClientRequest.accept("application/json"),
      HttpClientRequest.setHeader("X-Subscription-Token", apiKey),
    )

    const response = yield* HttpClient.filterStatusOk(http)
      .execute(request)
      .pipe(
        Effect.timeoutOrElse({
          duration: { seconds: 25 },
          orElse: () => Effect.die(new Error("Brave search request timed out")),
        }),
      )

    const body = yield* response.json
    const parsed = yield* Schema.decodeUnknown(BraveSearchResult)(body)

    const results = parsed.web?.results ?? []
    if (results.length === 0) {
      return undefined
    }

    const formatted = results
      .map((r) => `[${r.title}](${r.url}): ${r.description}`)
      .join("\n\n")

    return formatted
  })
