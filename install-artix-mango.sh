#!/usr/bin/env bash
# =============================================================================
#  install-artix-mango.sh
#  One-shot Artix Linux + s6 + MangoWM installer
#  Target : HP ProDesk Mini (Intel HD/UHD Graphics)
#  Init   : s6 / s6-rc
#  WM     : MangoWM (Wayland-native, XWayland compat layer included)
#  Usage  : Boot Artix ISO → edit CONFIG block below → sudo bash install-artix-mango.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─── Palette ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; MAG='\033[0;35m'
BOLD='\033[1m';   RST='\033[0m'

info()  { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[ OK ]${RST}  $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
die()   { echo -e "${RED}[FAIL]${RST}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}";
          echo -e "${BOLD}${CYN}  ▶  $*${RST}";
          echo -e "${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"; }

# =============================================================================
# CONFIG — edit before running
# =============================================================================
DISK="${DISK:-/dev/sda}"            # Override: DISK=/dev/nvme0n1 ./install-artix-mango.sh
HOSTNAME="${HOSTNAME:-mangodesk}"
USERNAME="${USERNAME:-wade}"
LOCALE="en_US.UTF-8"
TIMEZONE="America/Los_Angeles"      # Hillsboro, OR
KEYMAP="us"
MOUNT="/mnt"
BOOT_SIZE="512M"
SWAP_SIZE="8G"                      # Set to "" to skip swap partition
# =============================================================================

# ─── Package Lists ────────────────────────────────────────────────────────────

BASE_PKGS=(
  # Core
  base base-devel
  linux linux-headers linux-firmware
  intel-ucode                          # HP Mini — Intel CPU (Skylake / UHD)

  # Init
  s6 s6-rc s6-boot-scripts
  elogind elogind-s6                   # Seat/session management

  # Bootloader
  grub efibootmgr os-prober

  # Network
  networkmanager networkmanager-s6
  iwd                                  # WiFi backend if needed

  # Essentials
  sudo vim git curl wget rsync
  man-db man-pages
  bash-completion
  htop btop
  openssh
)

WAYLAND_PKGS=(
  # Wayland core
  wayland wayland-protocols

  # XWayland — X11 compat for Burp Suite, Android Studio, legacy GTK, etc.
  xorg-xwayland xorg-xlsclients

  # Input
  libinput

  # Intel GPU (HD Graphics 530 / UHD 630)
  mesa lib32-mesa
  vulkan-intel lib32-vulkan-intel
  intel-media-driver
  libva-intel-driver                   # VA-API for hardware video decode

  # wlroots compositor base (MangoWM dep)
  wlroots

  # Audio — PipeWire stack
  pipewire pipewire-pulse pipewire-alsa pipewire-jack
  wireplumber
  pavucontrol

  # Portals
  xdg-desktop-portal
  xdg-desktop-portal-wlr

  # PolicyKit
  polkit polkit-s6
)

DESKTOP_PKGS=(
  # Terminal
  foot                                 # Wayland-native, fast

  # Launcher
  fuzzel                               # Lightweight Wayland launcher

  # Bar
  waybar

  # Notifications
  mako

  # Wallpaper + lock
  swaybg
  swaylock

  # Screenshot
  grim slurp

  # Clipboard
  wl-clipboard

  # File manager
  thunar gvfs

  # Fonts
  noto-fonts noto-fonts-emoji noto-fonts-cjk
  ttf-jetbrains-mono
  ttf-font-awesome                     # Waybar icons

  # Media
  playerctl
  mpv

  # Misc utilities
  brightnessctl
  unzip p7zip
  jq
  fzf
  ripgrep fd
  bat eza                              # Modern ls/cat replacements
  zoxide                               # Smart cd
)

# ─── Sanity checks ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]]                   || die "Must run as root."
[[ -d /sys/firmware/efi ]]          || die "UEFI not detected — boot in UEFI mode."
[[ -b "$DISK" ]]                    || die "Disk $DISK not found. Set DISK= env var or edit CONFIG."
command -v basestrap &>/dev/null    || die "basestrap not found — run this from the Artix live ISO."

# ─── Banner + confirm ─────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYN}"
cat <<'BANNER'
  ┌─────────────────────────────────────────────────┐
  │      ARTIX LINUX  ·  s6  ·  MangoWM             │
  │      One-Shot Installer — HP ProDesk Mini        │
  └─────────────────────────────────────────────────┘
BANNER
echo -e "${RST}"
echo -e "  ${BOLD}Disk${RST}     : ${YLW}${DISK}${RST}"
echo -e "  ${BOLD}Hostname${RST} : ${YLW}${HOSTNAME}${RST}"
echo -e "  ${BOLD}User${RST}     : ${YLW}${USERNAME}${RST}"
echo -e "  ${BOLD}Timezone${RST} : ${YLW}${TIMEZONE}${RST}"
echo -e "  ${BOLD}Swap${RST}     : ${YLW}${SWAP_SIZE:-none}${RST}"
echo ""
warn "ALL DATA ON ${DISK} WILL BE PERMANENTLY DESTROYED."
echo -en "${MAG}  Type 'yes' to continue: ${RST}"
read -r CONFIRM
[[ "$CONFIRM" == "yes" ]] || die "Aborted by user."

# =============================================================================
# PHASE 1 — DISK PARTITIONING & FORMATTING
# =============================================================================
step "Partitioning: $DISK"

# Partition naming: NVMe uses p1/p2, SATA/SCSI uses 1/2
if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
  P="${DISK}p"
else
  P="${DISK}"
fi

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

if [[ -n "${SWAP_SIZE}" ]]; then
  PART_BOOT="${P}1"
  PART_SWAP="${P}2"
  PART_ROOT="${P}3"
  sgdisk \
    -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI" \
    -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"swap" \
    -n 3:0:0             -t 3:8300 -c 3:"root" \
    "$DISK"
else
  PART_BOOT="${P}1"
  PART_ROOT="${P}2"
  PART_SWAP=""
  sgdisk \
    -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI" \
    -n 2:0:0             -t 2:8300 -c 2:"root" \
    "$DISK"
fi

partprobe "$DISK"
sleep 1

step "Formatting partitions"
mkfs.fat -F32 -n EFI "$PART_BOOT"
ok "Boot partition formatted (FAT32)"

if [[ -n "${PART_SWAP:-}" ]]; then
  mkswap -L swap "$PART_SWAP"
  swapon "$PART_SWAP"
  ok "Swap created and enabled"
fi

mkfs.ext4 -L artix-root "$PART_ROOT"
ok "Root partition formatted (ext4)"

step "Mounting filesystems"
mount "$PART_ROOT" "$MOUNT"
mkdir -p "$MOUNT/boot/efi"
mount "$PART_BOOT" "$MOUNT/boot/efi"
ok "Filesystems mounted at $MOUNT"

# =============================================================================
# PHASE 2 — BASE INSTALL
# =============================================================================
step "Running basestrap"
basestrap "$MOUNT" "${BASE_PKGS[@]}"
ok "Base packages installed"

step "Generating /etc/fstab"
fstabgen -U "$MOUNT" >> "$MOUNT/etc/fstab"
ok "fstab written"

# =============================================================================
# PHASE 3 — CHROOT CONFIGURATION
# =============================================================================
step "Entering chroot for system configuration"

# Export variables for heredoc
export HOSTNAME USERNAME LOCALE TIMEZONE KEYMAP
export WAYLAND_PKGS_STR="${WAYLAND_PKGS[*]}"
export DESKTOP_PKGS_STR="${DESKTOP_PKGS[*]}"

artix-chroot "$MOUNT" /bin/bash <<'CHROOT'
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; RST='\033[0m'
ok()   { echo -e "${GRN}[ OK ]${RST}  $*"; }
info() { echo -e "\e[34m[INFO]\e[0m  $*"; }

# ── Locale ────────────────────────────────────────────────────────
info "Configuring locale..."
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ok "Locale set to ${LOCALE}"

# ── Timezone ──────────────────────────────────────────────────────
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
ok "Timezone: ${TIMEZONE}"

# ── Hostname ──────────────────────────────────────────────────────
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain  ${HOSTNAME}
EOF
ok "Hostname: ${HOSTNAME}"

# ── Pacman tweaks ─────────────────────────────────────────────────
sed -i \
  -e 's/^#ParallelDownloads.*/ParallelDownloads = 10/' \
  -e 's/^#Color/Color/' \
  -e '/^#\[multilib\]/,/^#Include/ s/^#//' \
  /etc/pacman.conf
pacman -Sy --noconfirm
ok "Pacman configured (parallel downloads, color, multilib)"

# ── Wayland + Desktop packages ────────────────────────────────────
info "Installing Wayland stack and desktop packages..."
# shellcheck disable=SC2086
pacman -S --noconfirm --needed $WAYLAND_PKGS_STR $DESKTOP_PKGS_STR
ok "Wayland and desktop packages installed"

# ── s6 Services ───────────────────────────────────────────────────
info "Enabling s6 services..."

# s6 service directories vary slightly between Artix versions
# Try both common paths
S6_SV_DIR=""
for d in /etc/s6/sv /etc/s6-rc/compiled /run/service; do
  [[ -d "$d" ]] && S6_SV_DIR="$d" && break
done

# s6-rc compiled database path
S6_ADMIN="${S6_ADMIN:-/etc/s6/adminsv}"
[[ -d "$S6_ADMIN" ]] || mkdir -p "$S6_ADMIN"

for svc in NetworkManager elogind polkit; do
  if [[ -d "/etc/s6/sv/${svc}" ]]; then
    ln -sf "/etc/s6/sv/${svc}" "${S6_ADMIN}/" 2>/dev/null || true
    ok "Service linked: ${svc}"
  else
    echo -e "${YLW}[WARN]${RST}  Service dir not found: /etc/s6/sv/${svc} — link manually post-boot"
  fi
done

# ── Bootloader (GRUB, UEFI) ───────────────────────────────────────
info "Installing GRUB..."
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=artix \
  --recheck
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
ok "GRUB installed and configured"

# ── Root password ─────────────────────────────────────────────────
echo "root:toor" | chpasswd
echo -e "${YLW}[WARN]${RST}  Root password set to 'toor' — change immediately after first boot"

# ── User account ──────────────────────────────────────────────────
if ! id "${USERNAME}" &>/dev/null; then
  useradd -m -G wheel,audio,video,input,storage,optical,network \
    -s /bin/bash "${USERNAME}"
  echo "${USERNAME}:changeme" | chpasswd
  echo -e "${YLW}[WARN]${RST}  ${USERNAME} password set to 'changeme' — change after first boot"
else
  ok "User ${USERNAME} already exists, skipping creation"
fi

# Passwordless sudo for wheel
cat > /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/10-wheel
ok "Sudo configured for wheel group"

# ── PipeWire session startup ──────────────────────────────────────
# PipeWire is started as a user service via systemd --user normally,
# but with s6 we'll start it from MangoWM's startup script
ok "PipeWire will be started from MangoWM startup script"

# ── AUR helper: paru ──────────────────────────────────────────────
info "Installing paru (AUR helper)..."
if ! command -v paru &>/dev/null; then
  cd /tmp
  git clone https://aur.archlinux.org/paru-bin.git
  chown -R "${USERNAME}:${USERNAME}" paru-bin
  cd paru-bin
  sudo -u "${USERNAME}" makepkg -si --noconfirm
  ok "paru installed"
else
  ok "paru already present"
fi

# ── MangoWM from AUR ──────────────────────────────────────────────
info "Installing MangoWM from AUR..."
sudo -u "${USERNAME}" paru -S --noconfirm mangowm || {
  echo -e "${YLW}[WARN]${RST}  MangoWM AUR install failed — try: paru -S mangowm after first boot"
}

CHROOT

ok "Chroot configuration complete"

# =============================================================================
# PHASE 4 — USER CONFIG FILES
# =============================================================================
step "Deploying user config files"

UHOME="$MOUNT/home/$USERNAME"
CFG="$UHOME/.config"
mkdir -p \
  "$CFG/mango" \
  "$CFG/foot" \
  "$CFG/waybar" \
  "$CFG/fuzzel" \
  "$CFG/mako" \
  "$CFG/swaylock" \
  "$UHOME/.local/share" \
  "$UHOME/screenshots" \
  "$UHOME/src"

# ── MangoWM config ────────────────────────────────────────────────
# NOTE: MangoWM uses a Lua-based or TOML-based config depending on version.
# Adjust key bindings to taste. Run `mango --help` for the actual config
# format used by your installed version.
cat > "$CFG/mango/config.lua" <<'EOF'
-- MangoWM config — HP ProDesk Mini
-- Mod key
local mod = "super"

-- Gaps & borders
gaps(8)
border(2)
border_color("#58a6ff", "#30363d")    -- active, inactive

-- Startup
spawn("waybar")
spawn("mako")
spawn("swaybg -i ~/.config/mango/wallpaper.jpg -m fill")
spawn("pipewire")
spawn("pipewire-pulse")
spawn("wireplumber")

-- Keybinds
bind(mod, "Return",   spawn("foot"))
bind(mod, "d",        spawn("fuzzel"))
bind(mod, "q",        close())
bind(mod .. "+Shift", "r", reload())
bind(mod .. "+Shift", "q", quit())

-- Focus
bind(mod, "h", focus("left"))
bind(mod, "j", focus("down"))
bind(mod, "k", focus("up"))
bind(mod, "l", focus("right"))

-- Move
bind(mod .. "+Shift", "h", move("left"))
bind(mod .. "+Shift", "j", move("down"))
bind(mod .. "+Shift", "k", move("up"))
bind(mod .. "+Shift", "l", move("right"))

-- Workspaces
for i = 1, 9 do
  bind(mod, tostring(i), workspace(i))
  bind(mod .. "+Shift", tostring(i), move_to_workspace(i))
end

-- Screenshot (requires grim + slurp)
bind(mod, "p", spawn('grim -g "$(slurp)" ~/screenshots/$(date +%Y%m%d_%H%M%S).png'))

-- Screen lock
bind(mod .. "+ctrl", "l", spawn("swaylock"))

-- Volume (PipeWire/WirePlumber)
bind("", "XF86AudioRaiseVolume",  spawn("wpctl set-volume @DEFAULT_SINK@ 5%+"))
bind("", "XF86AudioLowerVolume",  spawn("wpctl set-volume @DEFAULT_SINK@ 5%-"))
bind("", "XF86AudioMute",         spawn("wpctl set-mute @DEFAULT_SINK@ toggle"))

-- Media keys
bind("", "XF86AudioPlay",  spawn("playerctl play-pause"))
bind("", "XF86AudioNext",  spawn("playerctl next"))
bind("", "XF86AudioPrev",  spawn("playerctl previous"))
EOF

# Also drop a TOML variant in case this version of MangoWM uses TOML
cat > "$CFG/mango/config.toml" <<'EOF'
# MangoWM config (TOML format) — HP ProDesk Mini
# Uncomment and use if your MangoWM build expects TOML, not Lua.

[general]
gaps = 8
border_width = 2
border_active = "58a6ff"
border_inactive = "30363d"
mod = "super"

[startup]
exec = [
  "waybar",
  "mako",
  "swaybg -i ~/.config/mango/wallpaper.jpg -m fill",
  "pipewire",
  "pipewire-pulse",
  "wireplumber",
]

[[bind]]
keys = ["super", "Return"]
action = "spawn"
cmd = "foot"

[[bind]]
keys = ["super", "d"]
action = "spawn"
cmd = "fuzzel"

[[bind]]
keys = ["super", "q"]
action = "close"

[[bind]]
keys = ["super", "shift", "r"]
action = "reload"

[[bind]]
keys = ["super", "shift", "q"]
action = "quit"

[[bind]]
keys = ["super", "h"]
action = "focus_left"

[[bind]]
keys = ["super", "j"]
action = "focus_down"

[[bind]]
keys = ["super", "k"]
action = "focus_up"

[[bind]]
keys = ["super", "l"]
action = "focus_right"

[[bind]]
keys = ["super", "shift", "h"]
action = "move_left"

[[bind]]
keys = ["super", "shift", "j"]
action = "move_down"

[[bind]]
keys = ["super", "shift", "k"]
action = "move_up"

[[bind]]
keys = ["super", "shift", "l"]
action = "move_right"

[[bind]]
keys = ["super", "1"]
action = "workspace"
n = 1

[[bind]]
keys = ["super", "2"]
action = "workspace"
n = 2

[[bind]]
keys = ["super", "3"]
action = "workspace"
n = 3

[[bind]]
keys = ["super", "4"]
action = "workspace"
n = 4

[[bind]]
keys = ["super", "5"]
action = "workspace"
n = 5
EOF

# ── foot terminal ─────────────────────────────────────────────────
cat > "$CFG/foot/foot.ini" <<'EOF'
[main]
font=JetBrains Mono:size=11
pad=8x8
term=xterm-256color

[scrollback]
lines=5000

[colors]
# GitHub Dark
background=0d1117
foreground=c9d1d9
regular0=21262d
regular1=ff7b72
regular2=3fb950
regular3=d29922
regular4=58a6ff
regular5=bc8cff
regular6=39c5cf
regular7=b1bac4
bright0=6e7681
bright1=ffa198
bright2=56d364
bright3=e3b341
bright4=79c0ff
bright5=d2a8ff
bright6=56d4dd
bright7=f0f6fc

[cursor]
color=c9d1d9 58a6ff

[key-bindings]
scrollback-up-page=shift+Page_Up
scrollback-down-page=shift+Page_Down
clipboard-copy=Control+Shift+c
clipboard-paste=Control+Shift+v
EOF

# ── waybar ────────────────────────────────────────────────────────
cat > "$CFG/waybar/config" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 28,
  "spacing": 4,
  "modules-left": ["wlr/workspaces", "wlr/mode"],
  "modules-center": ["clock"],
  "modules-right": ["network", "pulseaudio", "cpu", "memory", "temperature", "tray"],

  "wlr/workspaces": {
    "on-click": "activate",
    "format": "{name}"
  },

  "clock": {
    "format": " {:%a %b %d  %H:%M}",
    "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>"
  },

  "cpu": {
    "interval": 3,
    "format": " {usage}%",
    "tooltip": true
  },

  "memory": {
    "interval": 5,
    "format": " {used:.1f}G / {total:.1f}G"
  },

  "temperature": {
    "thermal-zone": 0,
    "critical-threshold": 85,
    "format": " {temperatureC}°C",
    "format-critical": " {temperatureC}°C"
  },

  "network": {
    "interval": 5,
    "format-ethernet": " {bandwidthDownBytes}",
    "format-wifi": " {essid} {signalStrength}%",
    "format-disconnected": "⚠ offline",
    "tooltip-format": "{ifname}: {ipaddr}"
  },

  "pulseaudio": {
    "format": " {volume}%",
    "format-muted": " muted",
    "on-click": "wpctl set-mute @DEFAULT_SINK@ toggle",
    "on-click-right": "pavucontrol"
  },

  "tray": {
    "spacing": 8
  }
}
EOF

cat > "$CFG/waybar/style.css" <<'EOF'
* {
  font-family: "JetBrains Mono", "Font Awesome 6 Free";
  font-size: 12px;
  border: none;
  border-radius: 0;
  min-height: 0;
}

window#waybar {
  background: rgba(13, 17, 23, 0.92);
  color: #c9d1d9;
  border-bottom: 1px solid #30363d;
}

#workspaces button {
  padding: 2px 10px;
  color: #6e7681;
  border-radius: 0;
  border-bottom: 2px solid transparent;
}

#workspaces button.active {
  color: #58a6ff;
  border-bottom: 2px solid #58a6ff;
}

#workspaces button:hover {
  color: #c9d1d9;
  background: #21262d;
}

#clock         { color: #c9d1d9; padding: 0 12px; }
#cpu           { color: #3fb950; padding: 0 8px; }
#memory        { color: #bc8cff; padding: 0 8px; }
#temperature   { color: #d29922; padding: 0 8px; }
#temperature.critical { color: #ff7b72; }
#network       { color: #58a6ff; padding: 0 8px; }
#pulseaudio    { color: #d29922; padding: 0 8px; }
#tray          { padding: 0 8px; }
EOF

# ── fuzzel launcher ───────────────────────────────────────────────
cat > "$CFG/fuzzel/fuzzel.ini" <<'EOF'
[main]
font=JetBrains Mono:size=12
terminal=foot -e
layer=overlay
width=35
lines=12
tabs=4
horizontal-pad=18
vertical-pad=10
inner-pad=4

[colors]
background=0d1117ff
text=c9d1d9ff
match=58a6ffff
selection=21262dff
selection-text=c9d1d9ff
selection-match=79c0ffff
border=30363dff

[border]
width=1
radius=4
EOF

# ── mako notifications ────────────────────────────────────────────
cat > "$CFG/mako/config" <<'EOF'
background-color=#0d1117
text-color=#c9d1d9
border-color=#30363d
progress-color=over #58a6ff30
border-size=1
border-radius=4
font=JetBrains Mono 11
padding=10
margin=8
width=340
height=200
anchor=top-right
layer=overlay
sort=-time

[urgency=high]
border-color=#ff7b72
background-color=#3d1f1f
EOF

# ── swaylock ─────────────────────────────────────────────────────
cat > "$CFG/swaylock/config" <<'EOF'
color=0d1117
indicator-radius=90
indicator-thickness=6
ring-color=58a6ff
key-hl-color=3fb950
bs-hl-color=ff7b72
line-color=0d1117
inside-color=0d1117
separator-color=0d1117
text-color=c9d1d9
font=JetBrains Mono
EOF

# ── .bashrc ───────────────────────────────────────────────────────
cat > "$UHOME/.bashrc" <<'EOF'
# ─── Interactive check ────────────────────────────────────────────
[[ $- != *i* ]] && return

# ─── Prompt ───────────────────────────────────────────────────────
PS1='\[\e[36m\]\u\[\e[0m\]@\[\e[34m\]\h\[\e[0m\]:\[\e[33m\]\w\[\e[0m\]\$ '

# ─── Aliases ──────────────────────────────────────────────────────
alias ls='eza --icons --group-directories-first'
alias ll='eza -la --icons --group-directories-first'
alias lt='eza --tree --level=2 --icons'
alias cat='bat --pager=never'
alias grep='grep --color=auto'
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -Iv'
alias mkdir='mkdir -pv'
alias df='df -h'
alias du='du -h'
alias top='btop'
alias vi='vim'
alias pacup='sudo pacman -Syu'
alias pacc='sudo pacman -Sc'
alias pacs='pacman -Ss'
alias paci='sudo pacman -S'
alias pacr='sudo pacman -Rns'
alias paclogs='cat /var/log/pacman.log | tail -50'

# ─── zoxide (smart cd) ────────────────────────────────────────────
eval "$(zoxide init bash)"

# ─── fzf ─────────────────────────────────────────────────────────
[[ -f /usr/share/fzf/key-bindings.bash ]] && source /usr/share/fzf/key-bindings.bash
[[ -f /usr/share/fzf/completion.bash   ]] && source /usr/share/fzf/completion.bash

export FZF_DEFAULT_OPTS='--color=bg+:#21262d,bg:#0d1117,spinner:#58a6ff,hl:#58a6ff
  --color=fg:#c9d1d9,header:#58a6ff,info:#d29922,pointer:#58a6ff
  --color=marker:#3fb950,fg+:#c9d1d9,prompt:#bc8cff,hl+:#79c0ff'

# ─── Wayland env vars ─────────────────────────────────────────────
export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export CLUTTER_BACKEND=wayland
export _JAVA_AWT_WM_NONREPARENTING=1

# ─── Preferred apps ───────────────────────────────────────────────
export EDITOR=vim
export VISUAL=vim
export BROWSER=firefox
export TERMINAL=foot

# ─── Path additions ───────────────────────────────────────────────
export PATH="$HOME/.local/bin:$PATH"
EOF

# ── .bash_profile — auto-start MangoWM on tty1 ───────────────────
cat > "$UHOME/.bash_profile" <<'EOF'
# Source .bashrc
[[ -f ~/.bashrc ]] && . ~/.bashrc

# Auto-start MangoWM on tty1 (no display manager)
if [[ -z "${WAYLAND_DISPLAY:-}" && "${XDG_VTNR:-0}" -eq 1 ]]; then
  export XDG_SESSION_TYPE=wayland
  export XDG_CURRENT_DESKTOP=mango
  export MOZ_ENABLE_WAYLAND=1
  export QT_QPA_PLATFORM=wayland
  export SDL_VIDEODRIVER=wayland
  export CLUTTER_BACKEND=wayland
  export _JAVA_AWT_WM_NONREPARENTING=1
  export WLR_RENDERER=vulkan        # Intel — try vulkan renderer
  export WLR_NO_HARDWARE_CURSORS=0

  mkdir -p ~/.local/share/mango
  exec mango > ~/.local/share/mango/mango.log 2>&1
fi
EOF

# ── .vimrc ────────────────────────────────────────────────────────
cat > "$UHOME/.vimrc" <<'EOF'
set nocompatible
set number relativenumber
set expandtab tabstop=2 shiftwidth=2
set smartindent autoindent
set incsearch hlsearch ignorecase smartcase
set wildmenu wildmode=longest:full
set laststatus=2
set ruler showcmd
set wrap linebreak
set scrolloff=5
set backspace=indent,eol,start
set encoding=utf-8
set mouse=a
set clipboard=unnamedplus
syntax on
colorscheme desert
EOF

# ── Fix ownership ─────────────────────────────────────────────────
chown -R 1000:1000 "$UHOME"
ok "All config files deployed and ownership set"

# =============================================================================
# PHASE 5 — VERIFY & UNMOUNT
# =============================================================================
step "Verifying installation"

checks_passed=0
checks_total=0

check() {
  local label="$1"; local path="$2"; checks_total=$((checks_total+1))
  if [[ -e "$MOUNT/$path" ]]; then
    ok "$label"; checks_passed=$((checks_passed+1))
  else
    warn "$label — NOT FOUND: $path"
  fi
}

check "Kernel"          "boot/vmlinuz-linux"
check "Initramfs"       "boot/initramfs-linux.img"
check "GRUB EFI"        "boot/efi/EFI/artix/grubx64.efi"
check "fstab"           "etc/fstab"
check "s6 scripts"      "etc/s6"
check "NetworkManager"  "usr/bin/NetworkManager"
check "MangoWM"         "usr/bin/mango"
check "foot"            "usr/bin/foot"
check "waybar"          "usr/bin/waybar"
check "pipewire"        "usr/bin/pipewire"
check "XWayland"        "usr/bin/Xwayland"
check "User home"       "home/${USERNAME}"
check "MangoWM config"  "home/${USERNAME}/.config/mango/config.lua"
check "foot config"     "home/${USERNAME}/.config/foot/foot.ini"
check "bash_profile"    "home/${USERNAME}/.bash_profile"

echo ""
echo -e "  Checks: ${GRN}${checks_passed}${RST} / ${checks_total} passed"

step "Unmounting"
sync
umount -R "$MOUNT"
ok "All filesystems unmounted"

# ─── Final summary ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GRN}"
cat <<'DONE'
  ┌────────────────────────────────────────────────────────┐
  │   Installation complete!                               │
  └────────────────────────────────────────────────────────┘
DONE
echo -e "${RST}"
echo -e "  ${BOLD}Post-boot checklist:${RST}"
echo ""
echo -e "  1. ${YLW}Change root password${RST}"
echo -e "     # passwd"
echo ""
echo -e "  2. ${YLW}Change user password${RST}"
echo -e "     # passwd ${USERNAME}"
echo ""
echo -e "  3. ${YLW}Connect to network${RST}"
echo -e "     $ nmtui"
echo ""
echo -e "  4. ${YLW}Verify s6 services${RST}"
echo -e "     $ s6-rc -a list"
echo ""
echo -e "  5. ${YLW}Log in as ${USERNAME} on tty1 — MangoWM starts automatically${RST}"
echo ""
echo -e "  6. ${YLW}Check MangoWM config format (Lua vs TOML)${RST}"
echo -e "     $ mango --help  |  $ mango --version"
echo -e "     Both config.lua and config.toml are deployed — keep only the correct one."
echo ""
echo -e "  ${CYN}Reboot now:${RST} reboot"
echo ""
