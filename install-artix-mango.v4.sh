#!/usr/bin/env bash
# =============================================================================
# Artix Linux (s6) + MangoWM Automated Installer — v4 (final)
# - Safer, more robust, future-proofed
# - Optional LUKS root encryption (set ENCRYPT_ROOT=1 to enable)
# - AUR/build logs saved to /root inside the target
# - runuser fallback, artix-chroot check, better cleanup
# USAGE:
#   Interactive:
#     bash install-artix-mango.v4.sh
#   Non-interactive (passwords always prompted — never pass via env):
#     DISK=sda USERNAME=wade HOSTNAME=artix \
#     TIMEZONE=America/New_York LOCALE=en_US.UTF-8 \
#     SWAP_SIZE=8G YES=1 bash install-artix-mango.v4.sh
#   Dry run:
#     DRY_RUN=1 bash install-artix-mango.v4.sh
# =============================================================================

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# COLORS / LOGGING
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
LOG="/root/artix-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()     { echo -e "${RED}[ERR]${RESET}  $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${GREEN}==> $*${RESET}"; }
dryrun()  { echo -e "${YELLOW}[DRY-RUN]${RESET} Would run: $*"; }

# PRE-FLIGHT
header "Pre-flight checks"
[[ $EUID -ne 0 ]] && die "Run as root."

DRY_RUN="${DRY_RUN:-0}"
YES="${YES:-0}"
ENCRYPT_ROOT="${ENCRYPT_ROOT:-0}"   # set to 1 to enable LUKS root encryption (interactive passphrase)

if [[ "$DRY_RUN" -eq 0 ]]; then
    command -v basestrap &>/dev/null || die "basestrap not found — boot the Artix live ISO first."
    command -v artix-chroot &>/dev/null || die "artix-chroot not found — use an Artix live ISO with artix-chroot."
fi

# UEFI required
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode. This script requires UEFI."

# Network polite check
if ! ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    warn "No network connectivity detected. Ensure you are online before basestrap."
fi
success "Pre-flight checks OK."

# Helper: prompt_or_env
prompt_or_env() {
    local varname="$1" prompt="$2" default="$3"
    local val="${!varname:-}"
    if [[ -n "$val" ]]; then
        echo "$val"; return
    fi
    if [[ "$YES" -eq 1 ]]; then
        [[ -n "$default" ]] && echo "$default" && return
        die "Missing required config: $varname (set via env or run interactively)"
    fi
    read -rp "$prompt" val
    echo "${val:-$default}"
}

# CONFIG
header "Configuration"
echo ""; lsblk -d -o NAME,SIZE,MODEL | grep -v loop || true; echo ""

DISK_NAME="${DISK:-}"
if [[ -z "$DISK_NAME" ]]; then
    read -rp "$(echo -e "${BOLD}")Target disk (e.g. sda, nvme0n1): $(echo -e "${RESET}")" DISK_NAME
fi
DISK="/dev/${DISK_NAME}"
[[ "$DRY_RUN" -eq 1 ]] || [[ -b "$DISK" ]] || die "Disk $DISK not found."

# minimal size check (only in non-dry-run)
if [[ "$DRY_RUN" -eq 0 ]]; then
    if command -v lsblk &>/dev/null; then
        DISK_SIZE_GB=$(lsblk -bdn -o SIZE "$DISK" | awk '{printf "%d", $1/1024/1024/1024}')
        [[ "$DISK_SIZE_GB" -ge 20 ]] || die "Disk $DISK is ${DISK_SIZE_GB}GB — minimum 20GB required."
        info "Disk size: ${DISK_SIZE_GB}GB"
    fi
fi

# Partition naming
if [[ "$DISK_NAME" == nvme* ]]; then
    PART_EFI="${DISK}p1"; PART_SWAP="${DISK}p2"; PART_ROOT="${DISK}p3"
else
    PART_EFI="${DISK}1"; PART_SWAP="${DISK}2"; PART_ROOT="${DISK}3"
fi

SWAP_SIZE="${SWAP_SIZE:-8G}"
HOSTNAME="$(prompt_or_env HOSTNAME   "Hostname [artix]: "              "artix")"
USERNAME="$(prompt_or_env USERNAME   "Username: "                      "")"
[[ -n "$USERNAME" ]] || die "Username required."
TIMEZONE="$(prompt_or_env TIMEZONE   "Timezone (e.g. America/New_York): " "")"
[[ -n "$TIMEZONE" ]] || die "Timezone required."
[[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "Timezone '${TIMEZONE}' not found under /usr/share/zoneinfo."
LOCALE="$(prompt_or_env LOCALE "Locale [en_US.UTF-8]: " "en_US.UTF-8")"

# Passwords: always interactive
echo ""
warn "Root password (interactive only — never set via env):"
read -rsp "  Enter: " ROOT_PASS; echo
read -rsp "  Confirm: " ROOT_PASS2; echo
[[ "$ROOT_PASS" == "$ROOT_PASS2" ]] || die "Root passwords do not match."
[[ -n "$ROOT_PASS" ]] || die "Root password cannot be empty."

warn "Password for '${USERNAME}':"
read -rsp "  Enter: " USER_PASS; echo
read -rsp "  Confirm: " USER_PASS2; echo
[[ "$USER_PASS" == "$USER_PASS2" ]] || die "User passwords do not match."
[[ -n "$USER_PASS" ]] || die "User password cannot be empty."

if [[ "$ENCRYPT_ROOT" -eq 1 ]]; then
    echo ""
    warn "LUKS root encryption enabled. You will be prompted for a passphrase."
    read -rsp "  Enter LUKS passphrase: " LUKS_PASSPHRASE; echo
    read -rsp "  Confirm LUKS passphrase: " LUKS_PASSPHRASE2; echo
    [[ "$LUKS_PASSPHRASE" == "$LUKS_PASSPHRASE2" ]] || die "LUKS passphrases do not match."
fi

# Summary
echo ""
echo -e "${BOLD}Install summary:${RESET}"
echo "  Disk:      $DISK  ← WILL BE WIPED"
echo "  EFI:       $PART_EFI  (512MB)"
echo "  Swap:      $PART_SWAP  ($SWAP_SIZE)"
echo "  Root:      $PART_ROOT  (remainder)"
echo "  Hostname:  $HOSTNAME"
echo "  User:      $USERNAME"
echo "  Timezone:  $TIMEZONE"
echo "  Locale:    $LOCALE"
echo "  LUKS root: $( [[ "$ENCRYPT_ROOT" -eq 1 ]] && echo enabled || echo disabled )"
echo "  Log:       $LOG"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
    warn "DRY RUN — no destructive operations will be executed."
    dryrun "wipefs -af $DISK && sgdisk -Z $DISK"
    dryrun "sgdisk: EFI=512M swap=$SWAP_SIZE root=remainder"
    dryrun "format & mount steps (including optional LUKS if enabled)"
    dryrun "basestrap /mnt base base-devel sudo linux ..."
    dryrun "fstabgen -U /mnt >> /mnt/etc/fstab"
    dryrun "artix-chroot /mnt /root/chroot-install.sh"
    success "Dry run complete."
    exit 0
fi

warn "This will WIPE ALL DATA on $DISK."
if [[ "$YES" -eq 1 ]]; then
    info "YES=1 set — proceeding without interactive confirmation."
else
    read -rp "Type 'yes' to continue: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || die "Aborted."
fi

# TRAP / CLEANUP
PWFILE_HOST="/mnt/root/.pwfile"
on_exit() {
    local rc=$?
    set +e
    [[ $rc -ne 0 ]] && warn "Failure detected (exit $rc). Running cleanup..."
    if [[ -f "$PWFILE_HOST" ]]; then
        if command -v shred &>/dev/null; then shred -u "$PWFILE_HOST" 2>/dev/null; else rm -f "$PWFILE_HOST"; fi
    fi
    mountpoint -q /mnt/boot/efi && umount /mnt/boot/efi || true
    mountpoint -q /mnt && umount -R /mnt || true
    swapon --show=NAME 2>/dev/null | grep -q "${PART_SWAP}" && swapoff "${PART_SWAP}" || true
    [[ $rc -ne 0 ]] && warn "Cleanup done. See $LOG"
    exit $rc
}
trap on_exit EXIT

# PARTITION
header "Partitioning $DISK"
wipefs -af "$DISK"
sgdisk -Z "$DISK"
sgdisk -n 1:0:+512M          -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:+${SWAP_SIZE}  -t 2:8200 -c 2:"swap" "$DISK"
sgdisk -n 3:0:0               -t 3:8300 -c 3:"root" "$DISK"

# Re-read partitions
if command -v partprobe &>/dev/null; then
    partprobe "$DISK"
elif command -v kpartx &>/dev/null; then
    kpartx -u "$DISK"
else
    warn "Neither partprobe nor kpartx found — sleeping briefly for kernel to catch up."
fi
sleep 3
success "Partitioned."

# FORMAT (with optional LUKS)
header "Formatting"
if [[ "$ENCRYPT_ROOT" -eq 1 ]]; then
    # format EFI and swap first, then LUKS the root partition
    mkfs.fat -F32 -n EFI "$PART_EFI"
    mkswap -L swap "$PART_SWAP"
    # LUKS format root
    if [[ -z "${LUKS_PASSPHRASE:-}" ]]; then
        die "LUKS passphrase missing."
    fi
    echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 -q "$PART_ROOT" -
    echo -n "$LUKS_PASSPHRASE" | cryptsetup open "$PART_ROOT" cryptroot -
    mapper_root="/dev/mapper/cryptroot"
    mkfs.ext4 -L root "$mapper_root"
    ROOT_MOUNT_TARGET="$mapper_root"
else
    mkfs.fat -F32 -n EFI "$PART_EFI"
    mkswap -L swap "$PART_SWAP"
    mkfs.ext4 -F -L root "$PART_ROOT"
    ROOT_MOUNT_TARGET="$PART_ROOT"
fi
success "Formatted."

# MOUNT
header "Mounting"
mount "$ROOT_MOUNT_TARGET" /mnt
mkdir -p /mnt/boot/efi
mount "$PART_EFI" /mnt/boot/efi
swapon "$PART_SWAP"
success "Mounted."

# BASE INSTALL
header "Installing base system (this may take a while)"
basestrap /mnt \
    base base-devel sudo \
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
    # xf86-video-intel is kept, but modern systems often use modesetting
    xf86-video-intel \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    xorg-xwayland \
    wayland wayland-protocols \
    libinput libxkbcommon dbus dbus-s6

success "Base installed."

# FSTAB
header "Generating fstab"
# If using LUKS, the root entry should reference the mapper; fstabgen uses UUIDs automatically
fstabgen -U /mnt >> /mnt/etc/fstab
success "fstab written."

# SECURE PWFILE (host)
header "Writing secure password file for chroot stage"
umask 077
printf 'root:%s\n%s:%s\n' "$ROOT_PASS" "$USERNAME" "$USER_PASS" > "$PWFILE_HOST"
chmod 600 "$PWFILE_HOST"
umask 022

# Clear sensitive vars in host shell
ROOT_PASS=""; ROOT_PASS2=""; USER_PASS=""; USER_PASS2=""
if [[ "$ENCRYPT_ROOT" -eq 1 ]]; then
    # Clear LUKS passphrase in host shell (we still used it earlier)
    LUKS_PASSPHRASE=""
fi

# CHROOT SCRIPT
header "Writing chroot script (/root/chroot-install.sh)"
cat > /mnt/root/chroot-install.sh <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# simple logging helpers
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
success(){ echo "[OK] $*"; }

# exported vars expanded by outer script during write:
HOSTNAME=''"${HOSTNAME}"''
USERNAME=''"${USERNAME}"''
TIMEZONE=''"${TIMEZONE}"''
LOCALE=''"${LOCALE}"''
ENCRYPT_ROOT=''"${ENCRYPT_ROOT}"''

# Helper to run commands as the unprivileged user; prefer runuser, fallback to su -c
run_as_user(){
  local cmd="$*"
  if command -v runuser &>/dev/null; then
    runuser -u "${USERNAME}" -- bash -lc "$cmd"
  else
    su - "${USERNAME}" -c "$cmd"
  fi
}

# set passwords from secure pwfile and shred it
info "Setting passwords from /root/.pwfile"
if [[ -f /root/.pwfile ]]; then
  chpasswd < /root/.pwfile
  if command -v shred &>/dev/null; then shred -u /root/.pwfile; else rm -f /root/.pwfile; fi
  success "Passwords set and pwfile removed."
else
  warn "/root/.pwfile missing — set passwords manually after first boot."
fi

# timezone/clock
info "Timezone: ${TIMEZONE}"
if [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  hwclock --systohc
else
  warn "Timezone ${TIMEZONE} not found inside chroot."
fi

# locale
info "Configuring locale: ${LOCALE}"
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# hostname
info "Setting hostname: ${HOSTNAME}"
echo "${HOSTNAME}" > /etc/hostname
cat >> /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# create user and allow wheel sudo
info "Creating user: ${USERNAME}"
useradd -mG wheel,video,input,audio,seat "${USERNAME}" || true
# Allow wheel in sudoers
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

# GRUB install for UEFI
info "Installing GRUB (UEFI)"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARTIX --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# pacman tweaks + full upgrade
info "Updating pacman configuration and performing full upgrade"
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf || true
sed -i 's/^#Color/Color/' /etc/pacman.conf || true
sed -i '/\[multilib\]/{n;s/^#Include/Include/}' /etc/pacman.conf || true
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf || true
pacman -Syu --noconfirm --needed

# enable s6 services (best-effort)
info "Enabling s6 services (best-effort)"
for svc in NetworkManager seatd dbus; do
  if [[ -d /etc/s6/sv/${svc} ]]; then
    ln -sf /etc/s6/sv/${svc} /etc/s6/sv/default.d/ 2>/dev/null || true
    info "Linked s6 service: ${svc}"
  else
    info "s6 service not found, skipping: ${svc}"
  fi
done

# Buildyay & AUR installs — capture logs to /root for debugging
YAY_BUILD_LOG="/root/yay-build.log"
YAY_AUR_LOG="/root/yay-aur.log"

info "Building yay AUR helper as ${USERNAME} (logs: ${YAY_BUILD_LOG})"
rm -rf /tmp/yay
run_as_user "git clone https://aur.archlinux.org/yay.git /tmp/yay" || { warn "git clone yay failed"; }
run_as_user "bash -lc 'cd /tmp/yay && makepkg -si --noconfirm' " > "${YAY_BUILD_LOG}" 2>&1 || warn "yay build failed — see ${YAY_BUILD_LOG}"
rm -rf /tmp/yay

# MangoWM dependencies
info "Installing MangoWM dependencies"
pacman -S --noconfirm --needed \
  wayland wayland-protocols libinput libdrm libxkbcommon \
  pixman libdisplay-info libliftoff hwdata pcre2 \
  xorg-xwayland libxcb xcb-util-wm xcb-util-renderutil

# install MangoWM & AUR packages via yay (as user), log results
info "Installing MangoWM and AUR packages via yay (this may take a while)"
run_as_user "yay -S --noconfirm mangowm-git rofi-wayland swaync swaylock-effects-git wlogout" > "${YAY_AUR_LOG}" 2>&1 || warn "AUR installs had issues — see ${YAY_AUR_LOG}"

# minimal toolset via pacman
info "Installing minimal toolset"
pacman -S --noconfirm --needed \
  foot waybar swaybg wl-clipboard wl-clip-persist \
  grim slurp xdg-desktop-portal xdg-desktop-portal-wlr \
  xdg-user-dirs brightnessctl pamixer pavucontrol

# pull mango config as the user
info "Pulling MangoWM config"
run_as_user "git clone https://github.com/DreamMaoMao/mango-config.git /home/${USERNAME}/.config/mango" || warn "Failed to git clone mango-config"
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/mango 2>/dev/null || true

# waybar config
info "Writing waybar config"
mkdir -p /home/${USERNAME}/.config/waybar
cat > /home/${USERNAME}/.config/waybar/config <<'WAYBAR'
{
  "layer":"top","position":"top","height":24,
  "modules-left":["custom/mango","clock"],
  "modules-right":["pulseaudio","network","cpu","memory","battery"],
  "custom/mango":{"format":" mango","tooltip":false},
  "clock":{"format":"{:%a %b %d  %H:%M}","tooltip":false},
  "cpu":{"format":"cpu {usage}%","interval":5},
  "memory":{"format":"mem {}%","interval":10},
  "network":{"format-wifi":"{essid}","format-ethernet":"eth","format-disconnected":"offline","tooltip":false},
  "pulseaudio":{"format":"vol {volume}%","format-muted":"muted","on-click":"pamixer -t"},
  "battery":{"format":"bat {capacity}%","format-charging":"chr {capacity}%"}
}
WAYBAR
cat > /home/${USERNAME}/.config/waybar/style.css <<'CSS'
*{font-family:monospace;font-size:12px;border:none;border-radius:0;min-height:0}
window#waybar{background:#000;color:#0f0}
#clock,#cpu,#memory,#network,#pulseaudio,#battery,#custom-mango{padding:0 8px;color:#0f0}
CSS
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config/waybar 2>/dev/null || true

# auto-launch mango on tty1
info "Configuring auto-launch on TTY1"
cat >> /home/${USERNAME}/.bash_profile <<'PROFILE'

# Launch MangoWM on TTY1 login
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  export XDG_SESSION_TYPE=wayland
  export XDG_CURRENT_DESKTOP=mango
  export MOZ_ENABLE_WAYLAND=1
  export QT_QPA_PLATFORM=wayland
  export SDL_VIDEODRIVER=wayland
  exec mango
fi
PROFILE
chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bash_profile 2>/dev/null || true
run_as_user "xdg-user-dirs-update" 2>/dev/null || true

# done
echo ""
echo "Install (chroot) complete. Check /root/yay-build.log and /root/yay-aur.log in the installed system for build logs."
CHROOT_EOF

chmod +x /mnt/root/chroot-install.sh
success "Chroot script written to /mnt/root/chroot-install.sh"

# RUN CHROOT
header "Running chroot stage"
command -v artix-chroot >/dev/null || die "artix-chroot not found (unexpected) — cannot continue."
artix-chroot /mnt /root/chroot-install.sh
success "Chroot stage finished."

# HOST-SIDE CLEANUP
if [[ -f "$PWFILE_HOST" ]]; then
    if command -v shred &>/dev/null; then shred -u "$PWFILE_HOST" || rm -f "$PWFILE_HOST"; else rm -f "$PWFILE_HOST"; fi
fi
rm -f /mnt/root/chroot-install.sh || true

# UNMOUNT & FINISH
trap - EXIT
header "Unmounting"
sync
umount -R /mnt || warn "Failed to unmount /mnt — unmount manually before reboot."
swapoff "$PART_SWAP" || warn "Failed to swapoff $PART_SWAP"

echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  All done. Remove USB and reboot.${RESET}"
echo -e "${GREEN}${BOLD}  Log: ${LOG}${RESET}"
echo -e "${GREEN}${BOLD}  Login: ${USERNAME} on TTY1 — Mango autostarts.${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo ""
