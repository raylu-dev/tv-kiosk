#!/usr/bin/env python3
"""raylu-tv Slack bot. Listens for /raylu via Socket Mode, runs registered
celebration commands on the kiosk, replies ephemerally.

Registry at /etc/raylu-celebrations.json — adding a new celebration is just
dropping a binary in /usr/local/bin/ and adding a registry entry. The bot
reloads the registry on every command, so no restart is needed.

Tokens at /etc/raylu-slackbot.env (chmod 600):
  SLACK_BOT_TOKEN=xoxb-...
  SLACK_APP_TOKEN=xapp-...
"""
import fcntl
import json
import os
import shlex
import subprocess
import sys
import threading

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

REG_PATH = '/etc/raylu-celebrations.json'
ENV_PATH = '/etc/raylu-slackbot.env'
LOCK_PATH = '/run/raylu-celebration.lock'


def load_env(path):
    env = {}
    for line in open(path):
        line = line.strip()
        if '=' in line and not line.startswith('#'):
            k, v = line.split('=', 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def load_registry():
    with open(REG_PATH) as f:
        return json.load(f)


def usage_text():
    reg = load_registry()
    lines = ['*Raylu TV celebrations:*', '']
    for name, cfg in sorted(reg.items()):
        lines.append(f'• `/raylu {name}` — {cfg.get("description", "")}')
    lines.append('')
    lines.append('_Anyone in the workspace can fire any celebration from any channel or DM._')
    return '\n'.join(lines)


def acquire_lock():
    """Returns the lock fd if acquired, else None."""
    fd = open(LOCK_PATH, 'w')
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except BlockingIOError:
        fd.close()
        return None


def run_in_thread(reg_entry, args_str, user, respond):
    """Runs the celebration subprocess. Called in a worker thread so the
    Socket Mode websocket stays responsive."""
    progress = reg_entry.get('progress_message')
    if progress:
        respond(progress)

    argv = [reg_entry['binary']]
    if args_str:
        try:
            argv += shlex.split(args_str)
        except ValueError as e:
            respond(f'❌ argument parse error: {e}')
            return

    print(f'[bot] running {argv}', file=sys.stderr, flush=True)
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        respond('⏱️ command timed out (>3 min)')
        return
    except FileNotFoundError:
        respond(f'❌ binary not found: `{argv[0]}`')
        return
    except Exception as e:
        respond(f'💥 error launching: {e}')
        return

    out = (result.stdout or '').strip()
    err = (result.stderr or '').strip()
    if result.returncode == 0:
        msg = out or 'fired'
        if user:
            msg = f'{msg}  _(triggered by @{user})_'
        respond(msg)
    else:
        body = err or out or '(no output)'
        respond(f'❌ exit {result.returncode}\n```{body[:1500]}```')


def handle_command(text, user, respond):
    text = (text or '').strip()
    if not text or text in ('help', 'list', '?'):
        respond(usage_text())
        return

    parts = text.split(None, 1)
    cmd_name = parts[0].lower()
    args_str = parts[1] if len(parts) > 1 else ''

    reg = load_registry()
    if cmd_name not in reg:
        respond(f'❌ unknown command `{cmd_name}`\n\n{usage_text()}')
        return

    lock_fd = acquire_lock()
    if not lock_fd:
        respond('⏳ another celebration is already running — try again in a moment')
        return

    def worker():
        try:
            run_in_thread(reg[cmd_name], args_str, user, respond)
        finally:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            lock_fd.close()

    threading.Thread(target=worker, daemon=True).start()


def main():
    env = load_env(ENV_PATH)
    bot_token = env.get('SLACK_BOT_TOKEN')
    app_token = env.get('SLACK_APP_TOKEN')
    if not bot_token or not app_token:
        sys.exit('missing SLACK_BOT_TOKEN or SLACK_APP_TOKEN in ' + ENV_PATH)

    app = App(token=bot_token)

    @app.command('/raylu')
    def on_raylu(ack, command):
        ack()
        text = command.get('text', '')
        user = command.get('user_name', '?')
        channel = command.get('channel_name', '?')
        print(f'[bot] /raylu from {user} in #{channel}: {text!r}', file=sys.stderr, flush=True)

        # Build a respond() that always posts ephemeral so we don't spam channels
        from slack_bolt import Respond
        response_url = command['response_url']
        respond = Respond(response_url=response_url)

        def respond_ephemeral(msg):
            respond(text=msg, response_type='ephemeral')

        handle_command(text, user, respond_ephemeral)

    print('[bot] starting Socket Mode handler', file=sys.stderr, flush=True)
    SocketModeHandler(app, app_token).start()


if __name__ == '__main__':
    main()
