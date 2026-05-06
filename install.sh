#!/bin/bash
# tv-kiosk installer — Ubuntu Server 24.04 → cage+brave kiosk on Tailscale.
# One-shot, idempotent. Re-run anytime to converge config back to the source of truth here.
#
# Brave is used instead of Chromium because Ubuntu ships Chromium only as a snap,
# which is hostile to Wayland/cage kiosks.
#
# Usage (after fresh Ubuntu install, with `kiosk` user already created):
#   curl -fsSL https://raw.githubusercontent.com/raylu-dev/tv-kiosk/main/install.sh \
#     | sudo TS_AUTHKEY=tskey-auth-... KIOSK_URL=https://... bash
#
# Or paste the file directly and:
#   sudo TS_AUTHKEY=... KIOSK_URL=... bash install.sh

set -euo pipefail

: "${TS_AUTHKEY:?Set TS_AUTHKEY (Tailscale pre-auth key, tag:kiosk)}"
: "${KIOSK_URL:?Set KIOSK_URL (e.g. https://example.com)}"

KIOSK_HOSTNAME="${KIOSK_HOSTNAME:-tv-kiosk}"
KIOSK_USER="${KIOSK_USER:-kiosk}"
# wlroots output transforms: 0=normal, 1=90°CW, 2=180°, 3=270°CW (bottom-on-left).
KIOSK_ROTATION="${KIOSK_ROTATION:-3}"
WATCHDOG_WEBHOOK="${WATCHDOG_WEBHOOK:-}"

[[ $EUID -eq 0 ]] || { echo "must run as root (use sudo)"; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

phase_packages() {
  log "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    cage \
    openssh-server \
    curl ca-certificates gnupg \
    ufw unattended-upgrades \
    jq wakeonlan etherwake \
    tmux htop

  log "Adding Brave apt repo + installing brave-browser"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    -o /etc/apt/keyrings/brave-browser-archive-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list
  apt-get update -y
  apt-get install -y --no-install-recommends brave-browser
}

phase_brave_policies() {
  log "Installing Brave managed policies (disable Rewards/Wallet/News/AI/etc.)"
  install -d -m 0755 /etc/brave/policies/managed
  cat > /etc/brave/policies/managed/kiosk.json <<'EOF'
{
  "BraveRewardsDisabled": true,
  "BraveWalletDisabled": true,
  "BraveAIChatEnabled": false,
  "BraveVPNDisabled": true,
  "BraveNewsDisabled": true,
  "BraveTalkDisabled": true,
  "BraveSyncDisabled": true,
  "TorDisabled": true,
  "AutofillAddressEnabled": false,
  "AutofillCreditCardEnabled": false,
  "PasswordManagerEnabled": false,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "PromotionalTabsEnabled": false,
  "BackgroundModeEnabled": false
}
EOF
}

phase_user() {
  log "Ensuring user $KIOSK_USER"
  id "$KIOSK_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$KIOSK_USER"
  # Ubuntu/Debian PAM ships a rule that lets users in `nopasswdlogin` skip
  # password prompts. Adding kiosk lets PAMName=login succeed without a password.
  getent group nopasswdlogin >/dev/null || groupadd --system nopasswdlogin
  for grp in nopasswdlogin video input render tty; do
    getent group "$grp" >/dev/null && usermod -aG "$grp" "$KIOSK_USER" || true
  done
}

phase_hostname() {
  log "Setting hostname to $KIOSK_HOSTNAME"
  hostnamectl set-hostname "$KIOSK_HOSTNAME"
}

phase_emmc_preserve() {
  log "Configuring eMMC-friendly storage"
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/volatile.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=100M
EOF

  if ! grep -q '^tmpfs /tmp' /etc/fstab; then
    echo 'tmpfs /tmp tmpfs defaults,noatime,size=512M 0 0' >> /etc/fstab
  fi
}

phase_unattended_upgrades() {
  log "Configuring unattended-upgrades + 04:00 reboot"
  cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}";
  "${distro_id}:${distro_codename}-security";
  "${distro_id}ESMApps:${distro_codename}-apps-security";
  "${distro_id}ESM:${distro_codename}-infra-security";
  "${distro_id}:${distro_codename}-updates";
};
Unattended-Upgrade::Origins-Pattern {
  "origin=Brave Software";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

phase_kiosk_url() {
  log "Writing /etc/kiosk-url.env"
  cat > /etc/kiosk-url.env <<EOF
KIOSK_URL=${KIOSK_URL}
EOF
  chmod 644 /etc/kiosk-url.env
}

phase_slices() {
  log "Installing systemd slices (kiosk reserved, sidejobs capped)"
  cat > /etc/systemd/system/kiosk.slice <<'EOF'
[Slice]
CPUWeight=200
MemoryHigh=2G
EOF

  cat > /etc/systemd/system/sidejobs.slice <<'EOF'
[Slice]
CPUQuota=50%
MemoryMax=2G
EOF
}

phase_kiosk_service() {
  log "Installing kiosk.service"
  local kiosk_uid
  kiosk_uid="$(id -u "$KIOSK_USER")"

  cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=TV kiosk (cage + brave)
After=network-online.target systemd-user-sessions.service
Wants=network-online.target

[Service]
Type=simple
User=${KIOSK_USER}
Group=${KIOSK_USER}
PAMName=login
WorkingDirectory=/home/${KIOSK_USER}
EnvironmentFile=/etc/kiosk-url.env
Environment=XDG_RUNTIME_DIR=/run/user/${kiosk_uid}
Environment=WLR_LIBINPUT_NO_DEVICES=1
Environment=WLR_OUTPUT_TRANSFORM=${KIOSK_ROTATION}

ExecStart=/usr/bin/cage -s -- /usr/bin/brave-browser \\
  --kiosk \\
  --ozone-platform=wayland \\
  --enable-features=UseOzonePlatform \\
  --password-store=basic \\
  --noerrdialogs \\
  --disable-infobars \\
  --disable-translate \\
  --disable-features=TranslateUI \\
  --disable-pinch \\
  --overscroll-history-navigation=0 \\
  --no-first-run \\
  --no-default-browser-check \\
  --check-for-update-interval=31536000 \\
  --incognito \\
  --disk-cache-dir=/tmp/brave-cache \\
  --disk-cache-size=104857600 \\
  --remote-debugging-port=9222 \\
  --remote-debugging-address=127.0.0.1 \\
  \${KIOSK_URL}

Restart=always
RestartSec=5
Slice=kiosk.slice

[Install]
WantedBy=multi-user.target
EOF
}

phase_watchdog() {
  log "Installing watchdog"
  cat > /usr/local/bin/kiosk-watchdog.sh <<'WATCHDOG'
#!/bin/bash
# Verifies origin reachability + browser health every 5 min. One fail restarts
# kiosk; two consecutive fails reboot. Browser is Brave (Chromium-based, so the
# devtools protocol on :9222 is identical to Chromium).
set -u
URL="$(grep -oP '(?<=KIOSK_URL=).*' /etc/kiosk-url.env)"
WEBHOOK_FILE=/etc/kiosk-watchdog.env
[ -f "$WEBHOOK_FILE" ] && . "$WEBHOOK_FILE"
WEBHOOK="${WATCHDOG_WEBHOOK:-}"
STATE=/run/kiosk-watchdog.fails

notify() {
  [ -n "$WEBHOOK" ] || return 0
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"text\":\"tv-kiosk: $1\"}" "$WEBHOOK" >/dev/null || true
}

fail() {
  echo "watchdog: $1" >&2
  n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$STATE"
  notify "$1 (fail #$n)"
  if [ "$n" -ge 2 ]; then
    echo "watchdog: 2 consecutive fails, rebooting" >&2
    /sbin/reboot
  else
    /bin/systemctl restart kiosk
  fi
  exit 1
}

# 1. Origin reachable.
curl -fsS --max-time 10 -o /dev/null "$URL" || fail "origin not 200"

# 2. Chromium devtools responding, has at least one tab.
TABS="$(curl -fsS --max-time 5 http://127.0.0.1:9222/json)" || fail "devtools unreachable"
URL0="$(echo "$TABS" | jq -r '.[0].url' 2>/dev/null || echo '')"
[ -n "$URL0" ] && [ "$URL0" != "null" ] || fail "no chromium tab"

# 3. Tab is not on a chrome-error screen.
case "$URL0" in
  chrome-error://*) fail "chrome-error: $URL0" ;;
esac

echo 0 > "$STATE"
WATCHDOG
  chmod +x /usr/local/bin/kiosk-watchdog.sh

  if [ -n "$WATCHDOG_WEBHOOK" ]; then
    cat > /etc/kiosk-watchdog.env <<EOF
WATCHDOG_WEBHOOK=${WATCHDOG_WEBHOOK}
EOF
    chmod 600 /etc/kiosk-watchdog.env
  fi

  cat > /etc/systemd/system/kiosk-watchdog.service <<'EOF'
[Unit]
Description=Kiosk watchdog
After=kiosk.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kiosk-watchdog.sh
EOF

  cat > /etc/systemd/system/kiosk-watchdog.timer <<'EOF'
[Unit]
Description=Run kiosk watchdog every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

phase_nightly_reboot() {
  log "Installing nightly reboot timer (04:30)"
  cat > /etc/systemd/system/kiosk-nightly-reboot.service <<'EOF'
[Unit]
Description=Nightly kiosk reboot

[Service]
Type=oneshot
ExecStart=/sbin/reboot
EOF

  cat > /etc/systemd/system/kiosk-nightly-reboot.timer <<'EOF'
[Unit]
Description=Reboot kiosk nightly at 04:30

[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

phase_sshd() {
  log "Locking down sshd (key-only, no root)"
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/kiosk.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
EOF
  systemctl restart ssh || true
}

phase_tailscale() {
  log "Installing + bringing up Tailscale"
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled
  tailscale up \
    --ssh \
    --hostname="$KIOSK_HOSTNAME" \
    --advertise-tags=tag:kiosk \
    --authkey="$TS_AUTHKEY"
}

phase_firewall() {
  log "Configuring UFW (deny incoming, allow tailscale0)"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0
  ufw --force enable
}

phase_enable() {
  log "Enabling services"
  systemctl daemon-reload
  systemctl enable kiosk-watchdog.timer
  systemctl enable kiosk-nightly-reboot.timer
  systemctl enable kiosk.service
}

main() {
  phase_packages
  phase_brave_policies
  phase_user
  phase_hostname
  phase_emmc_preserve
  phase_unattended_upgrades
  phase_kiosk_url
  phase_slices
  phase_kiosk_service
  phase_watchdog
  phase_nightly_reboot
  phase_sshd
  # Tailscale BEFORE ufw lock-down: if anything fails earlier, you can still
  # reach the box on LAN. Once ufw is on, only tailscale0 is reachable.
  phase_tailscale
  phase_firewall
  phase_enable

  log "Done. Rebooting in 10s. Reconnect via:  ssh ${KIOSK_USER}@${KIOSK_HOSTNAME}"
  sleep 10
  systemctl reboot
}

main "$@"
