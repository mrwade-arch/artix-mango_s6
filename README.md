# artix-mango_r6

Automated installer for [Artix Linux](https://artixlinux.org/) (s6 init) + [MangoWM](https://github.com/mangowm/mango) — a dwm-style Wayland compositor.

## What it installs

- Artix Linux base with **s6** init
- **MangoWM** (from AUR) — lightweight Wayland compositor
- Minimal dwm-philosophy toolset:
  - `foot` — terminal
  - `rofi-wayland` — keyboard-driven launcher
  - `waybar` — status bar
  - `grim` + `slurp` — screenshot pipeline
  - `swaybg` — wallpaper
  - `wl-clipboard` — clipboard
  - `swaync` — notifications
  - `swaylock-effects` — lockscreen
  - `wlogout` — logout menu
- Intel GPU drivers (mesa, vulkan-intel)
- PipeWire audio
- NetworkManager

## Requirements

- Artix Linux base-s6 ISO booted via USB
- x86_64 machine
- UEFI firmware
- Internet connection
- 1TB HDD (or adjust partitioning in the script)

## Partition layout

| Partition | Size | Type |
|-----------|------|------|
| /dev/sdX1 | 512MB | EFI |
| /dev/sdX2 | 8GB | swap |
| /dev/sdX3 | remainder | root (ext4) |

## Usage

Boot the Artix base-s6 ISO, log in as root, then:

```bash
curl -O https://raw.githubusercontent.com/mrwade-arch/artix-mango_r6/main/install-artix-mango.sh
bash install-artix-mango.sh
```

The script will prompt you for:
- Target disk
- Hostname
- Username + password
- Root password
- Timezone
- Locale

> ⚠️ This will **wipe the target disk completely**. Double-check your disk name before confirming.

## After install

Remove the USB and reboot. Log in as your user on TTY1 — MangoWM launches automatically.

## Default keybindings

| Keybind | Action |
|---------|--------|
| `Alt+Enter` | Open terminal (foot) |
| `Alt+Space` | Open launcher (rofi) |
| `Alt+Q` | Kill focused window |
| `Alt+←/→/↑/↓` | Focus direction |
| `Super+M` | Quit MangoWM |

Full keybinding reference: [MangoWM wiki](https://github.com/mangowm/mango/wiki)

## Config

MangoWM config is pulled from [mango-config](https://github.com/DreamMaoMao/mango-config) into `~/.config/mango`. Edit to taste after install.

## License

MIT — see [LICENSE](LICENSE)
 
