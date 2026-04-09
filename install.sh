#!/bin/sh
# Install taskgrind — autonomous multi-session grind tool
# Usage: curl -fsSL https://raw.githubusercontent.com/cbrwizard/taskgrind/main/install.sh | sh
set -e

INSTALL_DIR="${TASKGRIND_INSTALL_DIR:-$HOME/apps/taskgrind}"
REPO="https://github.com/cbrwizard/taskgrind.git"

if [ -d "$INSTALL_DIR" ]; then
  echo "taskgrind is already installed at $INSTALL_DIR"
  echo "To update: cd $INSTALL_DIR && git pull"
  exit 0
fi

echo "Installing taskgrind to $INSTALL_DIR..."
mkdir -p "$(dirname "$INSTALL_DIR")"
git clone "$REPO" "$INSTALL_DIR"

echo ""
echo "taskgrind installed to $INSTALL_DIR"
echo ""
echo "Add to your PATH (add this to your shell rc file):"
echo ""
echo "  export PATH=\"$INSTALL_DIR/bin:\$PATH\""
echo ""
echo "Then run:"
echo "  taskgrind --help"
