#!/usr/bin/env bash
# Postgres -> Google Drive backup. All config via env/secrets. Logs use "target #N".
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && { set -a; . "$SCRIPT_DIR/.env"; set +a; }

: "${DB_HOST:?set DB_HOST}"
: "${DB_PORT:=5432}"
: "${DB_USER:?set DB_USER}"
: "${PGPASSWORD:?set PGPASSWORD}"
: "${PGSSLMODE:=require}"
: "${RCLONE_CONFIG:?set RCLONE_CONFIG}"
: "${RCLONE_DEST:?set RCLONE_DEST}"          # "remote:Base Folder"
: "${DB_TARGETS:?set DB_TARGETS}"            # "db:subfolder,db:subfolder"
: "${LOCAL_DIR:=$SCRIPT_DIR/dumps}"
: "${RETENTION_AGE:=24h}"                    # prune dumps older than this
: "${LOCAL_KEEP:=2}"

export PGPASSWORD PGSSLMODE RCLONE_CONFIG

mkdir -p "$LOCAL_DIR"
ts="$(date +%Y%m%d_%H%M%S)"
log() { echo "[$(date '+%F %T')] $*"; }

fail=0
idx=0
IFS=',' read -ra PAIRS <<< "$DB_TARGETS"
for pair in "${PAIRS[@]}"; do
  idx=$((idx + 1))
  db="$(echo "${pair%%:*}" | xargs)"
  sub="$(echo "${pair##*:}" | xargs)"
  if [ -z "$db" ] || [ -z "$sub" ] || [ "$db" = "$sub" ]; then
    log "ERROR: malformed DB_TARGETS at target #$idx"; fail=1; continue
  fi
  file="$LOCAL_DIR/${db}_${ts}.dump"
  remote="${RCLONE_DEST}/${sub}"
  log "=== target #$idx ==="

  if ! pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$db" \
        --format=custom --no-owner --no-privileges --file="$file"; then
    log "ERROR: pg_dump failed for target #$idx"; rm -f "$file"; fail=1; continue
  fi

  # verify archive is readable before trusting/uploading it
  bytes=$(stat -c%s "$file" 2>/dev/null || echo 0)
  if ! verr="$(pg_restore --list "$file" 2>&1 >/dev/null)"; then
    # redact paths / *.dump names before logging (public repo)
    safe="$(printf '%s' "$verr" | sed -E 's#/[^[:space:]]*##g; s#[[:alnum:]_]+\.dump##g' | tr '\n' ' ')"
    log "ERROR: verify failed for target #$idx (${bytes} bytes): ${safe}"
    rm -f "$file"; fail=1; continue
  fi
  log "target #$idx dump OK ($(du -h "$file" | cut -f1))"

  if ! rclone copy "$file" "$remote" --no-traverse; then
    log "ERROR: upload failed for target #$idx"; fail=1; continue
  fi
  log "target #$idx uploaded"

  # prune only this target's old dumps, scoped to its subfolder + filename pattern
  if rclone delete "$remote" --min-age "${RETENTION_AGE}" --include "${db}_*.dump"; then
    log "target #$idx pruned older than ${RETENTION_AGE}"
  else
    log "WARN: prune issues for target #$idx"
  fi

  ls -1t "$LOCAL_DIR/${db}_"*.dump 2>/dev/null | tail -n +"$((LOCAL_KEEP + 1))" | xargs -r rm -f
done

[ "$fail" -eq 0 ] && log "ALL BACKUPS OK" || { log "ONE OR MORE BACKUPS FAILED"; exit 1; }
