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

    if grep -qF -- "$env_line" "$config_file" 2>/dev/null; then
        echo "Environment already configured in ${config_file}"
        return
    fi

    local line_num
    line_num=$(grep -n -- "$path_line" "$config_file" 2>/dev/null | cut -d: -f1 | head -1)
    
    if [ -n "$line_num" ]; then
        sed -i '' "${line_num}a\\$env_line" "$config_file"
        echo "Added OPENCODE_DISABLE_AUTOUPDATE to ${config_file}"
        echo ""
        echo "Run: source ~/.zshrc"
    else
        echo "" >> "$config_file"
        echo "# kopencode (forked from opencode)" >> "$config_file"
        echo "$path_line" >> "$config_file"
        echo "$env_line" >> "$config_file"
        echo "Added kopencode to PATH in ${config_file}"
        echo ""
        echo "Run: source ~/.zshrc"
    fi
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
}

main "$@"