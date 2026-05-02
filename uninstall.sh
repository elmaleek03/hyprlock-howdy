#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${RED}This will remove face unlock from hyprlock.${NC}"
echo "Packages (howdy-git, python-dlib, ydotool) will NOT be removed automatically."
echo ""
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

info "Restoring PAM config..."
if [ -f /etc/pam.d/hyprlock.bak ]; then
    sudo cp /etc/pam.d/hyprlock.bak /etc/pam.d/hyprlock
    success "Restored /etc/pam.d/hyprlock from backup"
else
    sudo tee /etc/pam.d/hyprlock >/dev/null << 'EOF'
# PAM configuration file for hyprlock
auth        include     login
EOF
    success "Restored default /etc/pam.d/hyprlock"
fi

info "Removing face-unlock helper..."
rm -f ~/.local/bin/omarchy-face-unlock
success "Removed ~/.local/bin/omarchy-face-unlock"

info "Cleaning hyprlock.conf..."
HYPRLOCK_CONF="$HOME/.config/hypr/hyprlock.conf"
if [ -f "$HYPRLOCK_CONF" ]; then
    sed -i '/# Face unlock status label/,/^}/d' "$HYPRLOCK_CONF"
    sed -i '/# Trigger face unlock automatically/,/^}/d' "$HYPRLOCK_CONF"
    sed -i 's/ignore_empty_input = false/ignore_empty_input = true/' "$HYPRLOCK_CONF"
    success "Cleaned face unlock entries from hyprlock.conf"
fi

echo ""
echo -e "${GREEN}Face unlock removed.${NC}"
echo ""
echo "To fully remove packages:"
echo "  sudo pacman -Rns howdy-git python-dlib ydotool"
echo "  sudo rm -rf /etc/howdy /var/log/howdy"
echo ""
echo "To remove face models:"
echo "  sudo howdy clear"
echo ""
