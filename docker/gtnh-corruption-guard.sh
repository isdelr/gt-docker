#!/bin/sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
LATEST_LOG="${DATA_DIR}/logs/latest.log"
RECOVERY_DIR="${DATA_DIR}/.gtnh-recovery"
MARKER_FILE="${RECOVERY_DIR}/corruption-detected.marker"
RCON_HOST="${RCON_HOST:-127.0.0.1}"
RCON_PORT="${RCON_PORT:-25575}"
PATTERN="${CORRUPTION_GUARD_PATTERN:-Chunk file at .* is missing level data|Couldn't load chunk|Loading NBT data|Root tag must be a named compound tag|EOFException|UTFDataFormatException|NULL chunk found|failed to save|save failed}"

log() {
  echo "[gtnh-corruption-guard] $*"
}

rcon() {
  if [ -n "${RCON_PASSWORD_FILE:-}" ] && [ -r "${RCON_PASSWORD_FILE}" ]; then
    RCON_PASSWORD="$(cat "${RCON_PASSWORD_FILE}")"
    export RCON_PASSWORD
  fi
  rcon-cli --host "${RCON_HOST}" --port "${RCON_PORT}" "$@"
}

stop_server() {
  attempt=1
  while [ "$attempt" -le 30 ]; do
    if rcon stop; then
      log "Minecraft accepted the emergency stop command."
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  log "RCON did not accept the stop command; signaling the container supervisor."
  kill -TERM 1
}

mkdir -p "${RECOVERY_DIR}"
while [ ! -f "${LATEST_LOG}" ]; do
  sleep 1
done

log "Watching new log lines for chunk corruption signatures."
tail -n 0 -F "${LATEST_LOG}" | while IFS= read -r line; do
  if printf '%s\n' "$line" | grep -Eiq "${PATTERN}"; then
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    marker_tmp="${MARKER_FILE}.$$"
    detection_log="${RECOVERY_DIR}/corruption-detected-${timestamp}.log"
    {
      printf 'detected_at=%s\n' "$timestamp"
      printf 'log=%s\n' "${detection_log}"
      printf 'line=%s\n' "$line"
      printf 'action=server-stopped-and-startup-quarantined\n'
    } > "$marker_tmp"
    mv "$marker_tmp" "${MARKER_FILE}"
    cp "${LATEST_LOG}" "${detection_log}" 2>/dev/null || true
    log "Corruption signature detected: $line"
    log "Created quarantine marker at ${MARKER_FILE}."
    stop_server
    exit 0
  fi
done
