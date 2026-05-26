#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$REPO_ROOT/tmp"
VERSION="${CPK_VERSION:-0.10.0}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

case "$(uname -s)" in
  Linux)  OS=linux;  SUDO=""     ;;
  Darwin) OS=darwin; SUDO="sudo" ;; # macOS requires elevated permissions to run cloud-provider-kind
  *) log "Unsupported OS: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  amd64|x86_64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) log "Unsupported arch: $(uname -m)"; exit 1 ;;
esac

mkdir -p "$TMP_DIR"
TARBALL="$TMP_DIR/cloud-provider-kind.tar.gz"
CPK_URL="https://github.com/kubernetes-sigs/cloud-provider-kind/releases/download/v${VERSION}/cloud-provider-kind_${VERSION}_${OS}_${ARCH}.tar.gz"

log "Downloading cloud-provider-kind v${VERSION} (${OS}/${ARCH})..."
curl -fsSL "$CPK_URL" -o "$TARBALL"
tar -xzf "$TARBALL" -C "$TMP_DIR" cloud-provider-kind
rm -f "$TARBALL"
log "cloud-provider-kind installed to $TMP_DIR/cloud-provider-kind"
