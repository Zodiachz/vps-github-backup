#!/usr/bin/env bash
# vps-github-backup — daily full-server snapshot pushed to a private GitHub repo.
#
# Each run rebuilds a staging tree (code archives, database dumps, system config,
# raw asset folders), commits it as a single parentless commit and force-pushes it,
# so the remote always holds exactly one up-to-date snapshot. Unchanged raw files
# are deduplicated by git and are only uploaded once.
#
# Usage: backup.sh [-c /path/to/backup.conf] [--dry-run]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/backup.conf"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) CONF="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -r "$CONF" ] || { echo "config not found: $CONF" >&2; exit 2; }

# ---- defaults (override in backup.conf) -------------------------------------
REPO_REMOTE=""
SSH_KEY=""
STAGING=/var/backups/vps-github-backup
STATE_DIR=/var/lib/vps-github-backup
LOG=/var/log/vps-github-backup.log
LOG_MAX_KB=5120
ZSTD_LEVEL=10
SPLIT_MB=95
MIN_FREE_GB=5
MIN_DUMP_BYTES=1000
TAR_DIRS=()
TAR_EXCLUDES=(node_modules .git __pycache__ "*.log" logs)
RAW_DIRS=()
SQLITE_DBS=()
POSTGRES=0
MYSQL=0
REDIS=0
REDIS_RDB=/var/lib/redis/dump.rdb
REDIS_CLI_ARGS=()
ETC_PATHS=(etc/nginx etc/letsencrypt etc/cron.d etc/systemd/system etc/hosts)
PM2=0
GIT_NAME="vps-github-backup"
GIT_EMAIL="backup@localhost"
# shellcheck source=backup.conf.example
source "$CONF"
export DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}" DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}" \
       DISCORD_USER_IDS="${DISCORD_USER_IDS:-}"

[ -n "$REPO_REMOTE" ] || { echo "REPO_REMOTE is not set in $CONF" >&2; exit 2; }
for bin in git tar zstd split flock python3; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 2; }
done

# The staging directory is wiped on every run: refuse anything that looks like a real folder.
STAGING="${STAGING%/}"
case "$STAGING" in
  ""|/|/bin|/boot|/dev|/etc|/home|/lib*|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/var/backups|/var/lib|/var/www)
    echo "refusing to use STAGING=$STAGING (it is wiped on every run)" >&2; exit 2 ;;
esac
MARK=.vps-github-backup-staging
if [ -d "$STAGING" ] && [ -n "$(ls -A "$STAGING" 2>/dev/null)" ] && [ ! -e "$STAGING/$MARK" ]; then
  echo "refusing to use non-empty $STAGING: it was not created by vps-github-backup" >&2; exit 2
fi

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { echo "another backup is already running"; exit 0; }
if [ "$DRY_RUN" != 1 ]; then
  # keep the log small: trim to the last 2000 lines once it passes LOG_MAX_KB
  if [ -f "$LOG" ] && [ "$(du -k "$LOG" | cut -f1)" -gt "$LOG_MAX_KB" ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  exec >>"$LOG" 2>&1
fi

TS=$(date -u +%Y-%m-%dT%H:%MZ)
T0=$(date +%s)
ERRS=()
fail() { echo "  FAIL: $1"; ERRS+=("$1"); }
notify() { python3 "$HERE/notify.py" "$1" || echo "  (notification failed)"; }
zst() { zstd -q -f -T0 "-$ZSTD_LEVEL" "$@"; }
# unique, readable archive name from a path: /opt/my app -> opt_my-app
pname() { local p="${1%/}"; p="${p#/}"; echo "$p" | tr '/ ' '_-'; }
as_postgres() { if command -v sudo >/dev/null; then sudo -u postgres "$@"; else runuser -u postgres -- "$@"; fi; }
[ -n "$SSH_KEY" ] && export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

echo "=== $TS start$([ "$DRY_RUN" = 1 ] && echo ' (dry run)') ==="

# ---- staging repo ------------------------------------------------------------
mkdir -p "$STAGING" && cd "$STAGING" || { notify "🔴 **Backup failed** — cannot use staging dir \`$STAGING\`"; exit 1; }
[ -d .git ] || git init -q
git symbolic-ref HEAD refs/heads/main
git remote add origin "$REPO_REMOTE" 2>/dev/null || git remote set-url origin "$REPO_REMOTE"
git config user.name "$GIT_NAME"; git config user.email "$GIT_EMAIL"; git config core.compression 1
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
touch "$MARK"
mkdir -p code db system assets

FREE=$(df --output=avail -BG "$STAGING" | tail -1 | tr -dc 0-9)
[ "${FREE:-0}" -lt "$MIN_FREE_GB" ] && fail "low disk space: ${FREE}G free (min ${MIN_FREE_GB}G)"

# ---- 1) code / app directories ----------------------------------------------
EX=(); for e in "${TAR_EXCLUDES[@]}"; do EX+=(--exclude="$e"); done
for d in "${TAR_DIRS[@]}"; do
  d="${d%/}"
  [ -d "$d" ] || { fail "missing dir $d"; continue; }
  tar -I "zstd -T0 -$ZSTD_LEVEL" -cf "code/$(pname "$d").tar.zst" "${EX[@]}" -C "$(dirname "$d")" "$(basename "$d")"
  # exit 1 = "file changed as we read it" (live logs/dbs): harmless
  [ $? -le 1 ] || fail "tar $d"
done

# ---- 2) databases -----------------------------------------------------------
for db in "${SQLITE_DBS[@]}"; do
  [ -f "$db" ] || { fail "missing sqlite db $db"; continue; }
  tmp=$(mktemp "/tmp/vgb.XXXXXX")
  { sqlite3 "$db" ".backup '$tmp'" && zst --rm "$tmp" -o "db/$(pname "$db").zst"; } || fail "sqlite dump $db"
  rm -f "$tmp"
done
if [ "$POSTGRES" = 1 ]; then
  as_postgres pg_dumpall | zst -o db/postgres_all.sql.zst || fail "postgres dump"
fi
if [ "$MYSQL" = 1 ]; then
  mysqldump --all-databases --single-transaction --routines --events | zst -o db/mysql_all.sql.zst || fail "mysql dump"
fi
if [ "$REDIS" = 1 ]; then
  { redis-cli "${REDIS_CLI_ARGS[@]}" save | grep -q OK && zst "$REDIS_RDB" -o db/redis_dump.rdb.zst; } || fail "redis dump"
fi
# a dump that is suddenly tiny usually means something is wrong
for f in db/*; do
  [ -e "$f" ] || continue
  [ "$(stat -c%s "$f")" -ge "$MIN_DUMP_BYTES" ] || fail "$(basename "$f") is suspiciously small"
done

# ---- 3) system configuration ------------------------------------------------
existing=(); for p in "${ETC_PATHS[@]}"; do [ -e "/$p" ] && existing+=("$p"); done
if [ ${#existing[@]} -gt 0 ]; then
  tar -I "zstd -T0" -cf system/etc.tar.zst -C / "${existing[@]}"
  [ $? -le 1 ] || fail "tar system config"
fi
crontab -l > system/root.crontab 2>/dev/null
command -v ufw >/dev/null && ufw status numbered > system/ufw_status.txt 2>/dev/null
command -v dpkg >/dev/null && dpkg --get-selections > system/packages.txt
if [ "$PM2" = 1 ]; then
  cp "$HOME/.pm2/dump.pm2" system/pm2_dump.pm2 || fail "pm2 dump missing (run: pm2 save)"
fi
uname -a > system/host.txt

# ---- 4) raw asset folders (deduplicated by git -> uploaded once) -------------
for d in "${RAW_DIRS[@]}"; do
  d="${d%/}"
  [ -d "$d" ] || { fail "missing dir $d"; continue; }
  dest="assets/$(pname "$d")"
  # hard links are instant and free on the same filesystem; fall back to a copy
  cp -al "$d" "$dest" 2>/dev/null || { rm -rf "$dest"; cp -a "$d" "$dest"; } || fail "copy $d"
done

# ---- GitHub rejects files > 100 MB: split them (restore: cat f.part_* > f) ----
find . -path ./.git -prune -o -type f -size +"${SPLIT_MB}M" -print | while read -r f; do
  split -b "${SPLIT_MB}M" -d -a 3 "$f" "$f.part_" && rm -f "$f"
done

cp "$HERE/RESTORE.md" RESTORE.md 2>/dev/null
SIZE=$(du -sh --exclude=.git . | cut -f1)
printf 'snapshot %s\nhost %s\nsize %s\n' "$TS" "$(hostname)" "$SIZE" > SNAPSHOT.txt
echo "  snapshot size $SIZE"

# ---- commit + push -------------------------------------------------------------
# Build a parentless commit straight from the index: no branch switching, so the
# working tree (which may hard-link live files) is never rewritten by git.
if [ "$DRY_RUN" = 1 ]; then
  echo "  dry run: skipping commit/push. Staging tree: $STAGING"
else
  if git add -A && tree=$(git write-tree) \
     && commit=$(git commit-tree "$tree" -m "snapshot $TS") \
     && timeout 3000 git push -q -f origin "$commit:refs/heads/main"; then
    git update-ref refs/heads/main "$commit"
    echo "  pushed $commit"
  else
    fail "git push"
  fi
  git reflog expire --expire=now --all; git gc -q --prune=now
fi

DUR=$(( ($(date +%s) - T0) / 60 ))
if [ ${#ERRS[@]} -eq 0 ]; then
  [ "$DRY_RUN" = 1 ] || date +%s > "$STATE_DIR/last_ok"
  echo "=== $TS done OK (${DUR} min) ==="
else
  notify "$(printf '🔴 **Backup problem on %s** (%s, %s min)\n' "$(hostname)" "$TS" "$DUR"; printf '• %s\n' "${ERRS[@]}"; printf 'Log: `%s`' "$LOG")"
  echo "=== $TS done with ${#ERRS[@]} error(s) ==="
  exit 1
fi
