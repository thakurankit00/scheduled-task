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

  # Clean slate: drop every non-system schema (including public — the app puts
  # objects in both) and recreate public, so the dump's CREATE TYPE/TABLE never
  # collide with leftovers. CASCADE clears the FK web in one shot. One DO block,
  # ON_ERROR_STOP surfaces real failures. No project schema name in this public repo.
  if ! perr="$(psql "$url" -v ON_ERROR_STOP=1 -q 2>&1 <<'SQL'
DO $$
DECLARE s text;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      AND nspname NOT LIKE 'pg_temp%' AND nspname NOT LIKE 'pg_toast_temp%'
  LOOP EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', s); END LOOP;
  EXECUTE 'CREATE SCHEMA IF NOT EXISTS public';
END $$;
SQL
)"; then
    safe="$(printf '%s' "$perr" | sed -E 's#/[^[:space:]]*##g; s/[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*//g' | tr '\n' ' ')"
    log "ERROR: standby prep failed for target #$idx: ${safe}"
    rm -f "$f"; fail=1; continue
  fi

  # Load atomically: --single-transaction = all-or-nothing, standby never left half-built.
  # --no-owner/--no-privileges so it loads under the standby's role. Redact paths,
  # schema-qualified identifiers, and dump names from any error before logging (public repo).
  if ! rerr="$(pg_restore --no-owner --no-privileges --no-comments --single-transaction \
        -d "$url" "$f" 2>&1 >/dev/null)"; then
    safe="$(printf '%s' "$rerr" | sed -E 's#/[^[:space:]]*##g; s/[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*//g; s#[[:alnum:]_]+\.dump##g' | tr '\n' ' ')"
    log "ERROR: restore failed for target #$idx: ${safe}"
    rm -f "$f"; fail=1; continue
  fi
  log "target #$idx standby refreshed"
  rm -f "$f"
done

[ "$fail" -eq 0 ] && log "ALL STANDBYS SYNCED" || { log "ONE OR MORE SYNCS FAILED"; exit 1; }
