#!/usr/bin/env bash

#===============================================================================
# Artix Linux s6-init + MangoWM One-Shot Installation Script
# Version: 1.0
# Description: Fully automated installation from live ISO to working MangoWM desktop
# WARNING: This script will DESTROY all data on the target disk!
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# CONFIGURATION - Modify these variables to suit your preferences
#===============================================================================

# System Identity
HOSTNAME="wade-artix"
USERNAME="wade"
FULL_NAME="Wade"
# SECURITY WARNING: This password will be used for BOTH root and user accounts
# Leave empty to be prompted during execution (safer)
PASSWORD=""

# Disk Configuration
DISK="/dev/sda"
FILESYSTEM="ext4"          # ext4 is recommended for mechanical HDDs
SWAP_SIZE="16G"            # Adjust based on RAM (8GB RAM -> 16GB swap)
UEFI="yes"                 # Set to "no" for legacy BIOS (not recommended)

# Localization
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Package Selection
# Additional packages beyond base system and MangoWM dependencies
EXTRA_PKGS="alacritty firefox thunar neovim lf htop btop fastfetch \
            ttf-dejavu ttf-liberation ttf-jetbrains-mono-nerd \
            noto-fonts noto-fonts-emoji \
            grim slurp wl-clipboard wmenu \
            waybar swaybg mako libnotify \
            pipewire pipewire-pulse wireplumber \
            seatd dbus dbus-s6 \
            NetworkManager NetworkManager-s6 \
            openssh openssh-s6"

# AUR Helper choice ('yay' or 'paru')
AUR_HELPER="yay"

#===============================================================================
# SAFETY CHECKS AND INITIALIZATION
#===============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (live ISO environment)"
fi

# Check if we're in the live environment ( Artix ISO specific check )
if [[ ! -f /run/artix-live ]]; then
    warning "This doesn't appear to be the Artix Live ISO. Continue only if you know what you're doing."
    read -rp "Press Enter to continue or Ctrl+C to abort..."
fi

# Check internet connectivity
log "Checking internet connectivity..."
if ! ping -c 1 archlinux.org &>/dev/null; then
    error "No internet connection detected. Please configure networking first (e.g., dhcpcd or iwctl)"
fi
success "Internet connection confirmed"

# Prompt for password if not set
if [[ -z "$PASSWORD" ]]; then
    read -rsp "Enter password for both root and $USERNAME accounts: " PASSWORD
    echo
    read -rsp "Confirm password: " PASSWORD_CONFIRM
    echo
    if [[ "$PASSWORD" != "$PASSWORD_CONFIRM" ]]; then
        error "Passwords do not match"
    fi
    if [[ ${#PASSWORD} -lt 4 ]]; then
        error "Password must be at least 4 characters"
    fi
fi

# Final warning and confirmation
clear
cat << EOF
${RED}╔══════════════════════════════════════════════════════════════════╗
║                     DESTRUCTIVE OPERATION WARNING                  ║
╚══════════════════════════════════════════════════════════════════╝${NC}

This script will perform the following DESTRUCTIVE operations on ${YELLOW}$DISK${NC}:

  1. Completely WIPE the partition table (GPT)
  2. Create new partitions:
     - EFI System Partition (512M) [if UEFI=$UEFI]
     - Swap partition ($SWAP_SIZE)
     - Root partition (remainder of disk)
  3. Format all partitions
  4. Install Artix Linux s6-init system
  5. Install MangoWM and configure autostart

${RED}ALL EXISTING DATA ON $DISK WILL BE PERMANENTLY LOST!${NC}

System Configuration:
  Hostname:     $HOSTNAME
  Username:     $USERNAME
  Disk:         $DISK
  Filesystem:   $FILESYSTEM
  UEFI Mode:    $UEFI
  Timezone:     $TIMEZONE
  Locale:       $LOCALE

EOF

read -rp "Type 'DESTROY' to confirm and proceed: " CONFIRM
if [[ "$CONFIRM" != "DESTROY" ]]; then
    error "Installation aborted by user"
fi

#===============================================================================
# DISK PREPARATION
#===============================================================================

log "Preparing disk $DISK..."

# Unmount anything on the target disk
umount -R /mnt 2>/dev/null || true
swapoff "${DISK}2" 2>/dev/null || true

# Wipe existing signatures
log "Wiping existing filesystem signatures..."
wipefs -af "$DISK"
sgdisk -Zo "$DISK" 2>/dev/null || true

# Partitioning
log "Creating partition table..."
if [[ "$UEFI" == "yes" ]]; then
    # GPT with EFI
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary linux-swap 513MiB "$SWAP_SIZE"+513MiB
    parted -s "$DISK" mkpart primary "$FILESYSTEM" "$SWAP_SIZE"+513MiB 100%
    
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
else
    # Legacy BIOS (not recommended but supported)
    parted -s "$DISK" mklabel msdos
    parted -s "$DISK" mkpart primary linux-swap 1MiB "$SWAP_SIZE"
    parted -s "$DISK" mkpart primary "$FILESYSTEM" "$SWAP_SIZE" 100%
    parted -s "$DISK" set 2 boot on
    
    SWAP_PART="${DISK}1"
    ROOT_PART="${DISK}2"
    EFI_PART=""
fi

# Wait for kernel to recognize partitions
partprobe "$DISK"
sleep 2

# Formatting
log "Formatting partitions..."
if [[ "$UEFI" == "yes" ]]; then
    mkfs.fat -F32 -n EFI "$EFI_PART"
fi

mkswap -L SWAP "$SWAP_PART"
"mkfs.$FILESYSTEM" -L ROOT "$ROOT_PART"

# Mounting
log "Mounting partitions..."
mount "$ROOT_PART" /mnt

mkdir -p /mnt/boot/efi
if [[ "$UEFI" == "yes" ]]; then
    mount "$EFI_PART" /mnt/boot/efi
fi

swapon "$SWAP_PART"

success "Disk preparation complete"

#===============================================================================
# BASE SYSTEM INSTALLATION
#===============================================================================

log "Updating live system mirrors..."
pacman -Sy artix-keyring --noconfirm 2>/dev/null || true

log "Pacstrapping base system (this may take a while)..."
# Base packages for s6-init Artix
BASE_PKGS="base base-devel s6 s6-rc elogind-s6 $FILESYSTEM \
           linux linux-firmware linux-headers \
           grub efibootmgr dosfstools os-prober \
           neovim nano git curl wget man-db man-pages \
           texinfo networkmanager networkmanager-s6 \
           pipewire pipewire-pulse wireplumber \
           pipewire-s6 wireplumber-s6 \
           seatd seatd-s6 dbus dbus-s6 \
           openssh openssh-s6"

pacstrap /mnt $BASE_PKGS

# Generate fstab
log "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

success "Base system installed"

#===============================================================================
# CHROOT CONFIGURATION
#===============================================================================

log "Entering chroot to configure system..."

# Export variables for chroot environment
export HOSTNAME USERNAME FULL_NAME PASSWORD LOCALE KEYMAP TIMEZONE \
       UEFI AUR_HELPER EXTRA_PKGS EFI_PART

# Chroot configuration via heredoc
artix-chroot /mnt /bin/bash << 'CHROOT_EOF'
set -euo pipefail

#-------------------------------------------------------------------------------
# Basic System Configuration
#-------------------------------------------------------------------------------

echo "[Configuring hostname...]"
echo "$HOSTNAME" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "[Configuring timezone...]"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "[Configuring locale...]"
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen

echo "[Configuring keymap...]"
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

#-------------------------------------------------------------------------------
# User Accounts and Authentication
#-------------------------------------------------------------------------------

echo "[Setting root password...]"
echo "root:$PASSWORD" | chpasswd

echo "[Creating user $USERNAME...]"
useradd -m -g users -G wheel,audio,video,input,storage,seat -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
chfn -f "$FULL_NAME" "$USERNAME"

# Configure sudo
echo "[Configuring sudo...]"
pacman -S sudo --noconfirm
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

#-------------------------------------------------------------------------------
# Bootloader Installation (GRUB UEFI)
#-------------------------------------------------------------------------------

echo "[Installing GRUB bootloader...]"
if [[ "$UEFI" == "yes" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
else
    grub-install --target=i386-pc --recheck "$DISK"
fi

# GRUB configuration
sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=1/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

#-------------------------------------------------------------------------------
# s6 Service Configuration
#-------------------------------------------------------------------------------

echo "[Enabling s6 services...]"

# Function to enable s6 service
s6_service_enable() {
    local service=$1
    if [[ -d "/etc/s6/sv/$service" ]]; then
        ln -sf "/etc/s6/sv/$service" "/etc/s6/rc/compiled/default/$service"
        echo "  - Enabled $service"
    else
        echo "  - Warning: $service not found, skipping"
    fi
}

# Essential services
s6_service_enable seatd        # Required for Wayland/MangoWM
s6_service_enable dbus         # System message bus
s6_service_enable NetworkManager
s6_service_enable sshd
s6_service_enable ntpd         # Time synchronization (if available)

# Seatd configuration for MangoWM
# Add user to seat group (already done in useradd) and configure seatd
mkdir -p /etc/sv/seatd
echo 'SEATD_ARGS="-g seat"' > /etc/sv/seatd/conf

#-------------------------------------------------------------------------------
# AUR Helper Installation (as user)
#-------------------------------------------------------------------------------

echo "[Installing $AUR_HELPER...]"
cd /tmp
sudo -u "$USERNAME" git clone "https://aur.archlinux.org/$AUR_HELPER.git"
cd "$AUR_HELPER"
sudo -u "$USERNAME" makepkg -si --noconfirm
cd ..
rm -rf "$AUR_HELPER"

#-------------------------------------------------------------------------------
# MangoWM Installation and Configuration
#-------------------------------------------------------------------------------

echo "[Installing MangoWM and Wayland ecosystem...]"

# Install MangoWM from AUR
sudo -u "$USERNAME" "$AUR_HELPER" -S --noconfirm mangowm

# Install additional packages
pacman -S --noconfirm $EXTRA_PKGS

# MangoWM configuration directory
MANGO_CONFIG_DIR="/home/$USERNAME/.config/mango"
mkdir -p "$MANGO_CONFIG_DIR"
chown -R "$USERNAME:users" "/home/$USERNAME/.config"

# Copy default config if it exists
if [[ -f /etc/mango/config.conf ]]; then
    cp /etc/mango/config.conf "$MANGO_CONFIG_DIR/config.conf"
    chown "$USERNAME:users" "$MANGO_CONFIG_DIR/config.conf"
fi

# Create MangoWM autostart configuration
# This modifies the config to start essential wayland apps
cat >> "$MANGO_CONFIG_DIR/config.conf" << 'MANGO_CONFIG'

# Autostart applications
exec-once=waybar
exec-once=mako
exec-once=swaybg -i /usr/share/backgrounds/archlinux-simple.png -m fill
exec-once=pipewire & wireplumber
exec-once=dbus-update-activation-environment --all

# Basic keybinds (MangoWM uses similar syntax to dwl/sway)
# Alt+Return = Terminal
# Alt+Space = Launcher
# Alt+Q = Close window
# Super+M = Exit Mango
MANGO_CONFIG

chown "$USERNAME:users" "$MANGO_CONFIG_DIR/config.conf"

#-------------------------------------------------------------------------------
# Wayland Session Autostart (TTY1)
#-------------------------------------------------------------------------------

echo "[Configuring TTY autostart for MangoWM...]"

# Add to .bash_profile to auto-start MangoWM on tty1
cat >> "/home/$USERNAME/.bash_profile" << 'BASH_PROFILE'

# Auto-start MangoWM on first TTY if not already in a Wayland session
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    # Wait for seatd to be ready
    sleep 1
    exec mango
fi
BASH_PROFILE

chown "$USERNAME:users" "/home/$USERNAME/.bash_profile"

# Also create a desktop entry for display managers (optional)
mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/mango.desktop << 'DESKTOP_ENTRY'
[Desktop Entry]
Name=MangoWM
Comment=Practical and Powerful Wayland Compositor
Exec=mango
Type=Application
DESKTOP_ENTRY

#-------------------------------------------------------------------------------
# Final System Tweaks
#-------------------------------------------------------------------------------

# Enable multilib and extra repositories
sed -i '/\[extra\]/,/Include/s/^#//' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
pacman -Sy

# Set default editor
echo "EDITOR=nvim" >> /etc/environment
echo "VISUAL=nvim" >> /etc/environment

# Mkinitcpio (ensure hooks are correct for filesystem)
mkinitcpio -P

CHROOT_EOF

success "Chroot configuration complete"

#===============================================================================
# CLEANUP AND FINALIZATION
#===============================================================================

log "Cleaning up..."

# Remove password from environment for security
unset PASSWORD

# Unmount everything
umount -R /mnt
swapoff -a

success "Installation complete!"

cat << EOF

${GREEN}╔══════════════════════════════════════════════════════════════════╗
║             Artix Linux + MangoWM Installation Complete!          ║
╚══════════════════════════════════════════════════════════════════╝${NC}

System Details:
  Hostname:     $HOSTNAME
  Username:     $USERNAME
  Disk:         $DISK
  Boot Mode:    $([ "$UEFI" == "yes" ] && echo "UEFI" || echo "Legacy BIOS")

Next Steps:
  1. Remove the installation medium (USB/CD)
  2. Type ${YELLOW}reboot${NC} to restart into your new system
  3. Login as ${YELLOW}$USERNAME${NC} on TTY1 (MangoWM will auto-start)
  
First Boot Tips:
  - Default terminal: ${YELLOW}Alt + Return${NC} (opens foot)
  - Application launcher: ${YELLOW}Alt + Space${NC} (opens wmenu)
  - Close window: ${YELLOW}Alt + Q${NC}
  - Exit MangoWM: ${YELLOW}Super + M${NC}
  
Configuration files to edit later:
  - MangoWM: ~/.config/mango/config.conf
  - Waybar: ~/.config/waybar/config
  - Bash: ~/.bashrc

EOF

read -rp "Press Enter to reboot now or Ctrl+C to stay in live environment..."
reboot
