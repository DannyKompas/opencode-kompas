#!/usr/bin/env bun
// Seeds default LLM provider restrictions into the global opencode config
// (~/.config/opencode/opencode.jsonc), so kopencode blocks arbitrary models
// by default regardless of which directory it's run from. Only fills in
// keys that are missing - never overwrites a value someone already set.
import fs from "fs"

const DEFAULTS = {
  enabled_providers: ["amazon-bedrock", "azure"],
  provider: {
    "amazon-bedrock": { whitelist: ["minimax.minimax-m2.5"] },
    azure: {
      whitelist: ["deepseek-v4-flash"],
      options: { useCompletionUrls: true, apiKey: "{env:AZURE_API_KEY}" },
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

if (cfg.enabled_providers === undefined) cfg.enabled_providers = DEFAULTS.enabled_providers

cfg.provider = cfg.provider ?? {}
for (const [id, defaults] of Object.entries(DEFAULTS.provider)) {
  if (cfg.provider[id] === undefined) cfg.provider[id] = defaults
}

fs.writeFileSync(path, JSON.stringify(cfg, null, 2) + "\n")
