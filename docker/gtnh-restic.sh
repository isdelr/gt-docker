#!/bin/bash

GTNH_RESTIC_REPOSITORY="${GTNH_RESTIC_REPOSITORY:-/backups/restic}"
GTNH_RESTIC_PASSWORD_FILE="${GTNH_RESTIC_PASSWORD_FILE:-/backups/.gtnh-restic-password}"
GTNH_RESTIC_HOSTNAME="${GTNH_RESTIC_HOSTNAME:-gtnh}"
GTNH_RESTIC_RETRY_LOCK="${GTNH_RESTIC_RETRY_LOCK:-5m}"
GTNH_RESTIC_READ_CONCURRENCY="${GTNH_RESTIC_READ_CONCURRENCY:-4}"
GTNH_RESTIC_PROGRESS_SECONDS="${GTNH_RESTIC_PROGRESS_SECONDS:-10}"
GTNH_RESTIC_COMPRESSION="${GTNH_RESTIC_COMPRESSION:-auto}"
GTNH_PRE_UPDATE_SNAPSHOTS_KEEP="${GTNH_PRE_UPDATE_SNAPSHOTS_KEEP:-2}"
GTNH_MANAGER_DIR="${GTNH_MANAGER_DIR:-/data/.gtnh-manager}"
GTNH_RESTIC_SNAPSHOT_ID=""
GTNH_RESTIC_LAST_PROGRESS_EPOCH=0

function validateGTNHresticRepository(){
  if [[ "$GTNH_RESTIC_REPOSITORY" != "/backups/restic" ]]; then
    gtnhResticError "Invalid Restic repository setting. This stack requires /backups/restic; the supplied value was not logged because it may be sensitive."
    return 1
  fi
}

function isMisplacedGTNHresticRepository(){
  local candidate="$1"
  [[ -s "$candidate/config" \
    && -d "$candidate/data" \
    && -d "$candidate/index" \
    && -d "$candidate/keys" \
    && -d "$candidate/locks" \
    && -d "$candidate/snapshots" ]]
}

function findMisplacedGTNHresticRepositories(){
  local candidate=""
  for candidate in /data/* /data/.[!.]* /data/..?*; do
    [[ -d "$candidate" ]] || continue
    if isMisplacedGTNHresticRepository "$candidate"; then
      printf '%s\0' "$candidate"
    fi
  done
}

function appendGTNHmanagerEvent(){
  local level="$1"
  shift
  {
    mkdir -p "$GTNH_MANAGER_DIR"
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >> "$GTNH_MANAGER_DIR/events.log"
  } 2>/dev/null || true
}

function gtnhResticLog(){
  if declare -F log >/dev/null 2>&1; then
    log "[gtnh-manager] $*"
  else
    printf '[gtnh-manager] %s\n' "$*"
  fi
  appendGTNHmanagerEvent INFO "$*"
}

function gtnhResticError(){
  if declare -F logError >/dev/null 2>&1; then
    logError "[gtnh-manager] $*"
  else
    printf '[gtnh-manager] ERROR: %s\n' "$*" >&2
  fi
  appendGTNHmanagerEvent ERROR "$*"
}

function gtnhResticEnvironment(){
  validateGTNHresticRepository || return 1
  export RESTIC_REPOSITORY="$GTNH_RESTIC_REPOSITORY"
  export RESTIC_PASSWORD_FILE="$GTNH_RESTIC_PASSWORD_FILE"
  export RESTIC_PROGRESS_FPS=1
  export RESTIC_CACHE_DIR="${GTNH_RESTIC_CACHE_DIR:-$GTNH_MANAGER_DIR/restic-cache}"
}

function writeGTNHresticExcludes(){
  local excludes_file="$GTNH_MANAGER_DIR/restic-excludes.txt"
  local excludes_tmp="${excludes_file}.tmp.$$"
  local shared_excludes="/backups/.gtnh-restic-source-excludes"

  mkdir -p "$GTNH_MANAGER_DIR"
  cat > "$excludes_tmp" <<'EOF'
.tmp
.gtnh-manager
.gtnh-recovery
backups
cache
crash-reports
logs
packs
gtnh-upgrade-*
libraries
mods
journeymap
World-*.zip
*.jar
EOF
  if [[ -s "$shared_excludes" ]]; then
    cat "$shared_excludes" >> "$excludes_tmp"
  fi
  mv -f "$excludes_tmp" "$excludes_file"
  printf '%s\n' "$excludes_file"
}

function initializeGTNHresticRepository(){
  local init_output=""

  validateGTNHresticRepository || return 1
  if ! command -v restic >/dev/null 2>&1; then
    gtnhResticError "Restic is not installed in the GTNH image."
    return 1
  fi
  if [[ ! -s "$GTNH_RESTIC_PASSWORD_FILE" ]]; then
    gtnhResticError "Restic password file is missing or empty: $GTNH_RESTIC_PASSWORD_FILE"
    return 1
  fi

  mkdir -p "$GTNH_RESTIC_REPOSITORY" "$GTNH_MANAGER_DIR" "${GTNH_RESTIC_CACHE_DIR:-$GTNH_MANAGER_DIR/restic-cache}"
  gtnhResticEnvironment || return 1
  if restic cat config >/dev/null 2>&1; then
    return 0
  fi

  gtnhResticLog "Initializing the incremental backup repository at /backups/restic."
  if init_output="$(restic init --repository-version 2 2>&1)"; then
    [[ -n "$init_output" ]] && gtnhResticLog "$init_output"
    return 0
  fi

  if restic cat config >/dev/null 2>&1; then
    return 0
  fi
  gtnhResticError "Unable to initialize the Restic repository: $init_output"
  return 1
}

function gtnhResticSnapshotExists(){
  local snapshot_id="$1"
  [[ -n "$snapshot_id" ]] || return 1
  gtnhResticEnvironment || return 1
  restic cat snapshot "$snapshot_id" >/dev/null 2>&1
}

function forgetOldGTNHpreUpdateSnapshots(){
  if [[ ! "$GTNH_PRE_UPDATE_SNAPSHOTS_KEEP" =~ ^[1-9][0-9]*$ ]]; then
    gtnhResticError "GTNH_PRE_UPDATE_SNAPSHOTS_KEEP must be a positive integer."
    return 1
  fi
  gtnhResticEnvironment || return 1
  restic --retry-lock "$GTNH_RESTIC_RETRY_LOCK" forget \
    --host "$GTNH_RESTIC_HOSTNAME" \
    --tag gtnh,pre-upgrade \
    --keep-last "$GTNH_PRE_UPDATE_SNAPSHOTS_KEEP" >/dev/null
}

function renderGTNHresticEvent(){
  local event="$1"
  local last_progress_epoch="$2"
  local now_epoch=""
  local message_type=""
  local percent=""
  local bytes_done=""
  local total_bytes=""
  local files_done=""
  local total_files=""
  local seconds_remaining=""

  if ! jq -e . >/dev/null 2>&1 <<< "$event"; then
    gtnhResticLog "$event"
    GTNH_RESTIC_LAST_PROGRESS_EPOCH="$last_progress_epoch"
    return
  fi

  message_type="$(jq -r '.message_type // empty' <<< "$event")"
  case "$message_type" in
    status)
      now_epoch="$(date +%s)"
      if (( now_epoch - last_progress_epoch < GTNH_RESTIC_PROGRESS_SECONDS )); then
        GTNH_RESTIC_LAST_PROGRESS_EPOCH="$last_progress_epoch"
        return
      fi
      percent="$(jq -r '((.percent_done // 0) * 100 | floor)' <<< "$event")"
      bytes_done="$(jq -r '.bytes_done // 0' <<< "$event")"
      total_bytes="$(jq -r '.total_bytes // 0' <<< "$event")"
      files_done="$(jq -r '.files_done // 0' <<< "$event")"
      total_files="$(jq -r '.total_files // 0' <<< "$event")"
      seconds_remaining="$(jq -r '.seconds_remaining // 0' <<< "$event")"
      if (( percent > 100 || bytes_done > total_bytes || seconds_remaining > 86400 )); then
        gtnhResticLog "Snapshot progress: recalculating ($(( bytes_done / 1024 / 1024 )) MiB scanned, ${files_done} files)."
      else
        gtnhResticLog "Snapshot progress: ${percent}% ($(( bytes_done / 1024 / 1024 ))/$(( total_bytes / 1024 / 1024 )) MiB, ${files_done}/${total_files} files, ETA ${seconds_remaining}s)."
      fi
      GTNH_RESTIC_LAST_PROGRESS_EPOCH="$now_epoch"
      ;;
    summary)
      GTNH_RESTIC_SNAPSHOT_ID="$(jq -r '.snapshot_id // empty' <<< "$event")"
      gtnhResticLog "Snapshot committed: ${GTNH_RESTIC_SNAPSHOT_ID:-unknown} ($(jq -r '.data_added // 0' <<< "$event" | awk '{printf "%.1f", $1 / 1024 / 1024}') MiB added)."
      GTNH_RESTIC_LAST_PROGRESS_EPOCH="$last_progress_epoch"
      ;;
    error)
      gtnhResticError "$(jq -r '.error.message // .message // "Restic reported an error"' <<< "$event")"
      GTNH_RESTIC_LAST_PROGRESS_EPOCH="$last_progress_epoch"
      ;;
    *)
      GTNH_RESTIC_LAST_PROGRESS_EPOCH="$last_progress_epoch"
      ;;
  esac
}

function createGTNHresticSnapshot(){
  local snapshot_kind="$1"
  local source_id="$2"
  local target_id="$3"
  local excludes_file=""
  local fifo=""
  local json_log=""
  local last_progress_epoch=0
  local line=""
  local restic_pid=""
  local restic_status=0
  local safe_source=""
  local safe_target=""
  local -a backup_args=()

  initializeGTNHresticRepository || return 1
  gtnhResticLog "Checking for stale repository locks before the snapshot."
  if ! restic --retry-lock "$GTNH_RESTIC_RETRY_LOCK" unlock >/dev/null; then
    gtnhResticError "Unable to clear stale Restic locks. Another backup may still be running."
    return 1
  fi
  excludes_file="$(writeGTNHresticExcludes)"
  safe_source="$(printf '%s' "$source_id" | tr -c 'A-Za-z0-9._+-' '_')"
  safe_target="$(printf '%s' "$target_id" | tr -c 'A-Za-z0-9._+-' '_')"
  fifo="$GTNH_MANAGER_DIR/restic-events.$$.fifo"
  json_log="$GTNH_MANAGER_DIR/restic-last.jsonl"
  find "$GTNH_MANAGER_DIR" -maxdepth 1 -type p -name 'restic-events.*.fifo' -delete
  rm -f "$fifo"
  mkfifo "$fifo"
  : > "$json_log"
  GTNH_RESTIC_SNAPSHOT_ID=""
  gtnhResticEnvironment || return 1

  backup_args=(
    --retry-lock "$GTNH_RESTIC_RETRY_LOCK"
    --compression "$GTNH_RESTIC_COMPRESSION"
    backup .
    --json
    --host "$GTNH_RESTIC_HOSTNAME"
    --tag gtnh
    --tag "$snapshot_kind"
    --tag "source:$safe_source"
    --tag "target:$safe_target"
    --exclude-file "$excludes_file"
  )
  if [[ "$GTNH_RESTIC_READ_CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
    backup_args+=(--read-concurrency "$GTNH_RESTIC_READ_CONCURRENCY")
  fi

  gtnhResticLog "Creating $snapshot_kind incremental snapshot from $source_id to $target_id."
  (
    cd /data || exit 1
    restic "${backup_args[@]}"
  ) > "$fifo" 2>&1 &
  restic_pid="$!"

  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$json_log"
    renderGTNHresticEvent "$line" "$last_progress_epoch"
    last_progress_epoch="$GTNH_RESTIC_LAST_PROGRESS_EPOCH"
  done < "$fifo"

  if wait "$restic_pid"; then
    restic_status=0
  else
    restic_status=$?
  fi
  rm -f "$fifo"

  GTNH_RESTIC_SNAPSHOT_ID="$(jq -r 'select(.message_type == "summary") | .snapshot_id // empty' "$json_log" | tail -n 1)"
  if (( restic_status != 0 )) || [[ -z "$GTNH_RESTIC_SNAPSHOT_ID" ]]; then
    gtnhResticError "Restic snapshot failed with status $restic_status. Details: $json_log"
    return 1
  fi
  if ! gtnhResticSnapshotExists "$GTNH_RESTIC_SNAPSHOT_ID"; then
    gtnhResticError "Restic could not reopen committed snapshot $GTNH_RESTIC_SNAPSHOT_ID."
    return 1
  fi

  printf '%s\n' "$GTNH_RESTIC_SNAPSHOT_ID" > "/backups/.last-restic-snapshot.tmp.$$"
  mv -f "/backups/.last-restic-snapshot.tmp.$$" /backups/.last-restic-snapshot
  date -u +%s > "/backups/.last-verified.tmp.$$"
  mv -f "/backups/.last-verified.tmp.$$" /backups/.last-verified
  gtnhResticLog "Verified incremental snapshot $GTNH_RESTIC_SNAPSHOT_ID."
}
