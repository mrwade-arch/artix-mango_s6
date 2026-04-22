#!/usr/bin/env bash
# =============================================================================
#  install-artix-mango.sh
#  Artix Linux + s6 + MangoWM — One-Shot Installer
#  Target : HP ProDesk Mini (Intel HD/UHD Graphics)
#  Usage  : Boot Artix ISO → edit CONFIG block → sudo bash install-artix-mango.sh
#  Re-run : safe — completed phases are skipped automatically
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
skip()  { echo -e "${CYN}[SKIP]${RST}  $* — already done"; }
step()  {
  echo -e "\n${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
  echo -e "${BOLD}${CYN}  ▶  $*${RST}"
  echo -e "${BOLD}${CYN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}\n"
}

# =============================================================================
# CONFIG — edit before running
# =============================================================================
DISK="${DISK:-/dev/sda}"           # override: DISK=/dev/nvme0n1 sudo bash install-artix-mango.sh
HOSTNAME="${HOSTNAME:-mangodesk}"
USERNAME="${USERNAME:-wade}"
LOCALE="en_US.UTF-8"
TIMEZONE="America/Los_Angeles"     # Hillsboro, OR
KEYMAP="us"
MOUNT="/mnt"
BOOT_SIZE="512M"
SWAP_SIZE="8G"                     # set to "" to skip swap
# =============================================================================

# ─── Checkpoint system ────────────────────────────────────────────────────────
# On first run: state file lives in /tmp (RAM).
# Once the target disk is mounted: state migrates there so it survives
# a reboot back to the ISO mid-install.
# Each phase is idempotent — re-running skips completed phases.
STATE_FILE="/tmp/.artix-mango.state"

checkpoint() {
  echo "$1" >> "$STATE_FILE"
  ok "Checkpoint saved: $1"
}

done_already() {
  grep -qx "$1" "$STATE_FILE" 2>/dev/null
}

migrate_state() {
  [[ -f "$STATE_FILE" ]] && cp "$STATE_FILE" "$MOUNT/.artix-mango.state"
  STATE_FILE="$MOUNT/.artix-mango.state"
}

restore_state() {
  # If we're resuming after a reboot, try to mount root and pull state back.
  [[ -b "$DISK" ]] || return
  local try_root=""
  if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
    try_root="${DISK}p3"
  else
    try_root="${DISK}3"
  fi
  [[ -b "$try_root" ]] || return

  mkdir -p "$MOUNT" 2>/dev/null || true
  if mount "$try_root" "$MOUNT" 2>/dev/null; then
    if [[ -f "$MOUNT/.artix-mango.state" ]]; then
      cp "$MOUNT/.artix-mango.state" "$STATE_FILE"
      warn "Prior run detected — resuming. Completed phases will be skipped:"
      cat "$STATE_FILE"
      echo ""
    fi
    umount "$MOUNT" 2>/dev/null || true
  fi
}

# ─── Package lists ────────────────────────────────────────────────────────────
BASE_PKGS=(
  base base-devel
  linux linux-headers linux-firmware
  intel-ucode

  s6 s6-rc s6-scripts
  elogind elogind-s6

  grub efibootmgr os-prober

  networkmanager networkmanager-s6
  iwd

  sudo vim git curl wget rsync
  man-db man-pages
  bash-completion
  htop btop
  openssh
)

WAYLAND_PKGS=(
  wayland wayland-protocols
  xorg-xwayland xorg-xlsclients     # X11 compat — Burp Suite, Android Studio, etc.
  libinput
  mesa lib32-mesa
  vulkan-intel lib32-vulkan-intel
  intel-media-driver
  libva-intel-driver
  wlroots
  pipewire pipewire-pulse pipewire-alsa pipewire-jack
  wireplumber
  pavucontrol
  xdg-desktop-portal xdg-desktop-portal-wlr
  polkit polkit-s6
)

DESKTOP_PKGS=(
  foot fuzzel waybar mako
  swaybg swaylock
  grim slurp
  wl-clipboard
  thunar gvfs
  noto-fonts noto-fonts-emoji noto-fonts-cjk
  ttf-jetbrains-mono ttf-font-awesome
  playerctl mpv
  brightnessctl
  unzip p7zip jq fzf
  ripgrep fd bat eza zoxide
)

# ─── Sanity checks ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]]                 || die "Must run as root."
[[ -d /sys/firmware/efi ]]        || die "UEFI not detected — boot in UEFI mode."
[[ -b "$DISK" ]]                  || die "Disk $DISK not found. Set DISK= or edit CONFIG."
command -v basestrap &>/dev/null  || die "basestrap not found — run from the Artix live ISO."

restore_state

# ─── Banner + confirm ─────────────────────────────────────────────────────────
if ! done_already "CONFIRMED"; then
  clear
  echo -e "${BOLD}${CYN}"
  cat <<'BANNER'
  ┌──────────────────────────────────────────────────┐
  │   ARTIX LINUX  ·  s6  ·  MangoWM                │
  │   One-Shot Installer — HP ProDesk Mini           │
  └──────────────────────────────────────────────────┘
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
  checkpoint "CONFIRMED"
fi

# ─── Partition prefix ─────────────────────────────────────────────────────────
if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
  P="${DISK}p"
else
  P="${DISK}"
fi

if [[ -n "${SWAP_SIZE}" ]]; then
  PART_BOOT="${P}1"; PART_SWAP="${P}2"; PART_ROOT="${P}3"
else
  PART_BOOT="${P}1"; PART_SWAP="";    PART_ROOT="${P}2"
fi

# =============================================================================
# PHASE 1 — PARTITION
# =============================================================================
if done_already "PARTITIONED"; then
  skip "Disk partitioning"
else
  step "Partitioning: $DISK"
  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"

  if [[ -n "${SWAP_SIZE}" ]]; then
    sgdisk \
      -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI"  \
      -n 2:0:+${SWAP_SIZE} -t 2:8200 -c 2:"swap" \
      -n 3:0:0             -t 3:8300 -c 3:"root"  \
      "$DISK"
  else
    sgdisk \
      -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI" \
      -n 2:0:0             -t 2:8300 -c 2:"root" \
      "$DISK"
  fi

  partprobe "$DISK"; sleep 1
  checkpoint "PARTITIONED"
fi

# =============================================================================
# PHASE 2 — FORMAT
# =============================================================================
if done_already "FORMATTED"; then
  skip "Formatting"
else
  step "Formatting partitions"
  mkfs.fat -F32 -n EFI "$PART_BOOT"
  ok "EFI formatted (FAT32)"

  if [[ -n "${PART_SWAP}" ]]; then
    mkswap -L swap "$PART_SWAP"
    swapon "$PART_SWAP"
    ok "Swap created"
  fi

  mkfs.ext4 -L artix-root "$PART_ROOT"
  ok "Root formatted (ext4)"
  checkpoint "FORMATTED"
fi

# =============================================================================
# PHASE 3 — MOUNT
# =============================================================================
if done_already "MOUNTED"; then
  skip "Mounting"
  mountpoint -q "$MOUNT"          || mount "$PART_ROOT" "$MOUNT"
  mountpoint -q "$MOUNT/boot/efi" || { mkdir -p "$MOUNT/boot/efi"; mount "$PART_BOOT" "$MOUNT/boot/efi"; }
else
  step "Mounting filesystems"
  mount "$PART_ROOT" "$MOUNT"
  mkdir -p "$MOUNT/boot/efi"
  mount "$PART_BOOT" "$MOUNT/boot/efi"
  ok "Mounted at $MOUNT"
  checkpoint "MOUNTED"
fi

migrate_state   # state file now lives on the target disk

# =============================================================================
# PHASE 4 — BASESTRAP
# =============================================================================
if done_already "BASESTRAP"; then
  skip "Basestrap"
else
  step "Running basestrap"
  basestrap "$MOUNT" "${BASE_PKGS[@]}"
  ok "Base packages installed"

  fstabgen -U "$MOUNT" >> "$MOUNT/etc/fstab"
  ok "fstab written"
  checkpoint "BASESTRAP"
fi

# =============================================================================
# PHASE 5 — CHROOT
# =============================================================================
if done_already "CHROOT"; then
  skip "Chroot configuration"
else
  step "Entering chroot"

  # FIX 3: Write all variables explicitly to a file on the target disk.
  # More reliable than relying on env var inheritance through artix-chroot.
  cat > "$MOUNT/tmp/install-vars.sh" <<EOF
export HOSTNAME="${HOSTNAME}"
export USERNAME="${USERNAME}"
export LOCALE="${LOCALE}"
export TIMEZONE="${TIMEZONE}"
export KEYMAP="${KEYMAP}"
export WAYLAND_PKGS_STR="${WAYLAND_PKGS[*]}"
export DESKTOP_PKGS_STR="${DESKTOP_PKGS[*]}"
EOF

  artix-chroot "$MOUNT" /bin/bash <<'CHROOT'
set -euo pipefail
source /tmp/install-vars.sh

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; RST='\033[0m'
ok()   { echo -e "${GRN}[ OK ]${RST}  $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
info() { echo -e "\e[34m[INFO]\e[0m  $*"; }

# ── Locale ────────────────────────────────────────────────────────
sed -i "s/^#${LOCALE} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}"   > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
ok "Locale: ${LOCALE}"

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

# ── Pacman ────────────────────────────────────────────────────────
sed -i \
  -e 's/^#ParallelDownloads.*/ParallelDownloads = 10/' \
  -e 's/^#Color/Color/' \
  -e '/^#\[multilib\]/,/^#Include/ s/^#//' \
  /etc/pacman.conf
pacman -Syy --noconfirm
ok "Pacman configured"

# ── Packages ──────────────────────────────────────────────────────
info "Installing Wayland + desktop packages..."
# shellcheck disable=SC2086
pacman -S --noconfirm --needed $WAYLAND_PKGS_STR $DESKTOP_PKGS_STR
ok "Packages installed"

# ── s6 services ───────────────────────────────────────────────────
# FIX 5: Verify each service path exists before symlinking.
# Warn clearly if not found so user can fix post-boot rather than silently failing.
S6_SV="/etc/s6/sv"
S6_ADMIN="/etc/s6/adminsv"
[[ -d "$S6_ADMIN" ]] || mkdir -p "$S6_ADMIN"
for svc in NetworkManager elogind polkit; do
  if [[ -d "${S6_SV}/${svc}" ]]; then
    ln -sf "${S6_SV}/${svc}" "${S6_ADMIN}/${svc}"
    ok "s6: enabled ${svc}"
  else
    warn "s6: ${S6_SV}/${svc} not found — enable manually after boot:"
    warn "  ln -sf ${S6_SV}/${svc} ${S6_ADMIN}/${svc}"
  fi
done

# ── GRUB ──────────────────────────────────────────────────────────
grub-install \
  --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=artix \
  --recheck
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
ok "GRUB installed"

# ── Passwords ─────────────────────────────────────────────────────
echo "root:toor" | chpasswd
warn "Root password: 'toor' — change immediately after first boot"

# ── User + groups ─────────────────────────────────────────────────
# FIX 1: Create each group if missing so useradd never fails on an
# absent group (e.g. 'network' is not always present by default).
for grp in wheel audio video input storage optical network; do
  getent group "$grp" &>/dev/null || groupadd "$grp"
done

if ! id "${USERNAME}" &>/dev/null; then
  useradd -m \
    -G wheel,audio,video,input,storage,optical,network \
    -s /bin/bash "${USERNAME}"
  echo "${USERNAME}:changeme" | chpasswd
  warn "${USERNAME} password: 'changeme' — change after first boot"
  ok "User ${USERNAME} created"
else
  ok "User ${USERNAME} already exists — skipping"
fi

cat > /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/10-wheel
ok "Sudo configured"

# ── paru ──────────────────────────────────────────────────────────
if ! command -v paru &>/dev/null; then
  info "Installing paru..."
  cd /tmp
  git clone https://aur.archlinux.org/paru-bin.git
  chown -R "${USERNAME}:${USERNAME}" paru-bin
  cd paru-bin
  sudo -u "${USERNAME}" makepkg -si --noconfirm
  cd / && rm -rf /tmp/paru-bin
  ok "paru installed"
else
  ok "paru already present"
fi

# ── MangoWM ───────────────────────────────────────────────────────
# FIX 2: Try all known AUR package names — whichever succeeds wins.
info "Installing MangoWM from AUR..."
MANGO_INSTALLED=false
for pkg in mangowm mango mango-wm; do
  if sudo -u "${USERNAME}" paru -S --noconfirm "$pkg" 2>/dev/null; then
    ok "MangoWM installed via AUR package: $pkg"
    MANGO_INSTALLED=true
    break
  fi
done
$MANGO_INSTALLED || warn "MangoWM AUR install failed — run 'paru -S mangowm' after first boot"

# Detect and record the actual installed binary name for .bash_profile
MANGO_BIN=""
for b in mango mangowm mango-wm; do
  command -v "$b" &>/dev/null && MANGO_BIN="$b" && break
done
echo "${MANGO_BIN}" > /tmp/mango-bin
[[ -n "$MANGO_BIN" ]] && ok "MangoWM binary: $MANGO_BIN" || warn "MangoWM binary not detected"

rm -f /tmp/install-vars.sh
CHROOT

  checkpoint "CHROOT"
fi

# =============================================================================
# PHASE 6 — USER CONFIGS
# =============================================================================
if done_already "CONFIGS"; then
  skip "Config deployment"
else
  step "Deploying user configs"

  UHOME="$MOUNT/home/$USERNAME"
  CFG="$UHOME/.config"

  mkdir -p \
    "$CFG/mango" "$CFG/foot" "$CFG/waybar" \
    "$CFG/fuzzel" "$CFG/mako" "$CFG/swaylock" \
    "$UHOME/.local/share/mango" \
    "$UHOME/screenshots" "$UHOME/src"

  # Read binary name written by chroot — fallback to empty (detected at login)
  MANGO_BIN=""
  [[ -f "$MOUNT/tmp/mango-bin" ]] && MANGO_BIN="$(cat "$MOUNT/tmp/mango-bin")"
  rm -f "$MOUNT/tmp/mango-bin"

  # ── MangoWM config — Lua ────────────────────────────────────────
  # FIX 6: Use swaybg -c (solid color) — no wallpaper file needed.
  # Drop a wallpaper.jpg in ~/.config/mango/ and swap the swaybg line to use it.
  cat > "$CFG/mango/config.lua" <<'EOF'
-- MangoWM config — HP ProDesk Mini
-- Run `mango --help` or `mangowm --help` to confirm your build's config API.
local mod = "super"

gaps(8)
border(2)
border_color("#58a6ff", "#30363d")   -- active, inactive

-- Autostart
spawn("waybar")
spawn("mako")
spawn("swaybg -c '#0d1117'")         -- swap for: swaybg -i ~/.config/mango/wallpaper.jpg -m fill
spawn("pipewire")
spawn("pipewire-pulse")
spawn("wireplumber")

-- Core binds
bind(mod, "Return", spawn("foot"))
bind(mod, "d",      spawn("fuzzel"))
bind(mod, "q",      close())
bind(mod .. "+Shift", "r", reload())
bind(mod .. "+Shift", "q", quit())

-- Focus (vim-style)
bind(mod, "h", focus("left"))
bind(mod, "j", focus("down"))
bind(mod, "k", focus("up"))
bind(mod, "l", focus("right"))

-- Move
bind(mod .. "+Shift", "h", move("left"))
bind(mod .. "+Shift", "j", move("down"))
bind(mod .. "+Shift", "k", move("up"))
bind(mod .. "+Shift", "l", move("right"))

-- Workspaces 1–9
for i = 1, 9 do
  bind(mod, tostring(i), workspace(i))
  bind(mod .. "+Shift", tostring(i), move_to_workspace(i))
end

bind(mod, "p", spawn('grim -g "$(slurp)" ~/screenshots/$(date +%Y%m%d_%H%M%S).png'))
bind(mod .. "+ctrl", "l", spawn("swaylock"))

bind("", "XF86AudioRaiseVolume", spawn("wpctl set-volume @DEFAULT_SINK@ 5%+"))
bind("", "XF86AudioLowerVolume", spawn("wpctl set-volume @DEFAULT_SINK@ 5%-"))
bind("", "XF86AudioMute",        spawn("wpctl set-mute @DEFAULT_SINK@ toggle"))
bind("", "XF86AudioPlay",        spawn("playerctl play-pause"))
bind("", "XF86AudioNext",        spawn("playerctl next"))
bind("", "XF86AudioPrev",        spawn("playerctl previous"))
EOF

  # ── MangoWM config — TOML (keep both; delete whichever doesn't apply) ──
  cat > "$CFG/mango/config.toml" <<'EOF'
# MangoWM config (TOML) — use if your build expects TOML instead of Lua.
[general]
gaps = 8
border_width = 2
border_active = "58a6ff"
border_inactive = "30363d"
mod = "super"

[startup]
exec = [
  "waybar", "mako",
  "swaybg -c '#0d1117'",
  "pipewire", "pipewire-pulse", "wireplumber",
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
keys = ["super", "ctrl", "l"]
action = "spawn"
cmd = "swaylock"

[[bind]]
keys = ["XF86AudioRaiseVolume"]
action = "spawn"
cmd = "wpctl set-volume @DEFAULT_SINK@ 5%+"

[[bind]]
keys = ["XF86AudioLowerVolume"]
action = "spawn"
cmd = "wpctl set-volume @DEFAULT_SINK@ 5%-"

[[bind]]
keys = ["XF86AudioMute"]
action = "spawn"
cmd = "wpctl set-mute @DEFAULT_SINK@ toggle"
EOF

  # ── foot ────────────────────────────────────────────────────────
  cat > "$CFG/foot/foot.ini" <<'EOF'
[main]
font=JetBrains Mono:size=11
pad=8x8
term=xterm-256color

[scrollback]
lines=5000

[colors]
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

  # ── waybar ──────────────────────────────────────────────────────
  cat > "$CFG/waybar/config" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 28,
  "spacing": 4,
  "modules-left": ["wlr/workspaces", "wlr/mode"],
  "modules-center": ["clock"],
  "modules-right": ["network", "pulseaudio", "cpu", "memory", "temperature", "tray"],
  "wlr/workspaces": { "on-click": "activate" },
  "clock": {
    "format": " {:%a %b %d  %H:%M}",
    "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>"
  },
  "cpu":    { "interval": 3, "format": " {usage}%" },
  "memory": { "interval": 5, "format": " {used:.1f}G / {total:.1f}G" },
  "temperature": {
    "critical-threshold": 85,
    "format": " {temperatureC}°C",
    "format-critical": " {temperatureC}°C"
  },
  "network": {
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
  "tray": { "spacing": 8 }
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
  border-bottom: 2px solid transparent;
}
#workspaces button.active  { color: #58a6ff; border-bottom: 2px solid #58a6ff; }
#workspaces button:hover   { color: #c9d1d9; background: #21262d; }
#clock       { color: #c9d1d9; padding: 0 12px; }
#cpu         { color: #3fb950; padding: 0 8px; }
#memory      { color: #bc8cff; padding: 0 8px; }
#temperature { color: #d29922; padding: 0 8px; }
#temperature.critical { color: #ff7b72; }
#network     { color: #58a6ff; padding: 0 8px; }
#pulseaudio  { color: #d29922; padding: 0 8px; }
#tray        { padding: 0 8px; }
EOF

  # ── fuzzel ──────────────────────────────────────────────────────
  cat > "$CFG/fuzzel/fuzzel.ini" <<'EOF'
[main]
font=JetBrains Mono:size=12
terminal=foot -e
layer=overlay
width=35
lines=12
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

  # ── mako ────────────────────────────────────────────────────────
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

  # ── swaylock ────────────────────────────────────────────────────
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

  # ── .bashrc ─────────────────────────────────────────────────────
  cat > "$UHOME/.bashrc" <<'EOF'
[[ $- != *i* ]] && return

PS1='\[\e[36m\]\u\[\e[0m\]@\[\e[34m\]\h\[\e[0m\]:\[\e[33m\]\w\[\e[0m\]\$ '

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

eval "$(zoxide init bash)"

[[ -f /usr/share/fzf/key-bindings.bash ]] && source /usr/share/fzf/key-bindings.bash
[[ -f /usr/share/fzf/completion.bash   ]] && source /usr/share/fzf/completion.bash

export FZF_DEFAULT_OPTS='
  --color=bg+:#21262d,bg:#0d1117,spinner:#58a6ff,hl:#58a6ff
  --color=fg:#c9d1d9,header:#58a6ff,info:#d29922,pointer:#58a6ff
  --color=marker:#3fb950,fg+:#c9d1d9,prompt:#bc8cff,hl+:#79c0ff'

export XDG_SESSION_TYPE=wayland
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM=wayland
export SDL_VIDEODRIVER=wayland
export CLUTTER_BACKEND=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
export EDITOR=vim
export VISUAL=vim
export BROWSER=firefox
export TERMINAL=foot
export PATH="$HOME/.local/bin:$PATH"
EOF

  # ── .bash_profile — auto-start MangoWM on tty1 ─────────────────
  # FIX 2: If binary was detected at install time, hard-code it.
  # Otherwise fall back to runtime detection — never fails silently.
  # WLR_RENDERER removed — let wlroots auto-detect (vulkan flaky on HD 530).
  if [[ -n "$MANGO_BIN" ]]; then
    cat > "$UHOME/.bash_profile" <<EOF
[[ -f ~/.bashrc ]] && . ~/.bashrc

if [[ -z "\${WAYLAND_DISPLAY:-}" && "\${XDG_VTNR:-0}" -eq 1 ]]; then
  export XDG_SESSION_TYPE=wayland
  export XDG_CURRENT_DESKTOP=mango
  export MOZ_ENABLE_WAYLAND=1
  export QT_QPA_PLATFORM=wayland
  export SDL_VIDEODRIVER=wayland
  export CLUTTER_BACKEND=wayland
  export _JAVA_AWT_WM_NONREPARENTING=1
  export WLR_NO_HARDWARE_CURSORS=1   # set to 0 if cursor renders correctly

  mkdir -p ~/.local/share/mango
  exec ${MANGO_BIN} > ~/.local/share/mango/mango.log 2>&1
fi
EOF
  else
    # Binary unknown — detect at login time
    cat > "$UHOME/.bash_profile" <<'EOF'
[[ -f ~/.bashrc ]] && . ~/.bashrc

if [[ -z "${WAYLAND_DISPLAY:-}" && "${XDG_VTNR:-0}" -eq 1 ]]; then
  export XDG_SESSION_TYPE=wayland
  export XDG_CURRENT_DESKTOP=mango
  export MOZ_ENABLE_WAYLAND=1
  export QT_QPA_PLATFORM=wayland
  export SDL_VIDEODRIVER=wayland
  export CLUTTER_BACKEND=wayland
  export _JAVA_AWT_WM_NONREPARENTING=1
  export WLR_NO_HARDWARE_CURSORS=1   # set to 0 if cursor renders correctly

  MANGO_BIN=""
  for b in mango mangowm mango-wm; do
    command -v "$b" &>/dev/null && MANGO_BIN="$b" && break
  done

  if [[ -z "$MANGO_BIN" ]]; then
    echo "ERROR: MangoWM not found. Run: paru -S mangowm"
    sleep 5
  else
    mkdir -p ~/.local/share/mango
    exec "$MANGO_BIN" > ~/.local/share/mango/mango.log 2>&1
  fi
fi
EOF
  fi

  # ── .vimrc ──────────────────────────────────────────────────────
  cat > "$UHOME/.vimrc" <<'EOF'
set nocompatible
set number relativenumber
set expandtab tabstop=2 shiftwidth=2
set smartindent autoindent
set incsearch hlsearch ignorecase smartcase
set wildmenu wildmode=longest:full
set laststatus=2 ruler showcmd
set wrap linebreak scrolloff=5
set backspace=indent,eol,start
set encoding=utf-8
set mouse=a
set clipboard=unnamedplus
syntax on
colorscheme desert
EOF

  # FIX 4: Use username string — UID 1000 is not guaranteed
  chown -R "${USERNAME}:${USERNAME}" "$UHOME"
  ok "Configs deployed — ownership: ${USERNAME}:${USERNAME}"

  checkpoint "CONFIGS"
fi

# =============================================================================
# PHASE 7 — VERIFY
# =============================================================================
step "Verifying installation"

checks_passed=0; checks_total=0

check() {
  local label="$1" path="$2"
  checks_total=$((checks_total + 1))
  if [[ -e "$MOUNT/$path" ]]; then
    ok "$label"
    checks_passed=$((checks_passed + 1))
  else
    warn "$label — NOT FOUND: $path"
  fi
}

# FIX 7: Check all known MangoWM binary names — pass if any one exists
check_any() {
  local label="$1"; shift
  checks_total=$((checks_total + 1))
  for path in "$@"; do
    if [[ -e "$MOUNT/$path" ]]; then
      ok "$label  (${path##*/})"
      checks_passed=$((checks_passed + 1))
      return
    fi
  done
  warn "$label — not found at any of: $*"
}

check     "Kernel"         "boot/vmlinuz-linux"
check     "Initramfs"      "boot/initramfs-linux.img"
check     "GRUB EFI"       "boot/efi/EFI/artix/grubx64.efi"
check     "fstab"          "etc/fstab"
check     "s6 dir"         "etc/s6"
check     "NetworkManager" "usr/bin/NetworkManager"
check     "foot"           "usr/bin/foot"
check     "waybar"         "usr/bin/waybar"
check     "pipewire"       "usr/bin/pipewire"
check     "XWayland"       "usr/bin/Xwayland"
check     "User home"      "home/${USERNAME}"
check     "foot config"    "home/${USERNAME}/.config/foot/foot.ini"
check     "bash_profile"   "home/${USERNAME}/.bash_profile"
check_any "MangoWM"        "usr/bin/mango" "usr/bin/mangowm" "usr/bin/mango-wm"

echo ""
echo -e "  Checks: ${GRN}${checks_passed}${RST} / ${checks_total} passed"
[[ $checks_passed -lt $checks_total ]] && \
  warn "$((checks_total - checks_passed)) check(s) failed — review above before rebooting"

checkpoint "VERIFIED"

# =============================================================================
# UNMOUNT
# =============================================================================
step "Unmounting"
sync
umount -R "$MOUNT"
ok "Unmounted cleanly"

echo ""
echo -e "${BOLD}${GRN}"
cat <<'DONE'
  ┌──────────────────────────────────────────────────────────┐
  │   Installation complete!                                 │
  └──────────────────────────────────────────────────────────┘
DONE
echo -e "${RST}"
echo -e "  ${BOLD}Post-boot checklist:${RST}"
echo ""
echo -e "  1. ${YLW}Change root password${RST}   →  passwd"
echo -e "  2. ${YLW}Change user password${RST}   →  passwd ${USERNAME}"
echo -e "  3. ${YLW}Connect network${RST}        →  nmtui"
echo -e "  4. ${YLW}Verify s6 services${RST}     →  s6-rc -a list"
echo -e "  5. ${YLW}Check MangoWM config${RST}   →  mango --help  (Lua vs TOML)"
echo -e "     Delete whichever config.{lua,toml} doesn't match your build."
echo ""
echo -e "  Log in as ${USERNAME} on tty1 — MangoWM starts automatically."
echo -e "  If it fails: check ~/.local/share/mango/mango.log"
echo ""
echo -e "  ${CYN}Reboot:${RST}  reboot"
echo ""
