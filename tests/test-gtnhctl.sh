#!/bin/bash
set -euo pipefail

mkdir -p /data/world /backups
printf 'test-restic-password\n' > /backups/.gtnh-restic-password
printf 'world-data\n' > /data/world/level.dat
printf 'test-build\n' > /data/.gtnh-version

# shellcheck source=gtnh-restic.sh
. /usr/local/lib/gtnh-restic.sh
createGTNHresticSnapshot smoke test-build test-build
snapshot_id="$GTNH_RESTIC_SNAPSHOT_ID"

for target in retention-1 retention-2 retention-3; do
  printf '%s\n' "$target" > /data/world/retention-test.dat
  createGTNHresticSnapshot pre-upgrade test-build "$target"
done
forgetOldGTNHpreUpdateSnapshots
[[ "$(restic snapshots --host "$GTNH_RESTIC_HOSTNAME" --tag gtnh,pre-upgrade --json | jq 'length')" == "2" ]]

gtnhctl status
gtnhctl snapshots
gtnhctl logs 20
gtnhctl restore "$snapshot_id" --world world --target /tmp/gtnh-restore
[[ "$(cat /tmp/gtnh-restore/world/level.dat)" == "world-data" ]]

mkdir -p /tmp/legacy-source/World
printf 'legacy-world-data\n' > /tmp/legacy-source/World/level.dat
tar -czf /tmp/legacy-backup.tar.gz -C /tmp/legacy-source .
gtnhctl legacy-restore /tmp/legacy-backup.tar.gz --dry-run >/dev/null
gtnhctl legacy-restore /tmp/legacy-backup.tar.gz --target /tmp/legacy-restore
[[ "$(cat /tmp/legacy-restore/World/level.dat)" == "legacy-world-data" ]]

gtnhctl doctor

echo "gtnhctl smoke tests passed."
