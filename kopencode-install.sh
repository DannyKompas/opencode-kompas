#!/usr/bin/env bash
set -euo pipefail

OPENCODE_GLOBAL_CONFIG="${HOME}/.config/opencode/opencode.jsonc"
KOPENCODE_ENV_FILE="${HOME}/.config/kopencode/.env"
VERBOSE=true

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

write_hardening_config() {
    mkdir -p "$(dirname "$OPENCODE_GLOBAL_CONFIG")"
    cat > "$OPENCODE_GLOBAL_CONFIG" << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
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
    write_hardening_config
    setup_env "$force_keys"
    setup_shell

    echo ""
    echo "*****  source ~/.zshrc  OR  open a new terminal  *****"
    echo ""
}

main "$@"
