#!/usr/bin/env bash
set -euo pipefail

OPENCODE_GLOBAL_CONFIG="${HOME}/.config/opencode/opencode.jsonc"
KOPENCODE_ENV_FILE="${HOME}/.config/kopencode/.env"
VERBOSE=true

# Models to keep visible. All other known Bedrock models are disabled.
ALLOWED_BEDROCK_MODELS=(
    "minimax.minimax-m2"
    "moonshot.kimi-k2-thinking"
    "moonshotai.kimi-k2.5"
    "zai.glm-5"
)

# Full Bedrock model list from models.dev (as of this script version).
# Any model NOT in ALLOWED_BEDROCK_MODELS will be disabled in the config.
ALL_BEDROCK_MODELS=(
    "amazon.nova-2-lite-v1:0" "amazon.nova-lite-v1:0" "amazon.nova-micro-v1:0" "amazon.nova-pro-v1:0"
    "anthropic.claude-haiku-4-5-20251001-v1:0" "anthropic.claude-opus-4-1-20250805-v1:0"
    "anthropic.claude-opus-4-5-20251101-v1:0" "anthropic.claude-opus-4-6-v1" "anthropic.claude-opus-4-7"
    "anthropic.claude-sonnet-4-5-20250929-v1:0" "anthropic.claude-sonnet-4-6"
    "au.anthropic.claude-haiku-4-5-20251001-v1:0" "au.anthropic.claude-opus-4-6-v1"
    "au.anthropic.claude-sonnet-4-5-20250929-v1:0" "au.anthropic.claude-sonnet-4-6"
    "deepseek.r1-v1:0" "deepseek.v3-v1:0" "deepseek.v3.2"
    "eu.anthropic.claude-haiku-4-5-20251001-v1:0" "eu.anthropic.claude-opus-4-5-20251101-v1:0"
    "eu.anthropic.claude-opus-4-6-v1" "eu.anthropic.claude-opus-4-7"
    "eu.anthropic.claude-sonnet-4-5-20250929-v1:0" "eu.anthropic.claude-sonnet-4-6"
    "global.anthropic.claude-haiku-4-5-20251001-v1:0" "global.anthropic.claude-opus-4-5-20251101-v1:0"
    "global.anthropic.claude-opus-4-6-v1" "global.anthropic.claude-opus-4-7"
    "global.anthropic.claude-sonnet-4-5-20250929-v1:0" "global.anthropic.claude-sonnet-4-6"
    "google.gemma-3-12b-it" "google.gemma-3-27b-it" "google.gemma-3-4b-it"
    "jp.anthropic.claude-opus-4-7" "jp.anthropic.claude-sonnet-4-5-20250929-v1:0" "jp.anthropic.claude-sonnet-4-6"
    "meta.llama3-1-70b-instruct-v1:0" "meta.llama3-1-8b-instruct-v1:0" "meta.llama3-3-70b-instruct-v1:0"
    "meta.llama4-maverick-17b-instruct-v1:0" "meta.llama4-scout-17b-instruct-v1:0"
    "minimax.minimax-m2.1" "minimax.minimax-m2.5"
    "mistral.devstral-2-123b" "mistral.magistral-small-2509" "mistral.ministral-3-14b-instruct"
    "mistral.ministral-3-3b-instruct" "mistral.ministral-3-8b-instruct"
    "mistral.mistral-large-3-675b-instruct" "mistral.pixtral-large-2502-v1:0"
    "mistral.voxtral-mini-3b-2507" "mistral.voxtral-small-24b-2507"
    "nvidia.nemotron-nano-12b-v2" "nvidia.nemotron-nano-3-30b" "nvidia.nemotron-nano-9b-v2" "nvidia.nemotron-super-3-120b"
    "openai.gpt-oss-120b-1:0" "openai.gpt-oss-20b-1:0" "openai.gpt-oss-safeguard-120b" "openai.gpt-oss-safeguard-20b"
    "qwen.qwen3-235b-a22b-2507-v1:0" "qwen.qwen3-32b-v1:0" "qwen.qwen3-coder-30b-a3b-v1:0"
    "qwen.qwen3-coder-480b-a35b-v1:0" "qwen.qwen3-coder-next" "qwen.qwen3-next-80b-a3b" "qwen.qwen3-vl-235b-a22b"
    "us.anthropic.claude-haiku-4-5-20251001-v1:0" "us.anthropic.claude-opus-4-1-20250805-v1:0"
    "us.anthropic.claude-opus-4-5-20251101-v1:0" "us.anthropic.claude-opus-4-6-v1" "us.anthropic.claude-opus-4-7"
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0" "us.anthropic.claude-sonnet-4-6"
    "us.deepseek.r1-v1:0" "us.meta.llama4-maverick-17b-instruct-v1:0" "us.meta.llama4-scout-17b-instruct-v1:0"
    "writer.palmyra-x4-v1:0" "writer.palmyra-x5-v1:0"
    "zai.glm-4.7" "zai.glm-4.7-flash"
)

log()  { [ "$VERBOSE" = true ] && echo "$@" || true; }
warn() { echo "$@"; }

install_opencode() {
    if command -v opencode >/dev/null 2>&1; then
        log "opencode already installed at $(which opencode)"
        log "Auto-update is enabled — opencode will keep itself current."
    else
        log "Installing opencode..."
        curl -fsSL https://opencode.ai/install | bash
    fi
}

create_shim() {
    local shim="${HOME}/.local/bin/kopencode"
    mkdir -p "${HOME}/.local/bin"
    cat > "$shim" << EOF
#!/usr/bin/env bash
[ -f "${KOPENCODE_ENV_FILE}" ] && set -a && source "${KOPENCODE_ENV_FILE}" && set +a
exec opencode "\$@"
EOF
    chmod +x "$shim"
    log "Created kopencode shim at ${shim}"
}

write_hardening_config() {
    mkdir -p "$(dirname "$OPENCODE_GLOBAL_CONFIG")"

    # Build disabled-models JSON: every model NOT in ALLOWED_BEDROCK_MODELS gets disabled: true
    local disabled_models=""
    for model in "${ALL_BEDROCK_MODELS[@]}"; do
        local allowed=false
        for a in "${ALLOWED_BEDROCK_MODELS[@]}"; do
            [ "$model" = "$a" ] && allowed=true && break
        done
        if [ "$allowed" = false ]; then
            disabled_models+="        \"${model}\": { \"status\": \"deprecated\" },"$'\n'
        fi
    done
    disabled_models="${disabled_models%,$'\n'}"  # strip trailing comma

    cat > "$OPENCODE_GLOBAL_CONFIG" << EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "enabled_providers": ["amazon-bedrock"],
  "share": "disabled",
  "permission": {
    "websearch": "ask",
    "edit": "ask",
    "bash": "ask"
  },
  "tools": {
    "websearch": false,
    "github-triage": false,
    "github-pr-search": false
  },
  "mcp": {
    "brave-search": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-brave-search"]
    }
  },
  "provider": {
    "amazon-bedrock": {
      "options": {
        "apiKey": "${AWS_BEARER_TOKEN_BEDROCK:-}",
        "bearerToken": "${AWS_BEARER_TOKEN_BEDROCK:-}"
      },
      "models": {
${disabled_models}
      }
    }
  }
}
EOF
    log "Wrote hardening config to ${OPENCODE_GLOBAL_CONFIG}"
}

setup_env() {
    local force="${1:-false}"
    mkdir -p "$(dirname "$KOPENCODE_ENV_FILE")"

    # Source existing values so we can show "already set" behaviour
    if [ -f "$KOPENCODE_ENV_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$KOPENCODE_ENV_FILE"
        set +a
    fi

    local brave_key="${BRAVE_API_KEY:-}"
    if [ -z "$brave_key" ] || [ "$force" = true ]; then
        [ -n "$brave_key" ] && echo "Brave API key is set (press Enter to keep, or enter a new value):"
        [ -z "$brave_key" ] && echo "Enter your Brave Search API key (or press Enter to skip):"
        read -r input
        [ -n "$input" ] && brave_key="$input"
    fi
    if [ -n "$brave_key" ]; then
        if grep -q "^BRAVE_API_KEY=" "$KOPENCODE_ENV_FILE" 2>/dev/null; then
            sed -i '' "s|^BRAVE_API_KEY=.*|BRAVE_API_KEY=${brave_key}|" "$KOPENCODE_ENV_FILE"
        else
            echo "BRAVE_API_KEY=${brave_key}" >> "$KOPENCODE_ENV_FILE"
        fi
        log "Written BRAVE_API_KEY to ${KOPENCODE_ENV_FILE}"
    fi

    local bedrock_token="${AWS_BEARER_TOKEN_BEDROCK:-}"
    if [ -z "$bedrock_token" ] || [ "$force" = true ]; then
        [ -n "$bedrock_token" ] && echo "AWS Bedrock Bearer Token is set (press Enter to keep, or enter a new value):"
        [ -z "$bedrock_token" ] && echo "Enter your AWS Bedrock Bearer Token (or press Enter to skip):"
        read -r input
        [ -n "$input" ] && bedrock_token="$input"
    fi
    if [ -n "$bedrock_token" ]; then
        if grep -q "^AWS_BEARER_TOKEN_BEDROCK=" "$KOPENCODE_ENV_FILE" 2>/dev/null; then
            sed -i '' "s|^AWS_BEARER_TOKEN_BEDROCK=.*|AWS_BEARER_TOKEN_BEDROCK=${bedrock_token}|" "$KOPENCODE_ENV_FILE"
        else
            echo "AWS_BEARER_TOKEN_BEDROCK=${bedrock_token}" >> "$KOPENCODE_ENV_FILE"
        fi
        log "Written AWS_BEARER_TOKEN_BEDROCK to ${KOPENCODE_ENV_FILE}"

        # OPENCODE_AUTH_CONTENT: feeds the token directly into opencode's auth system,
        # bypassing the env-var path. This is what prevents the TUI from showing the
        # "connect provider" dialog even when AWS_BEARER_TOKEN_BEDROCK is set by the shim.
        local auth_json="{\"amazon-bedrock\":{\"type\":\"api\",\"key\":\"${bedrock_token}\"}}"
        if grep -q "^OPENCODE_AUTH_CONTENT=" "$KOPENCODE_ENV_FILE" 2>/dev/null; then
            sed -i '' "s|^OPENCODE_AUTH_CONTENT=.*|OPENCODE_AUTH_CONTENT='${auth_json}'|" "$KOPENCODE_ENV_FILE"
        else
            echo "OPENCODE_AUTH_CONTENT='${auth_json}'" >> "$KOPENCODE_ENV_FILE"
        fi
        log "Written OPENCODE_AUTH_CONTENT to ${KOPENCODE_ENV_FILE}"
    fi
}

setup_shell() {
    local config_file="${HOME}/.zshrc"
    local path_line="export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    local source_line="[ -f \"${KOPENCODE_ENV_FILE}\" ] && { set -a; source \"${KOPENCODE_ENV_FILE}\"; set +a; }"

    if grep -qF -- "$source_line" "$config_file" 2>/dev/null; then
        log "Shell already configured in ${config_file}"
        return
    fi

    # Append after existing PATH line if present, otherwise add at end
    local line_num
    line_num=$(grep -n -- "$path_line" "$config_file" 2>/dev/null | cut -d: -f1 | head -1 || true)

    if [ -n "$line_num" ]; then
        sed -i '' "${line_num}a\\
${source_line}" "$config_file"
    else
        {
            echo ""
            echo "# kopencode hardening"
            echo "$path_line"
            echo "$source_line"
        } >> "$config_file"
    fi

    log "Added env source to ${config_file}"
}

main() {
    force_keys=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --keys) force_keys=true; shift ;;
            -q)     VERBOSE=false; shift ;;
            *) shift ;;
        esac
    done

    install_opencode
    create_shim
    setup_env "$force_keys"
    write_hardening_config
    setup_shell

    # Activate env in the current shell (works when script is sourced; no-op in subshell)
    # shellcheck disable=SC1090
    [ -f "$KOPENCODE_ENV_FILE" ] && set -a && source "$KOPENCODE_ENV_FILE" && set +a

    echo ""
    echo "*****  source ~/.zshrc  OR  open a new terminal  *****"
    echo ""
}

main "$@"
