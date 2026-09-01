#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_NAME="kopencode"
BUILT_BINARY="${SCRIPT_DIR}/packages/opencode/dist/opencode-darwin-arm64/bin/opencode"
OUTPUT_BINARY="${SCRIPT_DIR}/packages/opencode/dist/opencode-darwin-arm64/bin/kopencode"

VERBOSE=true

log()  { [ "$VERBOSE" = true ] && echo "$@" || true; }
warn() { echo "$@"; }

run_quiet() {
    if [ "$VERBOSE" = true ]; then
        "$@"
    else
        "$@" > /dev/null 2>&1
    fi
}

install_bun() {
    if ! command -v bun >/dev/null 2>&1; then
        warn "Bun not found. Installing..."
        if [ "$VERBOSE" = true ]; then
            curl -fsSL https://bun.sh/install | bash
        else
            curl -fsSL https://bun.sh/install | bash > /dev/null 2>&1
        fi
        export BUN_INSTALL="${HOME}/.bun"
        export PATH="${BUN_INSTALL}/bin:${PATH}"
    fi
}

build() {
    log "Installing dependencies..."
    cd "${SCRIPT_DIR}"
    run_quiet bun install

    log "Building kopencode (forked from opencode)..."
    cd "${SCRIPT_DIR}/packages/opencode"
    if ! run_quiet bun run build --single; then
        warn "Error: Build failed. Re-run with -v for details."
        exit 1
    fi

    if [ ! -f "$BUILT_BINARY" ]; then
        warn "Error: Build failed. Binary not found at $BUILT_BINARY"
        [ "$VERBOSE" = false ] && warn "       Re-run with -v for details."
        exit 1
    fi

    cp "$BUILT_BINARY" "$OUTPUT_BINARY"
    chmod +x "$OUTPUT_BINARY"
    log "Build successful!"
}

install_binary() {
    mkdir -p "$INSTALL_DIR"
    cp "$OUTPUT_BINARY" "${INSTALL_DIR}/${BINARY_NAME}"
    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
    # Re-sign with ad-hoc signature — cp invalidates the original signature and macOS will SIGKILL unsigned binaries
    codesign --sign - --force "${INSTALL_DIR}/${BINARY_NAME}" 2>/dev/null || true
    log "Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"
}

add_to_path() {
    local config_file="${HOME}/.zshrc"
    local path_line="export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    local source_env_line="[ -f \"\${HOME}/.config/kopencode/.env\" ] && { set -a; source \"\${HOME}/.config/kopencode/.env\"; set +a; }"

    if grep -qF -- "$source_env_line" "$config_file" 2>/dev/null; then
        log "Environment already configured in ${config_file}"
        return
    fi

    local line_num
    line_num=$(grep -n -- "$path_line" "$config_file" 2>/dev/null | cut -d: -f1 | head -1 || true)

    if [ -n "$line_num" ]; then
        sed -i '' "${line_num}a\\$source_env_line" "$config_file"
        log "Added env source line to ${config_file}"
    else
        echo "" >> "$config_file"
        echo "# kopencode (forked from opencode)" >> "$config_file"
        echo "$path_line" >> "$config_file"
        echo "$source_env_line" >> "$config_file"
        log "Added kopencode to PATH in ${config_file}"
    fi
}

add_env_vars() {
    local env_file="${HOME}/.config/kopencode/.env"

    mkdir -p "${HOME}/.config/kopencode"

    # Always write the source dir so the binary can invoke the update script
    if grep -q "^KOPENCODE_SOURCE_DIR=" "$env_file" 2>/dev/null; then
        sed -i '' "s|^KOPENCODE_SOURCE_DIR=.*|KOPENCODE_SOURCE_DIR=${SCRIPT_DIR}|" "$env_file"
    else
        echo "KOPENCODE_SOURCE_DIR=${SCRIPT_DIR}" >> "$env_file"
    fi

    # Source existing env vars from config file (only export statements)
    local config_file="${HOME}/.zshrc"
    if [ -f "$config_file" ]; then
        while IFS= read -r line; do
            if [[ "$line" == export\ * ]]; then
                eval "$line" 2>/dev/null || true
            fi
        done < <(grep -E "^export " "$config_file" 2>/dev/null || true)
    fi

    local force="${1:-false}"

    local brave_key="${BRAVE_SEARCH_API_KEY:-}"
    if [ -z "$brave_key" ] || [ "$force" = true ]; then
        [ -n "$brave_key" ] && echo "Brave Search API key is set (press Enter to keep, or enter a new value):"
        [ -z "$brave_key" ] && echo "Enter your Brave Search API key (or press Enter to skip):"
        read -r input
        [ -n "$input" ] && brave_key="$input"
        export BRAVE_SEARCH_API_KEY="$brave_key"
    fi

    if [ -n "$brave_key" ]; then
        if grep -q "^BRAVE_SEARCH_API_KEY=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^BRAVE_SEARCH_API_KEY=.*|BRAVE_SEARCH_API_KEY=${brave_key}|" "$env_file"
        else
            echo "BRAVE_SEARCH_API_KEY=${brave_key}" >> "$env_file"
        fi
        log "Written BRAVE_SEARCH_API_KEY to ${env_file}"
    fi

    local bedrock_token="${AWS_BEARER_TOKEN_BEDROCK:-}"
    if [ -z "$bedrock_token" ] || [ "$force" = true ]; then
        [ -n "$bedrock_token" ] && echo "AWS Bedrock Bearer Token is set (press Enter to keep, or enter a new value):"
        [ -z "$bedrock_token" ] && echo "Enter your AWS Bedrock Bearer Token (or press Enter to skip):"
        read -r input
        [ -n "$input" ] && bedrock_token="$input"
        export AWS_BEARER_TOKEN_BEDROCK="$bedrock_token"
    fi

    if [ -n "$bedrock_token" ]; then
        if grep -q "^AWS_BEARER_TOKEN_BEDROCK=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^AWS_BEARER_TOKEN_BEDROCK=.*|AWS_BEARER_TOKEN_BEDROCK=${bedrock_token}|" "$env_file"
        else
            echo "AWS_BEARER_TOKEN_BEDROCK=${bedrock_token}" >> "$env_file"
        fi
        log "Written AWS_BEARER_TOKEN_BEDROCK to ${env_file}"
    fi

    local azure_resource_name="${AZURE_RESOURCE_NAME:-}"
    if [ -z "$azure_resource_name" ] || [ "$force" = true ]; then
        [ -n "$azure_resource_name" ] && echo "Azure resource name is set (press Enter to keep, or enter a new value):"
        [ -z "$azure_resource_name" ] && echo "Enter your Azure / Microsoft Foundry resource name (or press Enter to skip):"
        read -r input
        [ -n "$input" ] && azure_resource_name="$input"
        export AZURE_RESOURCE_NAME="$azure_resource_name"
    fi

    if [ -n "$azure_resource_name" ]; then
        if grep -q "^AZURE_RESOURCE_NAME=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^AZURE_RESOURCE_NAME=.*|AZURE_RESOURCE_NAME=${azure_resource_name}|" "$env_file"
        else
            echo "AZURE_RESOURCE_NAME=${azure_resource_name}" >> "$env_file"
        fi
        log "Written AZURE_RESOURCE_NAME to ${env_file}"
    fi

    local azure_api_key="${AZURE_API_KEY:-}"
    if [ -z "$azure_api_key" ] || [ "$force" = true ]; then
        [ -n "$azure_api_key" ] && echo "Azure API key is set (press Enter to keep, or enter a new value):"
        [ -z "$azure_api_key" ] && echo "Enter your Azure / Microsoft Foundry API key (or press Enter to skip):"
        read -r input
        [ -n "$input" ] && azure_api_key="$input"
        export AZURE_API_KEY="$azure_api_key"
    fi

    if [ -n "$azure_api_key" ]; then
        if grep -q "^AZURE_API_KEY=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^AZURE_API_KEY=.*|AZURE_API_KEY=${azure_api_key}|" "$env_file"
        else
            echo "AZURE_API_KEY=${azure_api_key}" >> "$env_file"
        fi
        log "Written AZURE_API_KEY to ${env_file}"
    fi

    local litellm_base_url="${LITELLM_BASE_URL:-}"
    if [ -z "$litellm_base_url" ] || [ "$force" = true ]; then
        [ -n "$litellm_base_url" ] && echo "LiteLLM base URL is set (press Enter to keep, or enter a new value):"
        [ -z "$litellm_base_url" ] && echo "Enter your LiteLLM proxy base URL (or press Enter to use http://localhost:4000):"
        read -r input
        [ -n "$input" ] && litellm_base_url="$input"
        [ -z "$litellm_base_url" ] && litellm_base_url="http://localhost:4000"
        export LITELLM_BASE_URL="$litellm_base_url"
    fi

    if [ -n "$litellm_base_url" ]; then
        if grep -q "^LITELLM_BASE_URL=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^LITELLM_BASE_URL=.*|LITELLM_BASE_URL=${litellm_base_url}|" "$env_file"
        else
            echo "LITELLM_BASE_URL=${litellm_base_url}" >> "$env_file"
        fi
        log "Written LITELLM_BASE_URL to ${env_file}"
    fi

    local litellm_api_key="${LITELLM_API_KEY:-}"
    if [ -z "$litellm_api_key" ] || [ "$force" = true ]; then
        [ -n "$litellm_api_key" ] && echo "LiteLLM API key is set (press Enter to keep, or enter a new value):"
        [ -z "$litellm_api_key" ] && echo "Enter your LiteLLM API key (or press Enter to skip):"
        read -r input
        [ -n "$input" ] && litellm_api_key="$input"
        export LITELLM_API_KEY="$litellm_api_key"
    fi

    if [ -n "$litellm_api_key" ]; then
        if grep -q "^LITELLM_API_KEY=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^LITELLM_API_KEY=.*|LITELLM_API_KEY=${litellm_api_key}|" "$env_file"
        else
            echo "LITELLM_API_KEY=${litellm_api_key}" >> "$env_file"
        fi
        log "Written LITELLM_API_KEY to ${env_file}"
    fi
}

configure_global_provider_defaults() {
    local config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
    local config_file="${config_dir}/opencode.jsonc"

    mkdir -p "$config_dir"
    [ -f "$config_file" ] || echo '{"$schema": "https://opencode.ai/config.json"}' > "$config_file"

    bun run "${SCRIPT_DIR}/script/kompas-provider-defaults.mjs" "$config_file" \
        && log "Ensured provider allowlist defaults in ${config_file}" \
        || warn "WARNING: could not apply default provider allowlist to ${config_file} (leaving it untouched)"
}

apply_patches() {
    local patches_dir="${SCRIPT_DIR}/patches/kompas"
    if [ ! -d "$patches_dir" ]; then
        log "No patches directory found at $patches_dir, skipping."
        return
    fi

    local patches
    patches=($(ls "${patches_dir}"/*.patch 2>/dev/null | sort))
    if [ ${#patches[@]} -eq 0 ]; then
        log "No patch files found in $patches_dir, skipping."
        return
    fi

    log "Applying ${#patches[@]} Kompas patch(es)..."
    for patch in "${patches[@]}"; do
        log "  Applying $(basename "$patch")..."
        if ! git apply --check "$patch" 2>/dev/null; then
            warn "  WARNING: $(basename "$patch") does not apply cleanly (may already be applied or upstream changed)"
            continue
        fi
        run_quiet git apply "$patch"
        log "  Applied $(basename "$patch")"
    done
}

stash_patches() {
    if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
        return
    fi
    warn ""
    warn "WARNING: Stashing applied patch changes to keep the working tree clean."
    warn "         The installed binary already contains all patches — the source"
    warn "         directory is intentionally left in the upstream state so the"
    warn "         next --update can merge cleanly without conflicts."
    warn "         To inspect the applied changes: git stash show -p"
    warn "         To restore them for debugging: git stash pop"
    warn ""
    run_quiet git stash push -m "kompas-patches: auto-stashed after build"
}

update_from_upstream() {
    local upstream_url="${1:-https://github.com/sst/opencode.git}"
    local upstream_branch="${2:-dev}"

    cd "${SCRIPT_DIR}"

    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        warn ""
        warn "WARNING: Working tree has uncommitted changes."
        warn "         If these are leftover applied patches from a previous build,"
        warn "         run 'git stash' before retrying --update to avoid merge conflicts."
        warn ""
    fi

    log "Fetching upstream opencode from ${upstream_url}..."
    if ! git remote get-url upstream >/dev/null 2>&1; then
        run_quiet git remote add upstream "$upstream_url"
        log "Added upstream remote."
    fi

    run_quiet git fetch upstream

    log "Merging upstream/${upstream_branch}..."
    run_quiet git merge "upstream/${upstream_branch}" --no-edit

    log "Applying Kompas patches on top of upstream..."
    log "(patches will be stashed after the build to keep this directory clean)"
    apply_patches
}

main() {
    install_bun
    export PATH="${HOME}/.bun/bin:${PATH}"

    force_rebuild=false
    do_update=false
    silent=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rebuild) force_rebuild=true; shift ;;
            --update)  do_update=true; shift ;;
            --silent)  silent=true; shift ;;
            -q)        VERBOSE=false; shift ;;
            *) shift ;;
        esac
    done

    if [ "$do_update" = true ]; then
        update_from_upstream
        force_rebuild=true
    fi

    if [ ! -f "$OUTPUT_BINARY" ] || [ "$force_rebuild" = true ]; then
        build
    else
        log "Binary already exists at $OUTPUT_BINARY. Use --rebuild to force rebuild."
    fi

    if [ "$do_update" = true ]; then
        stash_patches
    fi

    install_binary
    configure_global_provider_defaults
    if [ "$silent" = false ]; then
        add_to_path
        add_env_vars "$force_rebuild"
    else
        # In silent mode (called by auto-update), still write KOPENCODE_SOURCE_DIR
        # in case the env file was wiped, but skip interactive prompts.
        local env_file="${HOME}/.config/kopencode/.env"
        mkdir -p "${HOME}/.config/kopencode"
        if grep -q "^KOPENCODE_SOURCE_DIR=" "$env_file" 2>/dev/null; then
            sed -i '' "s|^KOPENCODE_SOURCE_DIR=.*|KOPENCODE_SOURCE_DIR=${SCRIPT_DIR}|" "$env_file"
        else
            echo "KOPENCODE_SOURCE_DIR=${SCRIPT_DIR}" >> "$env_file"
        fi
    fi

    echo ""
    echo "*****  source ~/.zshrc  OR  open a new terminal  *****"
    echo ""
}

main "$@"
