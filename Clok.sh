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

BASE_PACKAGES=(
    base base-devel linux linux-firmware
    s6 elogind-s6 dbus-s6 connman-s6
    grub efibootmgr os-prober dosfstools
    pipewire wireplumber pipewire-pulse pipewire-alsa
    alsa-utils pavucontrol
    alacritty firefox
    thunar thunar-archive-plugin thunar-volman
    neovim wofi git sudo
)
# ================================================================

if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: PASSWORD is empty. Set it before running."
    exit 1
fi

echo "=== Artix s6 + MangoWM Installer ==="
echo "This will COMPLETELY WIPE ${DISK} and install a fresh system."
echo "Hostname: ${HOSTNAME} | User: ${USERNAME} | WM: MangoWM (Wayland)"
#read -r -p "Type 'DESTROY' to continue (Ctrl+C to abort): " CONFIRM
#[[ "${CONFIRM}" == "DESTROY" ]] || { echo "Aborted."; exit 1; }

# ==================== PROXY ====================
export http_proxy="${HTTP_PROXY}"
export HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}"
export HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}"
export NO_PROXY="${NO_PROXY}"
echo ">>> Proxy enabled: ${HTTP_PROXY}"

# ==================== INTERNET CHECK ====================
echo "Checking internet connectivity..."
if ! curl -fsSL --proxy "${HTTP_PROXY}" --max-time 10 https://archlinux.org &>/dev/null; then
    echo "ERROR: No internet. Connect first (connman / iwctl)."
    exit 1
fi
echo "Internet OK."

# Only sync keyring and mirrorlist — NO full upgrade, which would cause a
# kernel/modules mismatch in the live environment and break modprobe vfat.
echo "Syncing keyring and mirrors..."
pacman -Sy --noconfirm artix-keyring artix-mirrorlist

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
