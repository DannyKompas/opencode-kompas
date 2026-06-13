#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_NAME="kopencode"
BUILT_BINARY="${SCRIPT_DIR}/packages/opencode/dist/opencode-darwin-arm64/bin/opencode"
OUTPUT_BINARY="${SCRIPT_DIR}/packages/opencode/dist/opencode-darwin-arm64/bin/kopencode"

install_bun() {
    if ! command -v bun >/dev/null 2>&1; then
        echo "Bun not found. Installing..."
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="${HOME}/.bun"
        export PATH="${BUN_INSTALL}/bin:${PATH}"
    fi
}

build() {
    echo "Installing dependencies..."
    cd "${SCRIPT_DIR}"
    bun install

    echo "Building kopencode (forked from opencode)..."
    cd "${SCRIPT_DIR}/packages/opencode"
    bun run build --single

    if [ ! -f "$BUILT_BINARY" ]; then
        echo "Error: Build failed. Binary not found at $BUILT_BINARY"
        exit 1
    fi

    cp "$BUILT_BINARY" "$OUTPUT_BINARY"
    chmod +x "$OUTPUT_BINARY"
    echo "Build successful!"
}

install_binary() {
    mkdir -p "$INSTALL_DIR"
    cp "$OUTPUT_BINARY" "${INSTALL_DIR}/${BINARY_NAME}"
    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
    echo "Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"
}

add_to_path() {
    local config_file="${HOME}/.zshrc"
    local path_line="export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    local env_line="export OPENCODE_DISABLE_AUTOUPDATE=1"
    local source_env_line="[ -f \"\${HOME}/.config/kopencode/.env\" ] && source \"\${HOME}/.config/kopencode/.env\""

    if grep -qF -- "$env_line" "$config_file" 2>/dev/null; then
        echo "Environment already configured in ${config_file}"
        return
    fi

    local line_num
    line_num=$(grep -n -- "$path_line" "$config_file" 2>/dev/null | cut -d: -f1 | head -1)
    
    if [ -n "$line_num" ]; then
        sed -i '' "${line_num}a\\$env_line" "$config_file"
        line_num=$((line_num + 1))
        sed -i '' "${line_num}a\\$source_env_line" "$config_file"
        echo "Added OPENCODE_DISABLE_AUTOUPDATE to ${config_file}"
        echo ""
        echo "Run: source ~/.zshrc"
    else
        echo "" >> "$config_file"
        echo "# kopencode (forked from opencode)" >> "$config_file"
        echo "$path_line" >> "$config_file"
        echo "$env_line" >> "$config_file"
        echo "$source_env_line" >> "$config_file"
        echo "Added kopencode to PATH in ${config_file}"
        echo ""
        echo "Run: source ~/.zshrc"
    fi
}

add_env_vars() {
    local config_file="${HOME}/.zshrc"
    local env_file="${HOME}/.config/kopencode/.env"
    
    mkdir -p "${HOME}/.config/kopencode"
    
    # Source existing env vars from config file (only export statements)
    if [ -f "$config_file" ]; then
        while IFS= read -r line; do
            if [[ "$line" == export\ * ]]; then
                eval "$line" 2>/dev/null || true
            fi
        done < <(grep -E "^export " "$config_file" 2>/dev/null || true)
    fi

    local brave_key="${BRAVE_SEARCH_API_KEY:-}"
    if [ -n "$brave_key" ]; then
        echo "BRAVE_SEARCH_API_KEY already set"
    else
        echo "Enter your Brave Search API key (or press Enter to skip):"
        read -r brave_key
        if [ -n "$brave_key" ]; then
            export BRAVE_SEARCH_API_KEY="$brave_key"
        fi
    fi

    if [ -n "$brave_key" ]; then
        if grep -q "^BRAVE_SEARCH_API_KEY=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^BRAVE_SEARCH_API_KEY=.*|BRAVE_SEARCH_API_KEY=${brave_key}|" "$env_file"
        else
            echo "BRAVE_SEARCH_API_KEY=${brave_key}" >> "$env_file"
        fi
        echo "Written BRAVE_SEARCH_API_KEY to ${env_file}"
    fi

    local bedrock_token="${AWS_BEARER_TOKEN_BEDROCK:-}"
    if [ -n "$bedrock_token" ]; then
        echo "AWS_BEARER_TOKEN_BEDROCK already set"
    else
        echo "Enter your AWS Bedrock Bearer Token (or press Enter to skip):"
        read -r bedrock_token
        if [ -n "$bedrock_token" ]; then
            export AWS_BEARER_TOKEN_BEDROCK="$bedrock_token"
        fi
    fi

    if [ -n "$bedrock_token" ]; then
        if grep -q "^AWS_BEARER_TOKEN_BEDROCK=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^AWS_BEARER_TOKEN_BEDROCK=.*|AWS_BEARER_TOKEN_BEDROCK=${bedrock_token}|" "$env_file"
        else
            echo "AWS_BEARER_TOKEN_BEDROCK=${bedrock_token}" >> "$env_file"
        fi
        echo "Written AWS_BEARER_TOKEN_BEDROCK to ${env_file}"
    fi

    echo ""
    echo "Run: source ~/.zshrc"
}

main() {
    install_bun
    export PATH="${HOME}/.bun/bin:${PATH}"

    force_rebuild=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rebuild) force_rebuild=true; shift ;;
            *) shift ;;
        esac
    done

    if [ ! -f "$OUTPUT_BINARY" ] || [ "$force_rebuild" = true ]; then
        build
    else
        echo "Binary already exists at $OUTPUT_BINARY. Use --rebuild to force rebuild."
    fi

    install_binary
    add_to_path
    add_env_vars
}

main "$@"