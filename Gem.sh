#!/usr/bin/env bash
set -euo pipefail

#############################################
# Artix Linux s6 + MangoWM One-Shot Installer
#    tailored for /dev/sda single-user setup
#############################################

# ---- CONFIGURATION ----
HOSTNAME="wade-artix"
USERNAME="wade"
PASSWORD="yup"      # <-- Set your user password here!
DISK="/dev/sda"
FILESYSTEM="ext4"
SWAP_SIZE="16G"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"
WIFI_SSID="DIRECT-NS-Hotspot"
WIFI_PASS="hahahehe"
HTTP_PROXY="http://192.168.49.1:8282"
HTTPS_PROXY="http://192.168.49.1:8282"
NO_PROXY="localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8"

BASE_PACKAGES=(
    base base-devel linux linux-firmware
    intel-ucode
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

LOGFILE="/root/artix-install.log"
FLAGBASE="/tmp/artixmango"

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

# ---- LOGGING & FLAGS ----
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo -e "\n\n!!! FAILURE at line ${LINENO}: ${BASH_COMMAND}\nSee $LOGFILE\n"; exit 1' ERR
step()   { echo -e "\n\033[1;32m== $*\033[0m"; }
flag()   { [ -f "${FLAGBASE}-$1" ]; }
mark()   { touch "${FLAGBASE}-$1"; }

# ---- PROXY ----
export http_proxy=$HTTP_PROXY HTTP_PROXY=$HTTP_PROXY
export https_proxy=$HTTPS_PROXY HTTPS_PROXY=$HTTPS_PROXY
export no_proxy=$NO_PROXY NO_PROXY=$NO_PROXY

# ---- NETWORK HELPERS ----
wifi_connect() {
    nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" 2>/dev/null || true
    sleep 4
}
check_net() {
    for i in {1..5}; do
        if curl -fsSL --proxy "$HTTP_PROXY" --max-time 15 https://archlinux.org &>/dev/null; then
            echo ">>> Network OK."
            return 0
        fi
        echo ">>> No internet (try $i/5), retrying WiFi"
        wifi_connect
    done
    echo "ERROR: No Internet, cannot continue."
    exit 1
}

# ---- STATE CHECKS ----
partitioned_ok() {
    [ -b "$EFI_PART" ] && [ -b "$SWAP_PART" ] && [ -b "$ROOT_PART" ]
}

formatted_ok() {
    blkid "$EFI_PART"   | grep -q 'FAT' &&
    blkid "$SWAP_PART"  | grep -q 'swap' &&
    blkid "$ROOT_PART"  | grep -qi "$FILESYSTEM"
}

mounted_ok() {
    mountpoint -q /mnt && mountpoint -q /mnt/boot/efi
}

# ---- PRE-FLIGHT ----
step "Artix + MangoWM 1-shot Installer (/dev/sda)"
[ -n "$PASSWORD" ] || { echo "ERROR: Set PASSWORD!"; exit 1; }
[ -b "$DISK" ]    || { echo "ERROR: Disk $DISK not found"; exit 1; }

if ! flag confirm; then
    echo "HOSTNAME: $HOSTNAME   USER: $USERNAME   DISK: $DISK"
    read -rp "Type 'DESTROY' to WIPE $DISK and install: " CONFIRM
    [[ "$CONFIRM" == "DESTROY" ]] || { echo "ABORT!"; exit 1; }
    mark confirm
fi

step "Checking network"
check_net

# ---- KEYRING / MIRROR ----
if ! flag keyring; then
    step "Keyring/mirror update"
    pacman -Sy --noconfirm artix-keyring artix-mirrorlist
    mark keyring
fi

# ---- PARTITION ----
if ! flag parts; then
    if partitioned_ok; then
        echo ">>> Partitions exist, skipping partitioning."
    else
        step "Partitioning ${DISK}"
        wipefs -af "$DISK"
        sfdisk --force --label gpt "$DISK" <<EOF
size=512MiB, type=uefi
size=$SWAP_SIZE, type=swap
size=+, type=linux
EOF
        partprobe "$DISK" || true
        sleep 2
    fi
    mark parts
fi

# ---- FORMAT ----
if ! flag format; then
    if formatted_ok; then
        echo ">>> Filesystems OK, skipping format."
    else
        step "Formatting"
        blkid "$EFI_PART"   | grep -q 'FAT'  || mkfs.fat -F32 -n EFI  "$EFI_PART"
        blkid "$SWAP_PART"  | grep -q 'swap' || mkswap    -L swap "$SWAP_PART"
        blkid "$ROOT_PART"  | grep -qi "$FILESYSTEM" || mkfs.$FILESYSTEM -F -L root "$ROOT_PART"
    fi
    mark format
fi

# ---- MOUNT ----
if ! flag mount; then
    if mounted_ok; then
        echo ">>> Mounts OK, skipping mounting."
    else
        step "Mounting"
        umount -R /mnt 2>/dev/null || true
        mkdir -p /mnt/boot/efi
        mount "$ROOT_PART" /mnt
        mkdir -p /mnt/boot/efi
        mount "$EFI_PART" /mnt/boot/efi
        swapon "$SWAP_PART" 2>/dev/null || true
    fi
    mark mount
fi

# ---- BASESTRAP ----
if ! flag base; then
    step "Installing base system"
    check_net
    basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm
    [[ -d /mnt/usr/bin ]] || { echo "basestrap failed!"; exit 1; }
    mark base
fi

# ---- FSTAB ----
if ! flag fstab; then
    fstabgen -U /mnt >> /mnt/etc/fstab
    mark fstab
fi

# ---- PROXY IN CHROOT ----
mkdir -p /mnt/etc/profile.d
cat > /mnt/etc/profile.d/proxy.sh <<EOF
export http_proxy="$HTTP_PROXY"
export HTTP_PROXY="$HTTP_PROXY"
export https_proxy="$HTTPS_PROXY"
export HTTPS_PROXY="$HTTPS_PROXY"
export no_proxy="$NO_PROXY"
export NO_PROXY="$NO_PROXY"
EOF
chmod 644 /mnt/etc/profile.d/proxy.sh

# ---- CHROOT SYSTEM CONFIG ----
if ! flag config; then
step "System config in chroot"
artix-chroot /mnt /bin/bash <<CHROOT1_EOF
set -euo pipefail
. /etc/profile.d/proxy.sh

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE"   > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME"     > /etc/hostname
cat > /etc/hosts <<EOF2
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF2

# Set root password
echo "root:$PASSWORD" | chpasswd

# Robust, idempotent group/user logic
for grp in wheel audio video input storage; do
    getent group "\$grp" >/dev/null || groupadd -r "\$grp"
done
id -u "$USERNAME" &>/dev/null && userdel -r "$USERNAME" || true
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
id "$USERNAME" || { echo "User $USERNAME was not created."; exit 1; }

echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Enable s6/elogind/connman
mkdir -p /etc/s6/adminsv/default/contents.d
for svc in dbus elogind connman; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
s6-db-reload || echo "Note: s6-db-reload skipped (in chroot ok)"

# GRUB install
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

CHROOT1_EOF
mark config
fi

# ---- CHROOT: AUR + MangoWM ----
if ! flag aur; then
step "AUR + MangoWM in user env"
artix-chroot /mnt /bin/bash <<CHROOT2_EOF
set -euo pipefail
. /etc/profile.d/proxy.sh

pacman -S --noconfirm --needed git base-devel
paru_ok=0
for attempt in 1 2 3; do
    rm -rf /tmp/paru
    if su - "$USERNAME" -c '
        export http_proxy="'"$HTTP_PROXY"'"
        export https_proxy="'"$HTTPS_PROXY"'"
        git clone https://aur.archlinux.org/paru.git /tmp/paru &&
        cd /tmp/paru && makepkg -si --noconfirm --needed
    '; then
        paru_ok=1
        break
    fi
    sleep 10
done
[[ \$paru_ok -eq 1 ]] || exit 1

su - "$USERNAME" -c '
    export http_proxy="'"$HTTP_PROXY"'"
    export https_proxy="'"$HTTPS_PROXY"'"
    paru -S --noconfirm --needed mangowm-git
'

mkdir -p "/home/$USERNAME/.config/mango"
cat > "/home/$USERNAME/.config/mango/config.conf" <<MANGO
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
MANGO

cat > "/home/$USERNAME/.bash_profile" <<'BASH_PROFILE'
if [ -z "\${WAYLAND_DISPLAY}" ] && [ "\${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config" "/home/$USERNAME/.bash_profile"

CHROOT2_EOF
mark aur
fi

# ---- UNMOUNT & FINAL ----
step "Unmounting"
umount -R /mnt || echo "umount error ignored"
swapoff -a

echo -e "\n=============================================="
echo "INSTALL COMPLETE — $(date)"
echo "Remove USB and reboot!"
echo "=============================================="
read -rp "Reboot now? (y/N): " REBOOT
[[ "$REBOOT" =~ ^[Yy]$ ]] && reboot || echo "Run 'reboot' when ready."
