#!/usr/bin/env bash
set -euo pipefail

# ================================================
# Artix Linux s6 + MangoWM One-Shot Installer (Final Verified)
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
# Resume/Skip logic using flags in /tmp
skip_step() { [[ -f "/tmp/step_$1" ]]; }
mark_done() { touch "/tmp/step_$1"; }

retry() {
    local attempts=$1 delay=$2
    shift 2
    local i=0
    until "$@"; do
        i=$(( i + 1 ))
        if (( i >= attempts )); then
            echo "ERROR: '\''$*'\'' failed after ${attempts} attempts."
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
read -r -p "Type 'DESTROY' to wipe ${DISK} and install (Ctrl+C to abort): " CONFIRM
[[ "${CONFIRM}" == "DESTROY" ]] || { echo "Aborted."; exit 1; }

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
retry 3 5 pacman -Sy --noconfirm artix-keyring artix-mirrorlist

# ==================== CLEAN SLATE ====================
step "Cleaning up previous attempts"
swapoff -a 2>/dev/null || true
fuser -kvm /mnt 2>/dev/null || true # Kill any process locking the mount
umount -R /mnt 2>/dev/null || true
sleep 1

# ==================== PARTITIONING ====================
if ! skip_step "parts"; then
    step "Partitioning ${DISK}"
    wipefs -af "${DISK}"
    sleep 1

    # FIXED: Added --force to resolve "Disk currently in use" error
    sfdisk --force --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi
size=${SWAP_SIZE}, type=swap
size=+, type=linux
EOF
    mark_done "parts"
fi

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"

sleep 2
blockdev --rereadpt "${DISK}" 2>/dev/null || true
sleep 1

# ==================== FORMAT ====================
if ! skip_step "format"; then
    step "Formatting"
    mkfs.fat -F32 -n EFI "${EFI_PART}"
    mkswap -L swap "${SWAP_PART}"
    mkfs."${FILESYSTEM}" -F -L root "${ROOT_PART}"
    mark_done "format"
fi

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
if ! skip_step "base"; then
    step "Basestrap"
    check_net
    retry 3 10 basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm
    [[ -d /mnt/usr/bin ]] || { echo "ERROR: basestrap failed."; exit 1; }
    mark_done "base"
fi

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

# ==================== CHROOT 1: SYSTEM CONFIG ====================
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
# FIXED: Comprehensive group creation loop
for grp in wheel audio video input storage; do
    groupadd -r "\$grp" 2>/dev/null || true
done

userdel -r "${USERNAME}" 2>/dev/null || true
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd

# FIXED: Added sleep for DB sync before verification
sleep 1
id "${USERNAME}" || { echo "ERROR: User ${USERNAME} was not created."; exit 1; }
echo ">>> User ${USERNAME} verified."

echo "--- sudo ---"
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

echo "--- s6 services ---"
mkdir -p /etc/s6/adminsv/default/contents.d
# FIXED: Corrected service names (connman instead of connmand)
for svc in dbus elogind connman; do
    touch "/etc/s6/adminsv/default/contents.d/\${svc}"
done
s6-db-reload || echo "Note: s6-db-reload skipped (normal in chroot)"

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
if [ -z "${WAYLAND_DISPLAY}" ] && [ "${XDG_VTNR}" -eq 1 ]; then
    exec mango
fi
BASH_PROFILE

chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config" "/home/${USERNAME}/.bash_profile"

echo "--- GRUB ---"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

echo "=== Chroot 1 complete ==="
CHROOT1_EOF

# ==================== CHROOT 2: AUR BUILDS ====================
step "Chroot 2: AUR builds (paru + MangoWM)"

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
        git clone https://aur.archlinux.org/paru.git /tmp/paru && cd /tmp/paru && makepkg -si --noconfirm --needed
    '; then
        paru_ok=1
        break
    fi
    sleep 10
done
[[ \${paru_ok} -eq 1 ]] || exit 1

echo "--- MangoWM ---"
su - "${USERNAME}" -c '
    export http_proxy="'"${HTTP_PROXY}"'"
    export https_proxy="'"${HTTPS_PROXY}"'"
    paru -S --noconfirm --needed mangowm-git
'

echo "=== Chroot 2 complete ==="
CHROOT2_EOF

# ==================== UNMOUNT ====================
step "Unmounting"
umount -R /mnt || echo "WARN: umount had errors"
swapoff -a

echo ""
echo "================================================"
echo "  INSTALL COMPLETE — $(date)"
echo "  Remove USB and reboot!"
echo "================================================"
read -r -p "Reboot now? (y/N): " REBOOT
[[ "${REBOOT}" =~ ^[Yy]$ ]] && reboot || echo "Run 'reboot' when ready."
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
#read -r -p "Type 'DESTROY' to wipe ${DISK} and install (Ctrl+C to abort): " CONFIRM
#[[ "${CONFIRM}" == "DESTROY" ]] || { echo "Aborted."; exit 1; }

export http_proxy="${HTTP_PROXY}" HTTP_PROXY="${HTTP_PROXY}"
export https_proxy="${HTTPS_PROXY}" HTTPS_PROXY="${HTTPS_PROXY}"
export no_proxy="${NO_PROXY}" NO_PROXY="${NO_PROXY}"

# ==================== DISK PREP ====================
if ! skip_step "parts"; then
    step "Partitioning ${DISK}"
    wipefs -af "${DISK}"
    sfdisk --label gpt "${DISK}" <<EOF
size=512MiB, type=uefi
size=${SWAP_SIZE}, type=swap
size=+, type=linux
EOF
    mark_done "parts"
fi

EFI_PART="${DISK}1"
SWAP_PART="${DISK}2"
ROOT_PART="${DISK}3"
sleep 2

if ! skip_step "format"; then
    step "Formatting"
    mkfs.fat -F32 -n EFI "${EFI_PART}"
    mkswap -L swap "${SWAP_PART}"
    mkfs."${FILESYSTEM}" -F -L root "${ROOT_PART}"
    mark_done "format"
fi

# ==================== MOUNTING ====================
step "Mounting"
mount "${ROOT_PART}" /mnt
mkdir -p /mnt/boot/efi
mount "${EFI_PART}" /mnt/boot/efi
swapon "${SWAP_PART}"

# ==================== INSTALLATION ====================
if ! skip_step "base"; then
    step "Basestrap"
    check_net
    retry 3 10 basestrap /mnt "${BASE_PACKAGES[@]}" --noconfirm
    mark_done "base"
fi

fstabgen -U /mnt >> /mnt/etc/fstab

# ==================== CHROOT 1: SYSTEM ====================
step "Chroot 1: System Config"
artix-chroot /mnt /bin/bash <<CHROOT1_EOF
set -euo pipefail

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME}" > /etc/hostname

echo "root:${PASSWORD}" | chpasswd

echo "--- User and Groups ---"
for grp in wheel audio video input storage; do
    groupadd -r "\$grp" 2>/dev/null || true
done
useradd -m -G wheel,audio,video,input,storage -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
sleep 1
id "${USERNAME}"

echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel

echo "--- s6 Services ---"
mkdir -p /etc/s6/adminsv/default/contents.d
# FIXED: connman instead of connmand
for svc in dbus elogind connman; do
    touch "/etc/s6/adminsv/default/contents.d/\$svc"
done
# This will warn in chroot but allows the system to compile on boot
s6-db-reload || echo "Note: s6-db-reload skipped (normal in chroot)"

echo "--- GRUB ---"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg
CHROOT1_EOF

# ==================== CHROOT 2: AUR ====================
step "Chroot 2: AUR Builds"
artix-chroot /mnt /bin/bash <<CHROOT2_EOF
set -euo pipefail

echo "--- paru ---"
paru_ok=0
for attempt in 1 2 3; do
    rm -rf /tmp/paru
    if su - "${USERNAME}" -c '
        export http_proxy="${HTTP_PROXY}"
        export https_proxy="${HTTPS_PROXY}"
        git clone https://aur.archlinux.org/paru.git /tmp/paru && cd /tmp/paru && makepkg -si --noconfirm
    '; then
        paru_ok=1
        break
    fi
    sleep 5
done
[[ \$paru_ok -eq 1 ]] || exit 1

echo "--- MangoWM ---"
su - "${USERNAME}" -c '
    export http_proxy="${HTTP_PROXY}"
    export https_proxy="${HTTPS_PROXY}"
    paru -S --noconfirm --needed mangowm-git
'

# Config setup
mkdir -p "/home/${USERNAME}/.config/mango"
cat > "/home/${USERNAME}/.config/mango/config.conf" <<'MANGO_EOF'
bind=SUPER,Return,spawn,alacritty
bind=SUPER,d,spawn,wofi --show drun
bind=SUPER,q,killclient
bind=SUPER+SHIFT,q,quit
exec-once=pipewire
exec-once=wireplumber
exec-once=pipewire-pulse
exec-once=waybar &
exec-once=mako &
MANGO_EOF
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}/.config"
CHROOT2_EOF

step "Done. Unmounting..."
umount -R /mnt
swapoff -a
echo "Install Finished. Reboot and login as ${USERNAME}."

# Determine partition prefix (for nvme/mmcblk drives)
PART_PREFIX=""
if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
    PART_PREFIX="p"
fi

EFI_PART="${DISK}${PART_PREFIX}1"
SWAP_PART="${DISK}${PART_PREFIX}2"
ROOT_PART="${DISK}${PART_PREFIX}3"

# Zap existing partition structures
sgdisk -Z "$DISK"

if [[ "$UEFI" == "yes" ]]; then
    # Partition 1: 512M EFI
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
    # Partition 2: Swap
    sgdisk -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"Linux Swap" "$DISK"
    # Partition 3: Root (remainder)
    sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux Root" "$DISK"
    
    echo "Formatting EFI partition..."
    mkfs.vfat -F32 "$EFI_PART"
else
    echo "ERROR: This script is explicitly configured for UEFI only per requirements."
    exit 1
fi

echo "Setting up swap..."
mkswap "$SWAP_PART"
swapon "$SWAP_PART"

echo "Formatting root partition as $FILESYSTEM..."
if [[ "$FILESYSTEM" == "ext4" ]]; then
    mkfs.ext4 -F "$ROOT_PART"
else
    echo "Unsupported filesystem in config. Exiting."
    exit 1
fi

echo "Mounting root partition..."
mount "$ROOT_PART" /mnt

echo "Mounting EFI partition..."
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

# ==============================================================================
# BASE SYSTEM INSTALLATION
# ==============================================================================
echo "Enabling Artix Universe repository for wider software availability..."
cat << EOF >> /etc/pacman.conf

[universe]
Server = https://universe.artixlinux.org/\$arch
Server = https://mirror1.artixlinux.org/universe/\$arch
Server = https://mirror.pascalpuffke.de/artix-linux/universe/\$arch
Server = https://artixlinux.qontinuum.space/artixlinux/universe/os/\$arch
Server = https://mirror1.cl.netactuate.com/artix/universe/\$arch
Server = https://ftp.crifo.org/artix-linux/universe/\$arch
EOF

echo "Updating live system keyring and mirrors..."
pacman -Sy --noconfirm artix-keyring archlinux-keyring

echo "Installing base system and s6 packages..."
# Installing base, kernel, s6 init, basic networking, text editor
basestrap /mnt base base-devel s6 elogind-s6 linux linux-firmware linux-headers \
    neovim vim git wget curl NetworkManager NetworkManager-s6 \
    dbus dbus-s6 grub efibootmgr sudo openssh openssh-s6 pipewire pipewire-pulse wireplumber

echo "Generating fstab..."
fstabgen -U /mnt >> /mnt/etc/fstab

# ==============================================================================
# CHROOT ENVIRONMENT SETUP
# ==============================================================================
echo "Preparing chroot configuration..."

# Generate hashed password to pass securely
HASHED_PASS=$(openssl passwd -6 "$PASSWORD")

# Create a config file for the chroot script to source
cat << EOF > /mnt/tmp/install_config.env
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
FULL_NAME="$FULL_NAME"
HASHED_PASS='$HASHED_PASS'
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
KEYMAP="$KEYMAP"
EOF

# Create the chroot execution script
cat << 'CHROOT_EOF' > /mnt/tmp/install_chroot.sh
#!/usr/bin/env bash
set -euo pipefail

# Load config
source /tmp/install_config.env

echo "-> Setting Timezone..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "-> Setting Locale..."
sed -i "s/^#\($LOCALE UTF-8\)/\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "-> Setting Keymap..."
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "-> Setting Hostname..."
echo "$HOSTNAME" > /etc/hostname
cat << HOSTS_EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain   $HOSTNAME
HOSTS_EOF

echo "-> Configuring Users and Passwords..."
# Root password
echo "root:$HASHED_PASS" | chpasswd -e

# User creation
useradd -m -G wheel,video,audio,input,storage -c "$FULL_NAME" -s /bin/bash "$USERNAME"
echo "$USERNAME:$HASHED_PASS" | chpasswd -e

# Sudo rights
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "-> Configuring Bootloader (GRUB)..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

echo "-> Configuring s6-rc services..."
# Create necessary touch files to enable services in s6
mkdir -p /etc/s6/adminsv/default/contents.d
touch /etc/s6/adminsv/default/contents.d/NetworkManager
touch /etc/s6/adminsv/default/contents.d/sshd
touch /etc/s6/adminsv/default/contents.d/elogind

echo "-> Enabling Artix Universe and Arch repos inside chroot..."
cat << PACMAN_EOF >> /etc/pacman.conf

[universe]
Server = https://universe.artixlinux.org/\$arch

# Arch Linux repositories support (for AUR compatibility)
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[community]
Include = /etc/pacman.d/mirrorlist-arch
PACMAN_EOF

# Install Arch repo compat layer
pacman -Sy --noconfirm artix-archlinux-support
# Populate Arch mirrorlist with a generic mirror
echo "Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist-arch
pacman -Sy

echo "-> Installing Xorg/Wayland stack and Desktop Tools..."
pacman -S --noconfirm xorg-server xorg-xinit xorg-xrandr wayland xorg-xwayland \
    alacritty firefox thunar neovim ttf-dejavu ttf-liberation noto-fonts

echo "-> Installing AUR helper (yay-bin) as user..."
su - "$USERNAME" -c "
    cd /tmp
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
"

echo "-> Installing MangoWM..."
# Install mangowm from AUR (assuming it exists as mangowm-git or mangowm)
# Also grabbing generic utilities just in case it's an X11 WM
su - "$USERNAME" -c "yay -S --noconfirm mangowm-git || yay -S --noconfirm mangowm"

echo "-> Creating default user configurations..."
# Setup .xinitrc for X11 fallback/usage
cat << XINIT_EOF > "/home/$USERNAME/.xinitrc"
#!/bin/sh
userresources=\$HOME/.Xresources
usermodmap=\$HOME/.Xmodmap
sysresources=/etc/X11/xinit/.Xresources
sysmodmap=/etc/X11/xinit/.Xmodmap

# Merge in defaults and keymaps
if [ -f \$sysresources ]; then xrdb -merge \$sysresources; fi
if [ -f \$sysmodmap ]; then xmodmap \$sysmodmap; fi
if [ -f "\$userresources" ]; then xrdb -merge "\$userresources"; fi
if [ -f "\$usermodmap" ]; then xmodmap "\$usermodmap"; fi

# Ensure dbus session is active
if [ -z "\$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval \$(dbus-launch --sh-syntax --exit-with-session)
fi

# Start Pipewire for user
pipewire &
pipewire-pulse &
wireplumber &

# Exec MangoWM
exec mangowm
XINIT_EOF

chmod +x "/home/$USERNAME/.xinitrc"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xinitrc"

# Create bash_profile to autostart X on login on tty1
cat << PROFILE_EOF > "/home/$USERNAME/.bash_profile"
[[ -f ~/.bashrc ]] && . ~/.bashrc

if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
PROFILE_EOF
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bash_profile"

# Clean up temporary install files
rm /tmp/install_config.env
rm /tmp/install_chroot.sh

CHROOT_EOF
# End of chroot script

chmod +x /mnt/tmp/install_chroot.sh

echo "Executing chroot environment setup..."
artix-chroot /mnt /tmp/install_chroot.sh

# ==============================================================================
# FINAL CLEANUP & REBOOT PROMPT
# ==============================================================================
echo "Installation complete. Unmounting filesystems..."
umount -R /mnt
swapoff -a

echo "======================================================================"
echo " Artix Linux (s6) + MangoWM installation finished successfully! "
echo " System will boot to tty1. Login as $USERNAME and Xorg/MangoWM will"
echo " autostart."
echo "======================================================================"
echo "Remove your installation media."
echo "Type 'reboot' to boot into your new system."
