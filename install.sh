#!/bin/bash
#
# Assay Installer
# https://getassay.dev
#
# Usage:
#   curl -fsSL https://getassay.dev/install.sh | sh
#   curl -fsSL https://getassay.dev/install.sh | ASSAY_VERSION=1.3.0 sh
#

set -e

# --- Configuration ---
GITHUB_REPO="Rul1an/assay"
BINARY_NAME="assay"
INSTALL_DIR="${ASSAY_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${ASSAY_VERSION:-latest}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# --- Helpers ---
log_info() { echo -e "${BLUE}${BOLD}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}${BOLD}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}${BOLD}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}${BOLD}[ERROR]${NC} $1"; exit 1; }

# --- Main ---
main() {
    echo -e "${BOLD}✨ Assay Installer${NC}"
    echo ""

    # 1. Detect OS & Arch
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    ARCH="$(uname -m)"

    case "$OS" in
        linux)
            TARGET_OS="unknown-linux-gnu"
            ;;
        darwin)
            TARGET_OS="apple-darwin"
            ;;
        mingw*|msys*)
            OS="windows"
            TARGET_OS="pc-windows-msvc"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            ;;
    esac

    case "$ARCH" in
        x86_64|amd64)
            TARGET_ARCH="x86_64"
            ;;
        arm64|aarch64)
            TARGET_ARCH="aarch64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            ;;
    esac

    TARGET="${TARGET_ARCH}-${TARGET_OS}"
    log_info "Detected platform: $OS/$ARCH ($TARGET)"

    # 2. Resolve Version
    if [ "$VERSION" = "latest" ]; then
        # Fetch latest release tag from GitHub API
        RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest")
        VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -z "$VERSION" ]; then
            log_error "Failed to resolve latest version."
        fi
    fi
    # Ensure 'v' prefix only if missing (though usually tags have it)
    # Check if version has 'v', if not add it, if yes keep it.
    # Actually, GitHub tags usually have 'v'.

    log_info "Target version: $VERSION"

    # 3. Construct Download URL
    # Format: assay-{version}-{target}.tar.gz (or .zip for windows)
    # E.g. assay-v1.3.0-x86_64-apple-darwin.tar.gz

    # Strip any potential leading 'v' for the filename content if needed?
    # Our release.yml uses: ARCHIVE_NAME="assay-${VERSION}-${{ matrix.target }}"
    # So if VERSION is "v1.3.0", archive is "assay-v1.3.0-x86_64-apple-darwin".

    if [ "$OS" = "windows" ]; then
        ARCHIVE_NAME="assay-${VERSION}-${TARGET}.zip"
    else
        ARCHIVE_NAME="assay-${VERSION}-${TARGET}.tar.gz"
    fi

    DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/$ARCHIVE_NAME"

    # 4. Download
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    log_info "Downloading from $DOWNLOAD_URL ..."
    HTTP_CODE=$(curl -fsSL -w "%{http_code}" -o "$TMP_DIR/$ARCHIVE_NAME" "$DOWNLOAD_URL")

    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Download failed (HTTP $HTTP_CODE). URL: $DOWNLOAD_URL"
    fi

    # 5. Extract
    cd "$TMP_DIR"
    log_info "Extracting ..."
    if [ "$OS" = "windows" ]; then
        unzip -q "$ARCHIVE_NAME"
        BINARY_PATH="$TMP_DIR/dist/assay-${VERSION}-${TARGET}/assay.exe" # Structure depends on how zip was made.
        # release.yml: Copy-Item ... "dist\${ARCHIVE_NAME}\" -> Compress "dist\${ARCHIVE_NAME}"
        # So zip contains a folder "assay-v1.3.0-..." which contains "assay.exe".
        EXTRACTED_DIR="assay-${VERSION}-${TARGET}"
    else
        tar xzkf "$ARCHIVE_NAME"
        # release.yml: tar -czvf "${ARCHIVE_NAME}.tar.gz" "${ARCHIVE_NAME}"
        # So tar contains a folder "assay-v1.3.0-..."
        EXTRACTED_DIR="assay-${VERSION}-${TARGET}"
    fi

    # 6. Install
    mkdir -p "$INSTALL_DIR"

    if [ "$OS" = "windows" ]; then
        mv "$EXTRACTED_DIR/assay.exe" "$INSTALL_DIR/assay.exe"
    else
        mv "$EXTRACTED_DIR/assay" "$INSTALL_DIR/assay"
        chmod +x "$INSTALL_DIR/assay"
    fi

    echo ""
    log_success "Assay installed to: $INSTALL_DIR/assay"

    # 7. Path Check
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        echo ""
        log_warn "Your path is missing $INSTALL_DIR"
        echo -e "   Add this to your shell config (~/.zshrc, ~/.bashrc):"
        echo -e "   ${BOLD}export PATH=\"\$PATH:$INSTALL_DIR\"${NC}"
        echo ""
    fi

    echo -e "Run ${BOLD}assay --help${NC} to get started."
}

main "$@"
