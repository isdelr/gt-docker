#!/bin/bash
set -euo pipefail

if [[ ! -f /.dockerenv ]]; then
  echo "This test must run inside the isolated GTNH container image." >&2
  exit 1
fi

source /image/scripts/start-deployGTNH

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

function testTransactionalUpdate(){
  local stage="/tmp/gtnh-transaction/new-pack"
  local backup=""
  local data_backup=""
  resetData
  rm -rf /tmp/gtnh-transaction
  find /backups -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +

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
  printf 'interrupted-backup\n' > /backups/.gtnh-pre-upgrade-stale.tmp.999

  makeValidPack "$stage"
  mkdir -p "$stage/config/JourneyMapServer" "$stage/journeymap"
  printf 'new-config\n' > "$stage/config/pack.cfg"
  printf 'pack-default-map\n' > "$stage/config/JourneyMapServer/default.dat"
  printf 'new-icons\n' > "$stage/journeymap/new.txt"

  base_dir="$stage"
  gtnh_selected_id="GTNH-daily-2026-07-19+630-server-java17-25.zip"
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
  [[ ! -e /backups/.gtnh-pre-upgrade-stale.tmp.999 ]]

  backup="$(find /data -maxdepth 1 -type d -name 'gtnh-upgrade-*' -print -quit)"
  [[ -n "$backup" ]]
  assertFileContains "$backup/mods/old.jar" old-mod
  assertFileContains "$backup/config/pack.cfg" old-config

  data_backup="$(find /backups -maxdepth 1 -type f -name 'gtnh-pre-upgrade-*.tar.gz' -print -quit)"
  [[ -n "$data_backup" ]]
  gzip -t "$data_backup"
  tar -tzf "$data_backup" > /tmp/gtnh-backup-contents.txt
  grep -Fqx './world/level.dat' /tmp/gtnh-backup-contents.txt
  grep -Fqx './serverutilities/state.dat' /tmp/gtnh-backup-contents.txt
  if grep -Fqx './mods/old.jar' /tmp/gtnh-backup-contents.txt; then
    echo "Pack-managed mods should not be duplicated in the data backup." >&2
    exit 1
  fi
  [[ -s /backups/.last-verified ]]
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

testDailyResolver
testArchiveValidation
testInstalledPinnedDailyNeedsNoArtifact
testTransactionalUpdate
testInterruptedRecovery
echo "GTNH deploy tests passed."
