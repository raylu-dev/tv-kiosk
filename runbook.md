# tv-kiosk runbook

Operational guide for the office TV kiosk. The README covers install. This covers everything that happens after.

## Architecture in 30 seconds

- **Display stack:** systemd unit `kiosk.service` runs `weston` (Wayland compositor) with `kiosk-shell.so`, which auto-launches `brave-browser --kiosk` via `/usr/local/bin/kiosk-launch.sh`. Config in `/etc/weston/weston.ini`. If Brave crashes, weston exits (`watch=true`), systemd restarts the unit. `systemctl status kiosk` reflects actual display health. Brave is used instead of Chromium because Ubuntu ships Chromium only as a snap. Weston is used instead of cage because Ubuntu's cage 0.1.5 lacks output rotation support.
- **Watchdog:** `kiosk-watchdog.timer` fires every 5 minutes. Checks origin reachability, chromium devtools, and that the page isn't on a `chrome-error://` screen. One failure → restart kiosk. Two consecutive failures → reboot.
- **Periodic refresh:** `kiosk-reload.timer` fires every 90 minutes and runs `/usr/local/bin/kiosk-soft-reload`, which sends a CDP `Page.reload` to Brave on `127.0.0.1:9222`. The page reloads in place — weston keeps running, no HDMI signal gap, so the panel doesn't get a chance to sleep. (Earlier versions of this kiosk did `systemctl restart kiosk.service` every 30 min, which blanked HDMI long enough for the Hisense Fire TV to trip its "no signal" auto-off and never wake up.)
- **No nightly reboot:** the box does not reboot itself on a schedule. `unattended-upgrades` handles security updates at 04:00 UTC and will reboot if a package requires it (`/etc/apt/apt.conf.d/50unattended-upgrades`). On most nights, no reboot happens at all — same reason as above (HDMI blanks → TV sleeps → doesn't auto-wake).
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
5. **Check the TV itself** before rebooting the box. The Hisense Fire TV sleeps on "no signal" and won't always auto-wake when HDMI returns. Grab the remote, press power, see if the page is already there. If yes → it's the TV's `Auto Power-Off` / `No Signal Auto-Off` settings; set both to *Never*.
6. Hard reset: `sudo reboot`. Note: this blanks HDMI for ~60 s, which often re-triggers the TV's sleep. Have the remote ready.

### TV shows "Aw, Snap" or chrome-error page

Watchdog will catch this within 5 minutes and restart kiosk. To force immediately: `sudo systemctl restart kiosk`. If it persists, the upstream URL is probably down — check from your Mac.

### Brave shows a welcome / onboarding page instead of the URL

Should not happen — `--no-first-run --no-default-browser-check` plus the `PromotionalTabsEnabled=false` policy in `/etc/brave/policies/managed/kiosk.json` suppress all of it. If it does: check that file exists, run `sudo systemctl restart kiosk`. If still broken, blow away Brave's profile: `sudo rm -rf /home/kiosk/.config/BraveSoftware && sudo systemctl restart kiosk`.

### Image is rotated wrong / sideways / upside-down

Edit `transform=` in `/etc/weston/weston.ini` under `[output]`. Valid values:

- `normal` — no rotation
- `rotate-90` — 90° clockwise (top of screen on the right as you face it)
- `rotate-180` — upside down
- `rotate-270` — 90° counter-clockwise (top of screen on the left)

Then `sudo systemctl restart kiosk`. No daemon-reload needed (weston re-reads its config on start).

Our office TV is on `rotate-90` (mounted vertically with the bottom of the screen on the left).

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

## Slack bot (`/raylu`)

The kiosk runs a Slack bot via Socket Mode (no public endpoint). Anyone in the workspace can fire celebrations from any channel or DM.

```
/raylu list                          # show all available celebrations
/raylu celebrate
/raylu easy
/raylu money
/raylu walkup <youtube-url> [name]
/raylu reset                         # force-clear stuck overlay
```

Replies are ephemeral (only the invoker sees them) so channels stay clean.

### Architecture
- `/etc/raylu-slackbot.env` — `SLACK_BOT_TOKEN` (xoxb-…) + `SLACK_APP_TOKEN` (xapp-…), chmod 600
- `/etc/raylu-celebrations.json` — registry of `name → {description, binary, progress_message?}`
- `/usr/local/bin/raylu-slackbot.py` — slack_bolt + Socket Mode handler
- `raylu-slackbot.service` — systemd unit, auto-restart, logs to journald
- Concurrency: `flock` on `/run/raylu-celebration.lock` — only one celebration runs at a time

The bot reloads the registry on every command — no restart needed when you add a new celebration to the JSON.

### Add a new celebration

1. Drop the script in `scripts/` of the repo, make it executable
2. Add an entry to `scripts/raylu-celebrations.json`:
   ```json
   "yourthing": {
     "description": "🎯 What it does",
     "binary": "/usr/local/bin/yourthing",
     "progress_message": "optional immediate-ack message for long-running ones"
   }
   ```
3. Commit + push
4. On the kiosk: `curl -fsSL <repo-raw>/scripts/yourthing -o /usr/local/bin/yourthing && chmod +x /usr/local/bin/yourthing && curl -fsSL <repo-raw>/scripts/raylu-celebrations.json -o /etc/raylu-celebrations.json`
5. Try it: `/raylu yourthing`

No bot restart needed.

### Mute / unmute (developer-only, NOT in Slack)

The audio mute flag is a developer command, not exposed to Slack:

```bash
ssh root@tv-kiosk mute       # /etc/kiosk-mute touched, all audio suppressed
ssh root@tv-kiosk unmute
```

Default after a fresh install is muted.

### Bot logs / debugging

```bash
ssh root@tv-kiosk 'journalctl -u raylu-slackbot -n 100 --no-pager'
ssh root@tv-kiosk 'journalctl -u raylu-slackbot -f'   # live tail
```

The bot logs every command with the Slack user + channel, so "who fired what" is traceable.

### Rotate Slack tokens

If a token leaks (always rotate after pasting into a chat transcript):

1. https://api.slack.com/apps → Raylu TV → **Basic Information** → "Regenerate" buttons
2. `ssh root@tv-kiosk` → edit `/etc/raylu-slackbot.env` with the new tokens
3. `systemctl restart raylu-slackbot`

### Disable the bot

```bash
ssh root@tv-kiosk 'systemctl disable --now raylu-slackbot'
```

`/raylu` commands will fail (Slack will say "the app didn't respond"). To re-enable: `systemctl enable --now raylu-slackbot`.

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
