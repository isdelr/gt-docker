#!/bin/sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
LATEST_LOG="${DATA_DIR}/logs/latest.log"
RECOVERY_DIR="${DATA_DIR}/.gtnh-recovery"
BACKUP_DIRS="${AUTO_RESTORE_BACKUP_DIRS:-/backups /data/backups}"
BACKUP_MAX_DEPTH="${AUTO_RESTORE_BACKUP_MAX_DEPTH:-4}"
WARNING_PATTERN="${AUTO_RESTORE_FML_PATTERN:-Forge Mod Loader detected that the backup level.dat is being used}"
MARKER_FILE="${RECOVERY_DIR}/last-restore.marker"

log() {
  echo "[gtnh-recovery] $*"
}

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

world_name() {
  if [ -n "${LEVEL_NAME:-}" ]; then
    printf '%s\n' "$LEVEL_NAME"
    return
  fi

  if [ -n "${LEVEL:-}" ]; then
    printf '%s\n' "$LEVEL"
    return
  fi

  if [ -f "${DATA_DIR}/server.properties" ]; then
    sed -n 's/^level-name=//p' "${DATA_DIR}/server.properties" | tr -d '\r' | tail -n 1
    return
  fi

  printf '%s\n' "world"
}

extract_archive() {
  archive="$1"
  dest="$2"

  case "$archive" in
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        if ! unzip -q "$archive" -d "$dest"; then
          return 1
        fi
      elif command -v jar >/dev/null 2>&1; then
        if ! (cd "$dest" && jar xf "$archive"); then
          return 1
        fi
      else
        log "Cannot extract zip backup because neither unzip nor jar is available: $archive"
        return 1
      fi
      ;;
    *.tgz|*.tar.gz)
      if ! tar -xzf "$archive" -C "$dest"; then
        return 1
      fi
      ;;
    *.tar.xz|*.txz)
      if ! tar -xJf "$archive" -C "$dest"; then
        return 1
      fi
      ;;
    *.tar.zst|*.tzst)
      if ! tar --zstd -xf "$archive" -C "$dest"; then
        return 1
      fi
      ;;
    *.tar)
      if ! tar -xf "$archive" -C "$dest"; then
        return 1
      fi
      ;;
    *)
      log "Unsupported backup archive type: $archive"
      return 1
      ;;
  esac
}

find_extracted_world() {
  extracted_dir="$1"
  wanted_world="$2"

  preferred="$(
    find "$extracted_dir" -type f -name level.dat 2>/dev/null | while IFS= read -r level_file; do
      candidate_dir="${level_file%/level.dat}"
      candidate_name="${candidate_dir##*/}"
      if [ "$candidate_name" = "$wanted_world" ]; then
        printf '%s\n' "$candidate_dir"
        break
      fi
    done
  )"

  if [ -n "$preferred" ]; then
    printf '%s\n' "$preferred"
    return
  fi

  first_level="$(find "$extracted_dir" -type f -name level.dat 2>/dev/null | head -n 1 || true)"
  if [ -n "$first_level" ]; then
    printf '%s\n' "${first_level%/level.dat}"
  fi
}

collect_backup_candidates() {
  candidates_file="$1"
  : > "$candidates_file"

  for backup_dir in $BACKUP_DIRS; do
    [ -d "$backup_dir" ] || continue

    find "$backup_dir" -maxdepth "$BACKUP_MAX_DEPTH" -type f \
      \( -name '*.zip' -o -name '*.tar' -o -name '*.tgz' -o -name '*.tar.gz' -o -name '*.tar.xz' -o -name '*.txz' -o -name '*.tar.zst' -o -name '*.tzst' \) \
      2>/dev/null | while IFS= read -r backup_file; do
        printf '%s|%s\n' "$(mtime "$backup_file")" "$backup_file"
      done >> "$candidates_file"
  done
}

restore_from_backup() {
  archive="$1"
  wanted_world="$(world_name)"

  if [ -z "$wanted_world" ]; then
    wanted_world="world"
  fi

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  extract_dir="${RECOVERY_DIR}/extract-${timestamp}-$$"
  failed_worlds_dir="${RECOVERY_DIR}/failed-worlds"
  target_world="${DATA_DIR}/${wanted_world}"
  replaced_world="${failed_worlds_dir}/${wanted_world}-${timestamp}"

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir" "$failed_worlds_dir"

  log "Restoring world '$wanted_world' from backup: $archive"

  if ! extract_archive "$archive" "$extract_dir"; then
    rm -rf "$extract_dir"
    return 1
  fi

  source_world="$(find_extracted_world "$extract_dir" "$wanted_world")"
  if [ -z "$source_world" ] || [ ! -d "$source_world" ]; then
    log "Backup did not contain a world folder with level.dat: $archive"
    rm -rf "$extract_dir"
    return 1
  fi

  if [ -e "$target_world" ]; then
    mv "$target_world" "$replaced_world"
    log "Moved the suspect world to: $replaced_world"
  fi

  mkdir -p "$target_world"
  cp -a "$source_world/." "$target_world/"

  if [ -f "$LATEST_LOG" ]; then
    mv "$LATEST_LOG" "${RECOVERY_DIR}/latest-before-restore-${timestamp}.log" || true
  fi

  {
    echo "restored_at_epoch=$(date +%s)"
    echo "backup=$archive"
    echo "world=$wanted_world"
    echo "replaced_world=$replaced_world"
  } > "$MARKER_FILE"

  if [ -n "${UID:-}" ] && [ -n "${GID:-}" ]; then
    chown -R "${UID}:${GID}" "$target_world" "$RECOVERY_DIR" 2>/dev/null || true
  fi

  rm -rf "$extract_dir"
  log "Restore complete; starting Minecraft with restored world."
}

maybe_restore_after_fml_warning() {
  is_true "${AUTO_RESTORE_ON_FML_LEVELDAT_WARNING:-true}" || return 0
  [ -f "$LATEST_LOG" ] || return 0
  grep -Fq "$WARNING_PATTERN" "$LATEST_LOG" || return 0

  mkdir -p "$RECOVERY_DIR"

  latest_log_mtime="$(mtime "$LATEST_LOG")"
  last_restore_epoch="0"
  last_restored_backup=""

  if [ -f "$MARKER_FILE" ]; then
    last_restore_epoch="$(sed -n 's/^restored_at_epoch=//p' "$MARKER_FILE" | tail -n 1)"
    last_restored_backup="$(sed -n 's/^backup=//p' "$MARKER_FILE" | tail -n 1)"
  fi

  case "$last_restore_epoch" in
    ''|*[!0-9]*) last_restore_epoch="0" ;;
  esac

  if [ "$latest_log_mtime" -le "$last_restore_epoch" ]; then
    log "Ignoring an old FML level.dat warning that predates the last restore."
    return 0
  fi

  candidates_file="${RECOVERY_DIR}/backup-candidates.$$"
  sorted_file="${RECOVERY_DIR}/backup-candidates-sorted.$$"
  collect_backup_candidates "$candidates_file"

  if [ ! -s "$candidates_file" ]; then
    log "FML level.dat warning found, but no backups were found in: $BACKUP_DIRS"
    rm -f "$candidates_file" "$sorted_file"
    return 0
  fi

  sort -t '|' -k 1,1nr -k 2,2r "$candidates_file" | cut -d '|' -f 2- > "$sorted_file"

  while IFS= read -r backup_file; do
    [ -n "$backup_file" ] || continue

    if [ "$backup_file" = "$last_restored_backup" ]; then
      log "Skipping backup that was already restored and still led to an FML warning: $backup_file"
      continue
    fi

    if restore_from_backup "$backup_file"; then
      rm -f "$candidates_file" "$sorted_file"
      return 0
    fi
  done < "$sorted_file"

  rm -f "$candidates_file" "$sorted_file"
  log "FML level.dat warning found, but none of the discovered backups could be restored."
}

maybe_restore_after_fml_warning

exec /start "$@"
