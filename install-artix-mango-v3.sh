#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# ==============================================================================
# install-artix-mango-v3.sh
# Artix Linux + s6 + MangoWM installer
# Features: logging, dry-run, checkpoint/resume, cleanup rollback
# ==============================================================================

# -------------------------------
# User config
# -------------------------------
DISK="${DISK:-/dev/sda}"
HOSTNAME="${HOSTNAME:-mangodesk}"
USERNAME="${USERNAME:-wade}"
LOCALE="${LOCALE:-en_US.UTF-8}"
TIMEZONE="${TIMEZONE:-America/Los_Angeles}"
KEYMAP="${KEYMAP:-us}"
MOUNT="${MOUNT:-/mnt}"
BOOT_SIZE="${BOOT_SIZE:-512M}"
SWAP_SIZE="${SWAP_SIZE:-8G}"   # set to "" to disable swap
DRY_RUN="${DRY_RUN:-0}"
RESUME="${RESUME:-1}"

# Artix s6 base packages per official install guide
BASE_PKGS=(
  base base-devel linux linux-firmware linux-headers
  s6-base elogind-s6
  grub efibootmgr os-prober
  sudo vim git curl wget rsync man-db man-pages bash-completion
  networkmanager-s6 networkmanager iwd
  intel-ucode
)

# Wayland / desktop stack
WAYLAND_PKGS=(
  wayland wayland-protocols libinput wlroots
  xorg-xwayland xorg-xlsclients
  mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver libva-intel-driver
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol
  xdg-desktop-portal xdg-desktop-portal-wlr
  polkit polkit-s6
)

DESKTOP_PKGS=(
  foot fuzzel waybar mako swaybg swaylock grim slurp wl-clipboard
  thunar gvfs
  noto-fonts noto-fonts-emoji noto-fonts-cjk ttf-jetbrains-mono ttf-font-awesome
  playerctl mpv brightnessctl unzip p7zip jq fzf ripgrep fd bat eza zoxide
)

# -------------------------------
# State / logging
# -------------------------------
STATE_DIR="${STATE_DIR:-/var/tmp/artix-mango-installer}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/install.log}"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE" "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# -------------------------------
# Helpers
# -------------------------------
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; CYN='\033[0;36m'; MAG='\033[0;35m'; BOLD='\033[1m'; RST='\033[0m'
info(){ echo -e "${BLU}[INFO]${RST} $*"; }
ok(){ echo -e "${GRN}[ OK ]${RST} $*"; }
warn(){ echo -e "${YLW}[WARN]${RST} $*"; }
die(){ echo -e "${RED}[FAIL]${RST} $*"; exit 1; }
step(){ echo -e "\n${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"; echo -e "${BOLD}${CYN}  ▶  $*${RST}"; echo -e "${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"; }

is_root(){ [[ $EUID -eq 0 ]]; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
is_done(){ grep -qx "$1" "$STATE_FILE" 2>/dev/null; }
mark_done(){ grep -qx "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"; }

run(){
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY] $*"
  else
    echo "[RUN] $*"
    bash -lc "$*"
  fi
}

require_cmd(){ cmd_exists "$1" || die "Missing command: $1"; }

# Cleanup only removes mounts / swap. It does not undo partitioning.
cleanup(){
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Installer failed at line $LINENO. Cleaning up mounts and swap."
  fi
  if mountpoint -q "$MOUNT/boot/efi" 2>/dev/null; then umount "$MOUNT/boot/efi" || true; fi
  if mountpoint -q "$MOUNT" 2>/dev/null; then umount "$MOUNT" || true; fi
  if [[ -n "${PART_SWAP:-}" ]] && swapon --show=NAME 2>/dev/null | grep -qx "${PART_SWAP}"; then swapoff "$PART_SWAP" || true; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'die "Error on line $LINENO"' ERR

usage(){
  cat <<EOF
Usage: sudo env [DISK=/dev/nvme0n1] [USERNAME=wade] [HOSTNAME=mangodesk] [DRY_RUN=1] bash $0

Notes:
- Resume is enabled by default via $STATE_FILE.
- Set RESUME=0 to ignore state and run from the beginning.
EOF
}

# -------------------------------
# Preconditions
# -------------------------------
[[ $# -eq 0 ]] || usage
is_root || die "Run as root."
[[ -d /sys/firmware/efi ]] || die "UEFI boot required."
[[ -b "$DISK" ]] || die "Disk not found: $DISK"
cmd_exists basestrap || die "basestrap missing. Boot the Artix live ISO."
cmd_exists artix-chroot || die "artix-chroot missing."
cmd_exists sgdisk || die "sgdisk missing."
cmd_exists wipefs || die "wipefs missing."

# Detect partition suffix style.
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
  P="${DISK}p"
else
  P="${DISK}"
fi
PART_BOOT="${P}1"
PART_SWAP=""
PART_ROOT="${P}2"

# -------------------------------
# Banner
# -------------------------------
clear || true
cat <<EOF
${BOLD}${CYN}
  ┌──────────────────────────────────────────────────────┐
  │  Artix Linux · s6 · MangoWM installer v3            │
  └──────────────────────────────────────────────────────┘
${RST}
Disk      : $DISK
Hostname  : $HOSTNAME
Username  : $USERNAME
Locale    : $LOCALE
Timezone  : $TIMEZONE
Swap      : ${SWAP_SIZE:-none}
Dry-run   : $DRY_RUN
Log file  : $LOG_FILE
State file : $STATE_FILE
EOF
warn "All data on $DISK will be destroyed."
if [[ "$DRY_RUN" != "1" ]]; then
  read -r -p "Type yes to continue: " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || die "Aborted."
fi

# -------------------------------
# Phase 1: partition
# -------------------------------
partition_disk(){
  if [[ "$RESUME" == "1" && is_done partitioned ]]; then
    info "Skipping partitioning (already marked done)."
    return
  fi
  step "Partitioning $DISK"
  run "wipefs -af '$DISK'"
  run "sgdisk --zap-all '$DISK'"
  if [[ -n "$SWAP_SIZE" ]]; then
    PART_BOOT="${P}1"; PART_SWAP="${P}2"; PART_ROOT="${P}3"
    run "sgdisk -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:EFI -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:swap -n 3:0:0 -t 3:8300 -c 3:root '$DISK'"
  else
    PART_BOOT="${P}1"; PART_SWAP=""; PART_ROOT="${P}2"
    run "sgdisk -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:EFI -n 2:0:0 -t 2:8300 -c 2:root '$DISK'"
  fi
  run "partprobe '$DISK'"
  sleep 1
  mark_done partitioned
  ok "Partitioning complete"
}

# -------------------------------
# Phase 2: format
# -------------------------------
format_partitions(){
  if [[ "$RESUME" == "1" && is_done formatted ]]; then
    info "Skipping formatting (already marked done)."
    return
  fi
  step "Formatting partitions"
  run "mkfs.fat -F32 -n EFI '$PART_BOOT'"
  if [[ -n "$PART_SWAP" ]]; then
    run "mkswap -L swap '$PART_SWAP'"
    if [[ "$DRY_RUN" != "1" ]]; then
      swapon "$PART_SWAP"
    fi
  fi
  run "mkfs.ext4 -L artix-root '$PART_ROOT'"
  mark_done formatted
  ok "Formatting complete"
}

# -------------------------------
# Phase 3: mount
# -------------------------------
mount_filesystems(){
  if [[ "$RESUME" == "1" && is_done mounted ]]; then
    info "Skipping mount step (already marked done)."
    return
  fi
  step "Mounting filesystems"
  run "mount '$PART_ROOT' '$MOUNT'"
  run "mkdir -p '$MOUNT/boot/efi'"
  run "mount '$PART_BOOT' '$MOUNT/boot/efi'"
  mark_done mounted
  ok "Mounted at $MOUNT"
}

# -------------------------------
# Phase 4: base install
# -------------------------------
install_base(){
  if [[ "$RESUME" == "1" && is_done basestrap ]]; then
    info "Skipping base install (already marked done)."
    return
  fi
  step "Installing base system"
  run "basestrap '$MOUNT' ${BASE_PKGS[*]}"
  run "fstabgen -U '$MOUNT' >> '$MOUNT/etc/fstab'"
  mark_done basestrap
  ok "Base installed"
}

# -------------------------------
# Phase 5: chroot config
# -------------------------------
chroot_config(){
  if [[ "$RESUME" == "1" && is_done chroot ]]; then
    info "Skipping chroot config (already marked done)."
    return
  fi
  step "Configuring system in chroot"
  export HOSTNAME USERNAME LOCALE TIMEZONE KEYMAP
  export STATE_MARKER="1"
  artix-chroot "$MOUNT" /bin/bash <<'CHROOT'
set -Eeuo pipefail
IFS=$'\n\t'

log(){ echo "[CHROOT] $*"; }

# Locale
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
printf 'KEYMAP=%s\n' "$KEYMAP" > /etc/vconsole.conf

# Timezone
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Hostname
printf '%s\n' "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF_HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF_HOSTS

# Pacman sanity
sed -i \
  -e 's/^#ParallelDownloads.*/ParallelDownloads = 10/' \
  -e 's/^#Color/Color/' \
  -e '/^#\[multilib\]/,/^#Include/ s/^#//' \
  /etc/pacman.conf || true
pacman -Sy --noconfirm

# Packages for desktop
pacman -S --noconfirm --needed \
  ${WAYLAND_PKGS[*]} \
  ${DESKTOP_PKGS[*]}

# s6 service enablement; official Artix s6 instructions use contents.d + s6-db-reload
if [[ -d /etc/s6/adminsv/default/contents.d ]]; then
  touch /etc/s6/adminsv/default/contents.d/NetworkManager
  touch /etc/s6/adminsv/default/contents.d/elogind
  touch /etc/s6/adminsv/default/contents.d/polkit
  touch /etc/s6/adminsv/default/contents.d/s6-rc || true
  s6-db-reload || true
fi

# Bootloader
pacman -S --noconfirm --needed grub efibootmgr os-prober
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub || true
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=artix --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Users
printf 'root:toor\n' | chpasswd
if ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G wheel,audio,video,input,storage,optical -s /bin/bash "$USERNAME"
fi
printf '%s:changeme\n' "$USERNAME" | chpasswd
mkdir -p /etc/sudoers.d
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# MangoWM / Mango package: official docs name the binary `mango`, config dir `~/.config/mango/`.
# AUR package name can vary; this block uses paru if available, otherwise leaves a clear note.
if ! command -v paru >/dev/null 2>&1; then
  pacman -S --noconfirm --needed base-devel git
  sudo -u "$USERNAME" bash -lc '
    cd /tmp
    rm -rf paru-bin
    git clone https://aur.archlinux.org/paru-bin.git
    cd paru-bin
    makepkg -si --noconfirm
  ' || true
fi
if command -v paru >/dev/null 2>&1; then
  sudo -u "$USERNAME" paru -S --noconfirm mangowm-git || true
fi

# User config root
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config/mango"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/screenshots"
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/src"

# Pull default Mango config if present, then overlay user-friendly config
if [[ -f /etc/mango/config.conf ]]; then
  cp /etc/mango/config.conf "/home/$USERNAME/.config/mango/config.conf"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/mango/config.conf"
fi

# Shell profile to start Mango on tty1
cat > "/home/$USERNAME/.bash_profile" <<'EOF_PROFILE'
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z "${WAYLAND_DISPLAY:-}" && "${XDG_VTNR:-0}" -eq 1 ]]; then
  export XDG_SESSION_TYPE=wayland
  export XDG_CURRENT_DESKTOP=mango
  export MOZ_ENABLE_WAYLAND=1
  export QT_QPA_PLATFORM=wayland
  export SDL_VIDEODRIVER=wayland
  export CLUTTER_BACKEND=wayland
  export _JAVA_AWT_WM_NONREPARENTING=1
  exec mango > ~/.local/share/mango.log 2>&1
fi
EOF_PROFILE
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"

cat > "/home/$USERNAME/.bashrc" <<'EOF_BASHRC'
[[ $- != *i* ]] && return
PS1='\[\e[36m\]\u\[\e[0m\]@\[\e[34m\]\h\[\e[0m\]:\[\e[33m\]\w\[\e[0m\]\$ '
alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --group-directories-first'
alias cat='bat --pager=never'
alias top='btop'
eval "$(zoxide init bash)"
[[ -f /usr/share/fzf/key-bindings.bash ]] && source /usr/share/fzf/key-bindings.bash
[[ -f /usr/share/fzf/completion.bash ]] && source /usr/share/fzf/completion.bash
export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export CLUTTER_BACKEND=wayland
EOF_BASHRC
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bashrc"

# Keep a minimal config file in place so Mango has something valid.
cat > "/home/$USERNAME/.config/mango/config.conf" <<'EOF_MANGO'
# MangoWM user config placeholder. Replace with the upstream example config if desired.
# Official quick-start says Mango reads ~/.config/mango/config.conf and launches with `mango`.
EOF_MANGO
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/mango/config.conf"

# Waybar / launcher / notifications / wallpaper assets can be added later.
mkdir -p /home/$USERNAME/.local/share
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
CHROOT
  mark_done chroot
  ok "Chroot config complete"
}

# -------------------------------
# Phase 6: verification
# -------------------------------
verify_install(){
  step "Verifying installation"
  local pass=0 total=0
  check(){
    total=$((total+1))
    if [[ -e "$MOUNT/$2" ]]; then
      ok "$1"
      pass=$((pass+1))
    else
      warn "$1 missing: $2"
    fi
  }
  check "Kernel" "boot/vmlinuz-linux"
  check "Initramfs" "boot/initramfs-linux.img"
  check "GRUB EFI" "boot/efi/EFI/artix/grubx64.efi"
  check "fstab" "etc/fstab"
  check "NetworkManager" "usr/bin/NetworkManager"
  check "Mango binary" "usr/bin/mango"
  check "foot" "usr/bin/foot"
  check "waybar" "usr/bin/waybar"
  check "pipewire" "usr/bin/pipewire"
  check "User home" "home/$USERNAME"
  echo "Checks: $pass / $total passed"
}

# -------------------------------
# Main
# -------------------------------
main(){
  partition_disk
  format_partitions
  mount_filesystems
  install_base
  chroot_config
  verify_install
  mark_done complete
  ok "Installation complete"
  echo "Log: $LOG_FILE"
  echo "State: $STATE_FILE"
  echo "Unmounting will be handled automatically."
}

main
