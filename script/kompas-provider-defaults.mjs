#!/usr/bin/env bun
// Seeds default LLM provider restrictions into the global opencode config
// (~/.config/opencode/opencode.jsonc), so kopencode blocks arbitrary models
// by default regardless of which directory it's run from. Only fills in
// keys that are missing - never overwrites a value someone already set.
import fs from "fs"

const DEFAULTS = {
  enabled_providers: ["amazon-bedrock", "azure", "litellm"],
  provider: {
    "amazon-bedrock": { whitelist: ["minimax.minimax-m2.5"] },
    azure: {
      whitelist: ["deepseek-v4-flash", "deepseek-v4-flash-0731"],
      options: { useCompletionUrls: true, apiKey: "{env:AZURE_API_KEY}" },
      models: {
        "deepseek-v4-flash-0731": {
          name: "DeepSeek V4 Flash (0731)",
          reasoning: true,
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
      if (existing.models[modelID] === undefined) existing.models[modelID] = modelDefaults
    }
  }
}

fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n")
