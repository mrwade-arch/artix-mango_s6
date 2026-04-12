#!/usr/bin/env bash
set -euo pipefail

# ================================================
# Artix Linux s6 + MangoWM One-Shot Installer
# ================================================

# ==================== CONFIGURABLE VARIABLES ====================
HOSTNAME="wade-artix"
USERNAME="wade"
PASSWORD="yup"  # <<< MUST BE SET BEFORE RUNNING
DISK="/dev/sda"
FILESYSTEM="ext4"
SWAP_SIZE="16G"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

HTTP_PROXY="http://192.168.49.1:8282"
HTTPS_PROXY="http://192.168.49.1:8282"
NO_PROXY="localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8"

WIFI_SSID="DIRECT-NS-Hotspot"
WIFI_PASS="hahahehe"

BASE_PACKAGES=(
    base base-devel linux linux-firmware
    s6 elogind-s6 dbus-s6 connman-s6
    grub efibootmgr os-prober dosfstools
    pipewire wireplumber pipewire-pulse pipewire-alsa
    alsa-utils pavucontrol
    alacritty firefox
    thunar thunar-archive-plugin thunar-volman
    neovim wofi git sudo
    waybar mako swaybg
    xdg-desktop-portal-wlr xorg-xwayland
)
# ================================================================

# ==================== LOGGING ====================
LOGFILE="/root/artix-install.log"
exec > >(tee -a "${LOGFILE}") 2>&1
echo "=== Install started: $(date) ==="

# Silence kernel log spam on live ISO
dmesg -n 1 2>/dev/null || true

# ==================== ERROR TRAP ====================
trap 'echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "SCRIPT FAILED at line ${LINENO}"
echo "Last command: ${BASH_COMMAND}"
echo "Full log: ${LOGFILE}"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"' ERR

# ==================== HELPERS ====================
retry() {
    local attempts=$1 delay=$2
    shift 2
    local i=0
    until "$@"; do
        i=$(( i + 1 ))
        if (( i >= attempts )); then
            echo "ERROR: '$*' failed after ${attempts} attempts."
            return 1
        fi
        echo ">>> Attempt ${i}/${attempts} failed. Retrying in ${delay}s..."
        sleep "${delay}"
    done
}

wifi_connect() {
    echo ">>> Connecting to WiFi: ${WIFI_SSID} (nmcli)..."
    nmcli device wifi connect "${WIFI_SSID}" password "${WIFI_PASS}" 2>/dev/null || true
    sleep 4
}

check_net() {
    local attempts=0 max=5
    while (( attempts < max )); do
        if curl -fsSL --proxy "${HTTP_PROXY}" --max-time 15 https://archlinux.org &>/dev/null; then
            echo ">>> Internet OK."
            return 0
        fi
        attempts=$(( attempts + 1 ))
        echo ">>> No internet (attempt ${attempts}/${max}). Reconnecting..."
        wifi_connect
    done
    echo "ERROR: Internet unavailable after ${max} attempts."
    exit 1
}

step() {
    echo ""
    echo "================================================================"
    echo "  STEP: $*"
    echo "================================================================"
}

# ==================== PRE-FLIGHT ====================
step "Pre-flight checks"
[[ -z "${PASSWORD}" ]] && { echo "ERROR: PASSWORD is empty."; exit 1; }
[[ -b "${DISK}" ]] || { echo "ERROR: Disk ${DISK} not found."; exit 1; }

echo "=== Artix s6 + MangoWM Installer ==="
echo "Hostname: ${HOSTNAME} | User: ${USERNAME} | Disk: ${DISK}"
echo "Log: ${LOGFILE}"
#read -r -p "Type 'DESTROY' to wipe ${DISK} and install (Ctrl+C to abort): " CONFIRM
#[[ "${CONFIRM}" == "DESTROY" ]] || { echo "Aborted."; exit 1; }

# ==================== PROXY ====================
export http_proxy="${HTTP_PROXY}" HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}" NO_PROXY="${NO_PROXY}"
echo ">>> Proxy: ${HTTP_PROXY}"

# ==================== WIFI + INTERNET ====================
step "WiFi and internet"
wifi_connect
check_net

# ==================== KEYRING + MIRRORS ====================
step "Keyring and mirrors"
# NO pacman -Syu — breaks live kernel module paths
retry 3 5 pacman -Sy --noconfirm artix-keyring artix-mirrorlist

# ==================== CLEAN SLATE ====================
step "Cleaning up previous attempts"
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

# ==================== PARTITIONING ====================
step "Partitioning ${DISK}"
wipefs -af "${DISK}"
sleep 1

sfdisk --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi
size=${SWAP_SIZE}, type=swap
size=+, type=linux
EOF

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

sleep 2
blockdev --rereadpt "${DISK}" 2>/dev/null || true
sleep 1

for part in "${EFI_PART}" "${SWAP_PART}" "${ROOT_PART}"; do
    [[ -b "${part}" ]] || { echo "ERROR: ${part} was not created."; exit 1; }
done
echo ">>> Partitions verified."

# ==================== FORMAT ====================
step "Formatting"
mkfs.fat -F32 -n EFI "${EFI_PART}"
mkswap -L swap "${SWAP_PART}"
mkfs."${FILESYSTEM}" -F -L root "${ROOT_PART}"

# ==================== MOUNT ====================
step "Mounting"
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi
swapon "${SWAP_PART}"

mountpoint -q /mnt          || { echo "ERROR: /mnt not mounted."; exit 1; }
mountpoint -q /mnt/boot/efi || { echo "ERROR: /mnt/boot/efi not mounted."; exit 1; }
echo ">>> Mounts verified."

# ==================== BASESTRAP ====================
step "Basestrap"
check_net
retry 3 10 basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm
[[ -d /mnt/usr/bin ]] || { echo "ERROR: basestrap failed."; exit 1; }
echo ">>> Base system verified."

fstabgen -U /mnt >> /mnt/etc/fstab
echo ">>> fstab generated."

# ==================== PROXY FOR INSTALLED SYSTEM ====================
mkdir -p /mnt/etc/profile.d
cat > /mnt/etc/profile.d/proxy.sh <<PROXY_EOF
#!/bin/sh
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
PROXY_EOF
chmod 644 /mnt/etc/profile.d/proxy.sh

# ==================== CHROOT 1: SYSTEM CONFIG ====================
# System config and user creation done separately from AUR builds
# so user existence is confirmed before any su attempts.
step "Chroot 1: system configuration"

artix-chroot /mnt /bin/bash <<CHROOT1_EOF
set -euo pipefail
. /etc/profile.d/proxy.sh

echo "--- Locale / timezone / hostname ---"
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

echo "--- Root password ---"
echo "root:${PASSWORD}" | chpasswd

echo "--- User: ${USERNAME} ---"
# Ensure groups exist before adding user
groupadd -r input   2>/dev/null || true
groupadd -r storage 2>/dev/null || true
# Remove user if leftover from a failed previous run, then recreate
userdel -r "${USERNAME}" 2>/dev/null || true
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
# Hard verify user exists before proceeding
id "${USERNAME}" || { echo "ERROR: User ${USERNAME} was not created."; exit 1; }
echo ">>> User ${USERNAME} verified."

echo "--- sudo ---"
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "--- s6 services ---"
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connmand; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
s6-db-reload || echo "WARN: s6-db-reload failed (non-fatal)"

echo "--- MangoWM config ---"
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_CONFIG'
# MangoWM config
# Terminal: alacritty | Launcher: wofi | SUPER = Mod4

bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
bind=SUPER,f,togglefullscreen

bind=ALT,Left,focusmon,left
bind=ALT,Right,focusmon,right
bind=ALT,Up,focusmon,up
bind=ALT,Down,focusmon,down

bind=CTRL,1,view,1
bind=CTRL,2,view,2
bind=CTRL,3,view,3
bind=CTRL,4,view,4
bind=CTRL,5,view,5
bind=CTRL,6,view,6
bind=CTRL,7,view,7
bind=CTRL,8,view,8
bind=CTRL,9,view,9

bind=ALT,1,tag,1
bind=ALT,2,tag,2
bind=ALT,3,tag,3
bind=ALT,4,tag,4
bind=ALT,5,tag,5
bind=ALT,6,tag,6
bind=ALT,7,tag,7
bind=ALT,8,tag,8
bind=ALT,9,tag,9

exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse
exec-once=waybar
exec-once=mako
exec-once=swaybg -i /home/${USERNAME}/Pictures/wallpaper.jpg
MANGO_CONFIG

cat > "/home/${USERNAME}/.bash_profile" <<'BASH_PROFILE'
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

chown -R "${USERNAME}:${USERNAME}" \
    "/home/${USERNAME}/.config" \
    "/home/${USERNAME}/.bash_profile"

echo "--- GRUB ---"
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=GRUB --recheck \
    || { echo "ERROR: grub-install failed."; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg \
    || { echo "ERROR: grub-mkconfig failed."; exit 1; }
echo ">>> GRUB installed."

echo "=== Chroot 1 complete ==="
CHROOT1_EOF

# ==================== CHROOT 2: AUR BUILDS ====================
# Separate chroot so user context is fully initialized before su
step "Chroot 2: AUR builds (paru + MangoWM)"

artix-chroot /mnt /bin/bash <<CHROOT2_EOF
set -euo pipefail
. /etc/profile.d/proxy.sh

# Confirm user exists before attempting su
id "${USERNAME}" || { echo "ERROR: User ${USERNAME} missing."; exit 1; }

echo "--- paru ---"
pacman -S --noconfirm --needed git base-devel

paru_ok=0
for attempt in 1 2 3; do
    echo ">>> paru attempt \${attempt}/3..."
    rm -rf /tmp/paru
    if su - "${USERNAME}" -c '
        set -e
        export http_proxy="'"${HTTP_PROXY}"'"
        export https_proxy="'"${HTTPS_PROXY}"'"
        git clone https://aur.archlinux.org/paru.git /tmp/paru
        cd /tmp/paru
        makepkg -si --noconfirm --needed
    '; then
        paru_ok=1
        break
    fi
    echo ">>> paru attempt \${attempt} failed. Waiting 10s..."
    sleep 10
done
rm -rf /tmp/paru
[[ \${paru_ok} -eq 1 ]] || { echo "ERROR: paru failed after 3 attempts."; exit 1; }
echo ">>> paru installed."

echo "--- MangoWM ---"
mango_ok=0
for attempt in 1 2 3; do
    echo ">>> MangoWM attempt \${attempt}/3..."
    if su - "${USERNAME}" -c '
        export http_proxy="'"${HTTP_PROXY}"'"
        export https_proxy="'"${HTTPS_PROXY}"'"
        paru -S --noconfirm --needed mangowm-git
    '; then
        mango_ok=1
        break
    fi
    echo ">>> MangoWM attempt \${attempt} failed. Waiting 15s..."
    sleep 15
done
[[ \${mango_ok} -eq 1 ]] || { echo "ERROR: MangoWM failed after 3 attempts."; exit 1; }
echo ">>> MangoWM installed."

echo "--- Cleanup ---"
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*

echo "=== Chroot 2 complete ==="
CHROOT2_EOF

# ==================== UNMOUNT ====================
step "Unmounting"
umount -R /mnt || echo "WARN: umount had errors"
swapoff -a

echo ""
echo "================================================"
echo "  INSTALL COMPLETE — $(date)"
echo "  Log: ${LOGFILE}"
echo "  Remove USB and reboot!"
echo "================================================"
read -r -p "Reboot now? (y/N): " REBOOT
[[ "${REBOOT}" =~ ^[Yy]$ ]] && reboot || echo "Run 'reboot' when ready."
        echo ">>> Attempt ${i}/${attempts} failed. Retrying in ${delay}s..."
        sleep "${delay}"
    done
}

wifi_connect() {
    echo ">>> Connecting to WiFi: ${WIFI_SSID}..."
    nmcli device wifi connect "${WIFI_SSID}" password "${WIFI_PASS}" || true
    sleep 4
}

check_net() {
    local attempts=0
    local max=10
    while (( attempts < max )); do
        if curl -fsSL --proxy "${HTTP_PROXY}" --max-time 15 https://archlinux.org &>/dev/null; then
            echo ">>> Internet OK."
            return 0
        fi
        attempts=$(( attempts + 1 ))
        echo ">>> No internet (attempt ${attempts}/${max}). Reconnecting WiFi..."
        wifi_connect
    done
    echo "ERROR: Internet unavailable after ${max} attempts."
    exit 1
}

step() {
    echo ""
    echo "================================================================"
    echo "  STEP: $*"
    echo "================================================================"
}

# ==================== PRE-FLIGHT ====================
step "Pre-flight checks"

if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: PASSWORD is empty. Set it before running."
    exit 1
fi

# Verify nmcli is available
if ! command -v nmcli &>/dev/null; then
    echo "ERROR: nmcli not found. WiFi reconnection will not work."
    exit 1
fi

# Verify disk exists
if [[ ! -b "${DISK}" ]]; then
    echo "ERROR: Disk ${DISK} not found. Check DISK variable."
    exit 1
fi

echo "=== Artix s6 + MangoWM Installer ==="
echo "Hostname: ${HOSTNAME} | User: ${USERNAME} | Disk: ${DISK} | WM: MangoWM"
echo "Log file: ${LOGFILE}"
#read -r -p "Type 'DESTROY' to wipe ${DISK} and install (Ctrl+C to abort): " CONFIRM
#[[ "${CONFIRM}" == "DESTROY" ]] || { echo "Aborted."; exit 1; }

# ==================== PROXY ====================
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
echo ">>> Proxy: ${HTTP_PROXY}"

# ==================== WIFI + INTERNET ====================
step "WiFi and internet"
wifi_connect
check_net

# ==================== KEYRING + MIRRORS ====================
step "Keyring and mirrors"
# NO pacman -Syu — full upgrade breaks live kernel module paths
retry 3 5 pacman -Sy --noconfirm artix-keyring artix-mirrorlist

# ==================== CLEAN SLATE ====================
step "Cleaning up any previous install attempt"
swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

# ==================== DISK PARTITIONING ====================
step "Partitioning ${DISK}"
wipefs -af "${DISK}"
sleep 1

sfdisk --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi
size=${SWAP_SIZE}, type=swap
size=+, type=linux
EOF

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

sleep 2
blockdev --rereadpt "${DISK}" 2>/dev/null || true
sleep 1

# Verify partitions actually exist before continuing
for part in "${EFI_PART}" "${SWAP_PART}" "${ROOT_PART}"; do
    if [[ ! -b "${part}" ]]; then
        echo "ERROR: Partition ${part} was not created. Aborting."
        exit 1
    fi
done
echo ">>> All partitions verified."

# ==================== FORMAT ====================
step "Formatting partitions"
mkfs.fat -F32 -n EFI "${EFI_PART}"
mkswap -L swap "${SWAP_PART}"
mkfs."${FILESYSTEM}" -F -L root "${ROOT_PART}"

# ==================== MOUNT ====================
step "Mounting filesystems"
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi
swapon "${SWAP_PART}"

# Verify mounts
mountpoint -q /mnt        || { echo "ERROR: /mnt not mounted."; exit 1; }
mountpoint -q /mnt/boot/efi || { echo "ERROR: /mnt/boot/efi not mounted."; exit 1; }
echo ">>> Mounts verified."

# ==================== BASESTRAP ====================
step "Installing base system (basestrap)"
check_net
retry 3 10 basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm

# Verify base install has something in it
[[ -d /mnt/usr/bin ]] || { echo "ERROR: basestrap appears to have failed — /mnt/usr/bin missing."; exit 1; }
echo ">>> Base system verified."

step "Generating fstab"
fstabgen -U /mnt >> /mnt/etc/fstab
echo ">>> fstab:"
cat /mnt/etc/fstab

# ==================== PROXY FOR INSTALLED SYSTEM ====================
mkdir -p /mnt/etc/profile.d
cat > /mnt/etc/profile.d/proxy.sh <<PROXY_EOF
#!/bin/sh
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
PROXY_EOF
chmod 644 /mnt/etc/profile.d/proxy.sh

# ==================== CHROOT ====================
step "Entering chroot"

artix-chroot /mnt /bin/bash <<CHROOT_EOF
set -euo pipefail

. /etc/profile.d/proxy.sh

echo "--- Locale / timezone / hostname ---"
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

echo "--- Accounts ---"
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "--- s6 services ---"
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connmand; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
s6-db-reload || echo "WARN: s6-db-reload failed (non-fatal, services will be available after reboot)"

echo "--- paru AUR helper ---"
pacman -S --noconfirm --needed git base-devel

# Retry paru clone + build up to 3 times in case of network blip
paru_installed=0
for attempt in 1 2 3; do
    echo ">>> paru install attempt \${attempt}/3..."
    rm -rf /tmp/paru
    if git clone https://aur.archlinux.org/paru.git /tmp/paru; then
        if su - "${USERNAME}" -c 'cd /tmp/paru && makepkg -si --noconfirm --needed'; then
            paru_installed=1
            break
        fi
    fi
    echo ">>> paru attempt \${attempt} failed. Waiting 10s..."
    sleep 10
done
rm -rf /tmp/paru
if [[ \${paru_installed} -eq 0 ]]; then
    echo "ERROR: paru failed to install after 3 attempts."
    exit 1
fi
echo ">>> paru installed successfully."

echo "--- MangoWM ---"
mango_installed=0
for attempt in 1 2 3; do
    echo ">>> MangoWM install attempt \${attempt}/3..."
    if su - "${USERNAME}" -c "paru -S --noconfirm --needed mangowm-git"; then
        mango_installed=1
        break
    fi
    echo ">>> MangoWM attempt \${attempt} failed. Waiting 15s..."
    sleep 15
done
if [[ \${mango_installed} -eq 0 ]]; then
    echo "ERROR: MangoWM failed to install after 3 attempts."
    exit 1
fi
echo ">>> MangoWM installed successfully."

echo "--- MangoWM config ---"
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_CONFIG'
# MangoWM config
# Terminal: alacritty | Launcher: wofi | SUPER = Mod4

bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
bind=SUPER,f,togglefullscreen

bind=ALT,Left,focusmon,left
bind=ALT,Right,focusmon,right
bind=ALT,Up,focusmon,up
bind=ALT,Down,focusmon,down

bind=CTRL,1,view,1
bind=CTRL,2,view,2
bind=CTRL,3,view,3
bind=CTRL,4,view,4
bind=CTRL,5,view,5
bind=CTRL,6,view,6
bind=CTRL,7,view,7
bind=CTRL,8,view,8
bind=CTRL,9,view,9

bind=ALT,1,tag,1
bind=ALT,2,tag,2
bind=ALT,3,tag,3
bind=ALT,4,tag,4
bind=ALT,5,tag,5
bind=ALT,6,tag,6
bind=ALT,7,tag,7
bind=ALT,8,tag,8
bind=ALT,9,tag,9

exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse
MANGO_CONFIG

cat > "/home/${USERNAME}/.bash_profile" <<'BASH_PROFILE'
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

chown -R "${USERNAME}:${USERNAME}" \
    "/home/${USERNAME}/.config" \
    "/home/${USERNAME}/.bash_profile"

echo "--- GRUB ---"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck \
    || { echo "ERROR: grub-install failed."; exit 1; }
grub-mkconfig -o /boot/grub/grub.cfg \
    || { echo "ERROR: grub-mkconfig failed."; exit 1; }
echo ">>> GRUB installed."

echo "--- Cleanup ---"
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*

echo "=== Chroot complete ==="
CHROOT_EOF

# ==================== UNMOUNT ====================
step "Unmounting"
umount -R /mnt || echo "WARN: umount had errors (may be fine)"
swapoff -a

echo ""
echo "================================================================"
echo "  INSTALL COMPLETE — $(date)"
echo "  Full log: ${LOGFILE}"
echo "================================================================"
read -r -p "Reboot now? (y/N): " REBOOT
[[ "${REBOOT}" =~ ^[Yy]$ ]] && reboot || echo "Run 'reboot' when ready."

# ==================== DISK PARTITIONING ====================
echo "Partitioning ${DISK} (WARNING: all data will be lost)..."
wipefs -af "${DISK}"
sleep 1

# GPT: 512M EFI + SWAP + ROOT
# size=+ means "use all remaining space"
sfdisk --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi
size=${SWAP_SIZE}, type=swap
size=+, type=linux
EOF

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

# Let kernel catch up with new partition table
sleep 2
blockdev --rereadpt "${DISK}" 2>/dev/null || true
sleep 1

# ==================== FORMAT ====================
echo "Formatting partitions..."
mkfs.fat -F32 -n EFI "${EFI_PART}"
mkswap -L swap "${SWAP_PART}"
mkfs."${FILESYSTEM}" -F -L root "${ROOT_PART}"

# ==================== MOUNT ====================
# EFI mounted at /boot/efi to match grub-install --efi-directory=/boot/efi
echo "Mounting filesystems..."
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi
swapon "${SWAP_PART}"

# ==================== BASESTRAP ====================
echo "Installing base system..."
basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm

echo "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab

# ==================== PROXY FOR INSTALLED SYSTEM ====================
mkdir -p /mnt/etc/profile.d
cat > /mnt/etc/profile.d/proxy.sh <<PROXY_EOF
#!/bin/sh
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
PROXY_EOF
chmod 644 /mnt/etc/profile.d/proxy.sh

# ==================== CHROOT ====================
echo "Entering chroot..."

artix-chroot /mnt /bin/bash <<CHROOT_EOF
set -euo pipefail

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
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# ── s6 services ───────────────────────────────────────────────────────────
# Use s6-db-reload (not s6-rc-compile directly) per Artix wiki
echo "Enabling s6-rc services..."
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connmand; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
s6-db-reload

# ── paru ──────────────────────────────────────────────────────────────────
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
su - "${USERNAME}" -c "paru -S --noconfirm --needed mangowm-git"

# ── MangoWM config ────────────────────────────────────────────────────────
echo "Creating MangoWM config..."
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_CONFIG'
# MangoWM config
# Terminal: alacritty | Launcher: wofi | SUPER = Mod4

bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
bind=SUPER,f,togglefullscreen

bind=ALT,Left,focusmon,left
bind=ALT,Right,focusmon,right
bind=ALT,Up,focusmon,up
bind=ALT,Down,focusmon,down

bind=CTRL,1,view,1
bind=CTRL,2,view,2
bind=CTRL,3,view,3
bind=CTRL,4,view,4
bind=CTRL,5,view,5
bind=CTRL,6,view,6
bind=CTRL,7,view,7
bind=CTRL,8,view,8
bind=CTRL,9,view,9

bind=ALT,1,tag,1
bind=ALT,2,tag,2
bind=ALT,3,tag,3
bind=ALT,4,tag,4
bind=ALT,5,tag,5
bind=ALT,6,tag,6
bind=ALT,7,tag,7
bind=ALT,8,tag,8
bind=ALT,9,tag,9

exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse
MANGO_CONFIG

# ── Autostart on tty1 ─────────────────────────────────────────────────────
cat > "/home/${USERNAME}/.bash_profile" <<'BASH_PROFILE'
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

chown -R "${USERNAME}:${USERNAME}" \
    "/home/${USERNAME}/.config" \
    "/home/${USERNAME}/.bash_profile"

# ── GRUB (UEFI) ───────────────────────────────────────────────────────────
echo "Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# ── Cleanup ───────────────────────────────────────────────────────────────
echo "Cleanup..."
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*

echo "=== Chroot complete ==="
CHROOT_EOF

# ==================== UNMOUNT ====================
echo "Unmounting..."
umount -R /mnt
swapoff -a

echo "Done! Ready to reboot."
read -r -p "Reboot now? (y/N): " REBOOT
[[ "${REBOOT}" =~ ^[Yy]$ ]] && reboot || echo "Run 'reboot' when ready."

# ==================== DISK PARTITIONING ====================
echo "Partitioning ${DISK} (WARNING: all data will be lost)..."
wipefs -af "${DISK}"
sleep 1

if [[ "${UEFI}" == "yes" ]]; then
    sfdisk --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi
size=${SWAP_SIZE}, type=swap
size=+, type=linux
EOF
    EFI_PART="${DISK}1"
    SWAP_PART="${DISK}2"
    ROOT_PART="${DISK}3"
else
    sfdisk --label dos "${DISK}" <<EOF
size=${SWAP_SIZE}, type=82
size=+, type=83
EOF
    EFI_PART=""
    SWAP_PART="${DISK}1"
    ROOT_PART="${DISK}2"
fi

# Let the kernel catch up with the new partition table
sleep 2
blockdev --rereadpt "${DISK}" 2>/dev/null || true
sleep 1

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

# ==================== PROXY FOR INSTALLED SYSTEM ====================
mkdir -p /mnt/etc/profile.d
cat > /mnt/etc/profile.d/proxy.sh <<PROXY_EOF
#!/bin/sh
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
PROXY_EOF
chmod 644 /mnt/etc/profile.d/proxy.sh

# ==================== CHROOT ====================
echo "Entering chroot..."

artix-chroot /mnt /bin/bash <<CHROOT_EOF
set -euo pipefail

. /etc/profile.d/proxy.sh

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

echo "Creating accounts..."
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "Enabling s6-rc services..."
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connmand; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
s6-rc-compile /etc/s6/rc/compiled /etc/s6/adminsv || true

echo "Installing paru..."
pacman -S --noconfirm --needed git base-devel
su - "${USERNAME}" -c '
    git clone https://aur.archlinux.org/paru.git /tmp/paru
    cd /tmp/paru
    makepkg -si --noconfirm --needed
    rm -rf /tmp/paru
'

echo "Installing MangoWM..."
su - "${USERNAME}" -c "paru -S --noconfirm --needed mangowm"

echo "Creating MangoWM config..."
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_CONFIG'
# MangoWM config
# Terminal: alacritty | Launcher: wofi | SUPER = Mod4

bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
bind=SUPER,f,togglefullscreen

bind=ALT,Left,focusmon,left
bind=ALT,Right,focusmon,right
bind=ALT,Up,focusmon,up
bind=ALT,Down,focusmon,down

bind=CTRL,1,view,1
bind=CTRL,2,view,2
bind=CTRL,3,view,3
bind=CTRL,4,view,4
bind=CTRL,5,view,5
bind=CTRL,6,view,6
bind=CTRL,7,view,7
bind=CTRL,8,view,8
bind=CTRL,9,view,9

bind=ALT,1,tag,1
bind=ALT,2,tag,2
bind=ALT,3,tag,3
bind=ALT,4,tag,4
bind=ALT,5,tag,5
bind=ALT,6,tag,6
bind=ALT,7,tag,7
bind=ALT,8,tag,8
bind=ALT,9,tag,9

exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse
MANGO_CONFIG

cat > "/home/${USERNAME}/.bash_profile" <<'BASH_PROFILE'
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config" "/home/${USERNAME}/.bash_profile"

echo "Installing GRUB..."
if [[ "${UEFI}" == "yes" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
else
    grub-install --target=i386-pc "${DISK}"
fi
grub-mkconfig -o /boot/grub/grub.cfg

echo "Cleanup..."
pacman -Scc --noconfirm
rm -rf /var/cache/pacman/pkg/*

echo "=== Chroot complete ==="
CHROOT_EOF

# ==================== UNMOUNT ====================
echo "Unmounting..."
umount -R /mnt
swapoff -a

echo "Done! Ready to reboot."
read -r -p "Reboot now? (y/N): " REBOOT
[[ "${REBOOT}" =~ ^[Yy]$ ]] && reboot || echo "Run 'reboot' when ready."
