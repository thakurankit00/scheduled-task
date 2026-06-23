#!/usr/bin/env bash
# Drive -> warm-standby sync. For each target: pull newest verified dump from its
# Drive subfolder and restore into its standby DB, wiping existing objects first.
# All config via env/secrets. Logs use "target #N"; standby URLs are masked.
set -Eeuo pipefail

: "${RCLONE_CONFIG:?set RCLONE_CONFIG}"
: "${RCLONE_DEST:?set RCLONE_DEST}"          # "remote:Base Folder"
: "${SYNC_TARGETS:?set SYNC_TARGETS}"        # "db:subfolder:URLVAR,db:subfolder:URLVAR"
: "${PGSSLMODE:=require}"
export PGSSLMODE RCLONE_CONFIG

WORK="${WORK:-./sync}"
mkdir -p "$WORK"
log() { echo "[$(date '+%F %T')] $*"; }

fail=0
idx=0
IFS=',' read -ra TGTS <<< "$SYNC_TARGETS"
for t in "${TGTS[@]}"; do
  idx=$((idx + 1))
  db="$(echo "$t" | cut -d: -f1 | xargs)"
  sub="$(echo "$t" | cut -d: -f2 | xargs)"
  urlvar="$(echo "$t" | cut -d: -f3 | xargs)"
  url="${!urlvar:-}"
  if [ -z "$db" ] || [ -z "$sub" ] || [ -z "$urlvar" ] || [ -z "$url" ]; then
    log "ERROR: malformed/empty target #$idx"; fail=1; continue
  fi
  echo "::add-mask::$url"
  log "=== target #$idx ==="
  remote="${RCLONE_DEST}/${sub}"

  # newest dump: filenames carry sortable YYYYMMDD_HHMMSS, so lexical sort = chronological
  latest="$(rclone lsf "$remote" --include "${db}_*.dump" 2>/dev/null | sort | tail -1)"
  if [ -z "$latest" ]; then
    log "ERROR: no dump found for target #$idx"; fail=1; continue
  fi

  rm -f "$WORK"/*.dump
  if ! rclone copy "$remote/$latest" "$WORK/" --no-traverse -q; then
    log "ERROR: download failed for target #$idx"; fail=1; continue
  fi
  f="$WORK/$latest"

  # verify the archive before touching the standby
  if ! pg_restore --list "$f" >/dev/null 2>&1; then
    log "ERROR: downloaded archive invalid for target #$idx"; rm -f "$f"; fail=1; continue
  fi
  log "target #$idx dump fetched + verified ($(du -h "$f" | cut -f1))"

  # wipe standby objects, then load. --no-owner/--no-privileges so it loads under
  # the standby's role. redact paths/dump names from any error before logging (public repo).
  if ! rerr="$(pg_restore --clean --if-exists --no-owner --no-privileges --no-comments \
        -d "$url" "$f" 2>&1 >/dev/null)"; then
    safe="$(printf '%s' "$rerr" | sed -E 's#/[^[:space:]]*##g; s#[[:alnum:]_]+\.dump##g' | tr '\n' ' ')"
    log "ERROR: restore failed for target #$idx: ${safe}"
    rm -f "$f"; fail=1; continue
  fi
  log "target #$idx standby refreshed"
  rm -f "$f"
done

[ "$fail" -eq 0 ] && log "ALL STANDBYS SYNCED" || { log "ONE OR MORE SYNCS FAILED"; exit 1; }
