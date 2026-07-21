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
  configured_password="${GTNH_RESTIC_PASSWORD:-}"
  # shellcheck disable=SC3028
  target_uid="${UID:-1000}"
  target_gid="${GID:-1000}"

  if [ -s "$password_file" ]; then
    if [ -n "$configured_password" ] && [ "$(cat "$password_file")" != "$configured_password" ]; then
      log "GTNH_RESTIC_PASSWORD does not match the existing Restic repository password file."
      exit 1
    fi
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

prepare_backup_volume
prepare_restic_credentials
maybe_auto_confirm_forge_queries

exec /start "$@"
