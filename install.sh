#!/bin/bash
set -e

# hyprlock-howdy: Windows Hello-style face unlock for Hyprland
# Tested on: HP Envy x360 14-fa0xxx with HP IR Camera (Chicony 04f2:b7fe)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────────────────────────────────────

info "Checking prerequisites..."

# Check if running on Arch-based system
if ! command -v pacman &>/dev/null; then
    error "This script requires an Arch-based system (pacman not found)"
fi

# Check for AUR helper
AUR_HELPER=""
if command -v paru &>/dev/null; then
    AUR_HELPER="paru"
elif command -v yay &>/dev/null; then
    AUR_HELPER="yay"
else
    error "No AUR helper found. Install paru or yay first."
fi
success "AUR helper: $AUR_HELPER"

# Check for hyprlock
if ! command -v hyprlock &>/dev/null; then
    error "hyprlock not found. Install it first: pacman -S hyprlock"
fi
success "hyprlock $(hyprlock --version 2>&1 | grep -oP 'v[\d.]+')"

# Check for IR camera
IR_CAMERA=""
for dev in /dev/video*; do
    if v4l2-ctl -d "$dev" --all 2>/dev/null | grep -qi "IR Camera"; then
        IR_CAMERA="$dev"
        break
    fi
done

if [ -z "$IR_CAMERA" ]; then
    warn "No IR camera auto-detected. You'll need to set device_path manually."
    warn "Run: v4l2-ctl --list-devices"
    warn "Look for an IR camera device and note its /dev/videoX path."
else
    success "IR camera found: $IR_CAMERA"
fi

# Get stable device path via /dev/v4l/by-path/
IR_CAMERA_STABLE=""
if [ -n "$IR_CAMERA" ]; then
    for link in /dev/v4l/by-path/*; do
        if [ "$(readlink -f "$link")" = "$IR_CAMERA" ]; then
            IR_CAMERA_STABLE="$link"
            break
        fi
    done
fi

if [ -n "$IR_CAMERA_STABLE" ]; then
    success "Stable path: $IR_CAMERA_STABLE"
else
    IR_CAMERA_STABLE="$IR_CAMERA"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Install python-dlib (CPU-only, no CUDA bloat)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 1: Installing python-dlib (CPU-only)..."

if pacman -Qi python-dlib &>/dev/null; then
    success "python-dlib already installed"
else
    info "Building python-dlib without CUDA (saves ~6GB of downloads)..."
    TMPDIR=$(mktemp -d)
    pushd "$TMPDIR" >/dev/null

    $AUR_HELPER -G python-dlib
    cd python-dlib
    sed -i 's/_build_cuda=1/_build_cuda=0/' PKGBUILD
    makepkg -si --noconfirm

    popd >/dev/null
    rm -rf "$TMPDIR"
    success "python-dlib installed (CPU-only)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Install howdy-git
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 2: Installing howdy-git..."

if pacman -Qi howdy-git &>/dev/null; then
    success "howdy-git already installed"
else
    $AUR_HELPER -S --noconfirm howdy-git
    success "howdy-git installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Install ydotool (kernel-level key simulation)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 3: Installing ydotool..."

if pacman -Qi ydotool &>/dev/null; then
    success "ydotool already installed"
else
    sudo pacman -S --noconfirm ydotool
    success "ydotool installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Configure ydotool (uinput permissions + service)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 4: Configuring ydotool..."

# Add user to input group
if groups | grep -q input; then
    success "User already in input group"
else
    sudo usermod -aG input "$USER"
    warn "Added $USER to input group. You may need to re-login for this to take effect."
fi

# Create udev rule for uinput
if [ ! -f /etc/udev/rules.d/80-uinput.rules ]; then
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660"' | sudo tee /etc/udev/rules.d/80-uinput.rules >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    success "uinput udev rule created"
else
    success "uinput udev rule already exists"
fi

# Ensure uinput module is loaded
sudo modprobe uinput
if ! grep -q "^uinput$" /etc/modules-load.d/*.conf 2>/dev/null; then
    echo "uinput" | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
    success "uinput module set to load on boot"
fi

# Fix current permissions
sudo chmod 0660 /dev/uinput 2>/dev/null
sudo chgrp input /dev/uinput 2>/dev/null

# Enable ydotool user service
systemctl --user enable ydotool.service
systemctl --user start ydotool.service 2>/dev/null || true
success "ydotool service enabled"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Configure howdy
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 5: Configuring howdy..."

# Set IR camera device path
if [ -n "$IR_CAMERA_STABLE" ] && [ "$IR_CAMERA_STABLE" != "none" ]; then
    sudo sed -i "s|device_path = .*|device_path = $IR_CAMERA_STABLE|" /etc/howdy/config.ini
    success "Camera set to: $IR_CAMERA_STABLE"
else
    warn "No IR camera detected. Edit /etc/howdy/config.ini manually:"
    warn "  sudo howdy config"
    warn "  Set device_path to your IR camera's /dev/v4l/by-path/ link"
fi

# Set optimal settings for IR cameras
sudo sed -i 's|dark_threshold = .*|dark_threshold = 90|' /etc/howdy/config.ini
sudo sed -i 's|timeout = .*|timeout = 5|' /etc/howdy/config.ini
sudo sed -i 's|certainty = .*|certainty = 3.5|' /etc/howdy/config.ini

# Create log directory
sudo mkdir -p /var/log/howdy
sudo chmod 755 /var/log/howdy

success "Howdy configured"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Configure PAM for hyprlock
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 6: Configuring PAM..."

# Backup existing hyprlock PAM
if [ -f /etc/pam.d/hyprlock ] && [ ! -f /etc/pam.d/hyprlock.bak ]; then
    sudo cp /etc/pam.d/hyprlock /etc/pam.d/hyprlock.bak
    success "Backed up /etc/pam.d/hyprlock → hyprlock.bak"
fi

# Install new PAM config
sudo cp "$SCRIPT_DIR/config/pam-hyprlock" /etc/pam.d/hyprlock
success "PAM config installed"

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Install face-unlock helper script
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 7: Installing face-unlock helper..."

mkdir -p ~/.local/bin
cp "$SCRIPT_DIR/config/omarchy-face-unlock" ~/.local/bin/omarchy-face-unlock
chmod +x ~/.local/bin/omarchy-face-unlock
success "Installed ~/.local/bin/omarchy-face-unlock"

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Configure hyprlock
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 8: Configuring hyprlock..."

HYPRLOCK_CONF="$HOME/.config/hypr/hyprlock.conf"

if [ -f "$HYPRLOCK_CONF" ]; then
    # Check if already configured
    if grep -q "omarchy-face-unlock" "$HYPRLOCK_CONF"; then
        success "hyprlock.conf already configured for face unlock"
    else
        # Backup
        cp "$HYPRLOCK_CONF" "$HYPRLOCK_CONF.bak.$(date +%s)"

        # Add face unlock config
        # Set ignore_empty_input = false (required for face unlock to trigger PAM)
        sed -i 's/ignore_empty_input = true/ignore_empty_input = false/' "$HYPRLOCK_CONF"

        # Append face unlock labels before the closing auth section or at end
        cat >> "$HYPRLOCK_CONF" << 'EOF'

# Face unlock status label
label {
    monitor =
    text = smile at the camera :)
    font_size = 16
    font_family = JetBrainsMono Nerd Font
    color = $font_color

    position = 0, -80
    halign = center
    valign = center
}

# Trigger face unlock automatically when hyprlock starts
label {
    monitor =
    text = cmd[update:999999] omarchy-face-unlock
    font_size = 1
    color = rgba(0, 0, 0, 0)

    position = 0, 0
    halign = center
    valign = center
}
EOF
        success "hyprlock.conf updated with face unlock"
    fi
else
    warn "hyprlock.conf not found at $HYPRLOCK_CONF"
    warn "Copy config/hyprlock-face-unlock.conf snippet into your hyprlock config manually."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Enroll face
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Step 9: Face enrollment"
echo ""
echo -e "${YELLOW}You need to enroll your face now.${NC}"
echo "Look straight at the IR camera when prompted."
echo ""
echo "  sudo howdy add"
echo ""
echo "Tips:"
echo "  - Add multiple models for better recognition:"
echo "    sudo howdy add  # without glasses"
echo "    sudo howdy add  # with glasses"
echo "    sudo howdy add  # different lighting"
echo ""

read -p "Enroll face now? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    sudo howdy add
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done!
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Face unlock setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Lock your screen to test. Your IR camera should activate and"
echo "unlock automatically when it recognizes your face."
echo ""
echo "If ydotool doesn't work yet, you may need to log out and back in"
echo "(for the input group membership to take effect)."
echo ""
echo "Useful commands:"
echo "  sudo howdy add       # Add another face model"
echo "  sudo howdy list      # List enrolled faces"
echo "  sudo howdy test      # Test face recognition (needs display)"
echo "  sudo howdy config    # Edit howdy configuration"
echo "  sudo howdy disable 1 # Temporarily disable face unlock"
echo "  sudo howdy disable 0 # Re-enable face unlock"
echo ""
