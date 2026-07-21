#!/bin/sh
set -eu

log() {
  echo "[gtnh-recovery] $*"
}

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

validate_restic_configuration() {
  repository="${GTNH_RESTIC_REPOSITORY:-/backups/restic}"
  password_file="${GTNH_RESTIC_PASSWORD_FILE:-/backups/.gtnh-restic-password}"

  if [ "$repository" != "/backups/restic" ]; then
    log "Invalid Restic repository setting. This stack requires /backups/restic; the supplied value was not logged because it may be sensitive."
    exit 1
  fi
  if [ "$password_file" != "/backups/.gtnh-restic-password" ]; then
    log "Invalid Restic password-file setting. This stack requires /backups/.gtnh-restic-password."
    exit 1
  fi

  export GTNH_RESTIC_REPOSITORY="$repository"
  export GTNH_RESTIC_PASSWORD_FILE="$password_file"
}

is_restic_repository_directory() {
  candidate="$1"
  [ -s "$candidate/config" ] \
    && [ -d "$candidate/data" ] \
    && [ -d "$candidate/index" ] \
    && [ -d "$candidate/keys" ] \
    && [ -d "$candidate/locks" ] \
    && [ -d "$candidate/snapshots" ]
}

password_was_exposed_as_repository() {
  password="$1"
  [ -n "$password" ] || return 1

  for candidate in /data/* /data/.[!.]* /data/..?*; do
    [ -d "$candidate" ] || continue
    if [ "$(basename "$candidate")" = "$password" ] && is_restic_repository_directory "$candidate"; then
      return 0
    fi
  done
  return 1
}

prepare_restic_source_excludes() {
  excludes_file="/backups/.gtnh-restic-source-excludes"
  excludes_tmp="${excludes_file}.tmp.$$"
  misplaced_count=0

  : > "$excludes_tmp"
  for candidate in /data/* /data/.[!.]* /data/..?*; do
    [ -d "$candidate" ] || continue
    if is_restic_repository_directory "$candidate"; then
      escaped_name="$(basename "$candidate" | sed 's/[][?*\\]/\\&/g')"
      printf '/%s\n' "$escaped_name" >> "$excludes_tmp"
      misplaced_count=$((misplaced_count + 1))
    fi
  done
  mv -f "$excludes_tmp" "$excludes_file"
  chmod 600 "$excludes_file"
  # shellcheck disable=SC3028
  if [ "$(id -u)" = "0" ]; then
    chown "${UID:-1000}:${GID:-1000}" "$excludes_file"
  fi

  if [ "$misplaced_count" -gt 0 ]; then
    log "Detected $misplaced_count misplaced Restic repository under /data; it will be excluded from all new backups until explicitly cleaned up."
  fi
}

prepare_backup_volume() {
  backup_dir="/backups"
  # UID and GID are injected by the itzg image/Compose contract.
  # shellcheck disable=SC3028
  target_uid="${UID:-1000}"
  target_gid="${GID:-1000}"

  if [ "$(id -u)" = "0" ]; then
    mkdir -p "$backup_dir"
    if [ "$(stat -c '%u:%g' "$backup_dir")" != "${target_uid}:${target_gid}" ]; then
      log "Changing ownership of $backup_dir to ${target_uid}:${target_gid} for Restic snapshots."
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

prepare_restic_credentials() {
  password_file="${GTNH_RESTIC_PASSWORD_FILE:-/backups/.gtnh-restic-password}"
  repository="${GTNH_RESTIC_REPOSITORY:-/backups/restic}"
  configured_password="${GTNH_RESTIC_PASSWORD:-}"
  # shellcheck disable=SC3028
  target_uid="${UID:-1000}"
  target_gid="${GID:-1000}"

  if [ -s "$password_file" ]; then
    stored_password="$(cat "$password_file")"
    if password_was_exposed_as_repository "$stored_password" \
      && { [ -z "$configured_password" ] || [ "$stored_password" = "$configured_password" ]; }; then
      stored_password=""
      log "The current Restic password was exposed as a repository path. Rotate GTNH_RESTIC_PASSWORD in Coolify before restarting."
      exit 1
    fi
    if [ -n "$configured_password" ] && [ "$stored_password" != "$configured_password" ]; then
      if [ ! -s "$repository/config" ]; then
        umask 077
        printf '%s\n' "$configured_password" > "$password_file"
        log "Replaced the password file for the uninitialized fixed Restic repository."
      else
        stored_password=""
        log "GTNH_RESTIC_PASSWORD does not match the initialized Restic repository password file. Rotate the repository key explicitly."
        exit 1
      fi
    fi
    stored_password=""
  else
    umask 077
    mkdir -p "$(dirname "$password_file")"
    if [ -n "$configured_password" ]; then
      printf '%s\n' "$configured_password" > "$password_file"
      log "Created the Restic password file from the configured Coolify secret."
    else
      generated_password="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
      printf '%s\n' "$generated_password" > "$password_file"
      generated_password=""
      log "Generated the persistent Restic repository password file. Back it up separately."
    fi
  fi

  chmod 600 "$password_file"
  if [ "$(id -u)" = "0" ]; then
    chown "${target_uid}:${target_gid}" "$password_file"
  fi
  export GTNH_RESTIC_PASSWORD_FILE="$password_file"
}

maybe_auto_confirm_forge_queries() {
  is_true "${AUTO_CONFIRM_FORGE_QUERIES:-false}" || return 0

  case " ${JVM_DD_OPTS:-} " in
    *"fml.queryResult:"*) return 0 ;;
  esac

  export JVM_DD_OPTS="${JVM_DD_OPTS:+$JVM_DD_OPTS }fml.queryResult:confirm"
  log "AUTO_CONFIRM_FORGE_QUERIES=true; setting fml.queryResult:confirm"
}

validate_restic_configuration
prepare_backup_volume
prepare_restic_credentials
prepare_restic_source_excludes
maybe_auto_confirm_forge_queries

exec /start "$@"
