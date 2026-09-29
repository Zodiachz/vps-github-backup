# Restore guide

This snapshot was produced by [vps-github-backup](https://github.com/Zodiachz/vps-github-backup).
`SNAPSHOT.txt` shows when and where it was taken.

## 1. Get the snapshot on the new server

```bash
git clone --depth 1 -b main git@github.com:YOUR_USER/server-backup.git /root/restore
cd /root/restore
```

## 2. Join split files

Files larger than the split size were cut into `*.part_000`, `*.part_001`, ...

```bash
find . -name '*.part_000' | while read -r p; do
  b=${p%.part_000}; cat "$b".part_* > "$b" && rm -f "$b".part_*
done
```

## 3. Install the base packages

Check `system/packages.txt` and `system/host.txt`, then install what you need
(nginx, database servers, runtimes, `zstd`, `sqlite3`, pm2, ...).

## 4. System configuration

```bash
tar -I zstd -tf system/etc.tar.zst          # list first
tar -I zstd -xf system/etc.tar.zst -C /     # restore
```

Review network files (`etc/hosts`, netplan) before restoring them: the new host has a new IP.
Then restore the crontab: `crontab system/root.crontab`.

## 5. Applications

Archives are named after their original path (`/` becomes `_`, spaces become `-`):
`code/opt_my-app.tar.zst` was `/opt/my-app`, so it goes back into `/opt`.

```bash
tar -I zstd -tf code/opt_my-app.tar.zst | head   # check the content first
tar -I zstd -xf code/opt_my-app.tar.zst -C /opt
```

Reinstall dependencies inside each app (`npm ci`, `pip install -r requirements.txt`, `composer install`, ...).
Raw asset folders are in `assets/`, named the same way: copy each one back to its original path.

## 6. Databases

```bash
# PostgreSQL
zstd -dc db/postgres_all.sql.zst | sudo -u postgres psql
# MySQL / MariaDB
zstd -dc db/mysql_all.sql.zst | mysql
# Redis (stop the service first)
zstd -d db/redis_dump.rdb.zst -o /var/lib/redis/dump.rdb && chown redis:redis /var/lib/redis/dump.rdb
# SQLite (named after the original path)
zstd -d db/opt_my-app_data_app.db.zst -o /opt/my-app/data/app.db
```

## 7. Services

```bash
cp system/pm2_dump.pm2 ~/.pm2/dump.pm2 && pm2 resurrect && pm2 save && pm2 startup
systemctl daemon-reload && systemctl restart nginx
```

Finally, point your DNS records to the new server IP.
