#!/usr/bin/env bash
set -euo pipefail

# ================================================
# Artix Linux s6 + MangoWM One-Shot Installer
# ================================================
# This is a complete, production-grade, one-time installation script.
# Run as root in the official artix-s6.iso live environment AFTER connecting to the internet.
# It will wipe the target disk (after explicit confirmation), install a minimal but fully functional
# Artix s6 system with MangoWM (Wayland compositor) as the primary WM, and reboot into it.
#
# All configurable options are at the top. Password is plain-text here (script hashes it safely
# via chpasswd). User must set PASSWORD before running.
# ================================================

# ==================== CONFIGURABLE VARIABLES ====================
HOSTNAME="wade-artix"
USERNAME="wade"
FULL_NAME="Wade"
PASSWORD=""  # <<< MUST BE FILLED IN BY USER BEFORE RUNNING (plain text, same for root + user)
DISK="/dev/sda"
FILESYSTEM="ext4"          # Best performance for mechanical HDDs
SWAP_SIZE="16G"            # Suitable for 8GB+ RAM systems
UEFI="yes"                 # "yes" for UEFI (512M EFI partition), "no" for legacy BIOS
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Essential packages for basestrap (base system + s6 + core desktop prerequisites)
BASE_PACKAGES=(
    base
    base-devel
    linux
    linux-firmware
    s6
    elogind-s6
    dbus-s6
    connman-s6
    grub
    efibootmgr
    os-prober
    pipewire
    wireplumber
    pipewire-pulse
    pipewire-alsa
    alsa-utils
    pavucontrol
    alacritty
    firefox
    thunar
    thunar-archive-plugin
    thunar-volman
    neovim
    wofi
    git
    sudo
)

# ================================================================

# Safety guard: PASSWORD must be set
if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: PASSWORD variable is empty. Edit the script and set a strong password before running."
    exit 1
fi

# Safety checks
echo "=== Artix s6 + MangoWM Installer ==="
echo "This script will COMPLETELY WIPE ${DISK} and install a fresh system."
echo "Hostname: ${HOSTNAME} | User: ${USERNAME} | WM: MangoWM (Wayland)"
read -r -p "Type 'DESTROY' to continue (or Ctrl+C to abort): " CONFIRM
if [[ "${CONFIRM}" != "DESTROY" ]]; then
    echo "Aborted by user."
    exit 1
fi

# Check internet connectivity (required for pacman and AUR)
echo "Checking internet connectivity..."
if ! ping -c 1 -W 5 archlinux.org &>/dev/null; then
    echo "ERROR: No internet connection. Connect to the network first (e.g. connman or iwctl)."
    exit 1
fi
echo "Internet OK."

# Update live environment and refresh Artix mirrors
echo "Updating live system and Artix mirrors..."
pacman -Syy --noconfirm
pacman -Syu --noconfirm --needed artix-mirrorlist

# Automated disk partitioning (GPT, destructive)
echo "Partitioning ${DISK} (WARNING: all data will be lost)..."
wipefs -af "${DISK}"
partprobe "${DISK}"

if [[ "${UEFI}" == "yes" ]]; then
    # UEFI layout: 512M EFI + SWAP + ROOT
    sfdisk --label gpt "${DISK}" <<EOF
label: gpt
size=512MiB, type=EF00, name="EFI"
size=${SWAP_SIZE}, type=8200, name="SWAP"
, type=8304, name="ROOT"
EOF
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
else
    # Legacy BIOS: SWAP + ROOT (no EFI)
    sfdisk --label dos "${DISK}" <<EOF
size=${SWAP_SIZE}, type=82, name="SWAP"
, type=83, name="ROOT"
EOF
    EFI_PART=""
    SWAP_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi
partprobe "${DISK}"

# Format partitions
echo "Formatting partitions..."
if [[ "${UEFI}" == "yes" ]]; then
    mkfs.fat -F32 -n EFI "${EFI_PART}"
fi
mkswap -L swap "${SWAP_PART}"
mkfs."${FILESYSTEM}" -F -L root "${ROOT_PART}"

# Mount everything
echo "Mounting filesystems..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
if [[ "${UEFI}" == "yes" ]]; then
    mount "${EFI_PART}" /mnt/boot
fi
swapon "${SWAP_PART}"

# Basestrap base s6 system + essentials
echo "Installing base system with basestrap (Artix s6)..."
basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm

# Generate fstab
echo "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab

# ==================== CHROOT PHASE ====================
echo "Entering chroot for final configuration..."

artix-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -euo pipefail

# Set timezone, locale, keymap, hostname
echo "Configuring locale, timezone, hostname..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# Root and user accounts (same password for both)
echo "Creating root and user accounts..."
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo "${FULL_NAME}" > "/home/${USERNAME}/.fullname" 2>/dev/null || true
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

# s6 service management - enable core services
echo "Enabling s6-rc services (networking, dbus, elogind, connman)..."
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connmand; do
    touch "/etc/s6/adminsv/default/contents.d/${svc}"
done
# Compile s6 database (Artix s6 standard)
s6-rc-compile -v /etc/s6/rc/compiled /etc/s6/sv || true

# Install AUR helper (paru) as regular user for MangoWM
echo "Installing paru AUR helper as ${USERNAME}..."
pacman -S --noconfirm --needed git base-devel
su - "${USERNAME}" -c '
    git clone https://aur.archlinux.org/paru.git /tmp/paru
    cd /tmp/paru
    makepkg -si --noconfirm --needed
    rm -rf /tmp/paru
'

# Install MangoWM from AUR (Wayland compositor based on dwl)
echo "Installing MangoWM and dependencies..."
su - "${USERNAME}" -c "paru -S --noconfirm --needed mangowm"

# Minimal MangoWM configuration (usable desktop with terminal, launcher, keybinds)
echo "Creating minimal MangoWM configuration for ${USERNAME}..."
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_CONFIG'
# MangoWM minimal config (dwl-style Wayland compositor)
# Terminal: alacritty
# Launcher: wofi (drun mode)
# Basic keybinds (SUPER = Mod4)

# Core actions
bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER,Shift,q,quit
bind=SUPER,f,toggle_fullscreen

# Focus movement
bind=ALT,Left,focusmon,-1
bind=ALT,Right,focusmon,1
bind=ALT,Up,focusmon,-1
bind=ALT,Down,focusmon,1

# Tag / workspace switching (1-9)
bind=CTRL,1,view,1
bind=CTRL,2,view,2
bind=CTRL,3,view,3
bind=CTRL,4,view,4
bind=CTRL,5,view,5
bind=CTRL,6,view,6
bind=CTRL,7,view,7
bind=CTRL,8,view,8
bind=CTRL,9,view,9

# Move window to tag
bind=ALT,1,sendtomon,1
bind=ALT,2,sendtomon,2
bind=ALT,3,sendtomon,3
bind=ALT,4,sendtomon,4
bind=ALT,5,sendtomon,5
bind=ALT,6,sendtomon,6
bind=ALT,7,sendtomon,7
bind=ALT,8,sendtomon,8
bind=ALT,9,sendtomon,9

# Autostart audio (pipewire + wireplumber) and other essentials
exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse

# Recommended defaults
terminal=alacritty
launcher=wofi --show drun
MANGO_CONFIG

# Autostart MangoWM on tty1 login (clean s6 + Wayland method)
echo "Setting up automatic MangoWM autostart on tty1..."
cat > "/home/${USERNAME}/.bash_profile" <<'BASH_PROFILE'
# Autostart MangoWM on first virtual terminal (tty1)
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    # Ensure pipewire is ready (audio)
    pipewire > /dev/null 2>&1 &
    wireplumber > /dev/null 2>&1 &
    sleep 1
    exec mango
fi
BASH_PROFILE

# Fix permissions
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config" "/home/${USERNAME}/.bash_profile"

# GRUB bootloader
echo "Installing GRUB bootloader..."
if [[ "${UEFI}" == "yes" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
else
    grub-install --target=i386-pc "${DISK}"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Final cleanup
echo "Final system cleanup..."
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*

echo "=== Installation complete inside chroot ==="
CHROOT_EOF

# Unmount and finish
echo "Unmounting filesystems..."
umount -R /mnt/boot 2>/dev/null || true
umount -R /mnt
swapoff -a

echo "Installation finished successfully!"
echo "You can now reboot into your new Artix s6 + MangoWM system."
read -r -p "Reboot now? (y/N): " REBOOT
if [[ "${REBOOT}" =~ ^[Yy]$ ]]; then
    reboot
else
    echo "Run 'reboot' manually when ready."
fi
