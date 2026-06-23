# scheduled-task — off-site DB backups

Scheduled GitHub Action that dumps Postgres databases and pushes **verified**
copies to Google Drive via rclone. Runs on GitHub's free hosted runners,
**every 30 min**, keeping a rolling **24h** window on Drive (older dumps auto-pruned).

Built after a database host went down with no off-site backup to recover from.

> **Public repo.** No hostnames, database names, or Drive paths live in this repo
> — they're all GitHub Actions **secrets**, and the script logs only generic
> `target #N` labels (Action logs are world-readable).

## One-time setup

Add these under **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Example value | Notes |
|---|---|---|
| `DB_HOST` | `db.example.internal` | database host |
| `DB_USER` | `appuser` | database user |
| `PGPASSWORD` | `••••••` | database password |
| `DB_PORT` | `5432` | optional (defaults to 5432) |
| `DB_TARGETS` | `db_one:SUB_ONE,db_two:SUB_TWO` | comma-separated `dbname:driveSubfolder` pairs |
| `RCLONE_DEST` | `myremote:Base Folder` | rclone destination prefix (subfolder appended) |
| `RCLONE_CONF_B64` | base64 of `rclone.conf` | the config with your Drive remote |

Generate `RCLONE_CONF_B64`:
```bash
base64 -w0 rclone.conf            # Linux
base64 -i rclone.conf | tr -d '\n' # macOS
```

> The DBs share one host/user/password — only the db name differs, so a single
> `DB_HOST`/`DB_USER`/`PGPASSWORD` covers all. List each db + its Drive subfolder
> in `DB_TARGETS`.

## Run it

Actions tab → `db-backup` → **Run workflow** (manual), then let the schedule
take over. A run should show, per target: `dump OK` → `uploaded` → `pruned`.

## Schedule + retention

- `*/30 * * * *` (UTC) = every 30 min, ~30 min worst-case data loss (no PITR/WAL).
- `RETENTION_AGE=24h` → each run deletes Drive dumps older than 24h, scoped to each
  target's own subfolder + filename — Drive holds only the last 24h, nothing stale,
  nothing outside the configured subfolders is touched.
- Both set in `.github/workflows/db-backup.yml`.

> GitHub may delay/skip scheduled runs under load — `*/30` is best-effort, not an SLA.

## Restore — one-click (panic mode)

`db-restore` workflow: pulls a dump from Drive and restores it into a target DB,
wiping existing objects first.

1. **Set the target as a secret** (NOT an input — inputs leak in the public run
   summary, and the URL has a password): add/update
   `RESTORE_TARGET_URL` = `postgres://user:pass@host:port/db?sslmode=require`.
2. Actions → `db-restore` → **Run workflow**:
   - `source_file` = path under `RCLONE_DEST`, e.g. `folder/filename.dump`
   - `confirm` = `RESTORE`
3. It downloads + verifies the dump, then `pg_restore --clean --if-exists` into
   the target.

> The target URL is masked in logs. `--clean --if-exists` drops the dump's
> objects before loading — point it at a recovery instance, not a live DB you
> still need.

## Restore — manual (CLI)

```bash
rclone ls "<RCLONE_DEST>/<SUBFOLDER>"                       # list dumps
rclone copy "<RCLONE_DEST>/<SUBFOLDER>/<db>_<ts>.dump" ./   # pull one
createdb -h NEWHOST -U USER <db>
pg_restore -h NEWHOST -U USER -d <db> --no-owner --clean --if-exists --jobs=4 <db>_<ts>.dump
# sanity-check, then repoint the app's DB env to the new instance
```

**Test-restore monthly** into a throwaway DB — an unverified backup is what caused
the original incident.

## Notes

- Runner is ephemeral; Drive is the source of truth. `pg_restore --list` verifies
  every dump before upload.
- A failed run exits non-zero → the Action goes red. Turn on Actions failure
  notifications so a silently-broken backup doesn't repeat history.
- Never commit `rclone.conf` or any credential (gitignored). Rotate the DB
  password periodically.
