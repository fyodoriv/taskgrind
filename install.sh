#!/bin/sh
# Install taskgrind — autonomous multi-session grind tool
# Usage: curl -fsSL https://raw.githubusercontent.com/cbrwizard/taskgrind/main/install.sh | sh
set -e

INSTALL_DIR="${TASKGRIND_INSTALL_DIR:-$HOME/apps/taskgrind}"
REPO="https://github.com/cbrwizard/taskgrind.git"

# Check for git
if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is required but not found. Install git and retry." >&2
  exit 1
fi

if [ -d "$INSTALL_DIR" ]; then
  if [ -x "$INSTALL_DIR/bin/taskgrind" ] || [ -f "$INSTALL_DIR/bin/taskgrind" ]; then
    echo "taskgrind is already installed at $INSTALL_DIR"
    echo "To update: cd \"$INSTALL_DIR\" && git pull"
    exit 0
  fi

  echo "Error: $INSTALL_DIR already exists but does not look like a taskgrind install." >&2
  echo "Move it aside or set TASKGRIND_INSTALL_DIR to a different path and retry." >&2
  exit 1
fi

echo "Installing taskgrind to $INSTALL_DIR..."
mkdir -p "$(dirname "$INSTALL_DIR")"
git clone "$REPO" "$INSTALL_DIR"

# Verify installation
if [ ! -x "$INSTALL_DIR/bin/taskgrind" ]; then
  echo "Warning: $INSTALL_DIR/bin/taskgrind is not executable" >&2
  chmod +x "$INSTALL_DIR/bin/taskgrind"
fi

echo ""
echo "taskgrind installed to $INSTALL_DIR"
echo ""
echo "Add to your PATH (add this to your shell rc file):"
echo ""
echo "  export PATH=\"$INSTALL_DIR/bin:\$PATH\""
echo ""
echo "Or install system-wide with man page:"
echo ""
echo "  make -C \"$INSTALL_DIR\" install"
echo ""
echo "Then run:"
echo "  taskgrind --help"
