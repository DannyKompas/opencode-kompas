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
    # Re-sign with ad-hoc signature — cp invalidates the original signature and macOS will SIGKILL unsigned binaries
    codesign --sign - --force "${INSTALL_DIR}/${BINARY_NAME}" 2>/dev/null || true
    echo "Installed ${BINARY_NAME} to ${INSTALL_DIR}/${BINARY_NAME}"
}

add_to_path() {
    local config_file="${HOME}/.zshrc"
    local path_line="export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    local source_env_line="[ -f \"\${HOME}/.config/kopencode/.env\" ] && { set -a; source \"\${HOME}/.config/kopencode/.env\"; set +a; }"

    if grep -qF -- "$source_env_line" "$config_file" 2>/dev/null; then
        echo "Environment already configured in ${config_file}"
        return
    fi

    local line_num
    line_num=$(grep -n -- "$path_line" "$config_file" 2>/dev/null | cut -d: -f1 | head -1)

    if [ -n "$line_num" ]; then
        sed -i '' "${line_num}a\\$source_env_line" "$config_file"
        echo "Added env source line to ${config_file}"
        echo ""
        echo "Run: source ~/.zshrc"
    else
        echo "" >> "$config_file"
        echo "# kopencode (forked from opencode)" >> "$config_file"
        echo "$path_line" >> "$config_file"
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

    # Always write the source dir so the binary can invoke the update script
    if grep -q "^KOPENCODE_SOURCE_DIR=" "$env_file" 2>/dev/null; then
        sed -i '' "s|^KOPENCODE_SOURCE_DIR=.*|KOPENCODE_SOURCE_DIR=${SCRIPT_DIR}|" "$env_file"
    else
        echo "KOPENCODE_SOURCE_DIR=${SCRIPT_DIR}" >> "$env_file"
    fi
    
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

apply_patches() {
    local patches_dir="${SCRIPT_DIR}/patches/kompas"
    if [ ! -d "$patches_dir" ]; then
        echo "No patches directory found at $patches_dir, skipping."
        return
    fi

    local patches
    patches=($(ls "${patches_dir}"/*.patch 2>/dev/null | sort))
    if [ ${#patches[@]} -eq 0 ]; then
        echo "No patch files found in $patches_dir, skipping."
        return
    fi

    echo "Applying ${#patches[@]} Kompas patch(es)..."
    for patch in "${patches[@]}"; do
        echo "  Applying $(basename "$patch")..."
        if ! git apply --check "$patch" 2>/dev/null; then
            echo "  WARNING: $(basename "$patch") does not apply cleanly (may already be applied or upstream changed)"
            continue
        fi
        git apply "$patch"
        echo "  Applied $(basename "$patch")"
    done
}

stash_patches() {
    if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
        return
    fi
    echo ""
    echo "WARNING: Stashing applied patch changes to keep the working tree clean."
    echo "         The installed binary already contains all patches — the source"
    echo "         directory is intentionally left in the upstream state so the"
    echo "         next --update can merge cleanly without conflicts."
    echo "         To inspect the applied changes: git stash show -p"
    echo "         To restore them for debugging: git stash pop"
    echo ""
    git stash push -m "kompas-patches: auto-stashed after build"
}

update_from_upstream() {
    local upstream_url="${1:-https://github.com/sst/opencode.git}"
    local upstream_branch="${2:-dev}"

    cd "${SCRIPT_DIR}"

    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        echo ""
        echo "WARNING: Working tree has uncommitted changes."
        echo "         If these are leftover applied patches from a previous build,"
        echo "         run 'git stash' before retrying --update to avoid merge conflicts."
        echo ""
    fi

    echo "Fetching upstream opencode from ${upstream_url}..."
    if ! git remote get-url upstream >/dev/null 2>&1; then
        git remote add upstream "$upstream_url"
        echo "Added upstream remote."
    fi

    git fetch upstream

    echo "Merging upstream/${upstream_branch}..."
    git merge "upstream/${upstream_branch}" --no-edit

    echo "Applying Kompas patches on top of upstream..."
    echo "(patches will be stashed after the build to keep this directory clean)"
    apply_patches

    echo ""
    echo "Upstream merge + patches applied. Building..."
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
        echo "Binary already exists at $OUTPUT_BINARY. Use --rebuild to force rebuild."
    fi

    if [ "$do_update" = true ]; then
        stash_patches
    fi

    install_binary
    if [ "$silent" = false ]; then
        add_to_path
        add_env_vars
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
}

main "$@"