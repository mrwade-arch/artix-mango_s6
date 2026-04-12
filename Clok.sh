#!/usr/bin/env bash
set -euo pipefail

# ================================================
# Artix Linux s6 + MangoWM One-Shot Installer
# ================================================
# Complete, production-grade, one-time installation script.
# Run as root in the artix-s6.iso live environment AFTER connecting to the internet.
# Wipes the target disk (after explicit confirmation), installs a minimal but fully
# functional Artix s6 system with MangoWM (Wayland compositor), then reboots.
#
# All configurable options are at the top. PASSWORD is plain-text here (hashed safely
# via chpasswd). You MUST set PASSWORD before running.
# ================================================

# ==================== CONFIGURABLE VARIABLES ====================
HOSTNAME="wade-artix"
USERNAME="wade"
FULL_NAME="Wade"
PASSWORD="yup"  # <<< MUST BE SET BEFORE RUNNING (plain text; used for both root and user)
DISK="/dev/sda"
FILESYSTEM="ext4"       # Best for mechanical HDDs
SWAP_SIZE="16G"
UEFI="yes"              # "yes" = UEFI (512M EFI partition), "no" = legacy BIOS
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Proxy configuration
HTTP_PROXY="http://192.168.49.1:8282"
HTTPS_PROXY="http://192.168.49.1:8282"
NO_PROXY="localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8"

# Base packages installed via basestrap
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

# ==================== PRE-FLIGHT CHECKS ====================
if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: PASSWORD is empty. Set it in the script before running."
    exit 1
fi

echo "=== Artix s6 + MangoWM Installer ==="
echo "This will COMPLETELY WIPE ${DISK} and install a fresh system."
echo "Hostname: ${HOSTNAME} | User: ${USERNAME} | WM: MangoWM (Wayland)"
read -r -p "Type 'DESTROY' to continue (Ctrl+C to abort): " CONFIRM
[[ "${CONFIRM}" == "DESTROY" ]] || { echo "Aborted."; exit 1; }

# ==================== PROXY SETUP (LIVE ENV) ====================
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
echo ">>> Proxy enabled: ${HTTP_PROXY}"

echo "Checking internet connectivity..."
if ! ping -c 1 -W 5 archlinux.org &>/dev/null; then
    echo "ERROR: No internet. Connect first (connman / iwctl)."
    exit 1
fi
echo "Internet OK."

echo "Updating live system and Artix mirrors..."
pacman -Syy --noconfirm
pacman -Syu --noconfirm --needed artix-mirrorlist

# ==================== DISK PARTITIONING ====================
echo "Partitioning ${DISK} (WARNING: all data will be lost)..."
wipefs -af "${DISK}"
partprobe "${DISK}"

if [[ "${UEFI}" == "yes" ]]; then
    # GPT: 512M EFI + SWAP + ROOT
    # sfdisk uses its own type aliases (not gdisk hex codes like EF00/8200/8304)
    sfdisk --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi,  name="EFI"
size=${SWAP_SIZE},        type=swap,  name="SWAP"
,                         type=linux, name="ROOT"
EOF
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
else
    # MBR: SWAP + ROOT
    sfdisk --label dos "${DISK}" <<EOF
size=${SWAP_SIZE}, type=82
,                  type=83
EOF
    EFI_PART=""
    SWAP_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi
partprobe "${DISK}"

# ==================== FORMAT ====================
echo "Formatting partitions..."
[[ "${UEFI}" == "yes" ]] && mkfs.fat -F32 -n EFI "${EFI_PART}"
mkswap -L swap "${SWAP_PART}"
mkfs."${FILESYSTEM}" -F -L root "${ROOT_PART}"

# ==================== MOUNT ====================
echo "Mounting filesystems..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot
[[ "${UEFI}" == "yes" ]] && mount "${EFI_PART}" /mnt/boot
swapon "${SWAP_PART}"

# ==================== BASESTRAP ====================
echo "Installing base system..."
basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm

echo "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab

# ==================== PROXY CONFIG FOR INSTALLED SYSTEM ====================
# Resolved at install time — static exports, no runtime condition needed.
mkdir -p /mnt/etc/profile.d
cat > /mnt/etc/profile.d/proxy.sh <<PROXY_EOF
#!/bin/sh
# Proxy injected by Artix installer. Edit manually if your proxy changes.
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
PROXY_EOF
chmod 644 /mnt/etc/profile.d/proxy.sh
echo ">>> Proxy settings written to installed system."

# ==================== CHROOT PHASE ====================
# Unquoted <<CHROOT_EOF so outer variables (TIMEZONE, USERNAME, PASSWORD,
# DISK, UEFI, etc.) expand before the block is passed to the chroot.
# Inner config-file heredocs use quoted delimiters (<<'MARKER') to prevent
# unwanted expansion inside those files.
echo "Entering chroot for final configuration..."

artix-chroot /mnt /bin/bash <<CHROOT_EOF
set -euo pipefail

# Load proxy
. /etc/profile.d/proxy.sh

# ── Locale / timezone / hostname ──────────────────────────────────────────
echo "Configuring locale, timezone, hostname..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}"       > /etc/hostname
cat > /etc/hosts <<EOF2
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF2

# ── Accounts ──────────────────────────────────────────────────────────────
echo "Creating accounts..."
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo "${FULL_NAME}" > "/home/${USERNAME}/.fullname" 2>/dev/null || true
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# ── s6 service database ───────────────────────────────────────────────────
echo "Enabling s6-rc services..."
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connmand; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
# Compile s6 service database
s6-rc-compile /etc/s6/rc/compiled /etc/s6/adminsv || true

# ── paru (AUR helper) ─────────────────────────────────────────────────────
echo "Installing paru AUR helper..."
pacman -S --noconfirm --needed git base-devel
su - "${USERNAME}" -c '
    git clone https://aur.archlinux.org/paru.git /tmp/paru
    cd /tmp/paru
    makepkg -si --noconfirm --needed
    rm -rf /tmp/paru
'

# ── MangoWM ───────────────────────────────────────────────────────────────
echo "Installing MangoWM..."
su - "${USERNAME}" -c "paru -S --noconfirm --needed mangowm"

# ── MangoWM config ────────────────────────────────────────────────────────
echo "Creating MangoWM config for ${USERNAME}..."
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_CONFIG'
# MangoWM config
# Terminal: alacritty | Launcher: wofi | SUPER = Mod4

# Core actions
bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
bind=SUPER,f,togglefullscreen

# Focus movement
bind=ALT,Left,focusmon,left
bind=ALT,Right,focusmon,right
bind=ALT,Up,focusmon,up
bind=ALT,Down,focusmon,down

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
bind=ALT,1,tag,1
bind=ALT,2,tag,2
bind=ALT,3,tag,3
bind=ALT,4,tag,4
bind=ALT,5,tag,5
bind=ALT,6,tag,6
bind=ALT,7,tag,7
bind=ALT,8,tag,8
bind=ALT,9,tag,9

# Autostart audio
exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse
MANGO_CONFIG

# ── Autostart MangoWM on tty1 ─────────────────────────────────────────────
cat > "/home/${USERNAME}/.bash_profile" <<'BASH_PROFILE'
# Autostart MangoWM on tty1
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

# Fix ownership
chown -R "${USERNAME}:${USERNAME}" \
    "/home/${USERNAME}/.config" \
    "/home/${USERNAME}/.bash_profile" \
    "/home/${USERNAME}/.fullname"

# ── GRUB ──────────────────────────────────────────────────────────────────
echo "Installing GRUB bootloader..."
if [[ "${UEFI}" == "yes" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
else
    grub-install --target=i386-pc "${DISK}"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# ── Cleanup ───────────────────────────────────────────────────────────────
echo "Final cleanup..."
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*

echo "=== Chroot phase complete ==="
CHROOT_EOF

# ==================== UNMOUNT & FINISH ====================
echo "Unmounting filesystems..."
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
