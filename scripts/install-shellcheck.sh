#!/bin/bash
# install-shellcheck.sh — install one pinned shellcheck release for CI.
# Local runs and every CI job use the same version, so a new SC rule in a
# newer or older distro package cannot turn main red on one side only.
# Usage: scripts/install-shellcheck.sh [install-dir]   (default ~/.local/bin)
set -euo pipefail

SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-v0.11.0}"
dest="${1:-$HOME/.local/bin}"

case "$(uname -s).$(uname -m)" in
  Linux.x86_64) asset="linux.x86_64" ;;
  Linux.aarch64) asset="linux.aarch64" ;;
  Darwin.arm64) asset="darwin.aarch64" ;;
  Darwin.x86_64) asset="darwin.x86_64" ;;
  *) echo "install-shellcheck: unsupported platform $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

url="https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.${asset}.tar.xz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$url" | tar -xJ -C "$tmp"
mkdir -p "$dest"
install -m 0755 "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$dest/shellcheck"
# Put the pinned binary first on PATH for later GitHub Actions steps.
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$dest" >> "$GITHUB_PATH"
fi
"$dest/shellcheck" --version
