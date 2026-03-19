#!/bin/sh
# Shard installer — downloads the latest release binary and installs it globally.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yesitsfebreeze/shard/main/install.sh | sh
#
# Options (env vars):
#   SHARD_VERSION=v0.1.0   Install a specific version (default: latest stable, falls back to nightly)
#   SHARD_INSTALL_DIR=/usr/local/bin   Install directory (default: /usr/local/bin or ~/bin)

set -e

REPO="yesitsfebreeze/shard"
INSTALL_DIR="${SHARD_INSTALL_DIR:-}"
VERSION="${SHARD_VERSION:-}"

# --- Detect platform ---

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Linux*)  OS="linux" ;;
  Darwin*) OS="macos" ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
  *) echo "error: unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64)  ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) echo "error: unsupported architecture: $ARCH"; exit 1 ;;
esac

TARGET="${OS}-${ARCH}"

if [ "$OS" = "windows" ]; then
  ARCHIVE="shard-${TARGET}.zip"
  BIN="shard.exe"
else
  ARCHIVE="shard-${TARGET}.tar.gz"
  BIN="shard"
fi

# --- Resolve install directory ---

if [ -z "$INSTALL_DIR" ]; then
  if [ -w "/usr/local/bin" ]; then
    INSTALL_DIR="/usr/local/bin"
  elif [ -d "$HOME/.local/bin" ]; then
    INSTALL_DIR="$HOME/.local/bin"
  elif [ -d "$HOME/bin" ]; then
    INSTALL_DIR="$HOME/bin"
  else
    mkdir -p "$HOME/.local/bin"
    INSTALL_DIR="$HOME/.local/bin"
  fi
fi

# --- Resolve version ---

if [ -z "$VERSION" ]; then
  # Try latest stable release first, fall back to nightly
  VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*: *"\(.*\)".*/\1/' || true)

  if [ -z "$VERSION" ] || [ "$VERSION" = "main" ]; then
    # No stable release yet — use nightly
    VERSION="main"
  fi
fi

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ARCHIVE}"

# --- Download and install ---

echo "shard installer"
echo "  platform: ${TARGET}"
echo "  version:  ${VERSION}"
echo "  install:  ${INSTALL_DIR}/${BIN}"
echo ""

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading ${ARCHIVE}..."
HTTP_CODE=$(curl -fsSL -w '%{http_code}' -o "${TMP}/${ARCHIVE}" "$DOWNLOAD_URL" 2>/dev/null || true)

if [ ! -f "${TMP}/${ARCHIVE}" ] || [ "$HTTP_CODE" = "404" ]; then
  echo ""
  echo "error: no release found for ${TARGET} (${VERSION})"
  echo ""
  echo "available platforms: linux-amd64, linux-arm64, macos-amd64, macos-arm64, windows-amd64"
  echo "check releases: https://github.com/${REPO}/releases"
  exit 1
fi

echo "extracting..."
cd "$TMP"
if [ "$OS" = "windows" ]; then
  unzip -q "$ARCHIVE"
else
  tar xzf "$ARCHIVE"
fi

echo "installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
mv "${BIN}" "${INSTALL_DIR}/${BIN}"
chmod +x "${INSTALL_DIR}/${BIN}"

# --- Verify ---

INSTALLED_PATH="${INSTALL_DIR}/${BIN}"
if [ -x "$INSTALLED_PATH" ]; then
  echo ""
  echo "done! shard installed to ${INSTALLED_PATH}"

  # Check if install dir is in PATH
  case ":$PATH:" in
    *":${INSTALL_DIR}:"*) ;;
    *)
      echo ""
      echo "note: ${INSTALL_DIR} is not in your PATH. Add it:"
      echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
      ;;
  esac
else
  echo "error: installation failed"
  exit 1
fi
