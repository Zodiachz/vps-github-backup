#!/usr/bin/env python3
"""Send a Discord alert. Usage: notify.py "message"

Uses DISCORD_WEBHOOK_URL (posts to a channel) and/or DISCORD_BOT_TOKEN +
DISCORD_USER_IDS (direct message to each user; the bot must share a server
with them). backup.sh exports these from backup.conf.
Exits 0 if at least one destination received the message."""
import json
import os
import sys
import urllib.request

UA = "DiscordBot (https://github.com/Zodiachz/vps-github-backup, 1)"


def post(url, body, token=None):
    headers = {"Content-Type": "application/json", "User-Agent": UA}
    if token:
        headers["Authorization"] = "Bot " + token
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def main():
    msg = (sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read())[:1900]
    # never ping @everyone/@here or roles, even if a path or error text contains them
    body = {"content": msg, "allowed_mentions": {"parse": []}}
    webhook = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
    users = [u.strip() for u in os.environ.get("DISCORD_USER_IDS", "").split(",") if u.strip()]
    if not webhook and not (token and users):
        print("notify: no Discord destination configured", file=sys.stderr)
        return 1

    sent = 0
    if webhook:
        try:
            post(webhook, body)
            sent += 1
        except Exception as e:
            print("notify: webhook failed:", e, file=sys.stderr)
    for uid in users if token else []:
        try:
            ch = post("https://discord.com/api/v10/users/@me/channels", {"recipient_id": uid}, token)
            post("https://discord.com/api/v10/channels/%s/messages" % ch["id"], body, token)
            sent += 1
        except Exception as e:
            print("notify: DM to %s failed: %s" % (uid, e), file=sys.stderr)
    return 0 if sent else 1


if __name__ == "__main__":
    sys.exit(main())
