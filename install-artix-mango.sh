#!/usr/bin/env bash
# =============================================================================
# Artix Linux (s6) + MangoWM Automated Installer
# Target: HP Mini Pro Desk | 1TB HDD | 8GB RAM
# Init: s6 | WM: MangoWM (dwm-style Wayland compositor)
# Philosophy: Minimal. Keyboard-driven. No bloat.
# =============================================================================
# USAGE (boot Artix base-s6 ISO, log in as root, then):
#   bash install-artix-mango.sh
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# COLORS
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${GREEN}==> $*${RESET}"; }

# ──────────────────────────────────────────────────────────────────────────────
# SANITY CHECKS
# ──────────────────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root."
command -v basestrap &>/dev/null || die "Not running from Artix live ISO."

# ──────────────────────────────────────────────────────────────────────────────
# USER CONFIG — edit these or let the prompts handle it
# ──────────────────────────────────────────────────────────────────────────────
header "Configuration"

# Disk selection
echo ""
lsblk -d -o NAME,SIZE,MODEL | grep -v loop
echo ""
read -rp "$(echo -e ${BOLD})Target disk (e.g. sda, nvme0n1): $(echo -e ${RESET})" DISK_NAME
DISK="/dev/${DISK_NAME}"
[[ -b "$DISK" ]] || die "Disk $DISK not found."

# Partition scheme
# /dev/sdX1 → 512MB  EFI
# /dev/sdX2 → 8GB    swap  (matches your RAM)
# /dev/sdX3 → rest   /     ext4
if [[ "$DISK_NAME" == nvme* ]]; then
    PART_EFI="${DISK}p1"
    PART_SWAP="${DISK}p2"
    PART_ROOT="${DISK}p3"
else
    PART_EFI="${DISK}1"
    PART_SWAP="${DISK}2"
    PART_ROOT="${DISK}3"
fi

read -rp "Hostname [artix]: " HOSTNAME;       HOSTNAME="${HOSTNAME:-artix}"
read -rp "Username: " USERNAME;               [[ -n "$USERNAME" ]] || die "Username required."
read -rp "Timezone (e.g. America/New_York): " TIMEZONE; [[ -n "$TIMEZONE" ]] || die "Timezone required."
read -rp "Locale [en_US.UTF-8]: " LOCALE;    LOCALE="${LOCALE:-en_US.UTF-8}"

echo ""
warn "Root password:"
read -rsp "  Enter: " ROOT_PASS; echo
read -rsp "  Confirm: " ROOT_PASS2; echo
[[ "$ROOT_PASS" == "$ROOT_PASS2" ]] || die "Passwords do not match."

warn "User password for $USERNAME:"
read -rsp "  Enter: " USER_PASS; echo
read -rsp "  Confirm: " USER_PASS2; echo
[[ "$USER_PASS" == "$USER_PASS2" ]] || die "Passwords do not match."

echo ""
warn "This will WIPE $DISK. All data will be lost."
read -rp "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || die "Aborted."

# ──────────────────────────────────────────────────────────────────────────────
# PARTITION
# ──────────────────────────────────────────────────────────────────────────────
header "Partitioning $DISK"

# Wipe
wipefs -af "$DISK"
sgdisk -Z "$DISK"

# Create partitions
sgdisk -n 1:0:+512M  -t 1:ef00 -c 1:"EFI"  "$DISK"   # EFI
sgdisk -n 2:0:+8G    -t 2:8200 -c 2:"swap" "$DISK"   # swap (8GB = your RAM)
sgdisk -n 3:0:0      -t 3:8300 -c 3:"root" "$DISK"   # root (rest of 1TB)

partprobe "$DISK"
sleep 2
success "Partitioned."

# ──────────────────────────────────────────────────────────────────────────────
# FORMAT
# ──────────────────────────────────────────────────────────────────────────────
header "Formatting"

mkfs.fat -F32 -n EFI "$PART_EFI"
mkswap -L swap "$PART_SWAP"
mkfs.ext4 -L root "$PART_ROOT"

success "Formatted."

# ──────────────────────────────────────────────────────────────────────────────
# MOUNT
# ──────────────────────────────────────────────────────────────────────────────
header "Mounting"

mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi
swapon "$PART_SWAP"

success "Mounted."

# ──────────────────────────────────────────────────────────────────────────────
# INSTALL BASE SYSTEM
# ──────────────────────────────────────────────────────────────────────────────
header "Installing base system (this takes a while)"

basestrap /mnt \
    base base-devel \
    linux linux-firmware linux-headers \
    s6 s6-rc s6-boot \
    elogind elogind-s6 \
    seatd seatd-s6 \
    networkmanager networkmanager-s6 \
    grub efibootmgr \
    neovim git curl wget \
    man-db man-pages \
    bash-completion \
    intel-ucode \
    mesa vulkan-intel \
    xf86-video-intel \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    xorg-xwayland \
    wayland wayland-protocols \
    libinput \
    libxkbcommon \
    dbus dbus-s6

success "Base installed."

# ──────────────────────────────────────────────────────────────────────────────
# FSTAB
# ──────────────────────────────────────────────────────────────────────────────
header "Generating fstab"
fstabgen -U /mnt >> /mnt/etc/fstab
success "fstab written."

# ──────────────────────────────────────────────────────────────────────────────
# CHROOT SCRIPT
# ──────────────────────────────────────────────────────────────────────────────
header "Entering chroot"

# Write the chroot stage to a temp script inside /mnt
cat > /mnt/root/chroot-install.sh << CHROOT_EOF
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "\${CYAN}[INFO]\${RESET} \$*"; }
success() { echo -e "\${GREEN}[OK]\${RESET}  \$*"; }
header()  { echo -e "\n\${BOLD}\${GREEN}==> \$*\${RESET}"; }

# ── Timezone & Clock ─────────────────────────────────────────────────────────
header "Timezone"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
success "Timezone set to ${TIMEZONE}."

# ── Locale ───────────────────────────────────────────────────────────────────
header "Locale"
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
success "Locale: ${LOCALE}."

# ── Hostname ─────────────────────────────────────────────────────────────────
header "Hostname"
echo "${HOSTNAME}" > /etc/hostname
cat >> /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
success "Hostname: ${HOSTNAME}."

# ── Passwords ────────────────────────────────────────────────────────────────
header "Setting passwords"
echo "root:${ROOT_PASS}" | chpasswd
success "Root password set."

# ── User ─────────────────────────────────────────────────────────────────────
header "Creating user: ${USERNAME}"
useradd -mG wheel,video,input,audio,seat ${USERNAME}
echo "${USERNAME}:${USER_PASS}" | chpasswd
# Allow wheel group sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
success "User created."

# ── GRUB ─────────────────────────────────────────────────────────────────────
header "Installing GRUB"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck
grub-mkconfig -o /boot/grub/grub.cfg
success "GRUB installed."

# ── s6 Services ──────────────────────────────────────────────────────────────
header "Enabling s6 services"
# NetworkManager
ln -sf /etc/s6/sv/NetworkManager /etc/s6/sv/default.d/ 2>/dev/null || \
ln -sf /run/service/NetworkManager /etc/s6/sv/default.d/ 2>/dev/null || true

# seatd (required for seat access without root in Wayland)
ln -sf /etc/s6/sv/seatd /etc/s6/sv/default.d/ 2>/dev/null || true

# dbus
ln -sf /etc/s6/sv/dbus /etc/s6/sv/default.d/ 2>/dev/null || true

success "s6 services linked."

# ── pacman.conf tweaks ───────────────────────────────────────────────────────
header "pacman tweaks"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
# Enable multilib
sed -i '/\[multilib\]/{n;s/^#Include/Include/}' /etc/pacman.conf
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
pacman -Sy --noconfirm
success "pacman configured."

# ── AUR Helper (yay) ─────────────────────────────────────────────────────────
header "Installing yay (AUR helper)"
cd /tmp
git clone https://aur.archlinux.org/yay.git
chown -R ${USERNAME}:${USERNAME} yay
cd yay
sudo -u ${USERNAME} makepkg -si --noconfirm
cd /
success "yay installed."

# ── MangoWM Dependencies ─────────────────────────────────────────────────────
header "Installing MangoWM dependencies"
pacman -S --noconfirm \
    wayland \
    wayland-protocols \
    libinput \
    libdrm \
    libxkbcommon \
    pixman \
    libdisplay-info \
    libliftoff \
    hwdata \
    pcre2 \
    xorg-xwayland \
    libxcb \
    xcb-util-wm \
    xcb-util-renderutil

success "Dependencies installed."

# ── MangoWM from AUR ─────────────────────────────────────────────────────────
header "Installing MangoWM"
sudo -u ${USERNAME} yay -S --noconfirm mangowm-git
success "MangoWM installed."

# ── Minimal dwm-philosophy toolset ───────────────────────────────────────────
# foot        → terminal (fast, minimal, Wayland-native)
# rofi-wayland → launcher (keyboard-driven)
# waybar      → status bar (minimal config)
# swaybg      → wallpaper setter (simple)
# wl-clipboard → clipboard
# swaync      → notification daemon (minimal)
# grim + slurp → screenshot pipeline (composable unix tools)
header "Installing minimal toolset (dwm philosophy)"
pacman -S --noconfirm \
    foot \
    waybar \
    swaybg \
    wl-clipboard \
    wl-clip-persist \
    grim \
    slurp \
    xdg-desktop-portal \
    xdg-desktop-portal-wlr \
    xdg-user-dirs \
    brightnessctl \
    pavucontrol \
    pamixer

# rofi-wayland from AUR
sudo -u ${USERNAME} yay -S --noconfirm rofi-wayland swaync swaylock-effects-git wlogout

success "Toolset installed."

# ── Mango Config ─────────────────────────────────────────────────────────────
header "Pulling MangoWM config"
sudo -u ${USERNAME} git clone \
    https://github.com/DreamMaoMao/mango-config.git \
    /home/${USERNAME}/.config/mango
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/mango
success "Config pulled."

# ── Shell profile: auto-start Mango on TTY1 ──────────────────────────────────
header "Configuring auto-launch on TTY1"
cat >> /home/${USERNAME}/.bash_profile << 'PROFILE'

# Auto-launch MangoWM on TTY1 login
if [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=mango
    export MOZ_ENABLE_WAYLAND=1
    export QT_QPA_PLATFORM=wayland
    export SDL_VIDEODRIVER=wayland
    exec mango
fi
PROFILE

chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile
success "Auto-launch configured."

# ── Minimal waybar config ─────────────────────────────────────────────────────
header "Writing minimal waybar config"
mkdir -p /home/${USERNAME}/.config/waybar
cat > /home/${USERNAME}/.config/waybar/config << 'WAYBAR'
{
    "layer": "top",
    "position": "top",
    "height": 24,
    "modules-left": ["custom/mango", "clock"],
    "modules-right": ["pulseaudio", "network", "cpu", "memory", "battery"],
    "custom/mango": {
        "format": " mango",
        "tooltip": false
    },
    "clock": {
        "format": "{:%a %b %d  %H:%M}",
        "tooltip": false
    },
    "cpu": {
        "format": "cpu {usage}%",
        "interval": 5
    },
    "memory": {
        "format": "mem {}%",
        "interval": 10
    },
    "network": {
        "format-wifi": "{essid}",
        "format-ethernet": "eth",
        "format-disconnected": "offline",
        "tooltip": false
    },
    "pulseaudio": {
        "format": "vol {volume}%",
        "format-muted": "muted",
        "on-click": "pamixer -t"
    },
    "battery": {
        "format": "bat {capacity}%",
        "format-charging": "chr {capacity}%"
    }
}
WAYBAR

cat > /home/${USERNAME}/.config/waybar/style.css << 'CSS'
* {
    font-family: monospace;
    font-size: 12px;
    border: none;
    border-radius: 0;
    min-height: 0;
}
window#waybar {
    background: #000000;
    color: #00ff00;
}
#clock, #cpu, #memory, #network, #pulseaudio, #battery, #custom-mango {
    padding: 0 8px;
    color: #00ff00;
}
CSS

chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/waybar
success "waybar configured."

# ── xdg-user-dirs ────────────────────────────────────────────────────────────
sudo -u ${USERNAME} xdg-user-dirs-update 2>/dev/null || true

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "\${GREEN}══════════════════════════════════════════════════\${RESET}"
echo -e "\${GREEN}  Install complete. Keybindings:\${RESET}"
echo -e "\${GREEN}  Alt+Enter    → foot terminal\${RESET}"
echo -e "\${GREEN}  Alt+Space    → rofi launcher\${RESET}"
echo -e "\${GREEN}  Alt+Q        → kill window\${RESET}"
echo -e "\${GREEN}  Alt+←/→/↑/↓ → focus\${RESET}"
echo -e "\${GREEN}  Super+M      → quit mango\${RESET}"
echo -e "\${GREEN}══════════════════════════════════════════════════\${RESET}"
echo ""
CHROOT_EOF

chmod +x /mnt/root/chroot-install.sh
artix-chroot /mnt /root/chroot-install.sh

# ──────────────────────────────────────────────────────────────────────────────
# CLEANUP & FINISH
# ──────────────────────────────────────────────────────────────────────────────
rm -f /mnt/root/chroot-install.sh

header "Unmounting"
sync
umount -R /mnt
swapoff "$PART_SWAP"

echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  All done. Remove your USB and reboot.${RESET}"
echo -e "${GREEN}${BOLD}  Log in as ${USERNAME} on TTY1 → Mango launches.${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════${RESET}"
echo ""
