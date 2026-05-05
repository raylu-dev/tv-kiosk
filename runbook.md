# tv-kiosk runbook

Operational guide for the office TV kiosk. The README covers install. This covers everything that happens after.

## Architecture in 30 seconds

- **Display stack:** systemd unit `kiosk.service` runs `cage` (Wayland compositor) which spawns `chromium --kiosk`. If chromium crashes, cage exits, systemd restarts the unit. `systemctl status kiosk` reflects actual display health.
- **Watchdog:** `kiosk-watchdog.timer` fires every 5 minutes. Checks origin reachability, chromium devtools, and that the page isn't on a `chrome-error://` screen. One failure → restart kiosk. Two consecutive failures → reboot.
- **Nightly reboot:** `kiosk-nightly-reboot.timer` reboots at 04:30. Unattended-upgrades runs at 04:00 and may also reboot. Either way, the box gets a fresh start daily.
- **Resource isolation:** `kiosk.slice` reserves CPU/memory for the display. `sidejobs.slice` caps anything else. Side jobs literally cannot starve the TV.
- **Access:** Tailscale only. `ssh kiosk@tv-kiosk` from anyone in `group:eng`. UFW denies all incoming except on `tailscale0`. System sshd is key-only, no root, but only reachable through the tailnet.
- **Storage:** journald is volatile (RAM only, capped at 100M). `/tmp` is tmpfs. Chromium's disk cache lives on tmpfs. The eMMC sees minimal writes.

## Common tasks

### Change the URL

```bash
ssh kiosk@tv-kiosk
sudo $EDITOR /etc/kiosk-url.env
sudo systemctl restart kiosk
```

### Add a teammate

In the Tailscale admin console, add them to `group:eng`. The ACL allows `group:eng` to SSH `tag:kiosk` as user `kiosk`. They can immediately `ssh kiosk@tv-kiosk` from their tailnet-connected machine.

### Add a Slack webhook for watchdog alerts

```bash
ssh kiosk@tv-kiosk
sudo tee /etc/kiosk-watchdog.env <<EOF
WATCHDOG_WEBHOOK=https://hooks.slack.com/services/...
EOF
sudo chmod 600 /etc/kiosk-watchdog.env
```

No service restart needed; the watchdog sources this on each run.

### Add a side cron job

Side jobs **must** be on `sidejobs.slice` so they can't starve the display:

```ini
# /etc/systemd/system/sidejob-myjob.service
[Unit]
Description=My side job
[Service]
Type=oneshot
ExecStart=/usr/local/bin/myjob.sh
Slice=sidejobs.slice
```

Pair with a `.timer` for scheduling. **Code review rule: any service on this box without `Slice=sidejobs.slice` (other than `kiosk.service` itself) is a bug.**

### Wake the box from off

```bash
wakeonlan <mac>     # from any LAN machine
```

(WoL doesn't traverse the tailnet — needs to be on the same broadcast domain.)

## Troubleshooting

### TV is black / "no signal"

1. Check the TV is on the right input.
2. SSH in: `ssh kiosk@tv-kiosk`. If SSH works, the box is alive — display side is the problem.
3. `sudo systemctl status kiosk` — running? failed?
4. `journalctl -u kiosk -n 200` — look for cage or chromium errors.
5. Hard reset: `sudo reboot`.

### TV shows "Aw, Snap" or chrome-error page

Watchdog will catch this within 5 minutes and restart kiosk. To force immediately: `sudo systemctl restart kiosk`. If it persists, the upstream URL is probably down — check from your Mac.

### Image is rotated wrong / sideways / upside-down

The rotation is controlled by `WLR_OUTPUT_TRANSFORM` in `/etc/systemd/system/kiosk.service`. Values:

- `0` — no rotation (landscape)
- `1` — 90° clockwise
- `2` — 180° (upside-down)
- `3` — 270° clockwise (= 90° counter-clockwise)

Edit, then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart kiosk
```

If `cage` errors out on the env var (older versions ignore it), pass it as a flag instead: change `cage -s --` to `cage -s -r 3 --`. Requires cage ≥ 0.1.5; install from `bookworm-backports` if needed.

### Tailscale is down, can't SSH

Recovery path: borrow a USB keyboard, plug into the Wyse, hit `Ctrl+Alt+F2` to get a getty (cage doesn't grab all VTs). Log in as `kiosk` (password from the Debian install). From there:

```bash
sudo tailscale status         # what does it think?
sudo systemctl restart tailscaled
sudo tailscale up --authkey=<new-key> --ssh --hostname=tv-kiosk --advertise-tags=tag:kiosk
```

If Tailscale itself is the problem (rare): UFW only allows `tailscale0`. To temporarily allow LAN SSH from a specific IP:

```bash
sudo ufw allow from <your-laptop-lan-ip> to any port 22
```

Remove it once you're done debugging.

### Office IP changed and the URL won't load

`raylove.raylu.ai/tv` is IP-allowlisted. If the office WAN IP changes (ISP rotation, office move), update the allowlist in the raylove config. Until then, the watchdog will reboot the box every ~10 minutes, which won't help — `sudo systemctl stop kiosk-watchdog.timer` until the URL is reachable again.

### Disk is filling up

Shouldn't happen — journald is volatile and `/tmp` is tmpfs. If it does:

```bash
df -h
sudo du -shx /var/* 2>/dev/null | sort -h | tail
```

Likely culprit: someone added a side job that writes logs to `/var/log` without rotation. Add log rotation or redirect to journald.

## TV settings (per device, do once)

After mounting:

- Auto input switching: **off**
- Eco / energy saving / "no signal power off": **off**
- Picture mode: **PC** or **Game**
- HDMI input label: **PC** (disables overscan + motion smoothing on most brands)
- Aspect ratio: **Just Scan** / **Screen Fit** / **1:1** / **Dot by Dot**

## Re-running the installer

`install.sh` is idempotent. If the box's config drifts or you want to apply changes from the repo, you can re-run it. The Tailscale step will skip if already joined; everything else converges. Re-running does **not** preserve the Tailscale auth key (you don't need it again) but you do need to pass `KIOSK_URL` again. To skip Tailscale on a re-run, comment out `phase_tailscale` in `main()`.

## Adding a second TV

The install is hostname-agnostic. For TV #2:

```bash
sudo TS_AUTHKEY=... KIOSK_URL=... KIOSK_HOSTNAME=tv-kiosk-2 KIOSK_ROTATION=3 bash install.sh
```

If you find yourself doing this more than twice, port `install.sh` to Ansible. The phase functions map cleanly to roles.
