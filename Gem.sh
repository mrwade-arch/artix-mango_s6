#!/usr/bin/env bash
set -euo pipefail

# ======= CONFIGURABLE VARIABLES =======
HOSTNAME="wade-artix"
USERNAME="wade"
PASSWORD="yup"       # <<< MUST SET BEFORE RUNNING
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
    intel-ucode
    pipewire wireplumber pipewire-pulse pipewire-alsa
    alsa-utils pavucontrol
    alacritty firefox
    thunar thunar-archive-plugin thunar-volman
    neovim wofi git sudo
    waybar mako swaybg
    xdg-desktop-portal-wlr xorg-xwayland
)

# ======= LOGGING =======
LOGFILE="/root/artix-install.log"
exec > >(tee -a "${LOGFILE}") 2>&1
echo "=== Install started: $(date) ==="

dmesg -n 1 2>/dev/null || true

trap '
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "SCRIPT FAILED at line ${LINENO}"
echo "Last command: ${BASH_COMMAND}"
echo "Full log: ${LOGFILE}"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
' ERR

# ======= HELPERS =======
flagfile=/tmp/artixmango
stepdone()   { [ -f "$flagfile-$1" ]; }
markdone()   { touch "$flagfile-$1"; }
cleardone()  { rm -f "$flagfile-"*; }
step() { echo -e "\n\033[1;32m>> $*\033[0m"; }

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

partition_exists() {
    lsblk -nlo NAME "${DISK}" | grep -q "^${1}$"
}

partition_formatted() {
    blkid "${DISK}$2" | grep -qi "$1"
}

mounted() {
    mountpoint -q "$1"
}

packages_installed() {
    # Call from inside chroot, checks if all base packages exist
    local missing=0
    for p in "${BASE_PACKAGES[@]}"; do
        pacman -Qq "$p" &>/dev/null || { echo "$p missing"; missing=1; }
    done
    return $missing
}

# ======= PRE-FLIGHT ===========================
step "Pre-flight checks"
[[ -z "${PASSWORD}" ]] && { echo "ERROR: PASSWORD is empty."; exit 1; }
[[ -b "${DISK}" ]] || { echo "ERROR: Disk ${DISK} not found."; exit 1; }

echo -e "\n=== Artix s6 + MangoWM Installer ==="
echo "Hostname: ${HOSTNAME} | User: ${USERNAME} | Disk: ${DISK}"
echo "Log: ${LOGFILE}"

if ! stepdone destroy; then
    read -r -p "Type 'DESTROY' to wipe ${DISK} and install (Ctrl+C to abort): " CONFIRM
    [[ "${CONFIRM}" == "DESTROY" ]] || { echo "Aborted."; exit 1; }
    markdone destroy
fi

# ======= PROXY SETUP ==========================
export http_proxy="${HTTP_PROXY}" HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"   NO_PROXY="${NO_PROXY}"
echo ">>> Proxy: ${HTTP_PROXY}"

# ======= WIFI/NET CHECK =======================
step "WiFi & Internet"
check_net

# ======= KEYRING/MIRRORS ======================
if ! stepdone keyring; then
    step "Keyring and mirrors"
    retry 3 5 pacman -Sy --noconfirm artix-keyring artix-mirrorlist
    markdone keyring
fi

# ======= DISK PREP ============================
if ! stepdone parts; then
    step "Partitioning ${DISK}"
    wipefs -af "${DISK}"
    sfdisk --force --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi
size=${SWAP_SIZE}, type=swap
size=+, type=linux
EOF
    partprobe "${DISK}" || true
    markdone parts
fi

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

# Wait for partitions to settle
sleep 2

# ======= FORMAT =================================
if ! stepdone format; then
    step "Formatting partitions"
    mkfs.fat -F32 -n EFI "${EFI_PART}"    # UEFI
    mkswap -L swap "${SWAP_PART}"
    mkfs.${FILESYSTEM} -F -L root "${ROOT_PART}"
    markdone format
else
    echo ">>> Skipping format: flag present"
fi

# ======= MOUNT ==================================
if ! stepdone mount; then
    step "Mounting"
    mount "${ROOT_PART}" /mnt
    mkdir -p /mnt/boot/efi
    mount "${EFI_PART}" /mnt/boot/efi
    swapon "${SWAP_PART}"
    markdone mount
fi

# Double check mounts:
mounted /mnt          || { echo "ERROR: /mnt not mounted."; exit 1; }
mounted /mnt/boot/efi || { echo "ERROR: /mnt/boot/efi not mounted."; exit 1; }
echo ">>> Mounts verified."

# ======= BASESTRAP ===============================
if ! stepdone base; then
    step "Installing base packages"
    check_net
    retry 3 10 basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm
    [[ -d /mnt/usr/bin ]] || { echo "ERROR: basestrap failed."; exit 1; }
    markdone base
else
    echo ">>> Base packages already installed (flag present)"
fi

# ======= FSTAB ===================================
if ! grep -q /mnt/etc/fstab /etc/mtab 2>/dev/null; then
    step "Generating fstab"
    fstabgen -U /mnt >> /mnt/etc/fstab
fi

# ======= PROXY SCRIPT IN CHROOT ==================
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

# ======= CHROOT & USER CONFIG ===================
if ! stepdone config; then
step "System config in chroot"
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
echo "${HOSTNAME}"     > /etc/hostname
cat > /etc/hosts <<EOF2
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF2

echo "--- Root password ---"
echo "root:${PASSWORD}" | chpasswd

echo "--- Groups/user ---"
for grp in wheel audio video input storage; do
    getent group "\$grp" >/dev/null || groupadd -r "\$grp"
done
id -u "${USERNAME}" &>/dev/null && userdel -r "${USERNAME}"
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
id "${USERNAME}" || { echo "User ${USERNAME} was not created."; exit 1; }
echo "User ${USERNAME} created and verified."

echo "--- sudo ---"
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "--- s6 services ---"
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connman; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
s6-db-reload || echo "Note: s6-db-reload skipped (normal in chroot)"

echo "--- GRUB ---"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

CHROOT1_EOF
markdone config
fi

# ======= CHROOT 2: AUR/USER DESKTOP =============
if ! stepdone aur; then
step "AUR + MangoWM as user"
artix-chroot /mnt /bin/bash <<CHROOT2_EOF
set -euo pipefail
. /etc/profile.d/proxy.sh

echo "--- paru ---"
pacman -S --noconfirm --needed git base-devel
paru_ok=0
for attempt in 1 2 3; do
    rm -rf /tmp/paru
    if su - "${USERNAME}" -c '
        export http_proxy="'"${HTTP_PROXY}"'"
        export https_proxy="'"${HTTPS_PROXY}"'"
        git clone https://aur.archlinux.org/paru.git /tmp/paru &&
        cd /tmp/paru && makepkg -si --noconfirm --needed
    '; then
        paru_ok=1
        break
    fi
    sleep 10
done
[[ \$paru_ok -eq 1 ]] || exit 1

echo "--- MangoWM ---"
su - "${USERNAME}" -c '
    export http_proxy="'"${HTTP_PROXY}"'"
    export https_proxy="'"${HTTPS_PROXY}"'"
    paru -S --noconfirm --needed mangowm-git
'

echo "--- MangoWM config ---"
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_CONFIG'
# MangoWM config
bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
bind=SUPER,f,togglefullscreen

exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse
exec-once=waybar &
exec-once=mako &
MANGO_CONFIG

cat > "/home/${USERNAME}/.bash_profile" <<'BASH_PROFILE'
if [ -z "\${WAYLAND_DISPLAY}" ] && [ "\${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config" "/home/${USERNAME}/.bash_profile"

CHROOT2_EOF
markdone aur
fi

# ======= UNMOUNT ================================
step "Unmounting"
umount -R /mnt || echo "WARN: umount had errors"
swapoff -a

echo -e "\n================================================"
echo "  INSTALL COMPLETE — $(date)"
echo "  Remove USB and reboot!"
echo "================================================"
read -r -p "Reboot now? (y/N): " REBOOT
[[ "${REBOOT}" =~ ^[Yy]$ ]] && reboot || echo "Run 'reboot' when ready."
