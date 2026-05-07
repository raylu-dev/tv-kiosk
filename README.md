# tv-kiosk

Office TV kiosk on a Wyse 5070. Ubuntu Server 24.04 + cage (Wayland compositor) + Brave in `--kiosk` mode. Restarts itself when broken, reboots itself nightly. SSH access via Tailscale.

Brave is used instead of Chromium because Ubuntu only ships Chromium as a snap, which is hostile to Wayland/cage kiosks.

## Initial install (one time, ~25 min total)

### 1. BIOS (5 min, needs keyboard on the Wyse)

Boot into BIOS (Del or F2):

- AC Power Recovery → **Power On**
- Wake-on-LAN → **Enabled**
- Secure Boot → **Disabled**
- Note the MAC address

Plug in ethernet (not Wi-Fi). Surge protector recommended.

### 2. Ubuntu Server 24.04 (10 min, needs keyboard)

Flash `ubuntu-24.04.x-live-server-amd64.iso` to USB on your Mac. Boot the Wyse from USB. Install with the **subiquity** installer:

- Language: English
- Keyboard: defaults
- Install type: **Ubuntu Server** (NOT minimized)
- Network: DHCP if your office allows it; otherwise pick "Edit IPv4" → Manual and set static
- Mirror: defaults
- Storage: **Use entire disk** (the eMMC, ~32GB) → no LVM
- Profile: name=`kiosk`, server name=`tv-kiosk`, username=`kiosk`, password=anything (you won't use it after install)
- Skip Ubuntu Pro
- **Install OpenSSH server**: yes
- Featured snaps: skip all

Reboot, log in once on the console as `kiosk`.

### 3. Run installer (5 min, hands-off)

Mint a Tailscale pre-auth key in the admin console:

- https://login.tailscale.com/admin/settings/keys
- Single-use, non-ephemeral, tag: `tag:kiosk`

Then on the Wyse console:

```bash
curl -fsSL https://raw.githubusercontent.com/raylu-dev/tv-kiosk/main/install.sh \
  | sudo TS_AUTHKEY=tskey-auth-... KIOSK_URL=https://raylove.raylu.ai/tv bash
```

The script installs everything, joins Tailscale, locks the firewall, enables services, and reboots. After it comes back up, the TV shows the URL.

### 4. Walk away

Unplug the keyboard. From your Mac (or any teammate's machine on the Raylu tailnet):

```bash
ssh kiosk@tv-kiosk
```

You're done.

## Celebration commands

Six commands installed on the kiosk for triggering visual + audio celebrations from anywhere on the tailnet (e.g. wired into Slack later). Each is a Python script that injects JS into the running Brave page via the devtools port — no page reload, no service restart.

| Command | Effect |
|---|---|
| `celebrate` | Confetti rain + emoji rain + rainbow banner + 6-sec synthesized fanfare |
| `easy` | Big red EASY button presses, camera flash, paparazzi mini-flashes, BOOM starburst sticker, "THAT WAS EASY" with ElevenLabs voice |
| `money` | "MONEY MONEY" gold text, gold confetti rain + side cannons, live counter scrolling $0 → ~$1-10M, cash pile building at the bottom, ka-ching synth |
| `walkup <url-or-path> [name]` | Stadium spotlights + sweeping stage lights + announcer text + plays the audio you give it |
| `mute` | Touches `/etc/kiosk-mute` — all four celebrations go silent (visuals still run) |
| `unmute` | Removes the flag — sound returns |

Default state is muted until operator unmutes.

Trigger from anywhere on the tailnet:
```bash
ssh root@tv-kiosk celebrate
ssh root@tv-kiosk easy
ssh root@tv-kiosk money
ssh root@tv-kiosk walkup "https://example.com/song.mp3" "Joe Smith"
ssh root@tv-kiosk unmute    # turn audio on first
```

## Day-to-day

| What | How |
|---|---|
| Change the URL | `ssh kiosk@tv-kiosk` → edit `/etc/kiosk-url.env` → `sudo systemctl restart kiosk` |
| Restart the display | `ssh kiosk@tv-kiosk 'sudo systemctl restart kiosk'` |
| Reboot the box | `ssh kiosk@tv-kiosk 'sudo reboot'` |
| See logs | `ssh kiosk@tv-kiosk 'journalctl -u kiosk -n 200'` |
| Wake from off | `wakeonlan <mac>` from any LAN machine |

## Card to tape on the back of the TV

```
hostname:  tv-kiosk
ssh:       ssh kiosk@tv-kiosk    (Tailscale; add yourself to group:eng)
url file:  /etc/kiosk-url.env
restart:   sudo systemctl restart kiosk
reboot:    sudo reboot
logs:      journalctl -u kiosk -n 200
mac:       b4:45:06:49:d7:1b
repo:      github.com/raylu-dev/tv-kiosk
```

See [`runbook.md`](runbook.md) for everything else (rotation fix, side cron jobs, recovery, TV settings).
