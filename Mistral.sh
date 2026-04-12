#!/usr/bin/env bash
set -euo pipefail

# =============================================
# Artix Linux S6 + MangoWM One-Shot Installer
# =============================================
# Personalized, automated, end-to-end installer for Artix Linux with s6-init and MangoWM.
# Designed to be run as root in the live ISO after connecting to the internet.
# =============================================

# =============================================
# CONFIGURATION (EDIT BEFORE RUNNING)
# =============================================
HOSTNAME="wade-artix"
USERNAME="wade"
FULL_NAME="Wade"
PASSWORD=""  # SET THIS BEFORE RUNNING! (plain text, will be hashed)
DISK="/dev/sda"
FILESYSTEM="ext4"
SWAP_SIZE="16G"
UEFI="yes"  # "yes" or "no"
TIMEZONE="America/Los_Angeles"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# =============================================
# SAFETY CHECKS
# =============================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: This script must be run as root." >&2
        exit 1
    fi
}

check_internet() {
    if ! ping -c 3 archlinux.org &> /dev/null; then
        echo "ERROR: No internet connection. Connect to the internet and try again." >&2
        exit 1
    fi
}

check_disk() {
    if [[ ! -b "$DISK" ]]; then
        echo "ERROR: Disk $DISK does not exist." >&2
        exit 1
    fi
}

check_password() {
    if [[ -z "$PASSWORD" ]]; then
        echo "ERROR: PASSWORD is not set. Edit the script and set a password." >&2
        exit 1
    fi
}

confirm_install() {
    echo "============================================="
    echo "WARNING: This will WIPE $DISK and install Artix Linux."
    echo "Hostname: $HOSTNAME"
    echo "Username: $USERNAME"
    echo "Disk: $DISK"
    echo "Filesystem: $FILESYSTEM"
    echo "Swap: $SWAP_SIZE"
    echo "UEFI: $UEFI"
    echo "============================================="
    read -rp "Type 'YES' to confirm and proceed: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Installation cancelled." >&2
        exit 1
    fi
}

# =============================================
# DISK PARTITIONING
# =============================================
partition_disk() {
    echo "=== Partitioning $DISK ==="

    # Wipe disk and create new partition table
    wipefs -a "$DISK"
    if [[ "$UEFI" == "yes" ]]; then
        parted -s "$DISK" mklabel gpt
        parted -s "$DISK" mkpart ESP fat32 1MiB 512MiB
        parted -s "$DISK" set 1 esp on
        parted -s "$DISK" mkpart swap linux-swap 512MiB "$(echo "$SWAP_SIZE" + 512MiB | bc)"
        parted -s "$DISK" mkpart root "$FILESYSTEM" "$(echo "$SWAP_SIZE" + 512MiB | bc)" 100%
    else
        parted -s "$DISK" mklabel msdos
        parted -s "$DISK" mkpart primary linux-swap 1MiB "$SWAP_SIZE"
        parted -s "$DISK" mkpart primary "$FILESYSTEM" "$SWAP_SIZE" 100%
    fi
}

format_partitions() {
    echo "=== Formatting partitions ==="

    if [[ "$UEFI" == "yes" ]]; then
        mkfs.fat -F32 "${DISK}1"
        mkswap "${DISK}2"
        mkfs."$FILESYSTEM" -F "${DISK}3"
    else
        mkswap "${DISK}1"
        mkfs."$FILESYSTEM" -F "${DISK}2"
    fi
}

mount_partitions() {
    echo "=== Mounting partitions ==="

    if [[ "$UEFI" == "yes" ]]; then
        mount "${DISK}3" /mnt
        mkdir -p /mnt/boot/efi
        mount "${DISK}1" /mnt/boot/efi
    else
        mount "${DISK}2" /mnt
    fi

    if [[ "$UEFI" == "yes" ]]; then
        swapon "${DISK}2"
    else
        swapon "${DISK}1"
    fi
}

# =============================================
# BASE SYSTEM INSTALLATION
# =============================================
setup_mirrors() {
    echo "=== Setting up Artix mirrors ==="
    pacman -S --noconfirm artix-archlinux-support
    pacman -Sy --noconfirm
}

install_base() {
    echo "=== Installing base system ==="
    pacstrap /mnt base s6 linux linux-firmware dbus polkit elogind connman pipewire wireplumber \
        xorg-server xorg-xinit mesa vulkan-intel vulkan-radeon libva-mesa-driver libva-vdpau-driver \
        alacritty firefox thunar neovim lxappearance picom feh scrot pavucontrol arandr xclip xdg-utils \
        xdg-user-dirs font-dejavu font-misc-misc ttf-dejavu ttf-liberation noto-fonts noto-fonts-cjk
}

generate_fstab() {
    echo "=== Generating fstab ==="
    genfstab -U /mnt >> /mnt/etc/fstab
}

# =============================================
# CHROOT CONFIGURATION
# =============================================
configure_system() {
    echo "=== Configuring system in chroot ==="
    local chroot_script="/mnt/chroot_script.sh"

    cat > "$chroot_script" << 'EOL'
#!/bin/bash
set -euo pipefail

# Set locale
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Set timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# Set keymap
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Set hostname
echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1 localhost" >> /etc/hosts
echo "127.0.1.1 $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

# Create user and set passwords
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$FULL_NAME" | chpasswd
echo "root:$PASSWORD_HASH" | chpasswd -e
echo "$USERNAME:$PASSWORD_HASH" | chpasswd -e

# Configure sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Install GRUB
if [[ "$UEFI" == "yes" ]]; then
    pacman -S --noconfirm grub efibootmgr
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Artix
else
    pacman -S --noconfirm grub
    grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Enable s6 services
skarn add dbus
skarn add elogind
skarn add connman
skarn add pipewire
skarn add wireplumber

# Install MangoWM
if ! pacman -S --noconfirm mangowm; then
    echo "MangoWM not in repos, installing from AUR..."
    pacman -S --noconfirm --needed base-devel git
    if ! command -v yay &> /dev/null; then
        useradd -m builduser
        echo "builduser ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
        su - builduser -c "git clone https://aur.archlinux.org/yay.git /home/builduser/yay"
        su - builduser -c "cd /home/builduser/yay && makepkg -si --noconfirm"
    fi
    su - "$USERNAME" -c "yay -S --noconfirm mangowm"
fi

# Configure MangoWM
mkdir -p "/home/$USERNAME/.config/mangowm"
cat > "/home/$USERNAME/.config/mangowm/mangowm.conf" << 'CONF'
# Minimal MangoWM config
mod = Mod4
terminal = alacritty
browser = firefox
filemanager = thunar
editor = nvim

# Keybinds
bind = $mod+Return exec $terminal
bind = $mod+d exec $browser
bind = $mod+f exec $filemanager
bind = $mod+e exec $editor
bind = $mod+Shift+q kill
bind = $mod+Shift+e exec mangowm exit
CONF
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

# Set up .xinitrc
cat > "/home/$USERNAME/.xinitrc" << 'XINIT'
#!/bin/sh
exec dbus-launch --exit-with-session mangowm
XINIT
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xinitrc"
chmod +x "/home/$USERNAME/.xinitrc"

# Cleanup
userdel -r builduser 2>/dev/null || true
EOL

    # Export variables to chroot script
    {
        echo "LOCALE=\"$LOCALE\""
        echo "TIMEZONE=\"$TIMEZONE\""
        echo "KEYMAP=\"$KEYMAP\""
        echo "HOSTNAME=\"$HOSTNAME\""
        echo "USERNAME=\"$USERNAME\""
        echo "FULL_NAME=\"$FULL_NAME\""
        echo "PASSWORD_HASH=\"$(echo -n "$PASSWORD" | mkpasswd -m sha-512 -s)\""
        echo "UEFI=\"$UEFI\""
        echo "DISK=\"$DISK\""
    } >> "$chroot_script"

    chmod +x "$chroot_script"
    arch-chroot /mnt /chroot_script.sh
    rm "$chroot_script"
}

# =============================================
# FINALIZATION
# =============================================
finalize() {
    echo "=== Installation complete! ==="
    echo "Unmounting partitions..."
    umount -R /mnt
    swapoff -a
    echo "You can now reboot and log in as $USERNAME."
    echo "Start the desktop with 'startx' after login."
}

# =============================================
# MAIN EXECUTION
# =============================================
main() {
    check_root
    check_internet
    check_disk
    check_password
    confirm_install

    partition_disk
    format_partitions
    mount_partitions

    setup_mirrors
    install_base
    generate_fstab

    configure_system
    finalize
}

main
