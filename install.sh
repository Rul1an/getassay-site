#!/bin/bash
# Assay Installer
# https://getassay.dev
#
# Usage:
#   curl -fsSL https://getassay.dev/install.sh | sh
#
# Options (via environment variables):
#   ASSAY_VERSION     - Specific version (default: latest)
#   ASSAY_INSTALL_DIR - Install directory (default: ~/.local/bin)
#
# Examples:
#   curl -fsSL https://assay.dev/install.sh | sh
#   curl -fsSL https://assay.dev/install.sh | ASSAY_VERSION=v1.3.0 sh
#   curl -fsSL https://assay.dev/install.sh | ASSAY_INSTALL_DIR=/usr/local/bin sudo sh

set -e

# ============================================================
# Configuration
# ============================================================

GITHUB_REPO="assay-dev/assay"
BINARY_NAME="assay"
VERSION="${ASSAY_VERSION:-latest}"
INSTALL_DIR="${ASSAY_INSTALL_DIR:-$HOME/.local/bin}"

# ============================================================
# Colors (disabled if not a terminal)
# ============================================================

if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  BOLD=''
  NC=''
fi

# ============================================================
# Helper functions
# ============================================================

info() {
  echo -e "${BLUE}${BOLD}==>${NC} $1"
}

success() {
  echo -e "${GREEN}${BOLD}✓${NC} $1"
}

warn() {
  echo -e "${YELLOW}${BOLD}⚠${NC} $1"
}

error() {
  echo -e "${RED}${BOLD}✗${NC} $1" >&2
  exit 1
}

# ============================================================
# Detect platform
# ============================================================

detect_platform() {
  local os arch target

  # Detect OS
  case "$(uname -s)" in
    Linux*)  os="unknown-linux-gnu" ;;
    Darwin*) os="apple-darwin" ;;
    MINGW*|MSYS*|CYGWIN*) os="pc-windows-msvc" ;;
    *) error "Unsupported operating system: $(uname -s)" ;;
  esac

  # Detect architecture
  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) error "Unsupported architecture: $(uname -m)" ;;
  esac

  # Windows only supports x86_64 for now
  if [ "$os" = "pc-windows-msvc" ] && [ "$arch" != "x86_64" ]; then
    error "Windows builds are only available for x86_64"
  fi

  echo "${arch}-${os}"
}

# ============================================================
# Get latest version from GitHub
# ============================================================

get_latest_version() {
  local latest

  # Try GitHub API first
  if command -v curl &> /dev/null; then
    latest=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | \
      grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  elif command -v wget &> /dev/null; then
    latest=$(wget -qO- "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null | \
      grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  fi

  if [ -z "$latest" ]; then
    error "Failed to determine latest version. Please specify ASSAY_VERSION manually."
  fi

  echo "$latest"
}

# ============================================================
# Download and install
# ============================================================

download() {
  local url="$1"
  local output="$2"

  if command -v curl &> /dev/null; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget &> /dev/null; then
    wget -q "$url" -O "$output"
  else
    error "Neither curl nor wget found. Please install one of them."
  fi
}

verify_checksum() {
  local file="$1"
  local checksum_url="$2"
  local tmp_checksum

  tmp_checksum=$(mktemp)
  
  if download "$checksum_url" "$tmp_checksum" 2>/dev/null; then
    local expected actual
    expected=$(cat "$tmp_checksum" | awk '{print $1}')
    
    if command -v sha256sum &> /dev/null; then
      actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum &> /dev/null; then
      actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
      warn "Cannot verify checksum (sha256sum/shasum not found)"
      rm -f "$tmp_checksum"
      return 0
    fi

    rm -f "$tmp_checksum"

    if [ "$expected" != "$actual" ]; then
      error "Checksum verification failed!\n  Expected: $expected\n  Actual:   $actual"
    fi
    
    success "Checksum verified"
  else
    warn "Could not download checksum file, skipping verification"
    rm -f "$tmp_checksum"
  fi
}

# ============================================================
# Main
# ============================================================

main() {
  echo ""
  echo -e "${GREEN}${BOLD}📦 Assay Installer${NC}"
  echo ""

  # Detect platform
  local target
  target=$(detect_platform)
  info "Detected platform: ${BOLD}${target}${NC}"

  # Get version
  if [ "$VERSION" = "latest" ]; then
    info "Fetching latest version..."
    VERSION=$(get_latest_version)
  fi
  info "Version: ${BOLD}${VERSION}${NC}"

  # Determine archive format and URL
  local archive_ext download_url checksum_url archive_name
  
  if [[ "$target" == *"windows"* ]]; then
    archive_ext="zip"
  else
    archive_ext="tar.gz"
  fi

  archive_name="assay-${VERSION}-${target}.${archive_ext}"
  download_url="https://github.com/${GITHUB_REPO}/releases/download/${VERSION}/${archive_name}"
  checksum_url="${download_url}.sha256"

  # Create temp directory
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap "rm -rf $tmp_dir" EXIT

  # Download
  info "Downloading ${archive_name}..."
  echo "    ${download_url}"
  download "$download_url" "$tmp_dir/$archive_name" || \
    error "Download failed. Check if version ${VERSION} exists for ${target}"

  # Verify checksum
  info "Verifying checksum..."
  verify_checksum "$tmp_dir/$archive_name" "$checksum_url"

  # Extract
  info "Extracting..."
  cd "$tmp_dir"
  
  if [ "$archive_ext" = "zip" ]; then
    if command -v unzip &> /dev/null; then
      unzip -q "$archive_name"
    else
      error "unzip not found. Please install it."
    fi
  else
    tar xzf "$archive_name"
  fi

  # Find the binary
  local binary_path
  binary_path=$(find . -name "$BINARY_NAME" -o -name "${BINARY_NAME}.exe" | head -1)
  
  if [ -z "$binary_path" ]; then
    error "Binary not found in archive"
  fi

  # Install
  info "Installing to ${BOLD}${INSTALL_DIR}${NC}..."
  mkdir -p "$INSTALL_DIR"
  
  if [[ "$target" == *"windows"* ]]; then
    cp "$binary_path" "$INSTALL_DIR/${BINARY_NAME}.exe"
  else
    cp "$binary_path" "$INSTALL_DIR/$BINARY_NAME"
    chmod +x "$INSTALL_DIR/$BINARY_NAME"
  fi

  # Verify installation
  if [ -x "$INSTALL_DIR/$BINARY_NAME" ] || [ -f "$INSTALL_DIR/${BINARY_NAME}.exe" ]; then
    echo ""
    success "Assay ${VERSION} installed successfully!"
    echo ""
  else
    error "Installation failed"
  fi

  # PATH check
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo -e "${YELLOW}${BOLD}Note:${NC} ${INSTALL_DIR} is not in your PATH."
    echo ""
    echo "Add it by running:"
    echo ""
    echo -e "  ${BLUE}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc${NC}"
    echo ""
    echo "Or for zsh:"
    echo ""
    echo -e "  ${BLUE}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc${NC}"
    echo ""
    echo "Then restart your shell or run: source ~/.bashrc"
    echo ""
  fi

  # Next steps
  echo -e "${GREEN}${BOLD}Next steps:${NC}"
  echo ""
  echo "  1. Setup for Claude Desktop:"
  echo -e "     ${BLUE}assay init claude${NC}"
  echo ""
  echo "  2. Or manually wrap an MCP server:"
  echo -e "     ${BLUE}assay mcp wrap --policy policy.yaml -- npx @modelcontextprotocol/server-filesystem ~/${NC}"
  echo ""
  echo "  3. Verify installation:"
  echo -e "     ${BLUE}assay --version${NC}"
  echo ""
}

main "$@"
