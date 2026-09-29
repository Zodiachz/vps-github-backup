#!/usr/bin/env bash
# Installs vps-github-backup to /opt/vps-github-backup, creates a deploy key and
# the cron jobs. Run as root on the server you want to back up.
set -euo pipefail
DEST=/opt/vps-github-backup
KEY=/root/.ssh/backup_deploy
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
for bin in git tar zstd python3 flock; do
  command -v "$bin" >/dev/null || { echo "missing: $bin  (apt install git zstd python3 util-linux)"; exit 1; }
done

mkdir -p "$DEST"
cp "$SRC"/backup.sh "$SRC"/watchdog.sh "$SRC"/notify.py "$SRC"/RESTORE.md "$SRC"/backup.conf.example "$DEST"/
chmod +x "$DEST"/backup.sh "$DEST"/watchdog.sh "$DEST"/notify.py
[ -f "$DEST/backup.conf" ] || { cp "$DEST/backup.conf.example" "$DEST/backup.conf"; chmod 600 "$DEST/backup.conf"; }

if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "vps-github-backup@$(hostname)" -f "$KEY"
fi

( { crontab -l 2>/dev/null || true; } | { grep -v vps-github-backup || true; }
  echo "10 4 * * * $DEST/backup.sh >/dev/null 2>&1   # vps-github-backup"
  echo "0 * * * * $DEST/watchdog.sh >/dev/null 2>&1  # vps-github-backup"
) | crontab -

cat <<EOF

Installed to $DEST
Next steps:
  1. Create a PRIVATE GitHub repository (e.g. server-backup).
  2. Add this public key as a deploy key WITH write access
     (repo -> Settings -> Deploy keys -> Add deploy key):

$(cat "$KEY.pub")

  3. Edit $DEST/backup.conf (REPO_REMOTE, folders, databases, Discord).
  4. Test:  $DEST/backup.sh --dry-run
  5. First real run:  $DEST/backup.sh && tail $(grep -oP '^LOG=\K.*' "$DEST/backup.conf" 2>/dev/null || echo /var/log/vps-github-backup.log)

Cron: daily backup at 04:10, watchdog every hour.
EOF
