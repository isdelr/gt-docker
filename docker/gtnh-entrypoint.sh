#!/bin/sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
LATEST_LOG="${DATA_DIR}/logs/latest.log"
RECOVERY_DIR="${DATA_DIR}/.gtnh-recovery"
BACKUP_DIRS="${AUTO_RESTORE_BACKUP_DIRS:-/backups /data/backups}"
BACKUP_MAX_DEPTH="${AUTO_RESTORE_BACKUP_MAX_DEPTH:-4}"
WARNING_PATTERN="${AUTO_RESTORE_FML_PATTERN:-Forge Mod Loader detected that the backup level.dat is being used}"
EOF_PATTERN="${AUTO_RESTORE_EOF_PATTERN:-Exception reading ./World/level.dat}"
MARKER_FILE="${RECOVERY_DIR}/last-restore.marker"
CORRUPTION_MARKER_FILE="${RECOVERY_DIR}/corruption-detected.marker"

log() {
  echo "[gtnh-recovery] $*"
}

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

prepare_backup_volume() {
  is_true "${GTNH_PRE_UPDATE_BACKUP:-true}" || return 0

  backup_dir="/backups"
  target_uid="${UID:-1000}"
  target_gid="${GID:-1000}"

  if [ "$(id -u)" = "0" ]; then
    mkdir -p "$backup_dir"
    if [ "$(stat -c '%u:%g' "$backup_dir")" != "${target_uid}:${target_gid}" ]; then
      log "Changing ownership of $backup_dir to ${target_uid}:${target_gid} for pre-upgrade backups."
      chown "${target_uid}:${target_gid}" "$backup_dir"
    fi
    chmod u+rwx "$backup_dir"

    if command -v gosu >/dev/null 2>&1 && ! gosu "${target_uid}:${target_gid}" test -w "$backup_dir"; then
      log "Backup directory is not writable by ${target_uid}:${target_gid}: $backup_dir"
      exit 1
    fi
  elif [ ! -w "$backup_dir" ]; then
    log "Backup directory is not writable: $backup_dir"
    exit 1
  fi
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

maybe_auto_confirm_forge_queries() {
  is_true "${AUTO_CONFIRM_FORGE_QUERIES:-false}" || return 0

  case " ${JVM_DD_OPTS:-} " in
    *"fml.queryResult:"*) return 0 ;;
  esac

  export JVM_DD_OPTS="${JVM_DD_OPTS:+$JVM_DD_OPTS }fml.queryResult:confirm"
  log "AUTO_CONFIRM_FORGE_QUERIES=true; setting fml.queryResult=confirm"
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

gzip_file_is_readable() {
  file_path="$1"

  [ -f "$file_path" ] || return 1
  [ -s "$file_path" ] || return 1

  if command -v gzip >/dev/null 2>&1; then
    gzip -t "$file_path" >/dev/null 2>&1
    return $?
  fi

  if command -v gunzip >/dev/null 2>&1; then
    gunzip -t "$file_path" >/dev/null 2>&1
    return $?
  fi

  return 0
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

  if ! gzip_file_is_readable "${source_world}/level.dat"; then
    log "Backup has an unreadable level.dat, skipping: $archive"
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

restore_newest_backup() {
  reason="$1"

  mkdir -p "$RECOVERY_DIR"
  last_restored_backup=""

  candidates_file="${RECOVERY_DIR}/backup-candidates.$$"
  sorted_file="${RECOVERY_DIR}/backup-candidates-sorted.$$"

  if [ -f "$MARKER_FILE" ]; then
    last_restored_backup="$(sed -n 's/^backup=//p' "$MARKER_FILE" | tail -n 1)"
  fi

  collect_backup_candidates "$candidates_file"

  if [ ! -s "$candidates_file" ]; then
    log "$reason, but no backups were found in: $BACKUP_DIRS"
    rm -f "$candidates_file" "$sorted_file"
    return 0
  fi

  sort -t '|' -k 1,1nr -k 2,2r "$candidates_file" | cut -d '|' -f 2- > "$sorted_file"

  while IFS= read -r backup_file; do
    [ -n "$backup_file" ] || continue

    if [ "$backup_file" = "$last_restored_backup" ]; then
      log "Skipping backup that was already restored and still led to startup failure: $backup_file"
      continue
    fi

    if restore_from_backup "$backup_file"; then
      rm -f "$candidates_file" "$sorted_file"
      return 0
    fi
  done < "$sorted_file"

  rm -f "$candidates_file" "$sorted_file"
  log "$reason, but none of the discovered backups could be restored."
}

level_dat_is_corrupt() {
  current_world="$(world_name)"
  if [ -z "$current_world" ]; then
    current_world="world"
  fi

  level_dat="${DATA_DIR}/${current_world}/level.dat"
  [ -f "$level_dat" ] || return 1

  if ! gzip_file_is_readable "$level_dat"; then
    log "Detected unreadable gzip/NBT level.dat: $level_dat"
    return 0
  fi

  return 1
}

maybe_restore_corrupt_level_dat() {
  is_true "${AUTO_RESTORE_ON_CORRUPT_LEVELDAT:-false}" || return 0
  if level_dat_is_corrupt; then
    restore_newest_backup "Corrupt level.dat detected before Minecraft startup"
  fi
}

maybe_restore_after_log_warning() {
  is_true "${AUTO_RESTORE_ON_FML_LEVELDAT_WARNING:-false}" || return 0
  [ -f "$LATEST_LOG" ] || return 0

  if grep -Fq "$WARNING_PATTERN" "$LATEST_LOG"; then
    restore_newest_backup "FML level.dat warning found in latest.log"
    return 0
  fi

  if grep -Fq "$EOF_PATTERN" "$LATEST_LOG" && grep -Fq "java.io.EOFException" "$LATEST_LOG"; then
    restore_newest_backup "level.dat EOFException found in latest.log"
  fi
}

enforce_corruption_quarantine() {
  [ -f "$CORRUPTION_MARKER_FILE" ] || return 0
  if is_true "${CORRUPTION_GUARD_CLEAR:-false}"; then
    cleared_at="$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$CORRUPTION_MARKER_FILE" "${CORRUPTION_MARKER_FILE}.cleared-${cleared_at}"
    log "Cleared the corruption quarantine marker by explicit configuration."
    return 0
  fi
  log "Refusing to start because a corruption quarantine marker exists:"
  sed -n '1,20p' "$CORRUPTION_MARKER_FILE" 2>/dev/null || true
  log "Inspect and restore the affected chunk, then set CORRUPTION_GUARD_CLEAR=true for one start."
  exit 42
}

start_corruption_guard() {
  is_true "${CORRUPTION_GUARD_ENABLED:-true}" || return 0
  /usr/local/bin/gtnh-corruption-guard.sh &
  log "Started the runtime chunk-corruption guard."
}

prepare_backup_volume
enforce_corruption_quarantine
maybe_restore_corrupt_level_dat
maybe_restore_after_log_warning
maybe_auto_confirm_forge_queries
start_corruption_guard

exec /start "$@"
