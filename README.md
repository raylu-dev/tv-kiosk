# tv-kiosk

Office TV kiosk on a Wyse 5070. Boots, displays a URL, restarts itself when broken, reboots itself nightly. SSH access via Tailscale.

## Initial install (one time, ~25 min total)

### 1. BIOS (5 min, needs keyboard on the Wyse)

Boot into BIOS (Del or F2):

- AC Power Recovery → **Power On**
- Wake-on-LAN → **Enabled**
- Secure Boot → **Disabled**
- Note the MAC address

Plug in ethernet (not Wi-Fi). Surge protector recommended.

### 2. Debian 12 minimal (10 min, needs keyboard)

Flash `debian-12-netinst-amd64.iso` to USB on your Mac. Boot the Wyse from USB. Install:

- No desktop environment, no print server
- Standard system utilities + SSH server
- Create user `kiosk` with a temporary password (you won't use it after install)
- Let it install GRUB to the eMMC

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
mac:       __:__:__:__:__:__     (fill in after BIOS)
repo:      github.com/raylu-dev/tv-kiosk
```

See [`runbook.md`](runbook.md) for everything else (rotation fix, side cron jobs, recovery, TV settings).
