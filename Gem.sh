#!/usr/bin/env bash
# set strict execution environment
set -euo pipefail

# ==============================================================================
# CONFIGURATION VARIABLES
# ==============================================================================
HOSTNAME="wade-artix"
USERNAME="wade"
FULL_NAME="Wade"

# WARNING: Set your plain-text password here before executing!
# The script will hash it and use the hash for both root and the user account.
PASSWORD=""

DISK="/dev/sda"
FILESYSTEM="ext4"
SWAP_SIZE="16G"
UEFI="yes"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# ==============================================================================
# PRE-FLIGHT SAFETY CHECKS
# ==============================================================================

# Ensure we are running as root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root. Try: sudo ./install.sh"
    exit 1
fi

# Ensure password is provided
if [[ -z "$PASSWORD" ]]; then
    echo "ERROR: The PASSWORD variable is empty. Please edit the script and set a password."
    exit 1
fi

# Ensure internet connectivity
echo "Checking internet connection..."
if ! ping -c 3 archlinux.org > /dev/null 2>&1; then
    echo "ERROR: No internet connection detected. Please connect and try again."
    exit 1
fi

# Final destructive warning
echo "======================================================================"
echo " WARNING: DESTRUCTIVE OPERATION AHEAD"
echo "======================================================================"
echo "This script will completely wipe $DISK."
echo "All data on $DISK will be lost forever."
echo "Press ENTER to continue or Ctrl+C to abort..."
read -r

# ==============================================================================
# TIME SYNCHRONIZATION
# ==============================================================================
echo "Syncing system clock..."
ntpd -qg || true
hwclock --systohc

# ==============================================================================
# DISK PARTITIONING & FORMATTING
# ==============================================================================
echo "Wiping and partitioning $DISK..."

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
