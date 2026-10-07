#!/usr/bin/env bun
// Seeds default LLM provider restrictions into the global opencode config
// (~/.config/opencode/opencode.jsonc), so kopencode blocks arbitrary models
// by default regardless of which directory it's run from. Only fills in
// keys that are missing - never overwrites a value someone already set.
import fs from "fs"

const DEFAULTS = {
  enabled_providers: ["amazon-bedrock", "azure", "litellm"],
  // Pinned to the reviewed release; bump deliberately after re-reviewing.
  plugin: ["@dietrichgebert/ponytail@4.10.1"],
  provider: {
    "amazon-bedrock": { whitelist: ["minimax.minimax-m2.5"] },
    azure: {
      whitelist: ["deepseek-v4-flash", "deepseek-v4-flash-0731", "deepseek-v4.1-flash"],
      // The deployment answers a saturated quota with `retry-after: 1` and
      // `retry-after-ms: 0`, neither of which is long enough for the window to
      // reopen - taken at face value that just re-throttles it. Override the
      // hint, and serialize so the title and build agents stop competing for
      // the same quota.
      options: {
        useCompletionUrls: true,
        apiKey: "{env:AZURE_API_KEY}",
        rateLimit: { minDelay: 15000, cooldown: 15000, maxConcurrent: 1 },
      },
      // Prices are USD per 1M tokens, Global Standard rates from the Azure retail
      // prices API (prices.azure.com, "Azure Deepseek Models"). models.dev has no
      // entry for 0731 and no cached rate for v4-flash, so without these the
      // session cost shows $0 or ignores cache reads.
      models: {
        "deepseek-v4.1-flash": {
          name: "DeepSeek V4.1 Flash",
          reasoning: true,
          provider: {
            npm: "@ai-sdk/openai-compatible",
            api: "https://${AZURE_RESOURCE_NAME}.services.ai.azure.com/models",
          },
        },
        "deepseek-v4-flash": {
          cost: { input: 0.19, output: 0.51, cache_read: 0.028 },
        },
        "deepseek-v4-flash-0731": {
          name: "DeepSeek V4 Flash (0731)",
          reasoning: true,
          cost: { input: 0.44, output: 1.32, cache_read: 0.014 },
          provider: {
            npm: "@ai-sdk/openai-compatible",
            api: "https://${AZURE_RESOURCE_NAME}.services.ai.azure.com/models",
          },
        },
      },
    },
    litellm: {
      npm: "@ai-sdk/openai-compatible",
      name: "LiteLLM",
      options: { baseURL: "{env:LITELLM_BASE_URL}", apiKey: "{env:LITELLM_API_KEY}" },
      // LiteLLM's azure_ai provider doesn't allow-list reasoning_effort by default;
      // this tells it to forward the param anyway, per litellm's own error message.
      models: {
        "deepseek-v4-flash": {
          name: "DeepSeek V4 Flash",
          reasoning: true,
          cost: { input: 0.19, output: 0.51, cache_read: 0.028 },
          variants: {
            low: { allowed_openai_params: ["reasoning_effort"] },
            medium: { allowed_openai_params: ["reasoning_effort"] },
            high: { allowed_openai_params: ["reasoning_effort"] },
            max: { allowed_openai_params: ["reasoning_effort"] },
          },
        },
        "deepseek-v4-flash-0731": {
          name: "DeepSeek V4 Flash (0731)",
          reasoning: true,
          cost: { input: 0.44, output: 1.32, cache_read: 0.014 },
          variants: {
            low: { allowed_openai_params: ["reasoning_effort"] },
            medium: { allowed_openai_params: ["reasoning_effort"] },
            high: { allowed_openai_params: ["reasoning_effort"] },
            max: { allowed_openai_params: ["reasoning_effort"] },
          },
        },
      },
    },
  },
}

const path = process.argv[2]
if (!path) {
  console.error("usage: kompas-provider-defaults.mjs <path-to-opencode.jsonc>")
  process.exit(1)
}

const raw = fs.readFileSync(path, "utf8")
let cfg
try {
  cfg = JSON.parse(raw)
} catch {
  console.error(`could not parse ${path} as JSON (comments/trailing commas not supported by this seeder) - leaving it untouched`)
  process.exit(1)
}

if (cfg.enabled_providers === undefined) {
  cfg.enabled_providers = DEFAULTS.enabled_providers
} else if (Array.isArray(cfg.enabled_providers)) {
  // Union in any newly-approved providers without disturbing removals someone made deliberately.
  for (const id of DEFAULTS.enabled_providers) {
    if (!cfg.enabled_providers.includes(id)) cfg.enabled_providers.push(id)
  }
}

// Match plugins by package name so a version someone pinned themselves isn't
// duplicated or overridden.
const pluginName = (spec) => (Array.isArray(spec) ? spec[0] : spec).replace(/(.)@[^@/]*$/, "$1")
cfg.plugin = Array.isArray(cfg.plugin) ? cfg.plugin : []
for (const spec of DEFAULTS.plugin) {
  if (!cfg.plugin.some((existing) => pluginName(existing) === pluginName(spec))) cfg.plugin.push(spec)
}

cfg.provider = cfg.provider ?? {}
for (const [id, defaults] of Object.entries(DEFAULTS.provider)) {
  const existing = cfg.provider[id]
  if (existing === undefined) {
    cfg.provider[id] = defaults
    continue
  }

  // Provider block already exists (from an earlier run) - union in newly-approved
  // models/whitelist entries without touching anything already customized.
  if (Array.isArray(defaults.whitelist)) {
    existing.whitelist = Array.isArray(existing.whitelist) ? existing.whitelist : []
    for (const modelID of defaults.whitelist) {
      if (!existing.whitelist.includes(modelID)) existing.whitelist.push(modelID)
    }
  }
  if (defaults.models) {
    existing.models = existing.models ?? {}
    for (const [modelID, modelDefaults] of Object.entries(defaults.models)) {
      if (existing.models[modelID] === undefined) {
        existing.models[modelID] = modelDefaults
        continue
      }
      // Model already seeded by an earlier run - fill in keys shipped since
      // (cost, say) so existing installs pick them up too.
      for (const [key, value] of Object.entries(modelDefaults)) {
        if (existing.models[modelID][key] === undefined) existing.models[modelID][key] = value
      }
    }
  }
  // Same rule for options: fill in keys we've newly started shipping (rateLimit,
  // say) without clobbering a value someone tuned for their own deployment.
  if (defaults.options) {
    existing.options = existing.options ?? {}
    for (const [key, value] of Object.entries(defaults.options)) {
      if (existing.options[key] === undefined) existing.options[key] = value
    }
  }
}

fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n")
