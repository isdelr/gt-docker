#!/bin/bash
set -euo pipefail

if [[ ! -f /.dockerenv ]]; then
  echo "This test must run inside the isolated GTNH container image." >&2
  exit 1
fi

source /image/scripts/start-deployGTNH
GTNH_BACKUP_MIN_FREE_GB=1

function assertFileContains(){
  local file="$1"
  local expected="$2"
  grep -Fqx "$expected" "$file" || {
    echo "Expected $file to contain exactly: $expected" >&2
    exit 1
  }
}

function resetData(){
  find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  mkdir -p /data
}

function resetBackups(){
  mkdir -p /backups
  find /backups -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  printf 'test-restic-password\n' > /backups/.gtnh-restic-password
  chmod 600 /backups/.gtnh-restic-password
}

function makeValidPack(){
  local pack="$1"
  mkdir -p "$pack/config" "$pack/mods" "$pack/libraries/example"
  printf 'config-a\n' > "$pack/config/a.cfg"
  printf 'config-b\n' > "$pack/config/b.cfg"
  printf 'mod-a\n' > "$pack/mods/a.jar"
  printf 'mod-b\n' > "$pack/mods/b.jar"
  printf 'library-a\n' > "$pack/libraries/example/a.jar"
  printf 'library-b\n' > "$pack/libraries/example/b.jar"
  printf 'forge\n' > "$pack/forge-1.7.10-10.13.4.1614-1.7.10-universal.jar"
  printf 'lwjgl\n' > "$pack/lwjgl3ify-forgePatches.jar"
  printf 'args\n' > "$pack/java9args.txt"
  printf '#!/bin/sh\n' > "$pack/startserver-java9.sh"
}

function testDailyResolver(){
  GTNH_PACK_VERSION="daily-2026-07-19+630"
  GTNH_GITHUB_TOKEN="test-token"
  current_java_version=25

  function githubApiCurl(){
    printf '%s\n' '{"artifacts":[{"name":"GTNH-daily-2026-07-19+630-server-java17-25.zip","expired":false,"created_at":"2026-07-19T06:30:02Z","archive_download_url":"https://api.github.test/artifacts/8439067728/zip","digest":"sha256:b74dea","size_in_bytes":553632932}]}'
  }

  selectDailyGTNHpack
  [[ "$gtnh_selected_id" == "GTNH-daily-2026-07-19+630-server-java17-25.zip" ]]
  [[ "$gtnh_download_path" == "https://api.github.test/artifacts/8439067728/zip" ]]
  [[ "$gtnh_download_sha256" == "b74dea" ]]
  [[ "$gtnh_download_size" == "553632932" ]]
}

function testArchiveValidation(){
  local fixture_root="/tmp/gtnh-validation"
  rm -rf "$fixture_root"
  mkdir -p "$fixture_root/config-only/config" "$fixture_root/config-only/mods"
  current_java_version=25
  GTNH_MIN_CONFIG_FILES=2
  GTNH_MIN_LIBRARY_JARS=2
  GTNH_MIN_MOD_JARS=2

  if validateGTNHarchive "$fixture_root/config-only"; then
    echo "Config-only nightly archive unexpectedly passed validation." >&2
    exit 1
  fi

  makeValidPack "$fixture_root/server"
  validateGTNHarchive "$fixture_root/server"
}

function testInstalledPinnedDailyNeedsNoArtifact(){
  resetData
  GTNH_PACK_VERSION="daily-2026-07-19+630"
  unset GTNH_GITHUB_TOKEN
  printf 'GTNH-daily-2026-07-19+630-server-java17-25.zip\n' > /data/.gtnh-version
  exactDailyGTNHisAlreadyInstalled
}

function testArtifactCacheAndResume(){
  local fixture_root="/tmp/gtnh-cache-test"
  local fixture_archive="$fixture_root/server.zip"
  local download_count_file="$fixture_root/download-count"
  local expected_staging=""

  resetData
  rm -rf "$fixture_root"
  mkdir -p "$fixture_root/pack"
  makeValidPack "$fixture_root/pack"
  python3 -c 'import shutil, sys; shutil.make_archive(sys.argv[1], "zip", sys.argv[2])' \
    "${fixture_archive%.zip}" "$fixture_root/pack"
  printf '0\n' > "$download_count_file"
  printf 'GT_New_Horizons_2.9.0-beta-2_Server_Java_17-25.zip\n' > /data/.gtnh-version

  GTNH_MIN_CONFIG_FILES=2
  GTNH_MIN_LIBRARY_JARS=2
  GTNH_MIN_MOD_JARS=2
  current_java_version=25
  gtnh_selected_id="GTNH-daily-cache-test-server-java17-25.zip"
  gtnh_download_path="https://api.github.test/cache-test.zip"
  gtnh_download_kind="github-actions"
  gtnh_download_sha256="$(sha256sum "$fixture_archive" | awk '{print $1}')"
  gtnh_download_size="$(stat -c '%s' "$fixture_archive")"

  function githubApiCurl(){
    local output=""
    while (( $# > 0 )); do
      if [[ "$1" == "-o" ]]; then
        output="$2"
        shift 2
      else
        shift
      fi
    done
    printf '%s\n' "$(( $(cat "$download_count_file") + 1 ))" > "$download_count_file"
    cp "$fixture_archive" "$output"
  }

  initializeGTNHmanagerOperation
  expected_staging="${GTNH_MANAGER_DIR}/staging/${gtnh_manager_operation_id}"
  downloadGTNH
  [[ "$(cat "$download_count_file")" == "1" ]]
  [[ -s "$gtnh_manager_artifact_path" ]]
  [[ "$(jq -r '.stage' "$GTNH_MANAGER_STATE_FILE")" == "staged" ]]
  [[ -s "$expected_staging/validated.json" ]]

  jq '.staging_path = "/data"' "$GTNH_MANAGER_STATE_FILE" > "$GTNH_MANAGER_STATE_FILE.tmp"
  mv -f "$GTNH_MANAGER_STATE_FILE.tmp" "$GTNH_MANAGER_STATE_FILE"
  gtnh_manager_operation_id=""
  gtnh_manager_staging_path=""
  initializeGTNHmanagerOperation
  [[ "$gtnh_manager_staging_path" == "$expected_staging" ]]
  downloadGTNH
  [[ "$(cat "$download_count_file")" == "1" ]]

  rm -rf "$expected_staging"
  gtnh_manager_operation_id=""
  initializeGTNHmanagerOperation
  downloadGTNH
  [[ "$(cat "$download_count_file")" == "1" ]]
  [[ -s "$expected_staging/validated.json" ]]
}

function testTransactionalUpdate(){
  local stage="/tmp/gtnh-transaction/new-pack"
  local backup=""
  local snapshot_id=""
  resetData
  resetBackups
  rm -rf /tmp/gtnh-transaction

  mkdir -p /data/world /data/mods /data/libraries /data/config/JourneyMapServer /data/journeymap
  mkdir -p /data/serverutilities
  printf 'world-data\n' > /data/world/level.dat
  printf 'old-mod\n' > /data/mods/old.jar
  printf 'old-library\n' > /data/libraries/old.jar
  printf 'old-config\n' > /data/config/pack.cfg
  printf 'player-map-data\n' > /data/config/JourneyMapServer/player.dat
  printf 'old-icons\n' > /data/journeymap/old.txt
  printf 'custom-properties\n' > /data/server.properties
  printf 'custom-whitelist\n' > /data/whitelist.json
  printf 'custom-ops\n' > /data/ops.json
  printf 'custom-icon\n' > /data/server-icon.png
  printf 'serverutilities-state\n' > /data/serverutilities/state.dat
  printf 'GT_New_Horizons_2.9.0-beta-2_Server_Java_17-25.zip\n' > /data/.gtnh-version

  makeValidPack "$stage"
  mkdir -p "$stage/config/JourneyMapServer" "$stage/journeymap"
  printf 'new-config\n' > "$stage/config/pack.cfg"
  printf 'pack-default-map\n' > "$stage/config/JourneyMapServer/default.dat"
  printf 'new-icons\n' > "$stage/journeymap/new.txt"

  base_dir="$stage"
  gtnh_selected_id="GTNH-daily-2026-07-19+630-server-java17-25.zip"
  gtnh_download_path="https://api.github.test/artifact.zip"
  initializeGTNHmanagerOperation
  updateGTNH

  assertFileContains /data/world/level.dat world-data
  assertFileContains /data/server.properties custom-properties
  assertFileContains /data/whitelist.json custom-whitelist
  assertFileContains /data/ops.json custom-ops
  assertFileContains /data/server-icon.png custom-icon
  assertFileContains /data/serverutilities/state.dat serverutilities-state
  assertFileContains /data/config/JourneyMapServer/player.dat player-map-data
  assertFileContains /data/config/pack.cfg new-config
  [[ ! -e /data/config/JourneyMapServer/default.dat ]]
  [[ -f /data/mods/a.jar && ! -e /data/mods/old.jar ]]
  [[ -f /data/journeymap/new.txt && ! -e /data/journeymap/old.txt ]]
  [[ ! -e "$GTNH_UPDATE_MARKER" ]]

  backup="$(find /data -maxdepth 1 -type d -name 'gtnh-upgrade-*' -print -quit)"
  [[ -n "$backup" ]]
  assertFileContains "$backup/mods/old.jar" old-mod
  assertFileContains "$backup/config/pack.cfg" old-config

  snapshot_id="$gtnh_manager_snapshot_id"
  [[ -n "$snapshot_id" ]]
  restic ls "$snapshot_id" > /tmp/gtnh-backup-contents.txt
  grep -Fq '/world/level.dat' /tmp/gtnh-backup-contents.txt
  grep -Fq '/serverutilities/state.dat' /tmp/gtnh-backup-contents.txt
  if grep -Fq '/mods/old.jar' /tmp/gtnh-backup-contents.txt; then
    echo "Pack-managed mods should not be duplicated in the data backup." >&2
    exit 1
  fi
  [[ "$(restic dump "$snapshot_id" /world/level.dat)" == "world-data" ]]
  [[ -s /backups/.last-verified ]]
  [[ "$(cat /backups/.last-restic-snapshot)" == "$snapshot_id" ]]
  [[ "$(jq -r '.stage' "$GTNH_MANAGER_STATE_FILE")" == "applied" ]]

  mkdir -p /data/gtnh-upgrade-retention-old-1 /data/gtnh-upgrade-retention-old-2
  touch -d '2020-01-01T00:00:00Z' /data/gtnh-upgrade-retention-old-1
  touch -d '2021-01-01T00:00:00Z' /data/gtnh-upgrade-retention-old-2
  printf '%s\n' "$gtnh_selected_id" > /data/.gtnh-version
  finalizeInstalledGTNHmanagerOperation
  [[ "$(jq -r '.stage' "$GTNH_MANAGER_STATE_FILE")" == "complete" ]]
  [[ ! -e "$gtnh_manager_staging_path" ]]
  [[ "$(find /data -mindepth 1 -maxdepth 1 -type d -name 'gtnh-upgrade-*' | wc -l)" == "2" ]]
}

function testInterruptedRecovery(){
  local backup="/data/gtnh-upgrade-interrupted-test"
  resetData
  mkdir -p /data/mods "$backup/mods"
  printf 'new-mod\n' > /data/mods/new.jar
  printf 'old-mod\n' > "$backup/mods/old.jar"
  printf 'present|mods\nabsent|libraries\n' > "$backup/.old-resources"
  mkdir -p /data/libraries
  printf 'new-library\n' > /data/libraries/new.jar
  printf '%s\n' "$backup" > "$GTNH_UPDATE_MARKER"

  recoverInterruptedGTNHupdate
  assertFileContains /data/mods/old.jar old-mod
  [[ ! -e /data/mods/new.jar ]]
  [[ ! -e /data/libraries ]]
  [[ ! -e "$GTNH_UPDATE_MARKER" ]]
}

function testConfigOverrides(){
  resetData
  mkdir -p /data/config /data/serverutilities
  printf '%s\n' \
    'S:backup_timer=1.0' \
    'I:backups_to_keep=48' \
    'I:max_folder_size=35' \
    'I:compression_level=9' \
    'B:only_backup_claimed_chunks=false' \
    'B:backup_entire_regions_with_claims=false' \
    > /data/serverutilities/serverutilities.cfg
  printf '%s\n' \
    '    B:poolZlibInstances=true' \
    '    B:speedupChunkCompression=true' \
    > /data/config/hodgepodge.cfg

  applyGTNHConfigOverrides

  assertFileContains /data/config/hodgepodge.cfg '    B:poolZlibInstances=false'
  assertFileContains /data/config/hodgepodge.cfg '    B:speedupChunkCompression=false'
}

testDailyResolver
testArchiveValidation
testInstalledPinnedDailyNeedsNoArtifact
testArtifactCacheAndResume
testTransactionalUpdate
testInterruptedRecovery
testConfigOverrides
echo "GTNH deploy tests passed."
